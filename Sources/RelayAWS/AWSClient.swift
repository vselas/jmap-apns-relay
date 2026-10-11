import AsyncHTTPClient
import Foundation
import NIOCore
import NIOHTTP1
import RelayCore
import SotoSignerV4

/// Credentials from the Lambda execution role, which the runtime hands every
/// function as environment variables (and refreshes on each new instance).
public struct AWSEnvironment: Sendable {
    public var region: String
    public var credential: StaticCredential
    /// Per-service endpoint overrides, from the SDK-standard
    /// `AWS_ENDPOINT_URL_<SERVICE>` variables — how a local run points at
    /// DynamoDB Local. Empty on Lambda, where the regional endpoints apply.
    public var endpoints: [String: URL]

    public init(region: String, credential: StaticCredential, endpoints: [String: URL] = [:]) {
        self.region = region
        self.credential = credential
        self.endpoints = endpoints
    }

    func endpoint(for service: String) -> URL? {
        endpoints[service] ?? URL(string: "https://\(service).\(region).amazonaws.com/")
    }

    public init(environment: [String: String]) throws {
        guard let region = environment["AWS_REGION"] ?? environment["AWS_DEFAULT_REGION"],
            let accessKeyId = environment["AWS_ACCESS_KEY_ID"],
            let secretAccessKey = environment["AWS_SECRET_ACCESS_KEY"]
        else { throw AWSError.missingCredentials }
        self.init(
            region: region,
            credential: StaticCredential(
                accessKeyId: accessKeyId,
                secretAccessKey: secretAccessKey,
                sessionToken: environment["AWS_SESSION_TOKEN"]
            ),
            endpoints: Dictionary(
                uniqueKeysWithValues: ["dynamodb", "ssm"].compactMap { service in
                    environment["AWS_ENDPOINT_URL_\(service.uppercased())"].flatMap(URL.init(string:)).map { (service, $0) }
                }
            )
        )
    }
}

public enum AWSError: Error, Equatable, CustomStringConvertible {
    case missingCredentials
    /// The service answered with an error. `type` is the short exception name
    /// (`ConditionalCheckFailedException`), already stripped of its namespace.
    case service(status: Int, type: String, message: String)
    case malformedResponse(String)

    public var description: String {
        switch self {
        case .missingCredentials: "AWS credentials are not in the environment"
        case .service(let status, let type, let message): "AWS \(status) \(type): \(message)"
        case .malformedResponse(let detail): "malformed AWS response: \(detail)"
        }
    }
}

/// The two AWS calls the relay makes, both JSON-1.0/1.1 POSTs signed with
/// SigV4. Talking to them directly keeps the Lambda binary — and its cold
/// start — free of a full SDK for what amounts to five operations.
public protocol AWSJSONTransport: Sendable {
    /// Sends `X-Amz-Target: <target>` with a JSON body to `service`, returning
    /// the JSON response. A non-2xx answer throws ``AWSError/service``.
    func call(service: String, target: String, body: [String: Any]) async throws -> [String: Any]
}

public struct SignedAWSTransport: AWSJSONTransport {
    let environment: AWSEnvironment
    let httpClient: HTTPClient
    let timeout: TimeAmount

    public init(environment: AWSEnvironment, httpClient: HTTPClient, timeout: TimeAmount = .seconds(5)) {
        self.environment = environment
        self.httpClient = httpClient
        self.timeout = timeout
    }

    public func call(service: String, target: String, body: [String: Any]) async throws -> [String: Any] {
        let (signingName, contentType): (String, String) =
            switch service {
            case "dynamodb": ("dynamodb", "application/x-amz-json-1.0")
            default: (service, "application/x-amz-json-1.1")
            }
        guard let url = environment.endpoint(for: service) else {
            throw AWSError.malformedResponse("bad endpoint for \(service)")
        }
        let payload = try JSONSerialization.data(withJSONObject: body)
        let signer = AWSSigner(credentials: environment.credential, name: signingName, region: environment.region)
        var headers = HTTPHeaders()
        headers.add(name: "content-type", value: contentType)
        headers.add(name: "x-amz-target", value: target)
        let signed = signer.signHeaders(url: url, method: .POST, headers: headers, body: .data(payload))

        var request = HTTPClientRequest(url: url.absoluteString)
        request.method = .POST
        request.headers = signed
        request.body = .bytes(ByteBuffer(bytes: payload))
        let prepared = request
        // Retried once on a dead pooled connection: the first call after a
        // frozen Lambda instance thaws often goes out on one. Every call the
        // relay makes is safe to repeat (see `retryingStaleConnection`).
        let (response, collected) = try await retryingStaleConnection(target) { [httpClient, timeout] in
            let response = try await httpClient.execute(prepared, timeout: timeout)
            return (response, try await response.body.collect(upTo: 4 * 1024 * 1024))
        }
        let data = Data(buffer: collected)
        let object = (data.isEmpty ? [:] : try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
        guard (200..<300).contains(Int(response.status.code)) else {
            throw Self.serviceError(status: Int(response.status.code), object: object)
        }
        return object
    }

    static func serviceError(status: Int, object: [String: Any]) -> AWSError {
        // `__type` is "com.amazonaws.dynamodb.v20120810#ConditionalCheckFailedException".
        let raw = object["__type"] as? String ?? "HTTP\(status)"
        let type = raw.split(separator: "#").last.map(String.init) ?? raw
        let message = object["message"] as? String ?? object["Message"] as? String ?? ""
        return .service(status: status, type: type, message: message)
    }
}
