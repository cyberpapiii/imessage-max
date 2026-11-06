// swift-tools-version: 6.3
import PackageDescription

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
