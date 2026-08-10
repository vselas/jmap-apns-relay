import Foundation
import Hummingbird
import HummingbirdTesting
import Testing

@testable import PushRelay

@Suite struct RelayTests {
    func makeApp(authToken: String? = nil) -> Application<RouterResponder<BasicRequestContext>> {
        let store = RelayStore(persistenceURL: nil)
        return Application(
            router: buildRouter(store: store, sender: LogPushSender(), authToken: authToken)
        )
    }

    @Test func registerThenPushThenPoll() async throws {
        let app = makeApp()
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
        let app = makeApp()
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
        let app = makeApp()
        try await app.test(.router) { client in
            let response = try await client.execute(uri: "/healthz", method: .get)
            #expect(response.status == .ok)
        }
    }

    @Test func queueIsCapped() async throws {
        let store = RelayStore(persistenceURL: nil)
        await store.register(DeviceRegistration(deviceId: "d"))
        for index in 0..<60 {
            await store.enqueue(deviceId: "d", push: PendingPush(body: Data("p\(index)".utf8)))
        }
        let drained = await store.drain(deviceId: "d")
        #expect(drained.count == 50)
        #expect(drained.first?.text == "p10")
    }

    // MARK: - Authentication

    /// Without a token anyone who can reach the relay can claim a device id,
    /// or re-point an existing one at their own APNs token.
    @Test func registrationRequiresTheTokenWhenOneIsSet() async throws {
        let app = makeApp(authToken: "s3cret")
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
        let app = makeApp(authToken: "s3cret")
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
        let app = makeApp(authToken: "s3cret")
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
        let app = makeApp(authToken: nil)
        try await app.test(.router) { client in
            let response = try await client.execute(
                uri: "/v1/register", method: .post,
                body: ByteBuffer(string: #"{"deviceId":"dev1"}"#)
            )
            #expect(response.status == .noContent)
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
