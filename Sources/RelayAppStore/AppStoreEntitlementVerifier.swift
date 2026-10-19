import AppStoreServerLibrary
import Foundation
import RelayCore

/// Verifies StoreKit 2 transactions and App Store Server Notifications V2
/// with Apple's App Store Server Library: the JWS signature, the x5c chain up
/// to Apple's root CA, Apple's receipt-signing OIDs, the bundle id and the
/// environment. Only then are the claims inside believed.
public struct AppStoreEntitlementVerifier: EntitlementVerifier {
    public struct Configuration: Sendable {
        public var bundleId: String
        /// The app's numeric App Store id; Apple requires it for production.
        public var appAppleId: Int64?
        /// The environments whose purchases count, tried in order. App Store
        /// purchases are `production`; TestFlight and App Review purchases are
        /// `sandbox`, so a relay serving both kinds of build accepts both.
        public var environments: [AppStoreServerLibrary.AppStoreEnvironment]
        /// Products that grant push, e.g. the Pro subscription's ids.
        public var productIds: Set<String>
        /// Apple's root certificates (DER). `AppleRootCertificates.all` ships
        /// them; tests pass their own.
        public var rootCertificates: [Data]
        /// Online OCSP revocation checks against Apple. On by default; off
        /// only for tests that cannot reach Apple.
        public var onlineChecks: Bool

        public init(
            bundleId: String,
            appAppleId: Int64?,
            environment: AppStoreServerLibrary.AppStoreEnvironment,
            productIds: Set<String>,
            rootCertificates: [Data] = AppleRootCertificates.all,
            onlineChecks: Bool = true
        ) {
            self.init(
                bundleId: bundleId, appAppleId: appAppleId, environments: [environment],
                productIds: productIds, rootCertificates: rootCertificates, onlineChecks: onlineChecks
            )
        }

        public init(
            bundleId: String,
            appAppleId: Int64?,
            environments: [AppStoreServerLibrary.AppStoreEnvironment],
            productIds: Set<String>,
            rootCertificates: [Data] = AppleRootCertificates.all,
            onlineChecks: Bool = true
        ) {
            self.bundleId = bundleId
            self.appAppleId = appAppleId
            self.environments = environments
            self.productIds = productIds
            self.rootCertificates = rootCertificates
            self.onlineChecks = onlineChecks
        }
    }

    public enum ConfigurationError: Error, Equatable {
        /// `xcode` and `localTesting` make Apple's library skip signature
        /// verification entirely. A relay configured that way would take any
        /// forged transaction, so it refuses to start instead.
        case unverifiedEnvironment(String)
        case noProducts
        case noEnvironments
    }

    public let configuration: Configuration
    /// One per configured environment, in the configuration's order.
    let verifiers: [SignedDataVerifier]

    public init(configuration: Configuration) throws {
        guard !configuration.environments.isEmpty else { throw ConfigurationError.noEnvironments }
        for environment in configuration.environments {
            switch environment {
            case .production, .sandbox: break
            default: throw ConfigurationError.unverifiedEnvironment(environment.rawValue)
            }
        }
        guard !configuration.productIds.isEmpty else { throw ConfigurationError.noProducts }
        self.configuration = configuration
        self.verifiers = try configuration.environments.map { environment in
            try SignedDataVerifier(
                rootCertificates: configuration.rootCertificates,
                bundleId: configuration.bundleId,
                appAppleId: configuration.appAppleId,
                environment: environment,
                enableOnlineChecks: configuration.onlineChecks
            )
        }
    }

    /// Runs `check` with each environment's verifier in turn and returns the
    /// first answer that isn't an environment mismatch, with the verifier that
    /// gave it. Every other check (signature, chain, bundle id) is the same
    /// in each, so only the environment decides which one answers.
    func firstMatching<T>(
        _ check: (SignedDataVerifier) async -> VerificationResult<T>
    ) async throws -> (T, SignedDataVerifier) {
        var last: VerificationResult<T>?
        for verifier in verifiers {
            let result = await check(verifier)
            if case .invalid(.INVALID_ENVIRONMENT) = result {
                last = result
                continue
            }
            return (try Self.unwrap(result), verifier)
        }
        // Init guarantees at least one verifier, so `last` is set here.
        guard let last else { throw EntitlementError.invalidProof("no environment configured") }
        return (try Self.unwrap(last), verifiers[verifiers.count - 1])
    }

    public func verify(_ proof: EntitlementProof) async throws -> Entitlement {
        guard case .signedTransaction(let jws) = proof else {
            throw EntitlementError.invalidProof("unsupported proof")
        }
        let (transaction, _) = try await firstMatching { await $0.verifyAndDecodeTransaction(signedTransaction: jws) }
        return try entitlement(from: transaction, status: nil)
    }

    public func verifyNotification(signedPayload: String) async throws -> Entitlement? {
        // The transaction and renewal inside are checked by the verifier that
        // accepted the notification: they share its environment.
        let (notification, verifier) = try await firstMatching {
            await $0.verifyAndDecodeNotification(signedPayload: signedPayload)
        }
        if notification.notificationType == .test { return nil }
        guard let data = notification.data, let signedTransaction = data.signedTransactionInfo else {
            // Summary, external-purchase and consumption notifications carry
            // no transaction, and change nothing the relay keeps.
            return nil
        }
        let transaction = try Self.unwrap(
            await verifier.verifyAndDecodeTransaction(signedTransaction: signedTransaction)
        )
        guard let productId = transaction.productId, configuration.productIds.contains(productId) else {
            return nil
        }
        var renewalGraceEndsAt: Date?
        if data.status == .billingGracePeriod, let signedRenewal = data.signedRenewalInfo {
            let renewal = try Self.unwrap(await verifier.verifyAndDecodeRenewalInfo(signedRenewalInfo: signedRenewal))
            renewalGraceEndsAt = renewal.gracePeriodExpiresDate
        }
        var entitlement = try entitlement(from: transaction, status: data.status)
        if let graceEnd = renewalGraceEndsAt {
            // Apple keeps the subscription in service through billing grace;
            // so does the relay.
            entitlement.expiresAt = max(entitlement.expiresAt ?? graceEnd, graceEnd)
        }
        if notification.notificationType == .refundReversed {
            entitlement.revokedAt = nil
        }
        // The notification's own signing time orders it against others for
        // the same subscription.
        if let signed = notification.signedDate { entitlement.signedAt = max(entitlement.signedAt, signed) }
        return entitlement
    }

    func entitlement(from transaction: JWSTransactionDecodedPayload, status: Status?) throws -> Entitlement {
        guard let productId = transaction.productId else {
            throw EntitlementError.invalidProof("transaction without a product id")
        }
        guard configuration.productIds.contains(productId) else {
            throw EntitlementError.wrongProduct(productId)
        }
        guard let originalTransactionId = transaction.originalTransactionId,
            let signedAt = transaction.signedDate
        else { throw EntitlementError.invalidProof("transaction without an id or signing date") }
        return Entitlement(
            originalTransactionId: originalTransactionId,
            productId: productId,
            expiresAt: transaction.expiresDate,
            revokedAt: transaction.revocationDate ?? (status == .revoked ? signedAt : nil),
            signedAt: signedAt
        )
    }

    static func unwrap<T>(_ result: VerificationResult<T>) throws -> T {
        switch result {
        case .valid(let value): return value
        case .invalid(.RETRYABLE_VERIFICATION_FAILURE):
            throw EntitlementError.retryable("Apple's certificate status service did not answer")
        case .invalid(let error):
            throw EntitlementError.invalidProof(String(describing: error))
        }
    }
}

extension AppStoreEntitlementVerifier {
    /// Reads the App Store configuration from the environment. Returns nil
    /// when `APPSTORE_PRODUCT_IDS` is unset: the relay then does not sell
    /// push, and registration works exactly as before.
    ///
    ///     APPSTORE_PRODUCT_IDS=de.vselas.orcamail.pro.yearly,de.vselas.orcamail.pro.monthly
    ///     APPSTORE_BUNDLE_ID=de.vselas.orcamail      (defaults to APNS_TOPIC)
    ///     APPSTORE_APP_APPLE_ID=1234567890           (required for Production)
    ///     APPSTORE_ENVIRONMENT=Production | Sandbox | Production,Sandbox  (default Production)
    ///
    /// `Production,Sandbox` serves App Store builds and TestFlight (whose
    /// purchases are sandbox transactions) from one relay.
    public static func fromEnvironment(_ environment: [String: String]) throws -> AppStoreEntitlementVerifier? {
        func value(_ name: String) -> String? {
            environment[name].flatMap { $0.trimmingCharacters(in: .whitespaces).isEmpty ? nil : $0 }
        }
        guard let products = value("APPSTORE_PRODUCT_IDS") else { return nil }
        let productIds = Set(products.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty })
        guard let bundleId = value("APPSTORE_BUNDLE_ID") ?? value("APNS_TOPIC") else {
            throw EnvironmentError.missing("APPSTORE_BUNDLE_ID")
        }
        let environmentNames = (value("APPSTORE_ENVIRONMENT") ?? "Production")
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        var appStoreEnvironments: [AppStoreServerLibrary.AppStoreEnvironment] = []
        for name in environmentNames {
            let environment: AppStoreServerLibrary.AppStoreEnvironment
            switch name.lowercased() {
            case "production": environment = .production
            case "sandbox": environment = .sandbox
            default: throw ConfigurationError.unverifiedEnvironment(name)
            }
            if !appStoreEnvironments.contains(environment) { appStoreEnvironments.append(environment) }
        }
        let appAppleId = try value("APPSTORE_APP_APPLE_ID").map { raw -> Int64 in
            guard let id = Int64(raw) else { throw EnvironmentError.invalid("APPSTORE_APP_APPLE_ID") }
            return id
        }
        if appStoreEnvironments.contains(.production), appAppleId == nil {
            throw EnvironmentError.missing("APPSTORE_APP_APPLE_ID")
        }
        return try AppStoreEntitlementVerifier(
            configuration: Configuration(
                bundleId: bundleId,
                appAppleId: appAppleId,
                environments: appStoreEnvironments,
                productIds: productIds
            )
        )
    }

    public enum EnvironmentError: Error, Equatable {
        case missing(String)
        case invalid(String)
    }
}
