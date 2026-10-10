import Crypto
import Foundation

/// Apple's root certificate authorities for App Store signed data.
///
/// StoreKit 2 transactions and App Store Server Notifications V2 chain to
/// **Apple Root CA - G3** (ECC). Embedded rather than loaded from a resource,
/// so a static Linux binary carries it with no bundle to find. Source:
/// https://www.apple.com/certificateauthority/AppleRootCA-G3.cer, checked
/// against the macOS system trust store. The init re-checks the fingerprint
/// so a damaged copy cannot silently become a trust anchor.
public enum AppleRootCertificates {
    static let rootCAG3SHA256 = "63343abfb89a6a03ebb57e9b3f5fa7be7c4f5c756f3017b3a8c488c3653e9179"

    static let rootCAG3Base64 = [
        "MIICQzCCAcmgAwIBAgIILcX8iNLFS5UwCgYIKoZIzj0EAwMwZzEbMBkGA1UEAwwSQXBwbGUgUm9v",
        "dCBDQSAtIEczMSYwJAYDVQQLDB1BcHBsZSBDZXJ0aWZpY2F0aW9uIEF1dGhvcml0eTETMBEGA1UE",
        "CgwKQXBwbGUgSW5jLjELMAkGA1UEBhMCVVMwHhcNMTQwNDMwMTgxOTA2WhcNMzkwNDMwMTgxOTA2",
        "WjBnMRswGQYDVQQDDBJBcHBsZSBSb290IENBIC0gRzMxJjAkBgNVBAsMHUFwcGxlIENlcnRpZmlj",
        "YXRpb24gQXV0aG9yaXR5MRMwEQYDVQQKDApBcHBsZSBJbmMuMQswCQYDVQQGEwJVUzB2MBAGByqG",
        "SM49AgEGBSuBBAAiA2IABJjpLz1AcqTtkyJygRMc3RCV8cWjTnHcFBbZDuWmBSp3ZHtfTjjTuxxE",
        "tX/1H7YyYl3J6YRbTzBPEVoA/VhYDKX1DyxNB0cTddqXl5dvMVztK517IDvYuVTZXpmkOlEKMaNC",
        "MEAwHQYDVR0OBBYEFLuw3qFYM4iapIqZ3r6966/ayySrMA8GA1UdEwEB/wQFMAMBAf8wDgYDVR0P",
        "AQH/BAQDAgEGMAoGCCqGSM49BAMDA2gAMGUCMQCD6cHEFl4aXTQY2e3v9GwOAEZLuN+yRhHFD/3m",
        "eoyhpmvOwgPUnPWTxnS4at+qIxUCMG1mihDK1A3UT82NQz60imOlM27jbdoXt2QfyFMm+YhidDkL",
        "F1vLUagM6BgD56KyKA=="
    ].joined()

    /// Every root the verifier should trust. Valid until 2039-04-30.
    public static let all: [Data] = {
        guard let der = Data(base64Encoded: rootCAG3Base64),
            SHA256.hash(data: der).map({ String(format: "%02x", $0) }).joined() == rootCAG3SHA256
        else {
            preconditionFailure("embedded Apple Root CA - G3 does not match its fingerprint")
        }
        return [der]
    }()
}
