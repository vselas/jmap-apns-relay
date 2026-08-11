import AsyncHTTPClient
import Foundation
import Hummingbird
import HummingbirdTLS
import NIOSSL

/// `POST /v1/register` body.
struct RegisterBody: Decodable {
    var deviceId: String
    var apnsToken: String?
}

enum RelayMode: String {
    case development
    case production
}

struct RuntimeConfiguration {
    var mode: RelayMode
    var authToken: String?
    var apns: APNsConfiguration?

    init(environment: [String: String]) throws {
        let modeValue = environment["RELAY_MODE"]?.lowercased() ?? "development"
        guard let mode = RelayMode(rawValue: modeValue) else {
            throw ConfigurationError.invalidMode(modeValue)
        }
        self.mode = mode
        authToken = environment["RELAY_AUTH_TOKEN"].flatMap { $0.isEmpty ? nil : $0 }
        apns = try APNsConfiguration.validated(environment: environment)
        if mode == .production {
            guard authToken != nil else { throw ConfigurationError.productionRequiresAuthToken }
            guard apns != nil else { throw ConfigurationError.productionRequiresAPNs }
        }
    }

    enum ConfigurationError: Error, Equatable {
        case invalidMode(String)
        case productionRequiresAuthToken
        case productionRequiresAPNs
    }
}

/// Builds the relay router.
///
/// Endpoints:
/// - `POST /v1/register`            device registration (deviceId, apnsToken?)
/// - `POST /v1/push/:deviceId`      Stalwart's PushSubscription webhook target
/// - `GET  /v1/pending/:deviceId`   dev-mode poll (returns and clears queue)
/// - `GET  /healthz`                liveness
/// - `GET  /readyz`                 persistence readiness
/// Whether a request carries the configured bearer token.
///
/// Constant-time comparison: a token checked with `==` leaks its prefix to
/// anyone willing to time the responses.
func isAuthorized(_ request: Request, token: String?) -> Bool {
    guard let token else { return true }
    guard let header = request.headers[.authorization],
        header.hasPrefix("Bearer ")
    else { return false }
    let presented = Array(header.dropFirst("Bearer ".count).utf8)
    let expected = Array(token.utf8)
    guard presented.count == expected.count else { return false }
    var difference: UInt8 = 0
    for (a, b) in zip(presented, expected) { difference |= a ^ b }
    return difference == 0
}

public func buildRouter(
    store: RelayStore,
    sender: any PushSender,
    authToken: String? = nil
) -> Router<BasicRequestContext> {
    let router = Router()

    router.get("healthz") { _, _ in
        "ok"
    }

    router.get("readyz") { _, _ -> Response in
        guard await store.isReady() else {
            return Response(status: .serviceUnavailable)
        }
        return Response(status: .ok, body: .init(byteBuffer: ByteBuffer(string: "ready")))
    }

    router.get("v1/capabilities") { _, _ -> Response in
        let capabilities: [String: Any] = [
            "protocol": "jmap-apns-relay",
            "protocolVersion": 1,
            "features": ["encryptedForwarding", "plaintextMetadata", "pendingPoll", "unregister"],
            "limits": ["maxWebhookBytes": 64 * 1024, "maxAPNsPayloadBytes": APNsSender.maximumPayloadBytes, "maxPendingPerDevice": 50],
        ]
        let data = try JSONSerialization.data(withJSONObject: capabilities)
        return Response(
            status: .ok,
            headers: [.contentType: "application/json"],
            body: .init(byteBuffer: ByteBuffer(data: data))
        )
    }

    router.post("v1/register") { request, context -> Response in
        // Without this anyone who can reach the relay can claim any device id,
        // or re-point an existing one at their own APNs token and take over
        // its notifications. Encryption stops them reading anything; only
        // authentication stops them redirecting it.
        guard isAuthorized(request, token: authToken) else {
            throw HTTPError(.unauthorized)
        }
        let body = try await request.decode(as: RegisterBody.self, context: context)
        guard !body.deviceId.isEmpty, body.deviceId.count <= 128 else {
            throw HTTPError(.badRequest)
        }
        try await store.register(DeviceRegistration(deviceId: body.deviceId, apnsToken: body.apnsToken))
        return Response(status: .noContent)
    }

    router.delete("v1/register/:deviceId") { request, context -> Response in
        guard isAuthorized(request, token: authToken) else {
            throw HTTPError(.unauthorized)
        }
        let deviceId = try context.parameters.require("deviceId")
        guard try await store.unregister(deviceId: deviceId) else {
            throw HTTPError(.notFound)
        }
        return Response(status: .noContent)
    }

    router.post("v1/push/:deviceId") { request, context -> Response in
        // Deliberately unauthenticated: this is the URL Stalwart was given,
        // and Stalwart sends what it sends. The unguessable device id is the
        // capability. An attacker who learns one can enqueue noise — which,
        // once payloads are encrypted, the app discards as undecryptable.
        let deviceId = try context.parameters.require("deviceId")
        guard let registration = await store.registration(deviceId: deviceId) else {
            throw HTTPError(.notFound)
        }
        let buffer = try await request.body.collect(upTo: 64 * 1024)
        // Bytes, not a String: an encrypted body is binary, and `readString`
        // returns nil for it — which silently turned every encrypted push
        // into an empty payload.
        let body = Data(buffer.readableBytesView)
        let push = PendingPush(
            body: body,
            contentEncoding: request.headers[.contentEncoding]
        )
        try await store.enqueue(deviceId: deviceId, push: push)
        let outcome = await sender.send(push, to: registration)
        if case .invalidToken(let reason) = outcome, let token = registration.apnsToken {
            try await store.invalidateAPNsToken(deviceId: deviceId, token: token)
            relayLog("[push] removed invalid APNs token for \(deviceId): \(reason)")
        } else if case .permanentFailure(let reason) = outcome {
            relayLog("[push] permanent delivery failure for \(deviceId): \(reason)")
        } else if case .transientFailure(let reason) = outcome {
            relayLog("[push] transient delivery failure for \(deviceId): \(reason)")
        }
        // 200 tells Stalwart the push URL is alive.
        return Response(status: .ok)
    }

    router.get("v1/pending/:deviceId") { request, context -> Response in
        // The dev poll hands back everything queued for a device; before
        // encryption that was readable mail metadata, so it takes the same
        // token as registration.
        guard isAuthorized(request, token: authToken) else {
            throw HTTPError(.unauthorized)
        }
        let deviceId = try context.parameters.require("deviceId")
        guard await store.registration(deviceId: deviceId) != nil else {
            throw HTTPError(.notFound)
        }
        let drained = try await store.drain(deviceId: deviceId)
        let data = try JSONEncoder().encode(drained)
        return Response(
            status: .ok,
            headers: [.contentType: "application/json"],
            body: .init(byteBuffer: ByteBuffer(data: data))
        )
    }

    return router
}

@main
struct PushRelayMain {
    static func main() async throws {
        let environment = ProcessInfo.processInfo.environment
        let runtime = try RuntimeConfiguration(environment: environment)
        let port = environment["PORT"].flatMap(Int.init) ?? 8090
        let statePath = environment["STATE_PATH"] ?? "/tmp/pushrelay-state.json"
        let store = try RelayStore(persistenceURL: URL(filePath: statePath))

        // Real APNs when a .p8 key is provisioned (APNS_KEY_PATH / APNS_KEY_ID
        // / APNS_TEAM_ID / APNS_TOPIC); otherwise the dev log + poll sender.
        let sender: any PushSender
        if let apnsConfig = runtime.apns {
            let client = HTTPClient(eventLoopGroupProvider: .singleton)
            do {
                sender = try APNsSender(configuration: apnsConfig, httpClient: client)
                relayLog("[push] APNs sender active (topic \(apnsConfig.topic), host \(apnsConfig.host))")
            } catch {
                try? await client.shutdown()
                if runtime.mode == .production { throw error }
                sender = LogPushSender()
                relayLog("[push] APNs key load failed (\(error)); using development log sender")
            }
        } else {
            sender = LogPushSender()
        }

        // Shared secret for /v1/register and /v1/pending. Optional so an
        // existing deployment keeps working, but the relay says loudly when it
        // is open — an unauthenticated registry is a notification hijack
        // waiting to happen, and silence would let that pass for a working
        // setup.
        let authToken = runtime.authToken
        if authToken == nil {
            relayLog(
                "[push] WARNING: RELAY_AUTH_TOKEN is not set — /v1/register accepts any device id, "
                    + "so anyone who can reach this relay can redirect a device's notifications. "
                    + "Set it in production."
            )
        }

        let router = buildRouter(store: store, sender: sender, authToken: authToken)
        let configuration = ApplicationConfiguration(address: .hostname("0.0.0.0", port: port))

        // JMAP push URLs must be https (RFC 8620 §7.2) — serve TLS when a
        // cert is configured (dev: Tools/gen-dev-certs.sh).
        if let certPath = environment["TLS_CERT"], let keyPath = environment["TLS_KEY"] {
            var tls = try TLSConfiguration.makeServerConfiguration(
                certificateChain: NIOSSLCertificate.fromPEMFile(certPath).map { .certificate($0) },
                privateKey: .privateKey(try NIOSSLPrivateKey(file: keyPath, format: .pem))
            )
            tls.applicationProtocols = ["http/1.1"]
            let app = try Application(
                router: router,
                server: .tls(tlsConfiguration: tls),
                configuration: configuration
            )
            relayLog("[push] relay listening on :\(port) (TLS), state at \(statePath)")
            try await app.runService()
        } else {
            let app = Application(router: router, configuration: configuration)
            relayLog("[push] relay listening on :\(port) (plain HTTP), state at \(statePath)")
            try await app.runService()
        }
    }
}
