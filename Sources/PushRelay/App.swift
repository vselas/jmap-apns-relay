import AsyncHTTPClient
import Foundation
import Hummingbird
import HummingbirdTLS
import NIOSSL
import RelayCore

@main
struct PushRelayMain {
    static func main() async throws {
        let environment = ProcessInfo.processInfo.environment
        let runtime = try RuntimeConfiguration(environment: environment)
        let port = environment["PORT"].flatMap(Int.init) ?? 8090
        let statePath = environment["STATE_PATH"] ?? "/tmp/pushrelay-state.json"
        let store = try RelayStore(persistenceURL: URL(filePath: statePath))

        // Real APNs when a .p8 key is provisioned (APNS_KEY_PATH or APNS_KEY,
        // with APNS_KEY_ID / APNS_TEAM_ID / APNS_TOPIC); otherwise the dev log
        // + poll sender.
        let sender = try await makeSender(runtime: runtime, httpClient: HTTPClient.shared)

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
