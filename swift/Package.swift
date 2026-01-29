// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "imessage-max",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "imessage-max", targets: ["iMessageMax"])
    ],
    dependencies: [
        .package(url: "https://github.com/modelcontextprotocol/swift-sdk.git", from: "0.10.0"),
        .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.3.0"),
    ],
    targets: [
        .executableTarget(
            name: "iMessageMax",
            dependencies: [
                .product(name: "MCP", package: "swift-sdk"),
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ],
            path: "Sources/iMessageMax"
        ),
        .testTarget(
            name: "iMessageMaxTests",
            dependencies: ["iMessageMax"],
            path: "Tests/iMessageMaxTests"
        ),
    ]
)
