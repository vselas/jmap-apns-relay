// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "PushRelay",
    platforms: [.macOS("15.0")],
    dependencies: [
        .package(url: "https://github.com/hummingbird-project/hummingbird.git", from: "2.0.0"),
        .package(url: "https://github.com/swift-server/async-http-client.git", from: "1.35.0"),
        .package(url: "https://github.com/apple/swift-crypto.git", from: "4.0.0"),
    ],
    targets: [
        .executableTarget(
            name: "PushRelay",
            dependencies: [
                .product(name: "Hummingbird", package: "hummingbird"),
                .product(name: "HummingbirdTLS", package: "hummingbird"),
                .product(name: "AsyncHTTPClient", package: "async-http-client"),
                .product(name: "Crypto", package: "swift-crypto"),
            ]
        ),
        .testTarget(
            name: "PushRelayTests",
            dependencies: [
                "PushRelay",
                .product(name: "HummingbirdTesting", package: "hummingbird"),
            ]
        ),
    ],
    swiftLanguageModes: [.v6]
)
