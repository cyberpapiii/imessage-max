// swift-tools-version: 6.3
import PackageDescription

let package = Package(
    name: "iMessageMaxMenu",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "MaxCore", targets: ["MaxCore"]),
        .executable(name: "iMessageMaxMenu", targets: ["iMessageMaxMenu"])
    ],
    targets: [
        .target(name: "MaxCore"),
        .target(name: "MaxBrand"),
        .executableTarget(name: "iMessageMaxMenu", dependencies: ["MaxCore", "MaxBrand"]),
        .testTarget(name: "MaxCoreTests", dependencies: ["MaxCore"])
    ],
    swiftLanguageModes: [.v6]
)
