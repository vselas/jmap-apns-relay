import AsyncHTTPClient
import Foundation
import Hummingbird

/// `POST /v1/register` body.
struct RegisterBody: Decodable {
    var deviceId: String
    var apnsToken: String?
}

public enum RelayMode: String, Sendable {
    case development
    case production
}

public struct RuntimeConfiguration: Sendable {
    public var mode: RelayMode
    public var authToken: String?
    public var apns: APNsConfiguration?

    public init(environment: [String: String]) throws {
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

    public enum ConfigurationError: Error, Equatable {
        case invalidMode(String)
        case productionRequiresAuthToken
        case productionRequiresAPNs
    }
}

/// Whether a request carries the configured bearer token.
///
/// Constant-time comparison: a token checked with `==` leaks its prefix to
/// anyone willing to time the responses.
public func isAuthorized(_ request: Request, token: String?) -> Bool {
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

/// Builds the relay router, for any request context: the container's
/// `BasicRequestContext` or the Lambda's `BasicLambdaRequestContext`.
///
/// Endpoints:
/// - `POST /v1/register`            device registration (deviceId, apnsToken?)
/// - `POST /v1/push/:deviceId`      Stalwart's PushSubscription webhook target
/// - `GET  /v1/pending/:deviceId`   returns and clears the queue (the app's
///                                  verification poll)
/// - `GET  /healthz`                liveness
/// - `GET  /readyz`                 persistence readiness
public func buildRouter<Context: RequestContext>(
    context: Context.Type = BasicRequestContext.self,
    store: any RelayStorage,
    sender: any PushSender,
    authToken: String? = nil
) -> Router<Context> {
    let router = Router(context: Context.self)

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
            "limits": [
                "maxWebhookBytes": RelayLimits.maxWebhookBytes,
                "maxAPNsPayloadBytes": APNsSender.maximumPayloadBytes,
                "maxPendingPerDevice": RelayLimits.maxPendingPerDevice,
            ],
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
        guard !body.deviceId.isEmpty, body.deviceId.count <= RelayLimits.maxDeviceIdLength else {
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
        guard let registration = try await store.registration(deviceId: deviceId) else {
            throw HTTPError(.notFound)
        }
        let buffer = try await request.body.collect(upTo: RelayLimits.maxWebhookBytes)
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
        guard try await store.registration(deviceId: deviceId) != nil else {
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

/// Picks the sender the configuration asks for: real APNs when credentials are
/// present, the log + poll sender otherwise. A key that fails to load is fatal
/// in production and a downgrade, said out loud, in development.
///
/// The client is only used, and only shut down on failure, when APNs is
/// configured. Pass a shared one when something else uses it too.
public func makeSender(
    runtime: RuntimeConfiguration, httpClient client: HTTPClient, ownsClient: Bool = true
) async throws -> any PushSender {
    guard let apnsConfig = runtime.apns else { return LogPushSender() }
    do {
        let sender = try APNsSender(configuration: apnsConfig, httpClient: client)
        relayLog("[push] APNs sender active (topic \(apnsConfig.topic), host \(apnsConfig.host))")
        return sender
    } catch {
        if ownsClient { try? await client.shutdown() }
        if runtime.mode == .production { throw error }
        relayLog("[push] APNs key load failed (\(error)); using development log sender")
        return LogPushSender()
    }
}
