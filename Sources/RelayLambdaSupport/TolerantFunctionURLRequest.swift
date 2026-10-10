import AWSLambdaEvents
import AWSLambdaRuntime
import Foundation
import HummingbirdLambda

/// A Function URL event that tolerates a request with no `User-Agent`.
///
/// When a caller sends no `User-Agent`, Lambda puts `"userAgent": null` in
/// `requestContext.http`, and `AWSLambdaEvents.FunctionURLRequest` (1.5.0 and
/// main as of 2026-10) declares that field a non-optional `String`. Decoding
/// then fails before any of our code runs: the runtime records a function
/// error, logs only at trace level, and the Function URL answers 502.
///
/// Stalwart's push client sends no `User-Agent`. Every webhook it sent to
/// the hosted relay — the subscription's verification first of all — died
/// this way, while every hand-made `curl` (which always sends one) worked.
///
/// This decodes the raw event, fills in an empty string where Lambda put
/// null, and then hands the repaired event to the stock type, so everything
/// downstream (body base64 handling, headers, cookies) is still the
/// library's own code.
public struct TolerantFunctionURLRequest: LambdaEvent, Sendable {
    public let request: FunctionURLRequest

    public init(from decoder: Decoder) throws {
        var event = try JSONValue(from: decoder)
        event.fillNullUserAgent()
        let repaired = try JSONEncoder().encode(event)
        request = try JSONDecoder().decode(FunctionURLRequest.self, from: repaired)
    }

    public func request(context: LambdaContext) throws -> Request {
        try request.request(context: context)
    }
}

/// Just enough JSON to rewrite one field and re-encode the rest unchanged.
enum JSONValue: Codable, Equatable {
    case object([String: JSONValue])
    case array([JSONValue])
    case string(String)
    case number(Double)
    case integer(Int64)
    case bool(Bool)
    case null

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Int64.self) {
            // Before Double: `timeEpoch` is an integer of milliseconds and
            // must not come back as 1.79e12.
            self = .integer(value)
        } else if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([JSONValue].self) {
            self = .array(value)
        } else {
            self = .object(try container.decode([String: JSONValue].self))
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .object(let value): try container.encode(value)
        case .array(let value): try container.encode(value)
        case .string(let value): try container.encode(value)
        case .number(let value): try container.encode(value)
        case .integer(let value): try container.encode(value)
        case .bool(let value): try container.encode(value)
        case .null: try container.encodeNil()
        }
    }

    /// `requestContext.http.userAgent`: null or missing becomes "".
    mutating func fillNullUserAgent() {
        guard case .object(var root) = self,
            case .object(var context)? = root["requestContext"],
            case .object(var http)? = context["http"]
        else { return }
        switch http["userAgent"] {
        case .string?: return
        default: http["userAgent"] = .string("")
        }
        context["http"] = .object(http)
        root["requestContext"] = .object(context)
        self = .object(root)
    }
}

/// `FunctionURLRequest`'s request conversion is reached through its
/// `LambdaEvent` conformance in HummingbirdLambda.
extension FunctionURLRequest {
    fileprivate func request(context: LambdaContext) throws -> Request {
        try (self as any LambdaEvent).request(context: context)
    }
}
