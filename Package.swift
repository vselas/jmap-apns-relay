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
        .package(url: "https://github.com/apple/swift-crypto.git", from: "4.0.0"),
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
        // The hosted relay: an AWS Lambda behind a Function URL.
        .executableTarget(
            name: "PushRelayLambda",
            dependencies: [
                "RelayCore",
                "RelayAWS",
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
