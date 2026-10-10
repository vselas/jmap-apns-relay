import Foundation

/// Resolves secrets from SSM Parameter Store into relay configuration.
///
/// A Lambda's environment variables are visible to anyone who can read the
/// function's configuration, so the APNs key and the bearer token live as
/// `SecureString` parameters and only their *names* are in the environment:
///
///     RELAY_AUTH_TOKEN_PARAMETER=/jmap-apns-relay/prod/auth-token
///     APNS_KEY_PARAMETER=/jmap-apns-relay/prod/apns-key
///
/// Every `<NAME>_PARAMETER` variable becomes `<NAME>` with the parameter's
/// decrypted value. A plain `<NAME>` already in the environment wins, which
/// keeps local runs and tests free of AWS.
public enum ParameterStore {
    static let suffix = "_PARAMETER"

    public static func resolve(
        environment: [String: String], transport: any AWSJSONTransport
    ) async throws -> [String: String] {
        let wanted = environment
            .filter { $0.key.hasSuffix(suffix) && !$0.value.isEmpty }
            .map { (name: String($0.key.dropLast(suffix.count)), parameter: $0.value) }
            .filter { environment[$0.name]?.isEmpty ?? true }
        guard !wanted.isEmpty else { return environment }

        // GetParameters takes at most 10 names per call; the relay asks for two.
        var values: [String: String] = [:]
        for chunk in stride(from: 0, to: wanted.count, by: 10).map({ Array(wanted[$0..<min($0 + 10, wanted.count)]) }) {
            let response = try await transport.call(
                service: "ssm",
                target: "AmazonSSM.GetParameters",
                body: ["Names": Array(Set(chunk.map(\.parameter))), "WithDecryption": true]
            )
            if let invalid = response["InvalidParameters"] as? [String], !invalid.isEmpty {
                throw ParameterError.missing(invalid.sorted())
            }
            for parameter in response["Parameters"] as? [[String: Any]] ?? [] {
                if let name = parameter["Name"] as? String, let value = parameter["Value"] as? String {
                    values[name] = value
                }
            }
        }
        var resolved = environment
        for entry in wanted {
            guard let value = values[entry.parameter] else { throw ParameterError.missing([entry.parameter]) }
            resolved[entry.name] = value
        }
        return resolved
    }

    public enum ParameterError: Error, Equatable {
        case missing([String])
    }
}
