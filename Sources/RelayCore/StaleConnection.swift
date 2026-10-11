import AsyncHTTPClient
import NIOCore

/// Whether a request failed because the pooled connection it went out on was
/// already dead, rather than because the far end refused it.
///
/// On Lambda this is routine. An instance is frozen between invocations, and
/// the connections in its pool die while it is: DynamoDB and APNs close idle
/// ones, and nothing in the frozen process notices. The first request after a
/// quiet spell then goes out on a closed channel. The webhook answered 500,
/// that push was lost, and the log read only "I/O on closed channel".
public func isStaleConnection(_ error: any Error) -> Bool {
    if let error = error as? HTTPClientError {
        return error == .remoteConnectionClosed
    }
    switch error as? ChannelError {
    case .ioOnClosedChannel?, .alreadyClosed?, .eof?, .outputClosed?, .inputClosed?:
        return true
    default:
        return false
    }
}

/// Runs `operation`, and once more if it failed on a stale connection: the
/// pool drops the dead connection, so the second attempt opens a fresh one.
///
/// Once, not in a loop. A second failure is not a stale pool, and it is
/// thrown. Only for requests that are safe to repeat — every one the relay
/// makes is, since an item is written under a fixed key and an APNs request
/// that never left a closed channel was never delivered.
public func retryingStaleConnection<T: Sendable>(
    _ label: String,
    _ operation: () async throws -> T
) async throws -> T {
    do {
        return try await operation()
    } catch where isStaleConnection(error) {
        relayLog("[push] \(label): stale connection (\(error)), retrying once")
        return try await operation()
    }
}
