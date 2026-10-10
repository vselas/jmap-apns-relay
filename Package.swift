// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "PushRelay",
    platforms: [.macOS("15.0")],
    products: [
        .executable(name: "PushRelay", targets: ["PushRelay"]),
        .executable(name: "PushRelayLambda", targets: ["PushRelayLambda"]),
    ],
    dependencies: [
        .package(url: "https://github.com/hummingbird-project/hummingbird.git", from: "2.0.0"),
        .package(url: "https://github.com/hummingbird-project/hummingbird-lambda.git", from: "2.1.0"),
        .package(url: "https://github.com/swift-server/async-http-client.git", from: "1.35.0"),
        // 3.12.3 floor, not 4: Apple's App Store Server Library still caps
        // swift-crypto below 4.0, and the relay only needs P-256 signing.
        .package(url: "https://github.com/apple/swift-crypto.git", "3.12.3"..<"5.0.0"),
        .package(url: "https://github.com/apple/app-store-server-library-swift.git", from: "6.0.0"),
        // Test-only: minting a fake Apple chain for the verifier tests.
        .package(url: "https://github.com/apple/swift-certificates.git", from: "1.0.0"),
        .package(url: "https://github.com/apple/swift-asn1.git", from: "1.1.0"),
        .package(url: "https://github.com/soto-project/soto-core.git", from: "7.17.0"),
        .package(url: "https://github.com/awslabs/swift-aws-lambda-events.git", from: "1.4.0"),
    ],
    targets: [
        // Protocol, storage contract, router and APNs: everything both
        // deployments share.
        .target(
            name: "RelayCore",
            dependencies: [
                .product(name: "Hummingbird", package: "hummingbird"),
                .product(name: "AsyncHTTPClient", package: "async-http-client"),
                .product(name: "Crypto", package: "swift-crypto"),
            ]
        ),
        // The self-hosted container: JSON-file storage, its own TLS.
        .executableTarget(
            name: "PushRelay",
            dependencies: [
                "RelayCore",
                .product(name: "Hummingbird", package: "hummingbird"),
                .product(name: "HummingbirdTLS", package: "hummingbird"),
                .product(name: "AsyncHTTPClient", package: "async-http-client"),
            ]
        ),
        // DynamoDB storage and Parameter Store secrets, signed requests only —
        // no SDK, so the Lambda stays small and starts fast.
        .target(
            name: "RelayAWS",
            dependencies: [
                "RelayCore",
                .product(name: "AsyncHTTPClient", package: "async-http-client"),
                .product(name: "SotoSignerV4", package: "soto-core"),
            ]
        ),
        // Apple-signed proof of a push subscription: StoreKit 2 transactions
        // and App Store Server Notifications V2, verified to Apple's root.
        .target(
            name: "RelayAppStore",
            dependencies: [
                "RelayCore",
                .product(name: "AppStoreServerLibrary", package: "app-store-server-library-swift"),
                .product(name: "Crypto", package: "swift-crypto"),
            ]
        ),
        // The hosted relay: an AWS Lambda behind a Function URL.
        .executableTarget(
            name: "PushRelayLambda",
            dependencies: [
                "RelayCore",
                "RelayAWS",
                "RelayAppStore",
                .product(name: "HummingbirdLambda", package: "hummingbird-lambda"),
                .product(name: "AWSLambdaEvents", package: "swift-aws-lambda-events"),
                .product(name: "AsyncHTTPClient", package: "async-http-client"),
            ]
        ),
        .testTarget(
            name: "PushRelayTests",
            dependencies: [
                "RelayCore",
                "RelayAWS",
                "RelayAppStore",
                .product(name: "AppStoreServerLibrary", package: "app-store-server-library-swift"),
                .product(name: "X509", package: "swift-certificates"),
                .product(name: "SwiftASN1", package: "swift-asn1"),
                .product(name: "HummingbirdTesting", package: "hummingbird"),
                .product(name: "AsyncHTTPClient", package: "async-http-client"),
                .product(name: "HummingbirdLambda", package: "hummingbird-lambda"),
                .product(name: "HummingbirdLambdaTesting", package: "hummingbird-lambda"),
                .product(name: "AWSLambdaEvents", package: "swift-aws-lambda-events"),
            ]
        ),
    ],
    swiftLanguageModes: [.v6]
)
