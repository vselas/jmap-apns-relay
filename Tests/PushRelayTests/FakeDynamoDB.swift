import Foundation
import RelayAWS

/// An in-memory DynamoDB that speaks just enough of the JSON protocol for
/// ``DynamoDBRelayStore``: PutItem, GetItem, DeleteItem, UpdateItem (REMOVE
/// with an equality condition), Query (pk = and begins_with on sk, with
/// pagination), and BatchWriteItem deletes. Requests are round-tripped through
/// JSON so a value that would not serialise fails here as it would on AWS.
actor FakeDynamoDB: AWSJSONTransport {
    private var items: [String: [String: [String: Any]]] = [:]  // pk -> sk -> item
    private(set) var calls: [String] = []
    /// Page size for Query, small enough to exercise pagination.
    var pageSize = 3
    /// Items BatchWriteItem hands back as unprocessed on its first call.
    var unprocessedOnFirstBatch = 0
    var parameters: [String: String] = [:]

    func setParameters(_ values: [String: String]) { parameters = values }
    func setUnprocessedOnFirstBatch(_ count: Int) { unprocessedOnFirstBatch = count }

    nonisolated func call(service: String, target: String, body: [String: Any]) async throws -> [String: Any] {
        let data = try JSONSerialization.data(withJSONObject: body)
        let encoded = try await handleEncoded(service: service, target: target, request: data)
        return try JSONSerialization.jsonObject(with: encoded) as? [String: Any] ?? [:]
    }

    /// Bytes across the isolation boundary: `[String: Any]` is not Sendable.
    private func handleEncoded(service: String, target: String, request data: Data) throws -> Data {
        let request = try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
        return try JSONSerialization.data(withJSONObject: handle(service: service, target: target, request: request))
    }

    var itemCount: Int { items.values.reduce(0) { $0 + $1.count } }

    func rawItem(pk: String, sk: String) -> [String: Any]? { items[pk]?[sk] }

    private func handle(service: String, target: String, request: [String: Any]) throws -> [String: Any] {
        let operation = String(target.split(separator: ".").last ?? "")
        calls.append(operation)
        if service == "ssm" {
            let names = request["Names"] as? [String] ?? []
            let found = names.compactMap { name in parameters[name].map { ["Name": name, "Value": $0] } }
            return ["Parameters": found, "InvalidParameters": names.filter { parameters[$0] == nil }]
        }
        switch operation {
        case "PutItem":
            let item = request["Item"] as? [String: Any] ?? [:]
            let (pk, sk) = keys(item)
            items[pk, default: [:]][sk] = item
            return [:]
        case "GetItem":
            let (pk, sk) = keys(request["Key"] as? [String: Any] ?? [:])
            return items[pk]?[sk].map { ["Item": $0] } ?? [:]
        case "DeleteItem":
            let (pk, sk) = keys(request["Key"] as? [String: Any] ?? [:])
            let old = items[pk]?.removeValue(forKey: sk)
            return old.map { ["Attributes": $0] } ?? [:]
        case "UpdateItem":
            let (pk, sk) = keys(request["Key"] as? [String: Any] ?? [:])
            let values = request["ExpressionAttributeValues"] as? [String: Any] ?? [:]
            let expected = (values[":token"] as? [String: Any])?["S"] as? String
            guard var item = items[pk]?[sk],
                (item["apnsToken"] as? [String: Any])?["S"] as? String == expected
            else {
                throw AWSError.service(status: 400, type: "ConditionalCheckFailedException", message: "condition")
            }
            item.removeValue(forKey: "apnsToken")
            items[pk]?[sk] = item
            return [:]
        case "Query":
            let values = request["ExpressionAttributeValues"] as? [String: Any] ?? [:]
            let pk = (values[":pk"] as? [String: Any])?["S"] as? String ?? ""
            let prefix = (values[":prefix"] as? [String: Any])?["S"] as? String ?? ""
            let sorted = (items[pk] ?? [:]).filter { $0.key.hasPrefix(prefix) }.sorted { $0.key < $1.key }
            let after = ((request["ExclusiveStartKey"] as? [String: Any])?["sk"] as? [String: Any])?["S"] as? String
            let remaining = sorted.filter { after == nil || $0.key > after! }
            let page = Array(remaining.prefix(pageSize))
            var response: [String: Any] = ["Items": page.map(\.value)]
            if remaining.count > pageSize, let last = page.last {
                response["LastEvaluatedKey"] = ["pk": ["S": pk], "sk": ["S": last.key]]
            }
            return response
        case "BatchWriteItem":
            let requestItems = request["RequestItems"] as? [String: Any] ?? [:]
            var unprocessed: [String: Any] = [:]
            for (table, writes) in requestItems {
                var writes = writes as? [[String: Any]] ?? []
                precondition(writes.count <= 25, "BatchWriteItem takes at most 25 writes")
                var handBack: [[String: Any]] = []
                if unprocessedOnFirstBatch > 0 {
                    handBack = Array(writes.prefix(unprocessedOnFirstBatch))
                    writes.removeFirst(handBack.count)
                    unprocessedOnFirstBatch = 0
                }
                for write in writes {
                    let key = (write["DeleteRequest"] as? [String: Any])?["Key"] as? [String: Any] ?? [:]
                    let (pk, sk) = keys(key)
                    items[pk]?.removeValue(forKey: sk)
                }
                if !handBack.isEmpty { unprocessed[table] = handBack }
            }
            return ["UnprocessedItems": unprocessed]
        default:
            throw AWSError.service(status: 400, type: "UnknownOperationException", message: operation)
        }
    }

    private func keys(_ item: [String: Any]) -> (String, String) {
        (
            (item["pk"] as? [String: Any])?["S"] as? String ?? "",
            (item["sk"] as? [String: Any])?["S"] as? String ?? ""
        )
    }
}
