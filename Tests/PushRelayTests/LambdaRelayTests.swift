import AWSLambdaEvents
import ExtrasBase64
import Foundation
import HummingbirdLambda
import HummingbirdLambdaTesting
import Testing

@testable import RelayAWS
@testable import RelayCore

/// The relay protocol through the real Function URL adapter and the DynamoDB
/// store: what the Lambda serves, minus AWS itself.
@Suite struct LambdaRelayTests {
    typealias Context = BasicLambdaRequestContext<FunctionURLRequest>

    func makeLambda(authToken: String? = "s3cret") -> FunctionURLLambdaFunction<RouterResponder<Context>> {
        let store = DynamoDBRelayStore(transport: FakeDynamoDB(), table: "relay")
        let router = buildRouter(context: Context.self, store: store, sender: LogPushSender(), authToken: authToken)
        return FunctionURLLambdaFunction(router: router)
    }

    @Test func registerPushPollOverFunctionURL() async throws {
        let lambda = makeLambda()
        try await lambda.test { client in
            try await client.execute(uri: "/v1/push/dev1", method: .post, body: ByteBuffer(string: "{}")) {
                #expect($0.statusCode == .notFound)
            }
            try await client.execute(
                uri: "/v1/register", method: .post,
                body: ByteBuffer(string: #"{"deviceId":"dev1"}"#)
            ) { #expect($0.statusCode == .unauthorized) }
            try await client.execute(
                uri: "/v1/register", method: .post,
                headers: [.authorization: "Bearer s3cret", .contentType: "application/json"],
                body: ByteBuffer(string: #"{"deviceId":"dev1","apnsToken":"tok"}"#)
            ) { #expect($0.statusCode == .noContent) }

            let verification = #"{"@type":"PushVerification","pushSubscriptionId":"ps1","verificationCode":"code-123"}"#
            try await client.execute(
                uri: "/v1/push/dev1", method: .post, body: ByteBuffer(string: verification)
            ) { #expect($0.statusCode == .ok) }

            try await client.execute(
                uri: "/v1/pending/dev1", method: .get, headers: [.authorization: "Bearer s3cret"]
            ) { response in
                #expect(response.statusCode == .ok)
                let items = try JSONDecoder().decode([PendingPush].self, from: Self.bodyData(response))
                #expect(items.count == 1)
                #expect(items.first?.text?.contains("code-123") == true)
            }
        }
    }

    /// A Function URL hands binary bodies over base64-encoded; what reaches
    /// the queue must be the original bytes, not their base64 or a UTF-8
    /// mangling of them.
    @Test func encryptedBytesSurviveTheFunctionURL() async throws {
        let ciphertext = Data([0x00, 0xFF, 0xFE, 0x80, 0x41, 0x04, 0xC3, 0x28, 0x7B, 0x00])
        let lambda = makeLambda()
        try await lambda.test { client in
            try await client.execute(
                uri: "/v1/register", method: .post,
                headers: [.authorization: "Bearer s3cret"],
                body: ByteBuffer(string: #"{"deviceId":"dev1"}"#)
            ) { #expect($0.statusCode == .noContent) }
            try await client.execute(
                uri: "/v1/push/dev1", method: .post,
                headers: [.contentEncoding: "aes128gcm"],
                body: ByteBuffer(data: ciphertext)
            ) { #expect($0.statusCode == .ok) }
            try await client.execute(
                uri: "/v1/pending/dev1", method: .get, headers: [.authorization: "Bearer s3cret"]
            ) { response in
                let items = try JSONDecoder().decode([PendingPush].self, from: Self.bodyData(response))
                #expect(items.first?.body == ciphertext)
                #expect(items.first?.isEncrypted == true)
            }
        }
    }

    @Test func capabilitiesMatchTheProtocolFixture() async throws {
        let lambda = makeLambda()
        try await lambda.test { client in
            try await client.execute(uri: "/v1/capabilities", method: .get) { response in
                #expect(response.statusCode == .ok)
                let root = try #require(
                    try JSONSerialization.jsonObject(with: Self.bodyData(response)) as? [String: Any]
                )
                #expect(root["protocol"] as? String == "jmap-apns-relay")
                let limits = try #require(root["limits"] as? [String: Any])
                #expect(limits["maxPendingPerDevice"] as? Int == 50)
                #expect(limits["maxWebhookBytes"] as? Int == 65_536)
            }
        }
    }

    static func bodyData(_ response: FunctionURLResponse) throws -> Data {
        let body = response.body ?? ""
        if response.isBase64Encoded == true {
            return Data(try body.base64decoded())
        }
        return Data(body.utf8)
    }
}
