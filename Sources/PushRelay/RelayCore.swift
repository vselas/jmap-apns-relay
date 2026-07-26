import Foundation

/// Writes a line to stdout with an immediate `write(2)`, so `[push]` logs show
/// up live in `docker logs` — a piped stdout is otherwise block-buffered, and
/// Glibc's `stdout` global isn't usable under strict concurrency.
func relayLog(_ message: String) {
    try? FileHandle.standardOutput.write(contentsOf: Data((message + "\n").utf8))
}

/// A push message queued for a device: either Stalwart's PushVerification
/// or a StateChange, forwarded verbatim.
public struct PendingPush: Sendable, Codable, Equatable {
    public var receivedAt: Date
    public var payload: String

    public init(receivedAt: Date = .now, payload: String) {
        self.receivedAt = receivedAt
        self.payload = payload
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
    func send(payload: String, to registration: DeviceRegistration) async
}

/// Dev-mode sender: the queue plus the `/v1/pending` poll endpoint stand in
/// for APNs.
public struct LogPushSender: PushSender {
    public init() {}

    public func send(payload: String, to registration: DeviceRegistration) async {
        relayLog("[push] would deliver to \(registration.deviceId) (apns: \(registration.apnsToken ?? "none")): \(payload.prefix(200))")
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

    public func enqueue(deviceId: String, payload: String) {
        var queue = pending[deviceId, default: []]
        queue.append(PendingPush(payload: payload))
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
