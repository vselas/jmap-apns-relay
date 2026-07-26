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

/// Builds the relay router.
///
/// Endpoints:
/// - `POST /v1/register`            device registration (deviceId, apnsToken?)
/// - `POST /v1/push/:deviceId`      Stalwart's PushSubscription webhook target
/// - `GET  /v1/pending/:deviceId`   dev-mode poll (returns and clears queue)
/// - `GET  /healthz`                liveness
public func buildRouter(store: RelayStore, sender: any PushSender) -> Router<BasicRequestContext> {
    let router = Router()

    router.get("healthz") { _, _ in
        "ok"
    }

    router.post("v1/register") { request, context -> Response in
        let body = try await request.decode(as: RegisterBody.self, context: context)
        guard !body.deviceId.isEmpty, body.deviceId.count <= 128 else {
            throw HTTPError(.badRequest)
        }
        await store.register(DeviceRegistration(deviceId: body.deviceId, apnsToken: body.apnsToken))
        return Response(status: .noContent)
    }

    router.post("v1/push/:deviceId") { request, context -> Response in
        let deviceId = try context.parameters.require("deviceId")
        guard await store.registration(deviceId: deviceId) != nil else {
            throw HTTPError(.notFound)
        }
        var buffer = try await request.body.collect(upTo: 64 * 1024)
        let payload = buffer.readString(length: buffer.readableBytes) ?? ""
        await store.enqueue(deviceId: deviceId, payload: payload)
        if let registration = await store.registration(deviceId: deviceId) {
            await sender.send(payload: payload, to: registration)
        }
        // 200 tells Stalwart the push URL is alive.
        return Response(status: .ok)
    }

    router.get("v1/pending/:deviceId") { _, context -> Response in
        let deviceId = try context.parameters.require("deviceId")
        guard await store.registration(deviceId: deviceId) != nil else {
            throw HTTPError(.notFound)
        }
        let drained = await store.drain(deviceId: deviceId)
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
        let port = environment["PORT"].flatMap(Int.init) ?? 8090
        let statePath = environment["STATE_PATH"] ?? "/tmp/pushrelay-state.json"
        let store = RelayStore(persistenceURL: URL(filePath: statePath))

        // Real APNs when a .p8 key is provisioned (APNS_KEY_PATH / APNS_KEY_ID
        // / APNS_TEAM_ID / APNS_TOPIC); otherwise the dev log + poll sender.
        let sender: any PushSender
        if let apnsConfig = APNsConfiguration(environment: environment) {
            let client = HTTPClient(eventLoopGroupProvider: .singleton)
            do {
                sender = try APNsSender(configuration: apnsConfig, httpClient: client)
                relayLog("[push] APNs sender active (topic \(apnsConfig.topic), host \(apnsConfig.host))")
            } catch {
                try? await client.shutdown()
                sender = LogPushSender()
                relayLog("[push] APNs key load failed (\(error)); using log sender")
            }
        } else {
            sender = LogPushSender()
        }

        let router = buildRouter(store: store, sender: sender)
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
