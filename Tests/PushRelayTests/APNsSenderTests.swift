import Crypto
import Foundation
import Hummingbird
import HummingbirdTesting
import NIOCore
import Testing

@testable import PushRelay

@Suite struct APNsSenderTests {
    @Test func onlyStateChangeIsDelivered() {
        #expect(APNsSender.isStateChange(#"{"@type":"StateChange","changed":{}}"#))
        #expect(!APNsSender.isStateChange(#"{"@type":"PushVerification","verificationCode":"x"}"#))
        #expect(!APNsSender.isStateChange("not json"))
    }

    @Test func alertPayloadIsValidAndCarriesStateChange() throws {
        let stateChange = #"{"@type":"StateChange","changed":{"acc":{"Email":"s1"}}}"#
        let data = try APNsSender.alertPayload(
            PendingPush(body: Data(stateChange.utf8)), deviceId: "device-7", title: "Acme", body: "You have mail"
        )
        let root = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let aps = try #require(root["aps"] as? [String: Any])
        let alert = try #require(aps["alert"] as? [String: Any])
        #expect(alert["title"] as? String == "Acme")
        #expect(alert["body"] as? String == "You have mail")
        #expect(aps["mutable-content"] as? Int == 1)
        // The raw StateChange rides along for a Notification Service Extension.
        let forwarded = try #require(root["stateChange"] as? [String: Any])
        #expect(forwarded["@type"] as? String == "StateChange")
        let sigill = try #require(root["sigill"] as? [String: Any])
        #expect(sigill["deviceId"] as? String == "device-7")
        #expect(sigill["protocolVersion"] as? Int == 1)
    }

    @Test func alertPayloadDefaultsAreGeneric() throws {
        let data = try APNsSender.alertPayload(PendingPush(body: Data(#"{"@type":"StateChange"}"#.utf8)))
        let root = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let alert = try #require((root["aps"] as? [String: Any])?["alert"] as? [String: Any])
        #expect(alert["title"] as? String == "Mail")
        #expect(alert["body"] as? String == "New mail")
    }

    /// An encrypted payload rides along base64-encoded and nothing about it
    /// leaks into the alert — which is the whole reason for encrypting it.
    @Test func anEncryptedPayloadIsForwardedOpaquely() throws {
        let ciphertext = Data([0x00, 0xFF, 0x10, 0x41, 0x04, 0xC3, 0x28])
        let data = try APNsSender.alertPayload(
            PendingPush(body: ciphertext, contentEncoding: "aes128gcm")
        )
        let root = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])

        let sigill = try #require(root["sigill"] as? [String: Any])
        let encoded = try #require(sigill["encrypted"] as? String)
        #expect(Data(base64Encoded: encoded) == ciphertext)
        // No plaintext field, and the alert stays generic.
        #expect(root["stateChange"] == nil)
        let alert = try #require((root["aps"] as? [String: Any])?["alert"] as? [String: Any])
        #expect(alert["body"] as? String == "New mail")
        #expect((root["aps"] as? [String: Any])?["mutable-content"] as? Int == 1)
    }

    /// The relay cannot tell an encrypted verification from an encrypted
    /// StateChange, so it forwards both rather than dropping mail it failed
    /// to recognise.
    @Test func encryptedPayloadsAreNeverGatedOnContent() {
        let encrypted = PendingPush(body: Data([0xFF, 0x00]), contentEncoding: "aes128gcm")
        #expect(encrypted.isEncrypted)
        #expect(encrypted.text == nil)
    }

    @Test func finalAPNsPayloadSizeIsEnforced() {
        let oversized = String(repeating: "x", count: 5_000)
        let push = PendingPush(body: Data(#"{"@type":"StateChange","changed":"\#(oversized)"}"#.utf8))
        #expect(throws: APNsSender.PayloadError.self) {
            _ = try APNsSender.alertPayload(push, deviceId: "device")
        }
    }

    @Test func responsesAreClassifiedForCleanupAndDiagnostics() {
        #expect(APNsSender.classify(status: 410, reason: "Unregistered") == .invalidToken(reason: "Unregistered"))
        #expect(APNsSender.classify(status: 400, reason: "BadDeviceToken") == .invalidToken(reason: "BadDeviceToken"))
        #expect(APNsSender.classify(status: 429, reason: "TooManyRequests") == .transientFailure(reason: "TooManyRequests"))
        #expect(APNsSender.classify(status: 503, reason: "Shutdown") == .transientFailure(reason: "Shutdown"))
        #expect(APNsSender.classify(status: 403, reason: "InvalidProviderToken") == .permanentFailure(reason: "InvalidProviderToken"))
    }

    @Test func jwtIsSignedAndDecodable() throws {
        let key = P256.Signing.PrivateKey()
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let jwt = try APNsSender.makeJWT(keyId: "KEY123", teamId: "TEAM45", key: key, now: now)
        let parts = jwt.split(separator: ".").map(String.init)
        #expect(parts.count == 3)

        let header = try decodeSegment(parts[0])
        #expect(header["alg"] as? String == "ES256")
        #expect(header["kid"] as? String == "KEY123")
        let claims = try decodeSegment(parts[1])
        #expect(claims["iss"] as? String == "TEAM45")
        #expect(claims["iat"] as? Int == 1_700_000_000)

        // The signature verifies over `header.claims` with the matching key.
        let signingInput = Data((parts[0] + "." + parts[1]).utf8)
        let sigBytes = try #require(Self.base64URLDecode(parts[2]))
        let signature = try P256.Signing.ECDSASignature(rawRepresentation: sigBytes)
        #expect(key.publicKey.isValidSignature(signature, for: signingInput))
    }

    @Test func webhookInvokesSenderWithRegisteredToken() async throws {
        let store = try RelayStore(persistenceURL: nil)
        let sender = CapturingSender()
        let app = Application(router: buildRouter(store: store, sender: sender))
        try await app.test(.router) { client in
            let registered = try await client.execute(
                uri: "/v1/register", method: .post,
                body: ByteBuffer(string: #"{"deviceId":"dev9","apnsToken":"abc123"}"#)
            )
            #expect(registered.status == .noContent)
            let pushed = try await client.execute(
                uri: "/v1/push/dev9", method: .post,
                body: ByteBuffer(string: #"{"@type":"StateChange"}"#)
            )
            #expect(pushed.status == .ok)
        }
        let sent = await sender.captured
        #expect(sent.count == 1)
        #expect(sent.first?.deviceId == "dev9")
        #expect(sent.first?.apnsToken == "abc123")
    }

    private func decodeSegment(_ segment: String) throws -> [String: Any] {
        let data = try #require(Self.base64URLDecode(segment))
        return try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    static func base64URLDecode(_ string: String) -> Data? {
        var s = string.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while s.count % 4 != 0 { s.append("=") }
        return Data(base64Encoded: s)
    }
}

/// Records deliveries so tests can assert the webhook reached the sender.
private actor CapturingSender: PushSender {
    private(set) var captured: [(deviceId: String, apnsToken: String?, push: PendingPush)] = []

    func send(_ push: PendingPush, to registration: DeviceRegistration) async -> DeliveryOutcome {
        captured.append((registration.deviceId, registration.apnsToken, push))
        return .delivered
    }
}
