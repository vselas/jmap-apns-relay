import Foundation

/// Writes a line to stdout with an immediate `write(2)`, so `[push]` logs show
/// up live in `docker logs` — a piped stdout is otherwise block-buffered, and
/// Glibc's `stdout` global isn't usable under strict concurrency.
func relayLog(_ message: String) {
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
    func send(_ push: PendingPush, to registration: DeviceRegistration) async
}

/// Dev-mode sender: the queue plus the `/v1/pending` poll endpoint stand in
/// for APNs.
public struct LogPushSender: PushSender {
    public init() {}

    public func send(_ push: PendingPush, to registration: DeviceRegistration) async {
        // Never log the body itself: for a plaintext payload that is the
        // account id and what changed in it, which is exactly what the relay
        // should not be keeping.
        let shape = push.isEncrypted ? "encrypted \(push.body.count)B" : "plaintext \(push.body.count)B"
        relayLog(
            "[push] would deliver to \(registration.deviceId) "
                + "(apns: \(registration.apnsToken == nil ? "none" : "set")): \(shape)"
        )
    }
}

/// Device registry + per-device pending queues, persisted as JSON so the
/// relay survives restarts. Single actor — relay state is tiny.
public actor RelayStore {
    private var registrations: [String: DeviceRegistration] = [:]
    private var pending: [String: [PendingPush]] = [:]
    private let persistenceURL: URL?
    private let maxQueue = 50

    public init(persistenceURL: URL?) {
        self.persistenceURL = persistenceURL
        if let persistenceURL,
            let data = try? Data(contentsOf: persistenceURL),
            let snapshot = try? JSONDecoder().decode(Snapshot.self, from: data)
        {
            registrations = snapshot.registrations
            pending = snapshot.pending
        }
    }

    private struct Snapshot: Codable {
        var registrations: [String: DeviceRegistration]
        var pending: [String: [PendingPush]]
    }

    public func register(_ registration: DeviceRegistration) {
        registrations[registration.deviceId] = registration
        persist()
    }

    public func registration(deviceId: String) -> DeviceRegistration? {
        registrations[deviceId]
    }

    public func enqueue(deviceId: String, push: PendingPush) {
        var queue = pending[deviceId, default: []]
        queue.append(push)
        if queue.count > maxQueue {
            queue.removeFirst(queue.count - maxQueue)
        }
        pending[deviceId] = queue
        persist()
    }

    /// Returns and clears the device's queue.
    public func drain(deviceId: String) -> [PendingPush] {
        let queue = pending[deviceId] ?? []
        pending[deviceId] = []
        persist()
        return queue
    }

    private func persist() {
        guard let persistenceURL else { return }
        let snapshot = Snapshot(registrations: registrations, pending: pending)
        if let data = try? JSONEncoder().encode(snapshot) {
            try? data.write(to: persistenceURL, options: .atomic)
        }
    }
}
