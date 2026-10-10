import Foundation

/// A paid entitlement to closed-app push: one App Store subscription,
/// identified by Apple's `originalTransactionId`, which stays the same across
/// renewals, upgrades and restores.
///
/// The relay only ever learns this from data Apple signed: a StoreKit 2
/// transaction the app forwards at registration, or an App Store Server
/// Notification. Nothing the app *says* about itself changes it.
public struct Entitlement: Sendable, Codable, Equatable {
    public var originalTransactionId: String
    public var productId: String
    /// When the current period ends. Nil only for a non-expiring product.
    public var expiresAt: Date?
    /// Set when Apple refunded or revoked the purchase. Wins over `expiresAt`.
    public var revokedAt: Date?
    /// Apple's own clock for the newest signed data applied, so an older
    /// notification arriving late cannot undo a newer one.
    public var signedAt: Date

    public init(
        originalTransactionId: String,
        productId: String,
        expiresAt: Date?,
        revokedAt: Date? = nil,
        signedAt: Date
    ) {
        self.originalTransactionId = originalTransactionId
        self.productId = productId
        self.expiresAt = expiresAt
        self.revokedAt = revokedAt
        self.signedAt = signedAt
    }

    /// Whether push is paid for at `now`. `grace` absorbs the minutes between
    /// a period ending and the renewal notification landing, so a renewing
    /// subscriber never loses a push to the race.
    public func isActive(at now: Date, grace: TimeInterval = 0) -> Bool {
        if revokedAt != nil { return false }
        guard let expiresAt else { return true }
        return expiresAt.addingTimeInterval(grace) > now
    }

    /// Applies newer signed data; older data than what is held is ignored.
    public func merged(with newer: Entitlement) -> Entitlement {
        newer.signedAt >= signedAt ? newer : self
    }
}

/// What a registration carries to prove it is paid for.
public enum EntitlementProof: Sendable, Equatable {
    /// A StoreKit 2 JWS (`Transaction.jwsRepresentation`).
    case signedTransaction(String)
}

/// Turns Apple-signed data into entitlements. The production implementation
/// (`AppStoreEntitlementVerifier` in `RelayAppStore`) checks the signature
/// chain to Apple's root; tests substitute their own.
public protocol EntitlementVerifier: Sendable {
    /// Verifies a transaction the app forwarded at registration.
    func verify(_ proof: EntitlementProof) async throws -> Entitlement
    /// Verifies an App Store Server Notification V2 `signedPayload`. Returns
    /// nil for a notification that changes no entitlement (a TEST ping, a
    /// different app, a product the relay does not sell).
    func verifyNotification(signedPayload: String) async throws -> Entitlement?
}

public enum EntitlementError: Error, Equatable, CustomStringConvertible {
    /// The signature, chain, bundle id or environment did not check out.
    case invalidProof(String)
    /// Signed by Apple, but for something the relay does not sell.
    case wrongProduct(String)
    /// Apple's certificate status service could not be reached; try again.
    case retryable(String)

    public var description: String {
        switch self {
        case .invalidProof(let reason): "invalid App Store proof: \(reason)"
        case .wrongProduct(let product): "product \(product) does not grant push"
        case .retryable(let reason): "App Store verification unavailable: \(reason)"
        }
    }
}

/// How the relay decides who may receive push.
public struct EntitlementPolicy: Sendable {
    public var verifier: any EntitlementVerifier
    /// How many devices one subscription may register. Each account on each
    /// device is one registration, so this is generous by default.
    public var maxDevicesPerEntitlement: Int
    /// Slack after `expiresAt` before pushes stop (see `Entitlement.isActive`).
    public var grace: TimeInterval

    public init(verifier: any EntitlementVerifier, maxDevicesPerEntitlement: Int = 10, grace: TimeInterval = 3600) {
        self.verifier = verifier
        self.maxDevicesPerEntitlement = maxDevicesPerEntitlement
        self.grace = grace
    }
}
