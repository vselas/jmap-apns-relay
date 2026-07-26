import Foundation
import Hummingbird
import HummingbirdTesting
import Testing

@testable import PushRelay

@Suite struct RelayTests {
    func makeApp() -> Application<RouterResponder<BasicRequestContext>> {
        let store = RelayStore(persistenceURL: nil)
        return Application(router: buildRouter(store: store, sender: LogPushSender()))
    }

    @Test func registerThenPushThenPoll() async throws {
        let app = makeApp()
        try await app.test(.router) { client in
            // Unregistered device: webhook is rejected.
            let rejected = try await client.execute(
                uri: "/v1/push/dev1", method: .post,
                body: ByteBuffer(string: #"{"@type":"StateChange"}"#)
            )
            #expect(rejected.status == .notFound)

            // Register, push, poll.
            let registered = try await client.execute(
                uri: "/v1/register", method: .post,
                body: ByteBuffer(string: #"{"deviceId":"dev1"}"#)
            )
            #expect(registered.status == .noContent)

            let verification = #"{"@type":"PushVerification","pushSubscriptionId":"ps1","verificationCode":"code-123"}"#
            let pushed = try await client.execute(
                uri: "/v1/push/dev1", method: .post,
                body: ByteBuffer(string: verification)
            )
            #expect(pushed.status == .ok)

            let pending = try await client.execute(uri: "/v1/pending/dev1", method: .get)
            #expect(pending.status == .ok)
            let items = try JSONDecoder().decode(
                [PendingPush].self, from: Data(buffer: pending.body)
            )
            #expect(items.count == 1)
            #expect(items[0].payload.contains("code-123"))

            // Drained: second poll is empty.
            let drained = try await client.execute(uri: "/v1/pending/dev1", method: .get)
            let empty = try JSONDecoder().decode([PendingPush].self, from: Data(buffer: drained.body))
            #expect(empty.isEmpty)
        }
    }

    @Test func healthz() async throws {
        let app = makeApp()
        try await app.test(.router) { client in
            let response = try await client.execute(uri: "/healthz", method: .get)
            #expect(response.status == .ok)
        }
    }

    @Test func queueIsCapped() async throws {
        let store = RelayStore(persistenceURL: nil)
        await store.register(DeviceRegistration(deviceId: "d"))
        for index in 0..<60 {
            await store.enqueue(deviceId: "d", payload: "p\(index)")
        }
        let drained = await store.drain(deviceId: "d")
        #expect(drained.count == 50)
        #expect(drained.first?.payload == "p10")
    }
}
