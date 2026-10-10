import AsyncHTTPClient
import Foundation
import Hummingbird

/// `POST /v1/register` body.
struct RegisterBody: Decodable {
    var deviceId: String
    var apnsToken: String?
    /// StoreKit 2 `Transaction.jwsRepresentation` for the push subscription.
    /// Required on a relay that sells push, the first time a device registers
    /// and whenever its entitlement has lapsed; ignored everywhere else.
    var signedTransaction: String?
}

/// The body Apple POSTs for an App Store Server Notification V2.
struct AppStoreNotificationEnvelope: Decodable {
    var signedPayload: String
}

/// Why a registration was refused, in a body the app can act on.
struct RegistrationRefusal: Encodable {
    /// `entitlementRequired`, `entitlementInvalid`, `entitlementExpired`,
    /// `deviceLimitReached`, `entitlementUnavailable`.
    var error: String
    var maxDevices: Int?
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
    authToken: String? = nil,
    entitlements: EntitlementPolicy? = nil,
    now: @escaping @Sendable () -> Date = { .now }
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
            "features": ["encryptedForwarding", "plaintextMetadata", "pendingPoll", "unregister"]
                + (entitlements == nil ? [] : ["appStoreEntitlement"]),
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
        guard let entitlements else {
            try await store.register(DeviceRegistration(deviceId: body.deviceId, apnsToken: body.apnsToken))
            return Response(status: .noContent)
        }
        let existing = try await store.registration(deviceId: body.deviceId)
        let entitlement: Entitlement
        if let proof = body.signedTransaction {
            do {
                entitlement = try await store.upsertEntitlement(
                    entitlements.verifier.verify(.signedTransaction(proof))
                )
            } catch let error as EntitlementError {
                relayLog("[push] registration of \(body.deviceId) refused: \(error)")
                if case .retryable = error {
                    return refusal(.serviceUnavailable, "entitlementUnavailable")
                }
                return refusal(.init(code: 402, reasonPhrase: "Payment Required"), "entitlementInvalid")
            }
        } else if let id = existing?.entitlementId, let stored = try await store.entitlement(id: id) {
            // A re-registration (new APNs token, every launch) rides on the
            // entitlement already proven; StoreKit is not asked again.
            entitlement = stored
        } else {
            return refusal(.init(code: 402, reasonPhrase: "Payment Required"), "entitlementRequired")
        }
        guard entitlement.isActive(at: now(), grace: entitlements.grace) else {
            return refusal(.init(code: 402, reasonPhrase: "Payment Required"), "entitlementExpired")
        }
        // The device itself never counts against its own limit, so
        // re-registering is always allowed.
        let others = try await store.devices(entitlementId: entitlement.originalTransactionId)
            .filter { $0 != body.deviceId }
        guard others.count < entitlements.maxDevicesPerEntitlement else {
            relayLog("[push] \(entitlement.originalTransactionId) is at its device limit")
            return refusal(.forbidden, "deviceLimitReached", maxDevices: entitlements.maxDevicesPerEntitlement)
        }
        try await store.register(
            DeviceRegistration(
                deviceId: body.deviceId,
                apnsToken: body.apnsToken,
                entitlementId: entitlement.originalTransactionId
            )
        )
        return Response(status: .noContent)
    }

    // App Store Server Notifications V2. Unauthenticated like the webhook,
    // and for the same reason — Apple sends what it sends — but nothing here
    // is taken on trust: the payload is verified against Apple's root, and
    // anything that fails is refused. Apple retries non-2xx, which is what a
    // transient verification failure should get.
    if let entitlements {
        router.post("v1/appstore/notifications") { request, context -> Response in
            let envelope = try await request.decode(as: AppStoreNotificationEnvelope.self, context: context)
            do {
                if let entitlement = try await entitlements.verifier.verifyNotification(
                    signedPayload: envelope.signedPayload
                ) {
                    let stored = try await store.upsertEntitlement(entitlement)
                    relayLog(
                        "[push] entitlement \(stored.originalTransactionId) now "
                            + (stored.isActive(at: now(), grace: entitlements.grace) ? "active" : "inactive")
                    )
                }
                return Response(status: .ok)
            } catch EntitlementError.retryable(let reason) {
                relayLog("[push] App Store notification deferred: \(reason)")
                return Response(status: .serviceUnavailable)
            } catch let error as EntitlementError {
                relayLog("[push] App Store notification rejected: \(error)")
                return Response(status: .badRequest)
            }
        }
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
        // Queued either way: the subscription's verification code has to
        // reach the app's poll even before anyone pays, or the app could
        // never finish setting push up. What payment buys is the APNs leg.
        if let entitlements {
            let active: Bool
            if let id = registration.entitlementId, let entitlement = try await store.entitlement(id: id) {
                active = entitlement.isActive(at: now(), grace: entitlements.grace)
            } else {
                active = false
            }
            guard active else {
                // 200 still: the URL is alive, and a non-2xx would only make
                // the server retry something that is not going to change.
                return Response(status: .ok)
            }
        }
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

private func refusal(_ status: HTTPResponse.Status, _ error: String, maxDevices: Int? = nil) -> Response {
    let body = (try? JSONEncoder().encode(RegistrationRefusal(error: error, maxDevices: maxDevices))) ?? Data()
    return Response(
        status: status,
        headers: [.contentType: "application/json"],
        body: .init(byteBuffer: ByteBuffer(data: body))
    )
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
