import Foundation
import RelayCore

/// ``RelayStorage`` on one DynamoDB table, for the Lambda relay.
///
/// Many short-lived Lambda instances serve the same devices at once, so
/// nothing here is read-modify-write of a shared document. The table is keyed
/// `pk` (partition) + `sk` (sort):
///
/// | pk               | sk                     | holds                                  |
/// |------------------|------------------------|----------------------------------------|
/// | `device#<id>`    | `registration`         | `apnsToken?`, `registeredAt`           |
/// | `device#<id>`    | `push#<time>#<nonce>`  | `body` (binary), `contentEncoding?`, `receivedAt`, `expiresAt` |
///
/// * A push is its own item, so two webhooks landing on two instances both
///   survive; the sort key keeps them in arrival order.
/// * Each push carries `expiresAt` for DynamoDB TTL. The queue only matters
///   for the app's verification poll, which comes within minutes, so a day
///   is generous and keeps the table from growing without bound.
/// * The 50-entry cap is enforced on read (newest 50) and trimmed on drain;
///   TTL does the rest. Trimming on every webhook would cost a query per push.
public struct DynamoDBRelayStore: RelayStorage {
    let transport: any AWSJSONTransport
    let table: String
    let pendingTTL: TimeInterval
    let now: @Sendable () -> Date

    public init(
        transport: any AWSJSONTransport,
        table: String,
        pendingTTL: TimeInterval = 24 * 3600,
        now: @escaping @Sendable () -> Date = { .now }
    ) {
        self.transport = transport
        self.table = table
        self.pendingTTL = pendingTTL
        self.now = now
    }

    static func partitionKey(_ deviceId: String) -> String { "device#\(deviceId)" }
    static let registrationKey = "registration"
    static let pushPrefix = "push#"

    // MARK: - Registrations

    public func register(_ registration: DeviceRegistration) async throws {
        var item: [String: Any] = [
            "pk": ["S": Self.partitionKey(registration.deviceId)],
            "sk": ["S": Self.registrationKey],
            "deviceId": ["S": registration.deviceId],
            "registeredAt": ["N": Self.number(registration.registeredAt)],
        ]
        if let token = registration.apnsToken {
            item["apnsToken"] = ["S": token]
        }
        _ = try await dynamo("PutItem", ["TableName": table, "Item": item])
    }

    public func registration(deviceId: String) async throws -> DeviceRegistration? {
        let response = try await dynamo("GetItem", [
            "TableName": table,
            "Key": registrationKey(deviceId),
            "ConsistentRead": true,
        ])
        guard let item = response["Item"] as? [String: Any] else { return nil }
        return try Self.decodeRegistration(item, deviceId: deviceId)
    }

    public func unregister(deviceId: String) async throws -> Bool {
        let response = try await dynamo("DeleteItem", [
            "TableName": table,
            "Key": registrationKey(deviceId),
            "ReturnValues": "ALL_OLD",
        ])
        guard response["Attributes"] != nil else { return false }
        // Discard the queue with the registration, as the file store does.
        _ = try await drain(deviceId: deviceId)
        return true
    }

    public func invalidateAPNsToken(deviceId: String, token: String) async throws {
        do {
            _ = try await dynamo("UpdateItem", [
                "TableName": table,
                "Key": registrationKey(deviceId),
                "UpdateExpression": "REMOVE apnsToken",
                // Only the token APNs rejected: a device that re-registered
                // with a fresh one in the meantime must keep it.
                "ConditionExpression": "apnsToken = :token",
                "ExpressionAttributeValues": [":token": ["S": token]],
            ])
        } catch AWSError.service(_, "ConditionalCheckFailedException", _) {
            // Already gone or already replaced: nothing to do.
        }
    }

    // MARK: - Pending queue

    public func enqueue(deviceId: String, push: PendingPush) async throws {
        let receivedAt = push.receivedAt
        let sortKey = Self.pushSortKey(receivedAt: receivedAt, nonce: UUID().uuidString)
        var item: [String: Any] = [
            "pk": ["S": Self.partitionKey(deviceId)],
            "sk": ["S": sortKey],
            "body": ["B": push.body.base64EncodedString()],
            "receivedAt": ["N": Self.number(receivedAt)],
            "expiresAt": ["N": String(Int(now().addingTimeInterval(pendingTTL).timeIntervalSince1970))],
        ]
        if let encoding = push.contentEncoding {
            item["contentEncoding"] = ["S": encoding]
        }
        _ = try await dynamo("PutItem", ["TableName": table, "Item": item])
    }

    public func drain(deviceId: String) async throws -> [PendingPush] {
        let items = try await pushItems(deviceId: deviceId)
        let expiryCutoff = Int(now().timeIntervalSince1970)
        // TTL deletion lags by hours; an expired item is already gone in
        // spirit and must not be handed out.
        let live = items.filter { item in
            guard let expires = Self.int(item["expiresAt"]) else { return true }
            return expires > expiryCutoff
        }
        let pushes = try live.map(Self.decodePush)
        try await delete(items.compactMap { ($0["sk"] as? [String: Any])?["S"] as? String }, deviceId: deviceId)
        return Array(pushes.suffix(RelayLimits.maxPendingPerDevice))
    }

    public func isReady() async -> Bool { true }

    // MARK: - Helpers

    private func registrationKey(_ deviceId: String) -> [String: Any] {
        ["pk": ["S": Self.partitionKey(deviceId)], "sk": ["S": Self.registrationKey]]
    }

    private func pushItems(deviceId: String) async throws -> [[String: Any]] {
        var items: [[String: Any]] = []
        var startKey: [String: Any]?
        repeat {
            var request: [String: Any] = [
                "TableName": table,
                "KeyConditionExpression": "pk = :pk AND begins_with(sk, :prefix)",
                "ExpressionAttributeValues": [
                    ":pk": ["S": Self.partitionKey(deviceId)],
                    ":prefix": ["S": Self.pushPrefix],
                ],
                "ConsistentRead": true,
            ]
            if let startKey { request["ExclusiveStartKey"] = startKey }
            let response = try await dynamo("Query", request)
            items += response["Items"] as? [[String: Any]] ?? []
            startKey = response["LastEvaluatedKey"] as? [String: Any]
        } while startKey != nil
        return items
    }

    /// BatchWriteItem takes 25 at a time and may hand some back unprocessed.
    private func delete(_ sortKeys: [String], deviceId: String) async throws {
        var remaining = sortKeys.map { sortKey -> [String: Any] in
            ["DeleteRequest": ["Key": ["pk": ["S": Self.partitionKey(deviceId)], "sk": ["S": sortKey]]]]
        }
        var attempts = 0
        while !remaining.isEmpty {
            let batch = Array(remaining.prefix(25))
            remaining.removeFirst(batch.count)
            let response = try await dynamo("BatchWriteItem", ["RequestItems": [table: batch]])
            if let unprocessed = (response["UnprocessedItems"] as? [String: Any])?[table] as? [[String: Any]],
                !unprocessed.isEmpty
            {
                attempts += 1
                guard attempts <= 5 else {
                    throw AWSError.malformedResponse("BatchWriteItem left \(unprocessed.count) items unprocessed")
                }
                try await Task.sleep(for: .milliseconds(50 * attempts))
                remaining += unprocessed
            }
        }
    }

    private func dynamo(_ operation: String, _ body: [String: Any]) async throws -> [String: Any] {
        try await transport.call(service: "dynamodb", target: "DynamoDB_20120810.\(operation)", body: body)
    }

    /// `push#<zero-padded microseconds>#<nonce>`: sorts by arrival, and the
    /// nonce keeps two pushes in the same microsecond from colliding.
    static func pushSortKey(receivedAt: Date, nonce: String) -> String {
        let micros = max(0, Int64(receivedAt.timeIntervalSince1970 * 1_000_000))
        let padded = String(micros).leftPadded(to: 17)
        return "\(pushPrefix)\(padded)#\(nonce)"
    }

    static func number(_ date: Date) -> String {
        String(date.timeIntervalSince1970)
    }

    static func int(_ attribute: Any?) -> Int? {
        ((attribute as? [String: Any])?["N"] as? String).flatMap { Int($0) ?? Double($0).map { Int($0) } }
    }

    static func date(_ attribute: Any?) -> Date? {
        ((attribute as? [String: Any])?["N"] as? String).flatMap(Double.init).map(Date.init(timeIntervalSince1970:))
    }

    static func decodeRegistration(_ item: [String: Any], deviceId: String) throws -> DeviceRegistration {
        DeviceRegistration(
            deviceId: deviceId,
            apnsToken: (item["apnsToken"] as? [String: Any])?["S"] as? String,
            registeredAt: date(item["registeredAt"]) ?? .distantPast
        )
    }

    static func decodePush(_ item: [String: Any]) throws -> PendingPush {
        // Binary attributes travel base64-encoded in DynamoDB's JSON protocol.
        guard let encoded = (item["body"] as? [String: Any])?["B"] as? String,
            let body = Data(base64Encoded: encoded)
        else { throw AWSError.malformedResponse("pending push without a binary body") }
        return PendingPush(
            receivedAt: date(item["receivedAt"]) ?? .distantPast,
            body: body,
            contentEncoding: (item["contentEncoding"] as? [String: Any])?["S"] as? String
        )
    }
}

extension String {
    fileprivate func leftPadded(to width: Int) -> String {
        count >= width ? self : String(repeating: "0", count: width - count) + self
    }
}
