import AppStoreServerLibrary
import Foundation
import Testing

@testable import RelayAppStore
@testable import RelayCore

/// The production verifier, run against a chain shaped like Apple's. Nothing
/// here uses the library's `xcode` / `localTesting` modes, which skip
/// signature checks; the relay refuses to be configured with them.
@Suite struct AppStoreEntitlementVerifierTests {
    static let bundleId = "de.vselas.orcamail"
    static let product = "de.vselas.orcamail.pro.yearly"

    func makeVerifier(_ signer: FakeAppleSigner, environment: AppStoreServerLibrary.AppStoreEnvironment = .sandbox) throws -> AppStoreEntitlementVerifier {
        try AppStoreEntitlementVerifier(
            configuration: .init(
                bundleId: Self.bundleId, appAppleId: 1_234_567_890, environment: environment,
                productIds: [Self.product], rootCertificates: [signer.rootDER], onlineChecks: false
            )
        )
    }

    func transaction(
        product: String = product, bundle: String = bundleId, environment: String = "Sandbox",
        expires: Date = .now.addingTimeInterval(86400 * 30), signed: Date = .now, revoked: Date? = nil
    ) -> [String: Any] {
        var payload: [String: Any] = [
            "transactionId": "2000000000000002",
            "originalTransactionId": "2000000000000001",
            "bundleId": bundle,
            "productId": product,
            "type": "Auto-Renewable Subscription",
            "purchaseDate": FakeAppleSigner.milliseconds(signed),
            "expiresDate": FakeAppleSigner.milliseconds(expires),
            "signedDate": FakeAppleSigner.milliseconds(signed),
            "environment": environment,
            "inAppOwnershipType": "PURCHASED",
        ]
        if let revoked { payload["revocationDate"] = FakeAppleSigner.milliseconds(revoked) }
        return payload
    }

    @Test func aGenuineTransactionBecomesAnEntitlement() async throws {
        let signer = try FakeAppleSigner()
        let expires = Date(timeIntervalSince1970: (Date.now.timeIntervalSince1970 + 86400 * 30).rounded())
        let entitlement = try await makeVerifier(signer).verify(.signedTransaction(signer.sign(transaction(expires: expires))))
        #expect(entitlement.originalTransactionId == "2000000000000001")
        #expect(entitlement.productId == Self.product)
        #expect(entitlement.expiresAt == expires)
        #expect(entitlement.revokedAt == nil)
        #expect(entitlement.isActive(at: .now))
    }

    @Test func forgeriesAreRefused() async throws {
        let signer = try FakeAppleSigner()
        let verifier = try makeVerifier(signer)

        // Apple's certificates copied into the header, someone else's key.
        await #expect(throws: EntitlementError.self) {
            _ = try await verifier.verify(.signedTransaction(signer.signWithForeignKey(transaction())))
        }
        // A whole chain of the forger's own.
        let stranger = try FakeAppleSigner()
        await #expect(throws: EntitlementError.self) {
            _ = try await verifier.verify(.signedTransaction(stranger.sign(transaction())))
        }
        // A chain whose leaf lacks Apple's receipt-signing OID.
        let notAReceiptSigner = try FakeAppleSigner(leafHasReceiptOID: false)
        await #expect(throws: EntitlementError.self) {
            _ = try await makeVerifier(notAReceiptSigner).verify(.signedTransaction(notAReceiptSigner.sign(transaction())))
        }
        // Not a JWS at all.
        await #expect(throws: EntitlementError.self) {
            _ = try await verifier.verify(.signedTransaction("eyJhbGciOiJub25lIn0.e30."))
        }
    }

    @Test func genuineButNotOursIsRefused() async throws {
        let signer = try FakeAppleSigner()
        let verifier = try makeVerifier(signer)
        await #expect(throws: EntitlementError.self) {
            _ = try await verifier.verify(.signedTransaction(signer.sign(transaction(bundle: "com.other.app"))))
        }
        await #expect(throws: EntitlementError.wrongProduct("de.vselas.orcamail.tip")) {
            _ = try await verifier.verify(.signedTransaction(signer.sign(transaction(product: "de.vselas.orcamail.tip"))))
        }
        // A sandbox purchase does not unlock a production relay.
        await #expect(throws: EntitlementError.self) {
            _ = try await makeVerifier(signer, environment: .production)
                .verify(.signedTransaction(signer.sign(transaction(environment: "Sandbox"))))
        }
    }

    @Test func expiredAndRefundedTransactionsAreInactive() async throws {
        let signer = try FakeAppleSigner()
        let verifier = try makeVerifier(signer)
        let lapsed = try await verifier.verify(
            .signedTransaction(signer.sign(transaction(expires: .now.addingTimeInterval(-7200), signed: .now.addingTimeInterval(-86400))))
        )
        #expect(!lapsed.isActive(at: .now))
        let refunded = try await verifier.verify(.signedTransaction(signer.sign(transaction(revoked: .now))))
        #expect(refunded.revokedAt != nil)
        #expect(!refunded.isActive(at: .now))
    }

    /// `xcode` and `localTesting` skip every signature check in Apple's
    /// library. A relay accepting them would accept anything.
    @Test func unverifiedEnvironmentsAreRefusedAtStartup() {
        for environment in [AppStoreServerLibrary.AppStoreEnvironment.xcode, .localTesting] {
            #expect(throws: AppStoreEntitlementVerifier.ConfigurationError.unverifiedEnvironment(environment.rawValue)) {
                _ = try AppStoreEntitlementVerifier(
                    configuration: .init(bundleId: Self.bundleId, appAppleId: 1, environment: environment, productIds: [Self.product])
                )
            }
        }
        #expect(throws: AppStoreEntitlementVerifier.ConfigurationError.unverifiedEnvironment("Xcode")) {
            _ = try AppStoreEntitlementVerifier.fromEnvironment([
                "APPSTORE_PRODUCT_IDS": Self.product, "APNS_TOPIC": Self.bundleId, "APPSTORE_ENVIRONMENT": "Xcode",
            ])
        }
    }

    @Test func environmentConfiguration() throws {
        #expect(try AppStoreEntitlementVerifier.fromEnvironment([:]) == nil)
        #expect(throws: AppStoreEntitlementVerifier.EnvironmentError.missing("APPSTORE_APP_APPLE_ID")) {
            _ = try AppStoreEntitlementVerifier.fromEnvironment(["APPSTORE_PRODUCT_IDS": Self.product, "APNS_TOPIC": Self.bundleId])
        }
        let verifier = try #require(
            try AppStoreEntitlementVerifier.fromEnvironment([
                "APPSTORE_PRODUCT_IDS": " \(Self.product) , de.vselas.orcamail.pro.monthly ,",
                "APNS_TOPIC": Self.bundleId,
                "APPSTORE_APP_APPLE_ID": "1234567890",
            ])
        )
        #expect(verifier.configuration.productIds == [Self.product, "de.vselas.orcamail.pro.monthly"])
        #expect(verifier.configuration.bundleId == Self.bundleId)
        #expect(verifier.configuration.environments == [.production])
        #expect(verifier.configuration.rootCertificates == AppleRootCertificates.all)
    }

    @Test func bothEnvironmentsFromTheEnvironment() throws {
        let both = try #require(
            try AppStoreEntitlementVerifier.fromEnvironment([
                "APPSTORE_PRODUCT_IDS": Self.product, "APNS_TOPIC": Self.bundleId,
                "APPSTORE_APP_APPLE_ID": "1234567890", "APPSTORE_ENVIRONMENT": " Production , sandbox ",
            ])
        )
        #expect(both.configuration.environments == [.production, .sandbox])
        // Production is in the list, so Apple's app id is still required.
        #expect(throws: AppStoreEntitlementVerifier.EnvironmentError.missing("APPSTORE_APP_APPLE_ID")) {
            _ = try AppStoreEntitlementVerifier.fromEnvironment([
                "APPSTORE_PRODUCT_IDS": Self.product, "APNS_TOPIC": Self.bundleId,
                "APPSTORE_ENVIRONMENT": "Production,Sandbox",
            ])
        }
        let sandbox = try #require(
            try AppStoreEntitlementVerifier.fromEnvironment([
                "APPSTORE_PRODUCT_IDS": Self.product, "APNS_TOPIC": Self.bundleId, "APPSTORE_ENVIRONMENT": "Sandbox",
            ])
        )
        #expect(sandbox.configuration.environments == [.sandbox])
        #expect(throws: AppStoreEntitlementVerifier.ConfigurationError.unverifiedEnvironment("Xcode")) {
            _ = try AppStoreEntitlementVerifier.fromEnvironment([
                "APPSTORE_PRODUCT_IDS": Self.product, "APNS_TOPIC": Self.bundleId,
                "APPSTORE_APP_APPLE_ID": "1", "APPSTORE_ENVIRONMENT": "Production,Xcode",
            ])
        }
        #expect(throws: AppStoreEntitlementVerifier.ConfigurationError.noEnvironments) {
            _ = try AppStoreEntitlementVerifier.fromEnvironment([
                "APPSTORE_PRODUCT_IDS": Self.product, "APNS_TOPIC": Self.bundleId, "APPSTORE_ENVIRONMENT": " , ",
            ])
        }
    }

    // MARK: - Both environments (App Store and TestFlight on one relay)

    func makeBothVerifier(_ signer: FakeAppleSigner) throws -> AppStoreEntitlementVerifier {
        try AppStoreEntitlementVerifier(
            configuration: .init(
                bundleId: Self.bundleId, appAppleId: 1_234_567_890, environments: [.production, .sandbox],
                productIds: [Self.product], rootCertificates: [signer.rootDER], onlineChecks: false
            )
        )
    }

    @Test func bothEnvironmentsAcceptAppStoreAndTestFlightPurchases() async throws {
        let signer = try FakeAppleSigner()
        let verifier = try makeBothVerifier(signer)
        for environment in ["Production", "Sandbox"] {
            let entitlement = try await verifier.verify(.signedTransaction(signer.sign(transaction(environment: environment))))
            #expect(entitlement.productId == Self.product)
        }
    }

    @Test func bothEnvironmentsStillRefuseForgeriesAndOtherApps() async throws {
        let signer = try FakeAppleSigner()
        let verifier = try makeBothVerifier(signer)
        // Falling through to the next environment never weakens another check.
        await #expect(throws: EntitlementError.self) {
            _ = try await verifier.verify(.signedTransaction(signer.sign(transaction(bundle: "com.other.app"))))
        }
        await #expect(throws: EntitlementError.self) {
            _ = try await verifier.verify(.signedTransaction(signer.sign(transaction(environment: "Xcode"))))
        }
        let stranger = try FakeAppleSigner()
        await #expect(throws: EntitlementError.self) {
            _ = try await verifier.verify(.signedTransaction(stranger.sign(transaction(environment: "Sandbox"))))
        }
    }

    @Test func bothEnvironmentsTakeSandboxNotifications() async throws {
        let signer = try FakeAppleSigner()
        let renewedUntil = Date(timeIntervalSince1970: (Date.now.timeIntervalSince1970 + 86400 * 30).rounded())
        let entitlement = try #require(
            try await makeBothVerifier(signer).verifyNotification(
                signedPayload: notification(
                    type: "DID_RENEW",
                    transaction: transaction(expires: renewedUntil),
                    signer: signer
                )
            )
        )
        #expect(entitlement.expiresAt == renewedUntil)
    }

    @Test func theEmbeddedAppleRootIsIntact() {
        // The accessor checks the fingerprint and traps if it is wrong;
        // reaching this line with one certificate means it held.
        #expect(AppleRootCertificates.all.count == 1)
        #expect(AppleRootCertificates.all[0].count == 583)
    }

    // MARK: - Server notifications

    func notification(type: String, subtype: String? = nil, status: Int? = nil, transaction: [String: Any], renewal: [String: Any]? = nil, signer: FakeAppleSigner, signed: Date = .now) throws -> String {
        var data: [String: Any] = [
            "bundleId": Self.bundleId,
            "appAppleId": 1_234_567_890,
            "environment": "Sandbox",
            "signedTransactionInfo": try signer.sign(transaction),
        ]
        if let status { data["status"] = status }
        if let renewal { data["signedRenewalInfo"] = try signer.sign(renewal) }
        var payload: [String: Any] = [
            "notificationType": type,
            "notificationUUID": UUID().uuidString,
            "version": "2.0",
            "signedDate": FakeAppleSigner.milliseconds(signed),
            "data": data,
        ]
        if let subtype { payload["subtype"] = subtype }
        return try signer.sign(payload)
    }

    @Test func aRenewalNotificationExtendsTheEntitlement() async throws {
        let signer = try FakeAppleSigner()
        let renewedUntil = Date(timeIntervalSince1970: (Date.now.timeIntervalSince1970 + 86400 * 365).rounded())
        let entitlement = try #require(
            try await makeVerifier(signer).verifyNotification(
                signedPayload: notification(type: "DID_RENEW", status: 1, transaction: transaction(expires: renewedUntil), signer: signer)
            )
        )
        #expect(entitlement.expiresAt == renewedUntil)
        #expect(entitlement.isActive(at: .now))
    }

    @Test func aRefundNotificationRevokes() async throws {
        let signer = try FakeAppleSigner()
        let entitlement = try #require(
            try await makeVerifier(signer).verifyNotification(
                signedPayload: notification(type: "REFUND", status: 5, transaction: transaction(revoked: .now), signer: signer)
            )
        )
        #expect(!entitlement.isActive(at: .now))
    }

    /// Apple keeps a subscriber in service through billing grace; so do we.
    @Test func billingGraceKeepsPushOn() async throws {
        let signer = try FakeAppleSigner()
        let graceEnds = Date(timeIntervalSince1970: (Date.now.timeIntervalSince1970 + 86400 * 6).rounded())
        let renewal: [String: Any] = [
            "originalTransactionId": "2000000000000001",
            "productId": Self.product,
            "autoRenewProductId": Self.product,
            "autoRenewStatus": 1,
            "isInBillingRetryPeriod": true,
            "gracePeriodExpiresDate": FakeAppleSigner.milliseconds(graceEnds),
            "signedDate": FakeAppleSigner.milliseconds(.now),
            "environment": "Sandbox",
        ]
        let entitlement = try #require(
            try await makeVerifier(signer).verifyNotification(
                signedPayload: notification(
                    type: "DID_FAIL_TO_RENEW", subtype: "GRACE_PERIOD", status: 4,
                    transaction: transaction(expires: .now.addingTimeInterval(-3600)), renewal: renewal, signer: signer
                )
            )
        )
        #expect(entitlement.expiresAt == graceEnds)
        #expect(entitlement.isActive(at: .now))
    }

    @Test func notificationsThatChangeNothingAreIgnoredAndForgedOnesRefused() async throws {
        let signer = try FakeAppleSigner()
        let verifier = try makeVerifier(signer)
        let test = try signer.sign([
            "notificationType": "TEST", "notificationUUID": UUID().uuidString, "version": "2.0",
            "signedDate": FakeAppleSigner.milliseconds(.now),
            "data": ["bundleId": Self.bundleId, "appAppleId": 1_234_567_890, "environment": "Sandbox"],
        ])
        #expect(try await verifier.verifyNotification(signedPayload: test) == nil)
        let otherProduct = try notification(type: "DID_RENEW", status: 1, transaction: transaction(product: "de.vselas.orcamail.tip"), signer: signer)
        #expect(try await verifier.verifyNotification(signedPayload: otherProduct) == nil)

        let stranger = try FakeAppleSigner()
        await #expect(throws: EntitlementError.self) {
            _ = try await verifier.verifyNotification(
                signedPayload: notification(type: "DID_RENEW", status: 1, transaction: transaction(), signer: stranger)
            )
        }
    }
}
