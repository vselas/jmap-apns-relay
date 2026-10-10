import Crypto
import Foundation
import SwiftASN1
import X509

/// A stand-in for Apple's App Store signing chain, shaped exactly like the
/// real one: root → intermediate carrying the WWDR OID → leaf carrying the
/// receipt-signing OID, ES256, with the leaf and intermediate in `x5c`.
///
/// Signing with this and verifying with the production verifier (given this
/// root instead of Apple's) runs every check Apple's library makes — chain,
/// OIDs, signature, bundle id, environment — without bypassing any of them.
struct FakeAppleSigner {
    let rootDER: Data
    private let intermediateDER: Data
    private let leafDER: Data
    private let leafKey: P256.Signing.PrivateKey

    /// `leafHasReceiptOID: false` builds a chain Apple would never issue, for
    /// testing that the OID policy is really enforced.
    init(leafHasReceiptOID: Bool = true) throws {
        let rootKey = P256.Signing.PrivateKey()
        let intermediateKey = P256.Signing.PrivateKey()
        leafKey = P256.Signing.PrivateKey()
        let now = Date()
        let rootName = try DistinguishedName { CommonName("Test Root CA") }
        let intermediateName = try DistinguishedName { CommonName("Test WWDR") }
        let leafName = try DistinguishedName { CommonName("Test App Store Receipt Signing") }

        let root = try Certificate(
            version: .v3, serialNumber: .init(), publicKey: .init(rootKey.publicKey),
            notValidBefore: now.addingTimeInterval(-86400 * 365), notValidAfter: now.addingTimeInterval(86400 * 365 * 5),
            issuer: rootName, subject: rootName, signatureAlgorithm: .ecdsaWithSHA256,
            extensions: try .init {
                Critical(BasicConstraints.isCertificateAuthority(maxPathLength: nil))
                Critical(KeyUsage(keyCertSign: true))
            },
            issuerPrivateKey: .init(rootKey)
        )
        let intermediate = try Certificate(
            version: .v3, serialNumber: .init(), publicKey: .init(intermediateKey.publicKey),
            notValidBefore: now.addingTimeInterval(-86400 * 365), notValidAfter: now.addingTimeInterval(86400 * 365 * 5),
            issuer: rootName, subject: intermediateName, signatureAlgorithm: .ecdsaWithSHA256,
            extensions: try .init {
                Critical(BasicConstraints.isCertificateAuthority(maxPathLength: 0))
                Critical(KeyUsage(keyCertSign: true))
                Certificate.Extension(oid: [1, 2, 840, 113635, 100, 6, 2, 1], critical: false, value: [0x05, 0x00])
            },
            issuerPrivateKey: .init(rootKey)
        )
        let leaf = try Certificate(
            version: .v3, serialNumber: .init(), publicKey: .init(leafKey.publicKey),
            notValidBefore: now.addingTimeInterval(-86400 * 365), notValidAfter: now.addingTimeInterval(86400 * 365 * 5),
            issuer: intermediateName, subject: leafName, signatureAlgorithm: .ecdsaWithSHA256,
            extensions: try .init {
                Critical(BasicConstraints.notCertificateAuthority)
                Critical(KeyUsage(digitalSignature: true))
                if leafHasReceiptOID {
                    Certificate.Extension(oid: [1, 2, 840, 113635, 100, 6, 11, 1], critical: false, value: [0x05, 0x00])
                }
            },
            issuerPrivateKey: .init(intermediateKey)
        )
        rootDER = try Self.der(root)
        intermediateDER = try Self.der(intermediate)
        leafDER = try Self.der(leaf)
    }

    /// Signs a JSON payload as an App Store JWS.
    func sign(_ payload: [String: Any]) throws -> String {
        let header: [String: Any] = [
            "alg": "ES256",
            "x5c": [leafDER.base64EncodedString(), intermediateDER.base64EncodedString(), rootDER.base64EncodedString()],
        ]
        let input = try Self.segment(header) + "." + Self.segment(payload)
        let signature = try leafKey.signature(for: Data(input.utf8))
        return input + "." + Self.base64URL(signature.rawRepresentation)
    }

    /// Signs with a key no certificate vouches for, keeping the real chain in
    /// the header: a forger who copied Apple's certificates.
    func signWithForeignKey(_ payload: [String: Any]) throws -> String {
        let honest = try sign(payload)
        let parts = honest.split(separator: ".")
        let input = parts[0] + "." + parts[1]
        let signature = try P256.Signing.PrivateKey().signature(for: Data(input.utf8))
        return input + "." + Self.base64URL(signature.rawRepresentation)
    }

    static func milliseconds(_ date: Date) -> Int64 { Int64(date.timeIntervalSince1970 * 1000) }

    private static func der(_ certificate: Certificate) throws -> Data {
        var serializer = DER.Serializer()
        try serializer.serialize(certificate)
        return Data(serializer.serializedBytes)
    }

    private static func segment(_ object: [String: Any]) throws -> String {
        base64URL(try JSONSerialization.data(withJSONObject: object))
    }

    private static func base64URL(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
