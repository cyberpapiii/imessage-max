// swift-tools-version: 6.3
import PackageDescription

let contract: Target.Dependency = .product(name: "IMessageMaxContract", package: "contract")

let package = Package(
    name: "iMessageMaxMenu",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "MaxCore", targets: ["MaxCore"]),
        .executable(name: "iMessageMaxMenu", targets: ["iMessageMaxMenu"])
    ],
    dependencies: [
        .package(path: "../contract")
    ],
    targets: [
        .target(name: "MaxCore", dependencies: [contract]),
        .target(name: "MaxBrand"),
        .executableTarget(name: "iMessageMaxMenu", dependencies: ["MaxCore", "MaxBrand", contract]),
        .target(name: "MaxTestSupport", dependencies: [contract], path: "Tests/MaxTestSupport"),
        .testTarget(name: "MaxCoreTests", dependencies: ["MaxCore", "MaxTestSupport", contract]),
        .testTarget(name: "CompanionTests", dependencies: ["iMessageMaxMenu", "MaxCore", "MaxBrand", "MaxTestSupport", contract])
    ],
    swiftLanguageModes: [.v6]
)
