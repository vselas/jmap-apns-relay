import Foundation
import Testing

@testable import RelayAWS
@testable import RelayCore

/// Lapsed entitlements are deleted `Entitlement.retention` after they stop
/// paying for anything, so the relay keeps no purchase record forever.
@Suite struct EntitlementRetentionTests {
    static let day: TimeInterval = 24 * 3600
    static let periodEnd = Date(timeIntervalSince1970: 1_800_000_000)

    static func entitlement(expiresAt: Date? = periodEnd, revokedAt: Date? = nil) -> Entitlement {
        Entitlement(
            originalTransactionId: "sub1", productId: "pro",
            expiresAt: expiresAt, revokedAt: revokedAt, signedAt: periodEnd.addingTimeInterval(-30 * day)
        )
    }

    // MARK: - Entitlement

    @Test func deletableRetentionAfterThePeriodEnds() {
        #expect(Entitlement.retention == 90 * Self.day)
        #expect(Self.entitlement().deletableAfter() == Self.periodEnd.addingTimeInterval(90 * Self.day))
    }

    @Test func aRevocationStartsTheRetentionInstead() {
        let refunded = Self.periodEnd.addingTimeInterval(-10 * Self.day)
        let entitlement = Self.entitlement(revokedAt: refunded)
        #expect(entitlement.deletableAfter() == refunded.addingTimeInterval(90 * Self.day))
    }

    @Test func aNonExpiringPurchaseStillHeldIsKept() {
        #expect(Self.entitlement(expiresAt: nil).deletableAfter() == nil)
    }

    // MARK: - DynamoDB

    static func storedItem(_ db: FakeDynamoDB) async throws -> [String: Any] {
        let response = try await db.call(service: "dynamodb", target: "DynamoDB_20120810.GetItem", body: [
            "TableName": "relay", "Key": DynamoDBRelayStore.entitlementKey("sub1"),
        ])
        return try #require(response["Item"] as? [String: Any])
    }

    @Test func dynamoEntitlementsCarryTheirRetentionAsTTL() async throws {
        let db = FakeDynamoDB()
        let store = DynamoDBRelayStore(transport: db, table: "relay")
        try await store.upsertEntitlement(Self.entitlement())

        let item = try await Self.storedItem(db)
        let deletable = Self.periodEnd.addingTimeInterval(90 * Self.day)
        #expect(DynamoDBRelayStore.int(item["expiresAt"]) == Int(deletable.timeIntervalSince1970))
        // The period end keeps its own name, so the TTL never deletes it at lapse.
        #expect(DynamoDBRelayStore.date(item["periodEndsAt"]) == Self.periodEnd)
    }

    @Test func aRenewalMovesTheTTLOn() async throws {
        let db = FakeDynamoDB()
        let store = DynamoDBRelayStore(transport: db, table: "relay")
        try await store.upsertEntitlement(Self.entitlement())
        var renewed = Self.entitlement(expiresAt: Self.periodEnd.addingTimeInterval(30 * Self.day))
        renewed.signedAt = Self.periodEnd
        try await store.upsertEntitlement(renewed)

        let item = try await Self.storedItem(db)
        let deletable = Self.periodEnd.addingTimeInterval(120 * Self.day)
        #expect(DynamoDBRelayStore.int(item["expiresAt"]) == Int(deletable.timeIntervalSince1970))
    }

    @Test func aNonExpiringDynamoEntitlementHasNoTTL() async throws {
        let db = FakeDynamoDB()
        try await DynamoDBRelayStore(transport: db, table: "relay").upsertEntitlement(Self.entitlement(expiresAt: nil))
        let item = try await Self.storedItem(db)
        #expect(item["expiresAt"] == nil)
    }

    // MARK: - File store

    final class Clock: @unchecked Sendable {
        var now: Date
        init(_ now: Date) { self.now = now }
    }

    @Test func theFileStoreForgetsAnEntitlementPastItsRetention() async throws {
        let clock = Clock(Self.periodEnd)
        let store = try RelayStore(persistenceURL: nil, now: { clock.now })
        try await store.upsertEntitlement(Self.entitlement())

        clock.now = Self.periodEnd.addingTimeInterval(89 * Self.day)
        #expect(await store.entitlement(id: "sub1") != nil)
        clock.now = Self.periodEnd.addingTimeInterval(91 * Self.day)
        #expect(await store.entitlement(id: "sub1") == nil)
    }

    @Test func aRestartDropsLapsedEntitlementsFromDisk() async throws {
        let url = FileManager.default.temporaryDirectory
            .appending(path: "relay-retention-\(UUID().uuidString)/state.json")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        let clock = Clock(Self.periodEnd)
        let store = try RelayStore(persistenceURL: url, now: { clock.now })
        try await store.upsertEntitlement(Self.entitlement())
        var kept = Self.entitlement(expiresAt: Self.periodEnd.addingTimeInterval(365 * Self.day))
        kept.originalTransactionId = "sub2"
        try await store.upsertEntitlement(kept)

        clock.now = Self.periodEnd.addingTimeInterval(100 * Self.day)
        let restarted = try RelayStore(persistenceURL: url, now: { clock.now })
        #expect(await restarted.entitlement(id: "sub1") == nil)
        #expect(await restarted.entitlement(id: "sub2") == kept)

        let onDisk = try String(contentsOf: url, encoding: .utf8)
        #expect(!onDisk.contains("sub1"))
        #expect(onDisk.contains("sub2"))
    }
}
