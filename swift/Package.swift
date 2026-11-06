// swift-tools-version: 6.3
import PackageDescription

let package = Package(
    name: "imessage-max",
    platforms: [.macOS(.v15)],
    products: [
        .executable(name: "imessage-max", targets: ["iMessageMax"])
    ],
    dependencies: [
        .package(url: "https://github.com/modelcontextprotocol/swift-sdk.git", .upToNextMinor(from: "0.12.1")),
        .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.8.2"),
        .package(url: "https://github.com/hummingbird-project/hummingbird.git", from: "2.26.0"),
        .package(url: "https://github.com/swift-server/swift-service-lifecycle.git", from: "2.12.0"),
        .package(path: "../contract"),
    ],
    targets: [
        .executableTarget(
            name: "iMessageMax",
            dependencies: [
                .product(name: "MCP", package: "swift-sdk"),
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
                .product(name: "Hummingbird", package: "hummingbird"),
                .product(name: "ServiceLifecycle", package: "swift-service-lifecycle"),
                .product(name: "UnixSignals", package: "swift-service-lifecycle"),
                .product(name: "IMessageMaxContract", package: "contract"),
            ],
            path: "Sources/iMessageMax"
        ),
        .testTarget(
            name: "iMessageMaxTests",
            dependencies: [
                "iMessageMax",
                .product(name: "IMessageMaxContract", package: "contract"),
                .product(name: "Hummingbird", package: "hummingbird"),
                .product(name: "HummingbirdTesting", package: "hummingbird"),
            ],
            path: "Tests/iMessageMaxTests",
            exclude: ["SendManualValidation.md"]
        ),
    ]
)
