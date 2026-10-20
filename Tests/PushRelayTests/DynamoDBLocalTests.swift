import AsyncHTTPClient
import Foundation
import Testing

@testable import RelayAWS
@testable import RelayCore

/// The DynamoDB store against a real DynamoDB (Local), not the fake: the
/// condition expressions, the sparse `byEntitlement` index and binary
/// attributes are exactly where a hand-written fake can be wrong.
///
/// Runs only when `DYNAMODB_LOCAL_URL` points at a DynamoDB Local whose
/// `relay` table has the template's schema; `scripts/test-dynamodb-local.sh`
/// sets that up. Skipped otherwise, so plain `swift test` needs nothing.
@Suite(.enabled(if: ProcessInfo.processInfo.environment["DYNAMODB_LOCAL_URL"] != nil))
struct DynamoDBLocalTests {
    func makeStore() throws -> DynamoDBRelayStore {
        let url = try #require(ProcessInfo.processInfo.environment["DYNAMODB_LOCAL_URL"].flatMap(URL.init(string:)))
        let environment = AWSEnvironment(
            region: "eu-central-1",
            credential: .init(accessKeyId: "test", secretAccessKey: "test"),
            endpoints: ["dynamodb": url]
        )
        return DynamoDBRelayStore(
            transport: SignedAWSTransport(environment: environment, httpClient: .shared),
            table: ProcessInfo.processInfo.environment["DYNAMODB_LOCAL_TABLE"] ?? "relay"
        )
    }

    /// Unique per run, so reruns against a long-lived table do not collide.
    let run = UUID().uuidString.prefix(8)

    @Test func entitlementWritesKeepTheNewest() async throws {
        let store = try makeStore()
        let id = "sub-\(run)"
        let base = Date(timeIntervalSince1970: 1_700_000_000)
        let renewed = Entitlement(originalTransactionId: id, productId: "pro", expiresAt: base.addingTimeInterval(86400 * 365), signedAt: base.addingTimeInterval(60))
        let stale = Entitlement(originalTransactionId: id, productId: "pro", expiresAt: base, revokedAt: base, signedAt: base)

        #expect(try await store.upsertEntitlement(renewed) == renewed)
        // An older notification arriving late is refused by the condition
        // and the stored, newer value comes back.
        #expect(try await store.upsertEntitlement(stale) == renewed)
        #expect(try await store.entitlement(id: id) == renewed)

        let refund = Entitlement(originalTransactionId: id, productId: "pro", expiresAt: renewed.expiresAt, revokedAt: base.addingTimeInterval(120), signedAt: base.addingTimeInterval(120))
        #expect(try await store.upsertEntitlement(refund) == refund)
        let stored = try #require(try await store.entitlement(id: id))
        #expect(stored.revokedAt == refund.revokedAt)
        #expect(!stored.isActive(at: base))
    }

    @Test func theIndexCountsASubscriptionsDevices() async throws {
        let store = try makeStore()
        let id = "sub-\(run)-devices"
        try await store.register(DeviceRegistration(deviceId: "\(run)-a", apnsToken: "t", entitlementId: id))
        try await store.register(DeviceRegistration(deviceId: "\(run)-b", entitlementId: id))
        try await store.register(DeviceRegistration(deviceId: "\(run)-free"))
        // Global secondary indexes are eventually consistent; Local is quick.
        var devices: [String] = []
        for _ in 0..<20 {
            devices = try await store.devices(entitlementId: id)
            if devices.count == 2 { break }
            try await Task.sleep(for: .milliseconds(100))
        }
        #expect(devices == ["\(run)-a", "\(run)-b"])

        // Moving a device off the subscription drops it from the count.
        try await store.register(DeviceRegistration(deviceId: "\(run)-b"))
        for _ in 0..<20 {
            devices = try await store.devices(entitlementId: id)
            if devices.count == 1 { break }
            try await Task.sleep(for: .milliseconds(100))
        }
        #expect(devices == ["\(run)-a"])
        #expect(try await store.registration(deviceId: "\(run)-a")?.entitlementId == id)
    }

    /// Against the real UpdateItem: the tokenless registration from the app's
    /// launch race must not erase the token the other one stored.
    @Test func aRegistrationWithoutATokenKeepsTheStoredOne() async throws {
        let store = try makeStore()
        let device = "\(run)-keeps-token"
        try await store.register(DeviceRegistration(deviceId: device, apnsToken: "tok"))
        let stored = try await store.register(DeviceRegistration(deviceId: device))
        #expect(stored.apnsToken == "tok")
        #expect(try await store.registration(deviceId: device)?.apnsToken == "tok")
    }

    /// The entitlement's TTL is the end of its retention, never the end of its
    /// period: DynamoDB must not delete it at lapse, or a late renewal would
    /// find nothing to extend.
    @Test func anEntitlementOutlivesItsPeriodByTheRetention() async throws {
        let store = try makeStore()
        let id = "sub-\(run)-ttl"
        try await store.upsertEntitlement(
            Entitlement(originalTransactionId: id, productId: "pro", expiresAt: Date(timeIntervalSince1970: 1), signedAt: Date(timeIntervalSince1970: 1))
        )
        let response = try await store.transport.call(
            service: "dynamodb", target: "DynamoDB_20120810.GetItem",
            body: ["TableName": store.table, "Key": DynamoDBRelayStore.entitlementKey(id), "ConsistentRead": true]
        )
        let item = try #require(response["Item"] as? [String: Any])
        #expect(DynamoDBRelayStore.int(item["expiresAt"]) == 1 + Int(Entitlement.retention))
        #expect(DynamoDBRelayStore.date(item["periodEndsAt"]) == Date(timeIntervalSince1970: 1))
    }

    @Test func pushesRoundTripAgainstRealDynamoDB() async throws {
        let store = try makeStore()
        let device = "\(run)-push"
        let ciphertext = Data((0..<255).map { UInt8($0) })
        try await store.register(DeviceRegistration(deviceId: device))
        try await store.enqueue(deviceId: device, push: PendingPush(body: ciphertext, contentEncoding: "aes128gcm"))
        let drained = try await store.drain(deviceId: device)
        #expect(drained.map(\.body) == [ciphertext])
        #expect(try await store.unregister(deviceId: device))
    }
}
