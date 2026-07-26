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
        let data = APNsSender.alertPayload(stateChange: stateChange, title: "Acme", body: "You have mail")
        let root = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let aps = try #require(root["aps"] as? [String: Any])
        let alert = try #require(aps["alert"] as? [String: Any])
        #expect(alert["title"] as? String == "Acme")
        #expect(alert["body"] as? String == "You have mail")
        #expect(aps["mutable-content"] as? Int == 1)
        // The raw StateChange rides along for a Notification Service Extension.
        let forwarded = try #require(root["stateChange"] as? [String: Any])
        #expect(forwarded["@type"] as? String == "StateChange")
    }

    @Test func alertPayloadDefaultsAreGeneric() throws {
        let data = APNsSender.alertPayload(stateChange: #"{"@type":"StateChange"}"#)
        let root = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let alert = try #require((root["aps"] as? [String: Any])?["alert"] as? [String: Any])
        #expect(alert["title"] as? String == "Mail")
        #expect(alert["body"] as? String == "New mail")
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
        let store = RelayStore(persistenceURL: nil)
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
    private(set) var captured: [(deviceId: String, apnsToken: String?)] = []

    func send(payload: String, to registration: DeviceRegistration) async {
        captured.append((registration.deviceId, registration.apnsToken))
    }
}
