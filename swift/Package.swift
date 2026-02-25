// swift-tools-version: 6.1
import PackageDescription

let package = Package(
    name: "imessage-max",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "imessage-max", targets: ["iMessageMax"])
    ],
    dependencies: [
        .package(url: "https://github.com/modelcontextprotocol/swift-sdk.git", from: "0.11.0"),
        .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.3.0"),
        .package(url: "https://github.com/hummingbird-project/hummingbird.git", from: "2.0.0"),
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
            dependencies: ["iMessageMax"],
            path: "Tests/iMessageMaxTests"
        ),
    ]
)
