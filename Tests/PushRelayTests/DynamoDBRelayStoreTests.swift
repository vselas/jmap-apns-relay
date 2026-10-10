import Foundation
import Testing

@testable import RelayAWS
@testable import RelayCore

@Suite struct DynamoDBRelayStoreTests {
    func makeStore(
        _ db: FakeDynamoDB, now: @escaping @Sendable () -> Date = { .now }
    ) -> DynamoDBRelayStore {
        DynamoDBRelayStore(transport: db, table: "relay", now: now)
    }

    @Test func registrationRoundTripsAndReplaces() async throws {
        let db = FakeDynamoDB()
        let store = makeStore(db)
        #expect(try await store.registration(deviceId: "d1") == nil)

        let first = DeviceRegistration(deviceId: "d1", registeredAt: Date(timeIntervalSince1970: 1_700_000_000.5))
        try await store.register(first)
        #expect(try await store.registration(deviceId: "d1") == first)

        // The APNs token arrives later; re-registering replaces the item.
        let second = DeviceRegistration(deviceId: "d1", apnsToken: "tok", registeredAt: Date(timeIntervalSince1970: 1_700_000_100))
        try await store.register(second)
        #expect(try await store.registration(deviceId: "d1") == second)
    }

    /// The point of encrypted push: bytes that are not text survive storage.
    @Test func pendingPushesKeepTheirBytesAndOrder() async throws {
        let db = FakeDynamoDB()
        let store = makeStore(db)
        try await store.register(DeviceRegistration(deviceId: "d1"))
        let ciphertext = Data([0x00, 0xFF, 0xFE, 0x80, 0x41, 0x04, 0xC3, 0x28])
        let base = Date(timeIntervalSince1970: 1_700_000_000)
        // Pagination (page size 3) has to stitch these back together in order.
        for index in 0..<7 {
            try await store.enqueue(
                deviceId: "d1",
                push: PendingPush(receivedAt: base.addingTimeInterval(Double(index)), body: Data("p\(index)".utf8))
            )
        }
        try await store.enqueue(
            deviceId: "d1",
            push: PendingPush(receivedAt: base.addingTimeInterval(100), body: ciphertext, contentEncoding: "aes128gcm")
        )

        let drained = try await store.drain(deviceId: "d1")
        #expect(drained.map(\.text) == ["p0", "p1", "p2", "p3", "p4", "p5", "p6", nil])
        #expect(drained.last?.body == ciphertext)
        #expect(drained.last?.isEncrypted == true)
        // Drained means gone — and the registration is untouched.
        #expect(try await store.drain(deviceId: "d1").isEmpty)
        #expect(try await store.registration(deviceId: "d1") != nil)
    }

    /// Two webhooks in the same instant must both land: one item per push
    /// is the reason the store has no shared queue document to race on.
    @Test func simultaneousPushesDoNotOverwriteEachOther() async throws {
        let db = FakeDynamoDB()
        let store = makeStore(db)
        let instant = Date(timeIntervalSince1970: 1_700_000_000)
        await withTaskGroup(of: Void.self) { group in
            for index in 0..<20 {
                group.addTask {
                    try? await store.enqueue(
                        deviceId: "d1", push: PendingPush(receivedAt: instant, body: Data("p\(index)".utf8))
                    )
                }
            }
        }
        #expect(try await store.drain(deviceId: "d1").count == 20)
    }

    @Test func drainHandsOutOnlyTheNewestFiftyAndClearsTheRest() async throws {
        let db = FakeDynamoDB()
        await db.setUnprocessedOnFirstBatch(4)
        let store = makeStore(db)
        let base = Date(timeIntervalSince1970: 1_700_000_000)
        for index in 0..<60 {
            try await store.enqueue(
                deviceId: "d1", push: PendingPush(receivedAt: base.addingTimeInterval(Double(index)), body: Data("p\(index)".utf8))
            )
        }
        let drained = try await store.drain(deviceId: "d1")
        #expect(drained.count == RelayLimits.maxPendingPerDevice)
        #expect(drained.first?.text == "p10")
        #expect(drained.last?.text == "p59")
        // All 60 deleted, across three batches and one retry of the four
        // DynamoDB handed back.
        #expect(await db.itemCount == 0)
    }

    @Test func expiredPushesAreNotHandedOut() async throws {
        let db = FakeDynamoDB()
        let clock = Clock()
        let store = DynamoDBRelayStore(transport: db, table: "relay", pendingTTL: 60, now: { clock.now })
        try await store.enqueue(deviceId: "d1", push: PendingPush(body: Data("old".utf8)))
        clock.advance(by: 120)
        try await store.enqueue(deviceId: "d1", push: PendingPush(body: Data("new".utf8)))
        #expect(try await store.drain(deviceId: "d1").map(\.text) == ["new"])
        #expect(await db.itemCount == 0)
    }

    @Test func pendingItemsCarryATTL() async throws {
        let db = FakeDynamoDB()
        let fixed = Date(timeIntervalSince1970: 1_700_000_000)
        let store = DynamoDBRelayStore(transport: db, table: "relay", pendingTTL: 3600, now: { fixed })
        try await store.enqueue(deviceId: "d1", push: PendingPush(receivedAt: fixed, body: Data("x".utf8)))
        // One push item exists, and its expiry is now + TTL in epoch seconds.
        let queried = try await db.call(service: "dynamodb", target: "DynamoDB_20120810.Query", body: [
            "TableName": "relay",
            "KeyConditionExpression": "pk = :pk AND begins_with(sk, :prefix)",
            "ExpressionAttributeValues": [":pk": ["S": "device#d1"], ":prefix": ["S": "push#"]],
        ])
        let items = try #require(queried["Items"] as? [[String: Any]])
        #expect(items.count == 1)
        #expect(DynamoDBRelayStore.int(items[0]["expiresAt"]) == 1_700_003_600)
    }

    @Test func unregisterRemovesTheRegistrationAndItsQueue() async throws {
        let db = FakeDynamoDB()
        let store = makeStore(db)
        #expect(try await store.unregister(deviceId: "d1") == false)
        try await store.register(DeviceRegistration(deviceId: "d1"))
        try await store.enqueue(deviceId: "d1", push: PendingPush(body: Data("x".utf8)))
        #expect(try await store.unregister(deviceId: "d1") == true)
        #expect(try await store.registration(deviceId: "d1") == nil)
        #expect(await db.itemCount == 0)
    }

    /// A device that re-registered with a fresh token while the rejected
    /// send was in flight keeps the fresh one.
    @Test func invalidatingATokenOnlyClearsThatToken() async throws {
        let db = FakeDynamoDB()
        let store = makeStore(db)
        try await store.register(DeviceRegistration(deviceId: "d1", apnsToken: "fresh"))
        try await store.invalidateAPNsToken(deviceId: "d1", token: "stale")
        #expect(try await store.registration(deviceId: "d1")?.apnsToken == "fresh")

        try await store.invalidateAPNsToken(deviceId: "d1", token: "fresh")
        let cleared = try #require(try await store.registration(deviceId: "d1"))
        #expect(cleared.apnsToken == nil)
        // An unknown device is not an error either.
        try await store.invalidateAPNsToken(deviceId: "nobody", token: "x")
    }

    @Test func sortKeysOrderByTime() {
        let early = DynamoDBRelayStore.pushSortKey(receivedAt: Date(timeIntervalSince1970: 9), nonce: "b")
        let late = DynamoDBRelayStore.pushSortKey(receivedAt: Date(timeIntervalSince1970: 10), nonce: "a")
        #expect(early < late)
        #expect(early.hasPrefix(DynamoDBRelayStore.pushPrefix))
    }

    @Test func serviceErrorsLoseTheirNamespace() {
        let error = SignedAWSTransport.serviceError(status: 400, object: [
            "__type": "com.amazonaws.dynamodb.v20120810#ConditionalCheckFailedException",
            "message": "The conditional request failed",
        ])
        #expect(error == .service(status: 400, type: "ConditionalCheckFailedException", message: "The conditional request failed"))
    }
}

@Suite struct ParameterStoreTests {
    @Test func parametersBecomeTheirVariables() async throws {
        let db = FakeDynamoDB()
        await db.setParameters(["/relay/token": "s3cret", "/relay/key": "-----BEGIN PRIVATE KEY-----"])
        let resolved = try await ParameterStore.resolve(
            environment: [
                "RELAY_AUTH_TOKEN_PARAMETER": "/relay/token",
                "APNS_KEY_PARAMETER": "/relay/key",
                "APNS_KEY_ID": "ABC",
            ],
            transport: db
        )
        #expect(resolved["RELAY_AUTH_TOKEN"] == "s3cret")
        #expect(resolved["APNS_KEY"] == "-----BEGIN PRIVATE KEY-----")
        #expect(resolved["APNS_KEY_ID"] == "ABC")
        #expect(await db.calls == ["GetParameters"])
    }

    @Test func aPlainValueWinsAndSkipsTheCall() async throws {
        let db = FakeDynamoDB()
        let resolved = try await ParameterStore.resolve(
            environment: ["RELAY_AUTH_TOKEN": "local", "RELAY_AUTH_TOKEN_PARAMETER": "/relay/token"],
            transport: db
        )
        #expect(resolved["RELAY_AUTH_TOKEN"] == "local")
        #expect(await db.calls.isEmpty)
    }

    /// A missing secret must stop the cold start, not start a relay that
    /// silently has no token.
    @Test func aMissingParameterFailsLoudly() async throws {
        let db = FakeDynamoDB()
        await #expect(throws: ParameterStore.ParameterError.missing(["/relay/token"])) {
            _ = try await ParameterStore.resolve(
                environment: ["RELAY_AUTH_TOKEN_PARAMETER": "/relay/token"], transport: db
            )
        }
    }
}

/// A clock tests can move.
final class Clock: @unchecked Sendable {
    private let lock = NSLock()
    private var current = Date(timeIntervalSince1970: 1_700_000_000)
    var now: Date { lock.withLock { current } }
    func advance(by seconds: TimeInterval) { lock.withLock { current = current.addingTimeInterval(seconds) } }
}

@Suite struct AWSEnvironmentTests {
    @Test func readsTheLambdaRoleAndEndpointOverrides() throws {
        let environment = try AWSEnvironment(environment: [
            "AWS_REGION": "eu-central-1",
            "AWS_ACCESS_KEY_ID": "AKIA",
            "AWS_SECRET_ACCESS_KEY": "secret",
            "AWS_SESSION_TOKEN": "session",
            "AWS_ENDPOINT_URL_DYNAMODB": "http://localhost:8000",
        ])
        #expect(environment.credential.sessionToken == "session")
        #expect(environment.endpoint(for: "dynamodb")?.absoluteString == "http://localhost:8000")
        #expect(environment.endpoint(for: "ssm")?.absoluteString == "https://ssm.eu-central-1.amazonaws.com/")
    }

    @Test func missingCredentialsStopTheColdStart() {
        #expect(throws: AWSError.missingCredentials) {
            _ = try AWSEnvironment(environment: ["AWS_REGION": "eu-central-1"])
        }
    }
}
