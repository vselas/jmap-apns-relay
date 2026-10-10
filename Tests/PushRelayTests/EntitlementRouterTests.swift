import Foundation
import Hummingbird
import HummingbirdTesting
import NIOCore
import Testing

@testable import RelayAWS
@testable import RelayCore

/// A verifier that believes proofs of the form `valid:<id>:<expiresIn>` and
/// nothing else, so the router's rules can be tested apart from Apple's.
struct StubVerifier: EntitlementVerifier {
    var now: Date = Date(timeIntervalSince1970: 1_700_000_000)

    func verify(_ proof: EntitlementProof) async throws -> Entitlement {
        guard case .signedTransaction(let text) = proof else { throw EntitlementError.invalidProof("kind") }
        let parts = text.split(separator: ":")
        if parts.first == "retry" { throw EntitlementError.retryable("ocsp") }
        guard parts.count == 3, parts[0] == "valid", let seconds = Double(parts[2]) else {
            throw EntitlementError.invalidProof("stub")
        }
        return Entitlement(
            originalTransactionId: String(parts[1]), productId: "pro",
            expiresAt: now.addingTimeInterval(seconds), signedAt: now
        )
    }

    /// `notify:<id>:<expiresIn>:<signedOffset>[:revoked]`
    func verifyNotification(signedPayload: String) async throws -> Entitlement? {
        let parts = signedPayload.split(separator: ":")
        if parts.first == "test" { return nil }
        if parts.first == "retry" { throw EntitlementError.retryable("ocsp") }
        guard parts.count >= 4, parts[0] == "notify", let seconds = Double(parts[2]), let offset = Double(parts[3]) else {
            throw EntitlementError.invalidProof("stub")
        }
        return Entitlement(
            originalTransactionId: String(parts[1]), productId: "pro",
            expiresAt: now.addingTimeInterval(seconds),
            revokedAt: parts.count > 4 ? now : nil,
            signedAt: now.addingTimeInterval(offset)
        )
    }
}

private actor CountingSender: PushSender {
    private(set) var deliveries: [String] = []
    func send(_ push: PendingPush, to registration: DeviceRegistration) async -> DeliveryOutcome {
        deliveries.append(registration.deviceId)
        return .delivered
    }
}

/// Runs every rule against both stores: they must agree.
enum StoreKind: CaseIterable, CustomTestStringConvertible {
    case file, dynamo
    func make() throws -> any RelayStorage {
        switch self {
        case .file: try RelayStore(persistenceURL: nil)
        case .dynamo: DynamoDBRelayStore(transport: FakeDynamoDB(), table: "relay")
        }
    }
    var testDescription: String { self == .file ? "file" : "dynamodb" }
}

@Suite struct EntitlementRouterTests {
    static let now = Date(timeIntervalSince1970: 1_700_000_000)
    let clock = Clock()

    private func makeApp(store: any RelayStorage, sender: any PushSender, maxDevices: Int = 2)
        -> Application<RouterResponder<BasicRequestContext>>
    {
        let policy = EntitlementPolicy(verifier: StubVerifier(), maxDevicesPerEntitlement: maxDevices, grace: 60)
        let clock = self.clock
        return Application(
            router: buildRouter(store: store, sender: sender, authToken: "s3cret", entitlements: policy, now: { clock.now })
        )
    }

    private func register(_ client: some TestClientProtocol, _ device: String, proof: String? = nil, token: String = "tok") async throws -> (HTTPResponse.Status, String) {
        var body: [String: String] = ["deviceId": device, "apnsToken": token]
        if let proof { body["signedTransaction"] = proof }
        let response = try await client.execute(
            uri: "/v1/register", method: .post,
            headers: [.authorization: "Bearer s3cret", .contentType: "application/json"],
            body: ByteBuffer(data: try JSONSerialization.data(withJSONObject: body))
        )
        return (response.status, String(buffer: response.body))
    }

    private func notify(_ client: some TestClientProtocol, _ payload: String) async throws -> HTTPResponse.Status {
        try await client.execute(
            uri: "/v1/appstore/notifications", method: .post,
            headers: [.contentType: "application/json"],
            body: ByteBuffer(string: #"{"signedPayload":"\#(payload)"}"#)
        ).status
    }

    private func push(_ client: some TestClientProtocol, _ device: String) async throws -> HTTPResponse.Status {
        try await client.execute(
            uri: "/v1/push/\(device)", method: .post, body: ByteBuffer(string: #"{"@type":"StateChange"}"#)
        ).status
    }

    @Test(arguments: StoreKind.allCases)
    func registrationNeedsAValidProofOnce(_ kind: StoreKind) async throws {
        let store = try kind.make()
        let app = makeApp(store: store, sender: CountingSender())
        try await app.test(.router) { client in
            let (missing, missingBody) = try await register(client, "d1")
            #expect(missing.code == 402)
            #expect(missingBody.contains("entitlementRequired"))

            let (forged, forgedBody) = try await register(client, "d1", proof: "forged")
            #expect(forged.code == 402)
            #expect(forgedBody.contains("entitlementInvalid"))

            let (retry, _) = try await register(client, "d1", proof: "retry")
            #expect(retry == .serviceUnavailable)

            #expect(try await register(client, "d1", proof: "valid:sub1:3600").0 == .noContent)
            // A later launch with a new APNs token needs no proof.
            #expect(try await register(client, "d1", token: "tok2").0 == .noContent)
        }
        let registration = try #require(try await store.registration(deviceId: "d1"))
        #expect(registration.entitlementId == "sub1")
        #expect(registration.apnsToken == "tok2")
    }

    @Test(arguments: StoreKind.allCases)
    func oneSubscriptionCoversALimitedNumberOfDevices(_ kind: StoreKind) async throws {
        let app = makeApp(store: try kind.make(), sender: CountingSender(), maxDevices: 2)
        try await app.test(.router) { client in
            #expect(try await register(client, "d1", proof: "valid:sub1:3600").0 == .noContent)
            #expect(try await register(client, "d2", proof: "valid:sub1:3600").0 == .noContent)
            let (third, body) = try await register(client, "d3", proof: "valid:sub1:3600")
            #expect(third == .forbidden)
            #expect(body.contains("deviceLimitReached"))
            // Devices already in keep re-registering.
            #expect(try await register(client, "d2", proof: "valid:sub1:3600").0 == .noContent)
            // Another subscription is its own budget.
            #expect(try await register(client, "d3", proof: "valid:sub2:3600").0 == .noContent)
        }
    }

    @Test(arguments: StoreKind.allCases)
    func pushReachesAPNsOnlyWhilePaid(_ kind: StoreKind) async throws {
        let store = try kind.make()
        let sender = CountingSender()
        let app = makeApp(store: store, sender: sender)
        try await app.test(.router) { client in
            #expect(try await register(client, "d1", proof: "valid:sub1:3600").0 == .noContent)
            #expect(try await push(client, "d1") == .ok)

            // An hour and a bit later: past the period, inside the grace.
            clock.advance(by: 3630)
            #expect(try await push(client, "d1") == .ok)
            // Past the grace: still 200 to the server, but no APNs send.
            clock.advance(by: 60)
            #expect(try await push(client, "d1") == .ok)
            let (expired, body) = try await register(client, "d1")
            #expect(expired.code == 402)
            #expect(body.contains("entitlementExpired"))
        }
        #expect(await sender.deliveries == ["d1", "d1"])
    }

    /// Setting push up must work before anyone pays: the subscription's
    /// verification code still reaches the app's poll.
    @Test(arguments: StoreKind.allCases)
    func theVerificationPollWorksForALapsedDevice(_ kind: StoreKind) async throws {
        let store = try kind.make()
        let sender = CountingSender()
        try await store.register(DeviceRegistration(deviceId: "d1", apnsToken: "tok"))
        let app = makeApp(store: store, sender: sender)
        try await app.test(.router) { client in
            #expect(try await push(client, "d1") == .ok)
            let pending = try await client.execute(
                uri: "/v1/pending/d1", method: .get, headers: [.authorization: "Bearer s3cret"]
            )
            let items = try JSONDecoder().decode([PendingPush].self, from: Data(buffer: pending.body))
            #expect(items.count == 1)
        }
        #expect(await sender.deliveries.isEmpty)
    }

    @Test(arguments: StoreKind.allCases)
    func serverNotificationsDriveTheEntitlement(_ kind: StoreKind) async throws {
        let store = try kind.make()
        let sender = CountingSender()
        let app = makeApp(store: store, sender: sender)
        try await app.test(.router) { client in
            let r1 = try await register(client, "d1", proof: "valid:sub1:60")
            #expect(r1.0 == .noContent)
            // Renewed for a year, signed a minute later.
            let r2 = try await notify(client, "notify:sub1:31536000:60")
            #expect(r2 == .ok)
            clock.advance(by: 86400)
            let r3 = try await push(client, "d1")
            #expect(r3 == .ok)

            // A stale notification from before the renewal changes nothing.
            let r4 = try await notify(client, "notify:sub1:10:30:revoked")
            #expect(r4 == .ok)
            let r5 = try await push(client, "d1")
            #expect(r5 == .ok)

            // A newer refund ends it.
            let r6 = try await notify(client, "notify:sub1:31536000:120:revoked")
            #expect(r6 == .ok)
            let r7 = try await push(client, "d1")
            #expect(r7 == .ok)

            let r8 = try await notify(client, "test")
            #expect(r8 == .ok)
            let r9 = try await notify(client, "forged")
            #expect(r9 == .badRequest)
            // Apple retries a 5xx, which is right for a transient failure.
            let r10 = try await notify(client, "retry")
            #expect(r10 == .serviceUnavailable)
        }
        #expect(await sender.deliveries == ["d1", "d1"])
        let stored = try #require(try await store.entitlement(id: "sub1"))
        #expect(stored.revokedAt != nil)
    }

    @Test func capabilitiesAdvertiseTheRequirement() async throws {
        let app = makeApp(store: try RelayStore(persistenceURL: nil), sender: CountingSender())
        try await app.test(.router) { client in
            let response = try await client.execute(uri: "/v1/capabilities", method: .get)
            #expect(String(buffer: response.body).contains("appStoreEntitlement"))
        }
        let open = Application(router: buildRouter(store: try RelayStore(persistenceURL: nil), sender: CountingSender()))
        try await open.test(.router) { client in
            let response = try await client.execute(uri: "/v1/capabilities", method: .get)
            #expect(!String(buffer: response.body).contains("appStoreEntitlement"))
            // And no notification endpoint where nothing is sold.
            let notification = try await client.execute(uri: "/v1/appstore/notifications", method: .post)
            #expect(notification.status == .notFound)
        }
    }

    @Test func entitlementsSurviveARestartOfTheFileStore() async throws {
        let url = FileManager.default.temporaryDirectory.appending(path: "\(UUID().uuidString)/relay.json")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let store = try RelayStore(persistenceURL: url)
        try await store.upsertEntitlement(Entitlement(originalTransactionId: "sub1", productId: "pro", expiresAt: Self.now, signedAt: Self.now))
        try await store.register(DeviceRegistration(deviceId: "d1", entitlementId: "sub1"))
        let reopened = try RelayStore(persistenceURL: url)
        let entitlement = try await reopened.entitlement(id: "sub1")
        let devices = try await reopened.devices(entitlementId: "sub1")
        #expect(entitlement?.expiresAt == Self.now)
        #expect(devices == ["d1"])
    }

    /// A snapshot from before entitlements existed still opens.
    @Test func aPreEntitlementSnapshotStillReads() async throws {
        let url = FileManager.default.temporaryDirectory.appending(path: "\(UUID().uuidString)/relay.json")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(#"{"version":1,"registrations":{"d1":{"deviceId":"d1","registeredAt":0}},"pending":{}}"#.utf8).write(to: url)
        let store = try RelayStore(persistenceURL: url)
        #expect(try await store.registration(deviceId: "d1")?.entitlementId == nil)
    }
}
