import Foundation
import Hummingbird
import HummingbirdTesting
import Testing

@testable import RelayCore

@Suite struct RelayTests {
    func makeApp(authToken: String? = nil) throws -> Application<RouterResponder<BasicRequestContext>> {
        let store = try RelayStore(persistenceURL: nil)
        return Application(
            router: buildRouter(store: store, sender: LogPushSender(), authToken: authToken)
        )
    }

    @Test func registerThenPushThenPoll() async throws {
        let app = try makeApp()
        try await app.test(.router) { client in
            // Unregistered device: webhook is rejected.
            let rejected = try await client.execute(
                uri: "/v1/push/dev1", method: .post,
                body: ByteBuffer(string: #"{"@type":"StateChange"}"#)
            )
            #expect(rejected.status == .notFound)

            // Register, push, poll.
            let registered = try await client.execute(
                uri: "/v1/register", method: .post,
                body: ByteBuffer(string: #"{"deviceId":"dev1"}"#)
            )
            #expect(registered.status == .noContent)

            let verification = #"{"@type":"PushVerification","pushSubscriptionId":"ps1","verificationCode":"code-123"}"#
            let pushed = try await client.execute(
                uri: "/v1/push/dev1", method: .post,
                body: ByteBuffer(string: verification)
            )
            #expect(pushed.status == .ok)

            let pending = try await client.execute(uri: "/v1/pending/dev1", method: .get)
            #expect(pending.status == .ok)
            let items = try JSONDecoder().decode(
                [PendingPush].self, from: Data(buffer: pending.body)
            )
            #expect(items.count == 1)
            #expect(items[0].text?.contains("code-123") == true)
            #expect(!items[0].isEncrypted)

            // Drained: second poll is empty.
            let drained = try await client.execute(uri: "/v1/pending/dev1", method: .get)
            let empty = try JSONDecoder().decode([PendingPush].self, from: Data(buffer: drained.body))
            #expect(empty.isEmpty)
        }
    }

    /// The whole point of encrypted push: bytes the relay cannot read must
    /// survive the round trip unchanged. Reading the body as a `String`
    /// returned nil for binary and silently queued an empty payload.
    @Test func anEncryptedBodySurvivesByteForByte() async throws {
        let app = try makeApp()
        // Not valid UTF-8 — an aes128gcm payload generally is not.
        let ciphertext = Data([0x00, 0xFF, 0xFE, 0x80, 0x41, 0x04, 0xC3, 0x28, 0x7B, 0x00])
        try await app.test(.router) { client in
            _ = try await client.execute(
                uri: "/v1/register", method: .post,
                body: ByteBuffer(string: #"{"deviceId":"dev1"}"#)
            )
            let pushed = try await client.execute(
                uri: "/v1/push/dev1", method: .post,
                headers: [.contentEncoding: "aes128gcm"],
                body: ByteBuffer(data: ciphertext)
            )
            #expect(pushed.status == .ok)

            let pending = try await client.execute(uri: "/v1/pending/dev1", method: .get)
            let items = try JSONDecoder().decode(
                [PendingPush].self, from: Data(buffer: pending.body)
            )
            #expect(items.count == 1)
            #expect(items[0].body == ciphertext)
            #expect(items[0].isEncrypted)
            // And it refuses to hand ciphertext back as if it were text.
            #expect(items[0].text == nil)
        }
    }

    @Test func healthz() async throws {
        let app = try makeApp()
        try await app.test(.router) { client in
            let response = try await client.execute(uri: "/healthz", method: .get)
            #expect(response.status == .ok)
        }
    }

    @Test func capabilitiesAndReadinessArePublished() async throws {
        let app = try makeApp()
        try await app.test(.router) { client in
            let ready = try await client.execute(uri: "/readyz", method: .get)
            #expect(ready.status == .ok)

            let response = try await client.execute(uri: "/v1/capabilities", method: .get)
            #expect(response.status == .ok)
            let root = try #require(
                try JSONSerialization.jsonObject(with: Data(buffer: response.body)) as? [String: Any]
            )
            #expect(root["protocol"] as? String == "jmap-apns-relay")
            #expect(root["protocolVersion"] as? Int == 1)
            let features = try #require(root["features"] as? [String])
            #expect(features.contains("encryptedForwarding"))
            #expect(features.contains("unregister"))
            let limits = try #require(root["limits"] as? [String: Any])
            #expect(limits["maxAPNsPayloadBytes"] as? Int == 4_096)
        }
    }

    @Test func unregisterRequiresTokenAndRemovesDevice() async throws {
        let app = try makeApp(authToken: "s3cret")
        try await app.test(.router) { client in
            _ = try await client.execute(
                uri: "/v1/register", method: .post,
                headers: [.authorization: "Bearer s3cret"],
                body: ByteBuffer(string: #"{"deviceId":"dev1"}"#)
            )
            let anonymous = try await client.execute(uri: "/v1/register/dev1", method: .delete)
            #expect(anonymous.status == .unauthorized)
            let removed = try await client.execute(
                uri: "/v1/register/dev1", method: .delete,
                headers: [.authorization: "Bearer s3cret"]
            )
            #expect(removed.status == .noContent)
            let pushed = try await client.execute(uri: "/v1/push/dev1", method: .post)
            #expect(pushed.status == .notFound)
        }
    }

    @Test func invalidDeliveryTokenIsClearedWithoutDeletingRegistration() async throws {
        let store = try RelayStore(persistenceURL: nil)
        let app = Application(router: buildRouter(store: store, sender: InvalidTokenSender()))
        try await app.test(.router) { client in
            _ = try await client.execute(
                uri: "/v1/register", method: .post,
                body: ByteBuffer(string: #"{"deviceId":"dev1","apnsToken":"bad"}"#)
            )
            let pushed = try await client.execute(
                uri: "/v1/push/dev1", method: .post,
                body: ByteBuffer(string: #"{"@type":"StateChange"}"#)
            )
            #expect(pushed.status == .ok)
        }
        #expect(await store.registration(deviceId: "dev1")?.apnsToken == nil)
    }

    /// The launch race, end to end: the app registers before iOS has issued
    /// a token and again once it has, and the tokenless request may land
    /// second. The token has to survive it.
    @Test func aRegistrationWithoutATokenKeepsTheStoredOne() async throws {
        let store = try RelayStore(persistenceURL: nil)
        let app = Application(router: buildRouter(store: store, sender: LogPushSender()))
        try await app.test(.router) { client in
            for body in [#"{"deviceId":"dev1","apnsToken":"tok"}"#, #"{"deviceId":"dev1"}"#] {
                let response = try await client.execute(
                    uri: "/v1/register", method: .post, body: ByteBuffer(string: body)
                )
                #expect(response.status == .noContent)
            }
        }
        #expect(await store.registration(deviceId: "dev1")?.apnsToken == "tok")

        // A new token still replaces the old one.
        try await store.register(DeviceRegistration(deviceId: "dev1", apnsToken: "tok2"))
        #expect(await store.registration(deviceId: "dev1")?.apnsToken == "tok2")
    }

    @Test func registrationLogLinesSayWhatHappenedToTheToken() {
        #expect(registrationSummary(sent: "0123456789abcdef", stored: "0123456789abcdef") == "token …abcdef sent")
        #expect(registrationSummary(sent: nil, stored: "0123456789abcdef") == "no token sent, kept …abcdef")
        #expect(registrationSummary(sent: nil, stored: nil) == "no token sent, none stored")
    }

    @Test func legacySnapshotMigratesAndParentDirectoryIsCreated() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let stateURL = root.appending(path: "nested/relay.json")
        try FileManager.default.createDirectory(at: stateURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let legacy = #"{"registrations":{"dev1":{"deviceId":"dev1","registeredAt":0}},"pending":{}}"#
        try Data(legacy.utf8).write(to: stateURL)

        let store = try RelayStore(persistenceURL: stateURL)
        #expect(await store.registration(deviceId: "dev1") != nil)
        let migrated = try #require(
            try JSONSerialization.jsonObject(with: Data(contentsOf: stateURL)) as? [String: Any]
        )
        #expect(migrated["version"] as? Int == 1)

        let newURL = root.appending(path: "other/deep/relay.json")
        let newStore = try RelayStore(persistenceURL: newURL)
        try await newStore.register(DeviceRegistration(deviceId: "dev2"))
        #expect(FileManager.default.fileExists(atPath: newURL.path))
    }

    @Test func productionConfigurationFailsClosed() throws {
        #expect(throws: RuntimeConfiguration.ConfigurationError.productionRequiresAuthToken) {
            _ = try RuntimeConfiguration(environment: ["RELAY_MODE": "production"])
        }
        #expect(throws: APNsConfiguration.ConfigurationError.incompleteCredentials) {
            _ = try RuntimeConfiguration(environment: [
                "RELAY_MODE": "development",
                "APNS_KEY_PATH": "/key.p8",
            ])
        }
        let development = try RuntimeConfiguration(environment: [:])
        #expect(development.mode == .development)
        #expect(development.apns == nil)
    }

    @Test func queueIsCapped() async throws {
        let store = try RelayStore(persistenceURL: nil)
        try await store.register(DeviceRegistration(deviceId: "d"))
        for index in 0..<60 {
            try await store.enqueue(deviceId: "d", push: PendingPush(body: Data("p\(index)".utf8)))
        }
        let drained = try await store.drain(deviceId: "d")
        #expect(drained.count == 50)
        #expect(drained.first?.text == "p10")
    }

    // MARK: - Authentication

    /// Without a token anyone who can reach the relay can claim a device id,
    /// or re-point an existing one at their own APNs token.
    @Test func registrationRequiresTheTokenWhenOneIsSet() async throws {
        let app = try makeApp(authToken: "s3cret")
        try await app.test(.router) { client in
            let anonymous = try await client.execute(
                uri: "/v1/register", method: .post,
                body: ByteBuffer(string: #"{"deviceId":"dev1"}"#)
            )
            #expect(anonymous.status == .unauthorized)

            let wrong = try await client.execute(
                uri: "/v1/register", method: .post,
                headers: [.authorization: "Bearer nope"],
                body: ByteBuffer(string: #"{"deviceId":"dev1"}"#)
            )
            #expect(wrong.status == .unauthorized)

            let authorized = try await client.execute(
                uri: "/v1/register", method: .post,
                headers: [.authorization: "Bearer s3cret"],
                body: ByteBuffer(string: #"{"deviceId":"dev1"}"#)
            )
            #expect(authorized.status == .noContent)
        }
    }

    @Test func pollingRequiresTheTokenToo() async throws {
        let app = try makeApp(authToken: "s3cret")
        try await app.test(.router) { client in
            _ = try await client.execute(
                uri: "/v1/register", method: .post,
                headers: [.authorization: "Bearer s3cret"],
                body: ByteBuffer(string: #"{"deviceId":"dev1"}"#)
            )
            let anonymous = try await client.execute(uri: "/v1/pending/dev1", method: .get)
            #expect(anonymous.status == .unauthorized)

            let authorized = try await client.execute(
                uri: "/v1/pending/dev1", method: .get,
                headers: [.authorization: "Bearer s3cret"]
            )
            #expect(authorized.status == .ok)
        }
    }

    /// The server's webhook cannot carry our token — Stalwart sends what it
    /// sends — so the unguessable device id stays the capability there.
    @Test func theServerWebhookStaysOpen() async throws {
        let app = try makeApp(authToken: "s3cret")
        try await app.test(.router) { client in
            _ = try await client.execute(
                uri: "/v1/register", method: .post,
                headers: [.authorization: "Bearer s3cret"],
                body: ByteBuffer(string: #"{"deviceId":"dev1"}"#)
            )
            let pushed = try await client.execute(
                uri: "/v1/push/dev1", method: .post,
                body: ByteBuffer(string: #"{"@type":"StateChange"}"#)
            )
            #expect(pushed.status == .ok)
        }
    }

    @Test func noTokenConfiguredMeansEverythingIsAccepted() async throws {
        let app = try makeApp(authToken: nil)
        try await app.test(.router) { client in
            let response = try await client.execute(
                uri: "/v1/register", method: .post,
                body: ByteBuffer(string: #"{"deviceId":"dev1"}"#)
            )
            #expect(response.status == .noContent)
        }
    }

    // MARK: - Pending window

    /// The queue exists for the verification a client polls for while it sets
    /// up push. Every later push went to APNs; keeping it as well cost a write
    /// per change and held a payload for a day that nobody would read.
    @Test func pushesAreKeptOnlyWhileTheDeviceMayAwaitVerification() async throws {
        let store = try RelayStore(persistenceURL: nil)
        let sender = CountingSender()
        let clock = Clock()
        let app = Application(
            router: buildRouter(
                store: store, sender: sender, pendingWindow: 15 * 60, now: { clock.now }
            )
        )
        try await app.test(.router) { client in
            func push(_ text: String) async throws {
                let response = try await client.execute(
                    uri: "/v1/push/dev1", method: .post, body: ByteBuffer(string: text)
                )
                #expect(response.status == .ok)
            }
            func register() async throws {
                _ = try await client.execute(
                    uri: "/v1/register", method: .post,
                    body: ByteBuffer(string: #"{"deviceId":"dev1","apnsToken":"tok"}"#)
                )
            }

            try await register()
            clock.advance(by: 60)
            try await push("verification")
            clock.advance(by: 15 * 60)
            try await push("later")
            #expect(try await store.drain(deviceId: "dev1").map(\.text) == ["verification"])

            // Registering again (a launch, a new token) opens it again.
            try await register()
            try await push("after re-registering")
            #expect(try await store.drain(deviceId: "dev1").map(\.text) == ["after re-registering"])
        }
        // Delivery does not depend on the window.
        #expect(sender.count == 3)
    }

    /// Development has no APNs: the poll is how pushes arrive at all.
    @Test func withoutAWindowEveryPushIsKept() async throws {
        let store = try RelayStore(persistenceURL: nil)
        let clock = Clock()
        let app = Application(
            router: buildRouter(store: store, sender: LogPushSender(), now: { clock.now })
        )
        try await app.test(.router) { client in
            _ = try await client.execute(
                uri: "/v1/register", method: .post, body: ByteBuffer(string: #"{"deviceId":"dev1"}"#)
            )
            clock.advance(by: 7 * 86_400)
            _ = try await client.execute(
                uri: "/v1/push/dev1", method: .post, body: ByteBuffer(string: "much later")
            )
        }
        #expect(try await store.drain(deviceId: "dev1").map(\.text) == ["much later"])
    }

    @Test func theWindowIsPublishedWhenThereIsOne() async throws {
        let app = Application(
            router: buildRouter(
                store: try RelayStore(persistenceURL: nil), sender: LogPushSender(), pendingWindow: 900
            )
        )
        try await app.test(.router) { client in
            let response = try await client.execute(uri: "/v1/capabilities", method: .get)
            let root = try #require(
                try JSONSerialization.jsonObject(with: Data(buffer: response.body)) as? [String: Any]
            )
            let limits = try #require(root["limits"] as? [String: Any])
            #expect(limits["pendingWindowSeconds"] as? Int == 900)
        }
    }

    @Test func theWindowDefaultsByModeAndCanBeSet() throws {
        let production: [String: String] = [
            "RELAY_MODE": "production", "RELAY_AUTH_TOKEN": "t",
            "APNS_KEY": "k", "APNS_KEY_ID": "KEYID12345", "APNS_TEAM_ID": "TEAM123456",
            "APNS_TOPIC": "com.example.app",
        ]
        #expect(try RuntimeConfiguration(environment: production).pendingWindow == 900)
        #expect(try RuntimeConfiguration(environment: [:]).pendingWindow == nil)
        var custom = production
        custom["PENDING_WINDOW_SECONDS"] = "120"
        #expect(try RuntimeConfiguration(environment: custom).pendingWindow == 120)
        custom["PENDING_WINDOW_SECONDS"] = "0"
        #expect(try RuntimeConfiguration(environment: custom).pendingWindow == nil)
        custom["PENDING_WINDOW_SECONDS"] = "soon"
        #expect(throws: RuntimeConfiguration.ConfigurationError.invalidPendingWindow("soon")) {
            _ = try RuntimeConfiguration(environment: custom)
        }
    }

    @Test func tokenComparisonRejectsPrefixesAndLengths() {
        // A `hasPrefix`-style check would let "s3" through.
        #expect(!isAuthorized(request(bearer: "s3"), token: "s3cret"))
        #expect(!isAuthorized(request(bearer: "s3cret-and-more"), token: "s3cret"))
        #expect(!isAuthorized(request(bearer: ""), token: "s3cret"))
        #expect(isAuthorized(request(bearer: "s3cret"), token: "s3cret"))
    }

    private func request(bearer: String) -> Request {
        Request(
            head: .init(
                method: .post, scheme: nil, authority: nil, path: "/v1/register",
                headerFields: [.authorization: "Bearer \(bearer)"]
            ),
            body: .init(buffer: ByteBuffer())
        )
    }
}

private struct InvalidTokenSender: PushSender {
    func send(_ push: PendingPush, to registration: DeviceRegistration) async -> DeliveryOutcome {
        .invalidToken(reason: "Unregistered")
    }
}

/// Counts what it was asked to deliver.
private final class CountingSender: PushSender, @unchecked Sendable {
    private let lock = NSLock()
    private var sent = 0
    var count: Int { lock.withLock { sent } }

    func send(_ push: PendingPush, to registration: DeviceRegistration) async -> DeliveryOutcome {
        lock.withLock { sent += 1 }
        return .delivered
    }
}
