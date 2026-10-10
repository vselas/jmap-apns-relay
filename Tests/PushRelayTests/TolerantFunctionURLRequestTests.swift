import AWSLambdaEvents
import AWSLambdaRuntime
import Foundation
import HummingbirdLambda
import Testing

@testable import RelayAWS
@testable import RelayCore
@testable import RelayLambdaSupport

/// The event Lambda built for a real Stalwart webhook (captured 2026-10-10,
/// signatures and ids shortened): no `User-Agent`, so `userAgent` is null.
/// The stock `FunctionURLRequest` fails to decode it; that was a 502 for
/// every push Stalwart sent to the hosted relay.
@Suite struct TolerantFunctionURLRequestTests {
    static let ciphertext = Data((0..<230).map { UInt8(($0 * 37) & 0xFF) })

    static func stalwartEvent(userAgent: String? = nil, omitUserAgent: Bool = false) -> Data {
        let agent = omitUserAgent ? "" : #","userAgent":\#(userAgent.map { "\"\($0)\"" } ?? "null")"#
        return Data("""
        {"version":"2.0","routeKey":"$default","rawPath":"/v1/push/dev-1","rawQueryString":"",
         "headers":{"content-length":"230","x-forwarded-proto":"https","content-encoding":"aes128gcm",
           "ttl":"86400","accept":"*/*",
           "authorization":"vapid t=eyJ0eXAiOiJKV1QifQ.eyJhdWQiOiJodHRwczovL3gifQ.sig, k=BJN2AOdKNc0bGT4c",
           "urgency":"normal","host":"relay.lambda-url.eu-central-1.on.aws",
           "content-type":"application/octet-stream","accept-encoding":"gzip,deflate"},
         "requestContext":{"accountId":"anonymous","apiId":"relay","domainName":"relay.lambda-url.eu-central-1.on.aws",
           "domainPrefix":"relay","http":{"method":"POST","path":"/v1/push/dev-1","protocol":"HTTP/1.1",
           "sourceIp":"147.78.126.48"\(agent)},"requestId":"347ac69d","routeKey":"$default","stage":"$default",
           "time":"10/Oct/2026:17:10:47 +0000","timeEpoch":1791652247349},
         "body":"\(ciphertext.base64EncodedString())","isBase64Encoded":true}
        """.utf8)
    }

    /// The bug, pinned: if this ever passes, upstream fixed it and the
    /// wrapper can go.
    @Test func theStockTypeRejectsANullUserAgent() {
        #expect(throws: DecodingError.self) {
            _ = try JSONDecoder().decode(FunctionURLRequest.self, from: Self.stalwartEvent())
        }
    }

    @Test(arguments: [(String?.none, false), (String?.none, true), ("curl/8.7.1", false)])
    func theTolerantTypeDecodesEveryShape(_ agent: String?, _ omit: Bool) throws {
        let event = try JSONDecoder().decode(
            TolerantFunctionURLRequest.self, from: Self.stalwartEvent(userAgent: agent, omitUserAgent: omit)
        )
        #expect(event.request.requestContext.http.userAgent == (agent ?? ""))
        #expect(event.request.requestContext.timeEpoch == 1_791_652_247_349)
        #expect(event.request.isBase64Encoded)
    }

    /// End to end through the real adapter and router: Stalwart's event
    /// lands, the ciphertext arrives intact.
    @Test func stalwartsWebhookReachesTheQueueIntact() async throws {
        typealias Context = BasicLambdaRequestContext<TolerantFunctionURLRequest>
        let store = try RelayStore(persistenceURL: nil)
        try await store.register(DeviceRegistration(deviceId: "dev-1"))
        let router = buildRouter(context: Context.self, store: store, sender: LogPushSender())
        let responder = router.buildResponder()

        let event = try JSONDecoder().decode(TolerantFunctionURLRequest.self, from: Self.stalwartEvent())
        let context = try LambdaContextFixture.make()
        let request = try event.request(context: context)
        #expect(request.uri.path == "/v1/push/dev-1")
        let response = try await responder.respond(
            to: request, context: Context(source: .init(event: event, lambdaContext: context))
        )
        #expect(response.status == .ok)
        let queued = try await store.drain(deviceId: "dev-1")
        #expect(queued.first?.body == Self.ciphertext)
        #expect(queued.first?.contentEncoding == "aes128gcm")
    }
}

enum LambdaContextFixture {
    static func make() throws -> LambdaContext {
        LambdaContext(
            requestID: "test", traceID: "test", tenantID: nil,
            invokedFunctionARN: "arn:aws:lambda:eu-central-1:000000000000:function:test",
            deadline: LambdaClock.maxLambdaDeadline,
            logger: .init(label: "test")
        )
    }
}
