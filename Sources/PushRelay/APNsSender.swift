import AsyncHTTPClient
import Crypto
import Foundation
import NIOCore
import NIOHTTP1

/// APNs credentials and target host, read from the process environment.
public struct APNsConfiguration: Sendable {
    public var keyPath: String
    public var keyId: String
    public var teamId: String
    public var topic: String
    /// `api.push.apple.com` (production) or `api.sandbox.push.apple.com`.
    public var host: String
    /// Fallback alert title/body (a Notification Service Extension can enrich).
    public var alertTitle: String
    public var alertBody: String

    /// Builds a configuration only when every required APNs variable is set;
    /// returns `nil` otherwise so the relay falls back to the dev log sender.
    public init?(environment: [String: String]) {
        guard let keyPath = environment["APNS_KEY_PATH"],
            let keyId = environment["APNS_KEY_ID"],
            let teamId = environment["APNS_TEAM_ID"],
            let topic = environment["APNS_TOPIC"]
        else { return nil }
        self.keyPath = keyPath
        self.keyId = keyId
        self.teamId = teamId
        self.topic = topic
        // Must match the installed build's aps-environment: development and
        // TestFlight sandbox builds require the sandbox host.
        self.host = environment["APNS_ENVIRONMENT"]?.lowercased() == "sandbox"
            ? "api.sandbox.push.apple.com"
            : "api.push.apple.com"
        self.alertTitle = environment["APNS_ALERT_TITLE"] ?? "Mail"
        self.alertBody = environment["APNS_ALERT_BODY"] ?? "New mail"
    }
}

/// Delivers push payloads to Apple. Loads the `.p8` signing key once, caches
/// the provider JWT (Apple wants it reused 20–60 min), and sends each Stalwart
/// `StateChange` as an alert push over HTTP/2.
public actor APNsSender: PushSender {
    private let configuration: APNsConfiguration
    private let httpClient: HTTPClient
    private let privateKey: P256.Signing.PrivateKey
    private var cachedToken: (jwt: String, issuedAt: Date)?

    public init(configuration: APNsConfiguration, httpClient: HTTPClient) throws {
        self.configuration = configuration
        self.httpClient = httpClient
        let pem = try String(contentsOfFile: configuration.keyPath, encoding: .utf8)
        self.privateKey = try P256.Signing.PrivateKey(pemRepresentation: pem)
    }

    public func send(payload: String, to registration: DeviceRegistration) async {
        // The PushVerification handshake is consumed by the app's setup poll,
        // never delivered as a notification — only forward StateChanges.
        guard Self.isStateChange(payload) else { return }
        guard let deviceToken = registration.apnsToken else {
            relayLog("[push] no APNs token for \(registration.deviceId); skipping")
            return
        }
        do {
            let jwt = try bearerToken()
            var request = HTTPClientRequest(url: "https://\(configuration.host)/3/device/\(deviceToken)")
            request.method = .POST
            request.headers.add(name: "authorization", value: "bearer \(jwt)")
            request.headers.add(name: "apns-topic", value: configuration.topic)
            request.headers.add(name: "apns-push-type", value: "alert")
            request.headers.add(name: "apns-priority", value: "10")
            request.body = .bytes(ByteBuffer(bytes: Self.alertPayload(
                stateChange: payload, title: configuration.alertTitle, body: configuration.alertBody)))
            let response = try await httpClient.execute(request, timeout: .seconds(10))
            if response.status != .ok {
                let body = try? await response.body.collect(upTo: 4 * 1024)
                let text = body.map { String(buffer: $0) } ?? ""
                // 410 = token no longer valid (app removed); a later pass could
                // prune it from the registry.
                relayLog("[push] APNs \(response.status.code) for \(registration.deviceId): \(text)")
            }
        } catch {
            relayLog("[push] APNs send failed for \(registration.deviceId): \(error)")
        }
    }

    /// A cached ES256 provider token, regenerated well inside Apple's 60-min
    /// limit and reused past their 20-min minimum.
    private func bearerToken() throws -> String {
        if let cached = cachedToken, Date().timeIntervalSince(cached.issuedAt) < 30 * 60 {
            return cached.jwt
        }
        let jwt = try Self.makeJWT(keyId: configuration.keyId, teamId: configuration.teamId, key: privateKey)
        cachedToken = (jwt, Date())
        return jwt
    }

    /// Signs an APNs provider JWT (ES256) — header `{alg,kid}`, claims
    /// `{iss,iat}`, signature over `header.claims`.
    static func makeJWT(keyId: String, teamId: String, key: P256.Signing.PrivateKey, now: Date = .now) throws -> String {
        let header = base64URL(Data(#"{"alg":"ES256","kid":"\#(keyId)"}"#.utf8))
        let iat = Int(now.timeIntervalSince1970)
        let claims = base64URL(Data(#"{"iss":"\#(teamId)","iat":\#(iat)}"#.utf8))
        let signingInput = header + "." + claims
        let signature = try key.signature(for: Data(signingInput.utf8))
        return signingInput + "." + base64URL(signature.rawRepresentation)
    }

    /// Whether a relay payload is a JMAP `StateChange` (vs a `PushVerification`).
    static func isStateChange(_ payload: String) -> Bool {
        struct Envelope: Decodable {
            let type: String?
            enum CodingKeys: String, CodingKey { case type = "@type" }
        }
        guard let data = payload.data(using: .utf8) else { return false }
        return (try? JSONDecoder().decode(Envelope.self, from: data))?.type == "StateChange"
    }

    /// The APNs alert body. Generic today; the raw StateChange rides along so a
    /// Notification Service Extension can enrich it after a targeted sync.
    static func alertPayload(stateChange: String, title: String = "Mail", body: String = "New mail") -> Data {
        let aps: [String: Any] = [
            "alert": ["title": title, "body": body],
            "sound": "default",
            "mutable-content": 1,
        ]
        var root: [String: Any] = ["aps": aps]
        if let data = stateChange.data(using: .utf8),
            let object = try? JSONSerialization.jsonObject(with: data) {
            root["stateChange"] = object
        }
        return (try? JSONSerialization.data(withJSONObject: root))
            ?? Data(#"{"aps":{"alert":"New mail"}}"#.utf8)
    }

    static func base64URL(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
