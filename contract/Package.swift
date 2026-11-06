// swift-tools-version: 6.3
import PackageDescription

// The wire contract between the imessage-max server (swift/) and its macOS
// companion (macos/). Both depend on it by path; Foundation only.
let package = Package(
    name: "IMessageMaxContract",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "IMessageMaxContract", targets: ["IMessageMaxContract"])
    ],
    targets: [
        .target(name: "IMessageMaxContract"),
        .testTarget(name: "IMessageMaxContractTests", dependencies: ["IMessageMaxContract"]),
    ],
    swiftLanguageModes: [.v6]
)
