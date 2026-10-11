import AsyncHTTPClient
import NIOCore
import Synchronization
import Testing

@testable import RelayCore

@Suite struct StaleConnectionTests {
    @Test func deadPooledConnectionsCountAsStale() {
        #expect(isStaleConnection(ChannelError.ioOnClosedChannel))
        #expect(isStaleConnection(ChannelError.eof))
        #expect(isStaleConnection(HTTPClientError.remoteConnectionClosed))
    }

    /// A timeout or a refusal is not a dead pool, and repeating it would only
    /// double the wait.
    @Test func otherFailuresAreNot() {
        #expect(!isStaleConnection(HTTPClientError.deadlineExceeded))
        #expect(!isStaleConnection(ChannelError.connectTimeout(.seconds(1))))
        #expect(!isStaleConnection(CancellationError()))
    }

    @Test func aStaleConnectionIsRetriedOnce() async throws {
        let attempts = Mutex(0)
        let value = try await retryingStaleConnection("test") {
            let attempt = attempts.withLock { $0 += 1; return $0 }
            if attempt == 1 { throw ChannelError.ioOnClosedChannel }
            return "ok"
        }
        #expect(value == "ok")
        #expect(attempts.withLock { $0 } == 2)
    }

    @Test func aSecondFailureIsThrown() async {
        let attempts = Mutex(0)
        await #expect(throws: ChannelError.self) {
            try await retryingStaleConnection("test") { () async throws -> String in
                attempts.withLock { $0 += 1 }
                throw ChannelError.ioOnClosedChannel
            }
        }
        #expect(attempts.withLock { $0 } == 2)
    }

    @Test func otherErrorsAreNotRetried() async {
        let attempts = Mutex(0)
        await #expect(throws: HTTPClientError.self) {
            try await retryingStaleConnection("test") { () async throws -> String in
                attempts.withLock { $0 += 1 }
                throw HTTPClientError.deadlineExceeded
            }
        }
        #expect(attempts.withLock { $0 } == 1)
    }
}
