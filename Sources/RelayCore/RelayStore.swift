import Foundation

/// Writes a line to stdout with an immediate `write(2)`, so `[push]` logs show
/// up live in `docker logs` — a piped stdout is otherwise block-buffered, and
/// Glibc's `stdout` global isn't usable under strict concurrency.
public func relayLog(_ message: String) {
    try? FileHandle.standardOutput.write(contentsOf: Data((message + "\n").utf8))
}

/// A push message queued for a device, forwarded verbatim.
///
/// The body is bytes rather than a `String` on purpose. When a subscription
/// carries RFC 8291 keys the server encrypts what it sends, and the result is
/// binary: forcing it through `String(decoding:as:UTF8.self)` mangles it, and
/// reading it with `readString` yields nil. Bytes are also the honest model —
/// the relay's job is to carry this somewhere, not to understand it.
public struct PendingPush: Sendable, Codable, Equatable {
    public var receivedAt: Date
    /// The request body exactly as it arrived. Base64 in JSON, since `Data`
    /// is what `Codable` encodes it as.
    public var body: Data
    /// The body's `Content-Encoding`. `aes128gcm` means the payload is
    /// encrypted to the device and unreadable here; nil means plain JSON.
    public var contentEncoding: String?

    public init(receivedAt: Date = .now, body: Data, contentEncoding: String? = nil) {
        self.receivedAt = receivedAt
        self.body = body
        self.contentEncoding = contentEncoding
    }

    /// True when the payload is encrypted to the device — the relay can route
    /// it but never read it.
    public var isEncrypted: Bool { contentEncoding?.lowercased() == "aes128gcm" }

    /// The body as text, when it *is* text. Nil for an encrypted payload,
    /// which keeps callers from accidentally treating ciphertext as JSON.
    public var text: String? {
        isEncrypted ? nil : String(data: body, encoding: .utf8)
    }
}

/// A registered device.
public struct DeviceRegistration: Sendable, Codable, Equatable {
    public var deviceId: String
    /// APNs device token; absent in dev/poll mode.
    public var apnsToken: String?
    public var registeredAt: Date
    /// The App Store subscription that pays for this device's push
    /// (`Entitlement.originalTransactionId`). Nil on a relay that does not
    /// sell push, and absent from snapshots written before it did, which is
    /// why it is optional rather than versioning the snapshot.
    public var entitlementId: String?

    public init(deviceId: String, apnsToken: String? = nil, registeredAt: Date = .now, entitlementId: String? = nil) {
        self.deviceId = deviceId
        self.apnsToken = apnsToken
        self.registeredAt = registeredAt
        self.entitlementId = entitlementId
    }
}

/// Delivers a push payload to a device. The production implementation
/// speaks APNs (APNSwift + a .p8 key); the development implementation logs
/// and relies on the poll endpoint.
public protocol PushSender: Sendable {
    func send(_ push: PendingPush, to registration: DeviceRegistration) async -> DeliveryOutcome
}

public enum DeliveryOutcome: Sendable, Equatable {
    case delivered
    case skipped(reason: String)
    case invalidToken(reason: String)
    case transientFailure(reason: String)
    case permanentFailure(reason: String)
}

/// Dev-mode sender: the queue plus the `/v1/pending` poll endpoint stand in
/// for APNs.
public struct LogPushSender: PushSender {
    public init() {}

    public func send(_ push: PendingPush, to registration: DeviceRegistration) async -> DeliveryOutcome {
        // Never log the body itself: for a plaintext payload that is the
        // account id and what changed in it, which is exactly what the relay
        // should not be keeping.
        let shape = push.isEncrypted ? "encrypted \(push.body.count)B" : "plaintext \(push.body.count)B"
        relayLog(
            "[push] would deliver to \(registration.deviceId) "
                + "(apns: \(registration.apnsToken == nil ? "none" : "set")): \(shape)"
        )
        return .skipped(reason: "development log sender")
    }
}

/// Where the relay keeps its device registry and per-device pending queues.
///
/// Two implementations: ``RelayStore`` (a JSON file, for the single-process
/// Docker relay) and `DynamoDBRelayStore` in `RelayAWS` (for Lambda, where
/// many short-lived instances share state and none has a lasting disk).
/// Every method may suspend, and every write may fail; a failure is thrown,
/// never swallowed, so the caller can tell Stalwart the push was not taken.
public protocol RelayStorage: Sendable {
    /// Adds or updates a device's registration and returns what is now stored.
    ///
    /// A registration that carries no APNs token keeps the one already stored.
    /// The app registers at launch before iOS has issued it a token, then again
    /// once the token arrives, and the two requests race: when the tokenless
    /// one landed last it erased the token, and every push after that was
    /// skipped until the next launch happened to win. Only
    /// ``invalidateAPNsToken(deviceId:token:)`` clears a token. The entitlement
    /// is still replaced, so a device can move off a subscription.
    @discardableResult
    func register(_ registration: DeviceRegistration) async throws -> DeviceRegistration
    func registration(deviceId: String) async throws -> DeviceRegistration?
    /// Appends to a device's queue, keeping at most
    /// ``RelayLimits/maxPendingPerDevice`` of the newest entries.
    func enqueue(deviceId: String, push: PendingPush) async throws
    /// Returns and clears the device's queue, oldest first.
    func drain(deviceId: String) async throws -> [PendingPush]
    /// Removes a registration and its queue; false when there was none.
    func unregister(deviceId: String) async throws -> Bool
    /// Clears the APNs token, but only while it is still `token` — a device
    /// that re-registered in the meantime keeps its new one.
    func invalidateAPNsToken(deviceId: String, token: String) async throws
    func isReady() async -> Bool

    // MARK: Entitlements (only used when the relay sells push)

    func entitlement(id: String) async throws -> Entitlement?
    /// Stores `entitlement`, keeping whichever of it and the stored one Apple
    /// signed later (`Entitlement.merged`). Returns what is now stored.
    @discardableResult
    func upsertEntitlement(_ entitlement: Entitlement) async throws -> Entitlement
    /// Device ids currently registered against an entitlement.
    func devices(entitlementId: String) async throws -> [String]
}

public enum RelayLimits {
    public static let maxPendingPerDevice = 50
    public static let maxWebhookBytes = 64 * 1024
    public static let maxDeviceIdLength = 128
}

/// Device registry + per-device pending queues, persisted as JSON so the
/// relay survives restarts. Single actor — relay state is tiny.
public actor RelayStore: RelayStorage {
    private var registrations: [String: DeviceRegistration] = [:]
    private var pending: [String: [PendingPush]] = [:]
    private var entitlements: [String: Entitlement] = [:]
    private let persistenceURL: URL?
    private let maxQueue = RelayLimits.maxPendingPerDevice

    private var persistenceError: String?

    public init(persistenceURL: URL?) throws {
        self.persistenceURL = persistenceURL
        guard let persistenceURL else { return }
        let parent = persistenceURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        guard FileManager.default.fileExists(atPath: persistenceURL.path) else { return }
        let data = try Data(contentsOf: persistenceURL)
        let decoder = JSONDecoder()
        if let snapshot = try? decoder.decode(Snapshot.self, from: data) {
            guard snapshot.version == Snapshot.currentVersion else {
                throw StoreError.unsupportedSnapshotVersion(snapshot.version)
            }
            registrations = snapshot.registrations
            pending = snapshot.pending
            entitlements = snapshot.entitlements ?? [:]
        } else {
            let legacy = try decoder.decode(LegacySnapshot.self, from: data)
            registrations = legacy.registrations
            pending = legacy.pending
            let migrated = Snapshot(
                version: Snapshot.currentVersion,
                registrations: registrations,
                pending: pending
            )
            try JSONEncoder().encode(migrated).write(to: persistenceURL, options: .atomic)
        }
    }

    private struct Snapshot: Codable {
        static let currentVersion = 1
        var version: Int
        var registrations: [String: DeviceRegistration]
        var pending: [String: [PendingPush]]
        /// Optional so a version-1 snapshot from before entitlements reads.
        var entitlements: [String: Entitlement]? = nil
    }

    private struct LegacySnapshot: Codable {
        var registrations: [String: DeviceRegistration]
        var pending: [String: [PendingPush]]
    }

    public enum StoreError: Error, Equatable {
        case unsupportedSnapshotVersion(Int)
    }

    @discardableResult
    public func register(_ registration: DeviceRegistration) throws -> DeviceRegistration {
        let previous = registrations[registration.deviceId]
        var stored = registration
        stored.apnsToken = registration.apnsToken ?? previous?.apnsToken
        registrations[registration.deviceId] = stored
        do {
            try persist()
        } catch {
            registrations[registration.deviceId] = previous
            throw error
        }
        return stored
    }

    public func registration(deviceId: String) -> DeviceRegistration? {
        registrations[deviceId]
    }

    public func enqueue(deviceId: String, push: PendingPush) throws {
        let previous = pending[deviceId]
        var queue = pending[deviceId, default: []]
        queue.append(push)
        if queue.count > maxQueue {
            queue.removeFirst(queue.count - maxQueue)
        }
        pending[deviceId] = queue
        do {
            try persist()
        } catch {
            pending[deviceId] = previous
            throw error
        }
    }

    /// Returns and clears the device's queue.
    public func drain(deviceId: String) throws -> [PendingPush] {
        let queue = pending[deviceId] ?? []
        pending[deviceId] = []
        do {
            try persist()
        } catch {
            pending[deviceId] = queue
            throw error
        }
        return queue
    }

    public func unregister(deviceId: String) throws -> Bool {
        guard let registration = registrations.removeValue(forKey: deviceId) else { return false }
        let queued = pending.removeValue(forKey: deviceId)
        do {
            try persist()
            return true
        } catch {
            registrations[deviceId] = registration
            pending[deviceId] = queued
            throw error
        }
    }

    public func invalidateAPNsToken(deviceId: String, token: String) throws {
        guard var registration = registrations[deviceId], registration.apnsToken == token else { return }
        let previous = registration
        registration.apnsToken = nil
        registrations[deviceId] = registration
        do {
            try persist()
        } catch {
            registrations[deviceId] = previous
            throw error
        }
    }

    public func isReady() -> Bool { persistenceError == nil }

    public func entitlement(id: String) -> Entitlement? { entitlements[id] }

    @discardableResult
    public func upsertEntitlement(_ entitlement: Entitlement) throws -> Entitlement {
        let previous = entitlements[entitlement.originalTransactionId]
        let merged = previous?.merged(with: entitlement) ?? entitlement
        entitlements[entitlement.originalTransactionId] = merged
        do {
            try persist()
        } catch {
            entitlements[entitlement.originalTransactionId] = previous
            throw error
        }
        return merged
    }

    public func devices(entitlementId: String) -> [String] {
        registrations.values.filter { $0.entitlementId == entitlementId }.map(\.deviceId).sorted()
    }

    private func persist() throws {
        guard let persistenceURL else { return }
        let snapshot = Snapshot(
            version: Snapshot.currentVersion,
            registrations: registrations,
            pending: pending,
            entitlements: entitlements.isEmpty ? nil : entitlements
        )
        do {
            let data = try JSONEncoder().encode(snapshot)
            try data.write(to: persistenceURL, options: .atomic)
            persistenceError = nil
        } catch {
            persistenceError = String(describing: error)
            throw error
        }
    }
}
