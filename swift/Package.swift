// swift-tools-version: 6.1
import PackageDescription

let package = Package(
    name: "imessage-max",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "imessage-max", targets: ["iMessageMax"])
    ],
    dependencies: [
        // Upstream is stalled at 0.12.1; an exact-minor pin keeps `swift package update`
        // from pulling a breaking 0.13 unreviewed.
        .package(url: "https://github.com/modelcontextprotocol/swift-sdk.git", .upToNextMinor(from: "0.12.1")),
        .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.8.2"),
        .package(url: "https://github.com/hummingbird-project/hummingbird.git", from: "2.26.0"),
    ],
    targets: [
        .executableTarget(
            name: "iMessageMax",
            dependencies: [
                .product(name: "MCP", package: "swift-sdk"),
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
                .product(name: "Hummingbird", package: "hummingbird"),
            ],
            path: "Sources/iMessageMax",
            swiftSettings: [
                .unsafeFlags(["-parse-as-library"])
            ]
        ),
        .testTarget(
            name: "iMessageMaxTests",
            dependencies: [
                "iMessageMax",
                .product(name: "Hummingbird", package: "hummingbird"),
                .product(name: "HummingbirdTesting", package: "hummingbird"),
            ],
            path: "Tests/iMessageMaxTests",
            exclude: ["SendManualValidation.md"]
        ),
    ]
)
