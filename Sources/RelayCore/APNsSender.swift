import AsyncHTTPClient
import Crypto
import Foundation
import NIOCore
import NIOHTTP1

/// APNs credentials and target host, read from the process environment.
public struct APNsConfiguration: Sendable {
    /// Where the `.p8` signing key comes from.
    public enum Key: Sendable, Equatable {
        /// A file on disk (`APNS_KEY_PATH`), as the Docker relay mounts it.
        case file(path: String)
        /// The PEM text itself (`APNS_KEY`), as the Lambda relay reads it
        /// from Parameter Store — a Lambda has no secrets volume to mount.
        case pem(String)
    }

    public var key: Key
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
        do {
            guard let configuration = try Self.validated(environment: environment) else { return nil }
            self = configuration
        } catch {
            return nil
        }
    }

    static func validated(environment: [String: String]) throws -> APNsConfiguration? {
        func value(_ name: String) -> String? {
            environment[name].flatMap { $0.isEmpty ? nil : $0 }
        }
        // The key may come as a path or as its contents; either one counts.
        let key: Key? = value("APNS_KEY").map(Key.pem) ?? value("APNS_KEY_PATH").map { .file(path: $0) }
        let present = [key != nil] + ["APNS_KEY_ID", "APNS_TEAM_ID", "APNS_TOPIC"].map { value($0) != nil }
        guard present.contains(true) else { return nil }
        guard !present.contains(false) else { throw ConfigurationError.incompleteCredentials }
        guard let key,
            let keyId = environment["APNS_KEY_ID"],
            let teamId = environment["APNS_TEAM_ID"],
            let topic = environment["APNS_TOPIC"]
        else { throw ConfigurationError.incompleteCredentials }
        let apnsEnvironment = environment["APNS_ENVIRONMENT"]?.lowercased() ?? "production"
        guard apnsEnvironment == "production" || apnsEnvironment == "sandbox" else {
            throw ConfigurationError.invalidEnvironment(apnsEnvironment)
        }
        return APNsConfiguration(
            key: key,
            keyId: keyId,
            teamId: teamId,
            topic: topic,
            host: apnsEnvironment == "sandbox" ? "api.sandbox.push.apple.com" : "api.push.apple.com",
            alertTitle: environment["APNS_ALERT_TITLE"] ?? "Mail",
            alertBody: environment["APNS_ALERT_BODY"] ?? "New mail"
        )
    }

    enum ConfigurationError: Error, Equatable {
        case incompleteCredentials
        case invalidEnvironment(String)
    }

    private init(key: Key, keyId: String, teamId: String, topic: String, host: String, alertTitle: String, alertBody: String) {
        self.key = key
        self.keyId = keyId
        self.teamId = teamId
        self.topic = topic
        // Must match the installed build's aps-environment: development and
        // TestFlight sandbox builds require the sandbox host.
        self.host = host
        self.alertTitle = alertTitle
        self.alertBody = alertBody
    }
}

/// Delivers push payloads to Apple. Loads the `.p8` signing key once, caches
/// the provider JWT (Apple wants it reused 20–60 min), and sends each Stalwart
/// `StateChange` as an alert push over HTTP/2.
public actor APNsSender: PushSender {
    public static let maximumPayloadBytes = 4_096
    private let configuration: APNsConfiguration
    private let httpClient: HTTPClient
    private let privateKey: P256.Signing.PrivateKey
    private var cachedToken: (jwt: String, issuedAt: Date)?

    public init(configuration: APNsConfiguration, httpClient: HTTPClient) throws {
        self.configuration = configuration
        self.httpClient = httpClient
        let pem: String
        switch configuration.key {
        case .file(let path): pem = try String(contentsOfFile: path, encoding: .utf8)
        case .pem(let text): pem = text
        }
        self.privateKey = try P256.Signing.PrivateKey(pemRepresentation: pem)
    }

    public func send(_ push: PendingPush, to registration: DeviceRegistration) async -> DeliveryOutcome {
        // A plaintext PushVerification is consumed by the app's setup poll and
        // is not worth a notification. An *encrypted* payload cannot be told
        // apart from a StateChange without the device's key — which is the
        // point — so it is always forwarded, and the extension decides. The
        // cost is one generic notification during setup; see the README.
        guard push.isEncrypted || Self.isStateChange(push.text ?? "") else {
            return .skipped(reason: "not a StateChange")
        }
        guard let deviceToken = registration.apnsToken else {
            relayLog("[push] no APNs token for \(registration.deviceId); skipping")
            return .skipped(reason: "no APNs token")
        }
        do {
            let jwt = try bearerToken()
            var request = HTTPClientRequest(url: "https://\(configuration.host)/3/device/\(deviceToken)")
            request.method = .POST
            request.headers.add(name: "authorization", value: "bearer \(jwt)")
            request.headers.add(name: "apns-topic", value: configuration.topic)
            request.headers.add(name: "apns-push-type", value: "alert")
            request.headers.add(name: "apns-priority", value: "10")
            let payload = try Self.alertPayload(
                push,
                deviceId: registration.deviceId,
                title: configuration.alertTitle,
                body: configuration.alertBody
            )
            request.body = .bytes(ByteBuffer(bytes: payload))
            let prepared = request
            let response = try await retryingStaleConnection("APNs") { [httpClient] in
                try await httpClient.execute(prepared, timeout: .seconds(10))
            }
            guard response.status != .ok else {
                // Logged, unlike before: a delivered push left no line, so a
                // device that got none looked exactly like one that got all
                // of them. The apns-id is what Apple's Push Notifications
                // Console looks a delivery up by.
                let apnsId = response.headers.first(name: "apns-id") ?? "?"
                relayLog("[push] APNs 200 for \(registration.deviceId) (apns-id \(apnsId))")
                return .delivered
            }
            let body = try? await response.body.collect(upTo: 4 * 1024)
            let text = body.map { String(buffer: $0) } ?? ""
            let reason = Self.responseReason(text) ?? "HTTP \(response.status.code)"
            let outcome = Self.classify(status: Int(response.status.code), reason: reason)
            relayLog("[push] APNs \(response.status.code) for \(registration.deviceId): \(reason)")
            return outcome
        } catch let error as PayloadError {
            relayLog("[push] APNs payload rejected for \(registration.deviceId): \(error)")
            return .permanentFailure(reason: String(describing: error))
        } catch {
            relayLog("[push] APNs send failed for \(registration.deviceId): \(error)")
            return .transientFailure(reason: String(describing: error))
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

    /// The APNs alert body.
    ///
    /// The alert text is always generic — the relay has no business knowing a
    /// sender or a subject, and with an encrypted payload it could not know
    /// them anyway. `mutable-content` lets the app's notification service
    /// extension replace the text once it has decrypted and synced.
    ///
    /// An encrypted payload rides along base64-encoded under
    /// `sigill.encrypted`; a plaintext one keeps the old `stateChange` field
    /// so an app built before encryption still works against this relay.
    enum PayloadError: Error, Equatable {
        case exceedsMaximum(actual: Int, maximum: Int)
    }

    static func alertPayload(
        _ push: PendingPush,
        deviceId: String = "",
        title: String = "Mail",
        body: String = "New mail"
    ) throws -> Data {
        let aps: [String: Any] = [
            "alert": ["title": title, "body": body],
            "sound": "default",
            "mutable-content": 1,
        ]
        var root: [String: Any] = ["aps": aps]
        if push.isEncrypted {
            // Base64 because an APNs payload is JSON and this is not text.
            // The account is whichever one holds the key that opens it, which
            // is unambiguous in a way the JMAP account id never was.
            root["sigill"] = ["encrypted": push.body.base64EncodedString()]
        } else if let text = push.text,
            let object = try? JSONSerialization.jsonObject(with: Data(text.utf8))
        {
            root["stateChange"] = object
            root["sigill"] = ["deviceId": deviceId, "protocolVersion": 1]
        }
        let data = (try? JSONSerialization.data(withJSONObject: root))
            ?? Data(#"{"aps":{"alert":"New mail"}}"#.utf8)
        guard data.count <= maximumPayloadBytes else {
            throw PayloadError.exceedsMaximum(actual: data.count, maximum: maximumPayloadBytes)
        }
        return data
    }

    static func responseReason(_ body: String) -> String? {
        guard let data = body.data(using: .utf8),
            let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        return object["reason"] as? String
    }

    static func classify(status: Int, reason: String) -> DeliveryOutcome {
        let invalidReasons = ["BadDeviceToken", "DeviceTokenNotForTopic", "Unregistered"]
        if status == 410 || invalidReasons.contains(reason) {
            return .invalidToken(reason: reason)
        }
        if status == 429 || status >= 500 {
            return .transientFailure(reason: reason)
        }
        return .permanentFailure(reason: reason)
    }

    static func base64URL(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
