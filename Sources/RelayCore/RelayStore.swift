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

    public init(deviceId: String, apnsToken: String? = nil, registeredAt: Date = .now) {
        self.deviceId = deviceId
        self.apnsToken = apnsToken
        self.registeredAt = registeredAt
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
    /// Adds or replaces a device's registration.
    func register(_ registration: DeviceRegistration) async throws
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
    }

    private struct LegacySnapshot: Codable {
        var registrations: [String: DeviceRegistration]
        var pending: [String: [PendingPush]]
    }

    public enum StoreError: Error, Equatable {
        case unsupportedSnapshotVersion(Int)
    }

    public func register(_ registration: DeviceRegistration) throws {
        let previous = registrations[registration.deviceId]
        registrations[registration.deviceId] = registration
        do {
            try persist()
        } catch {
            registrations[registration.deviceId] = previous
            throw error
        }
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

    private func persist() throws {
        guard let persistenceURL else { return }
        let snapshot = Snapshot(
            version: Snapshot.currentVersion,
            registrations: registrations,
            pending: pending
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
