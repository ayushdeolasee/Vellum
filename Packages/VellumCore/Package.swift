// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "VellumCore",
    platforms: [.macOS("26.0"), .iOS("26.0")],
    products: [.library(name: "VellumCore", targets: ["VellumCore"])],
    dependencies: [
        .package(url: "https://github.com/apple/swift-crypto.git", exact: "4.0.0")
    ],
    targets: [
        .systemLibrary(name: "CZlib", pkgConfig: "zlib", providers: [.apt(["zlib1g-dev"])]),
        .target(
            name: "VellumCore",
            dependencies: [
                "CZlib",
                .product(name: "Crypto", package: "swift-crypto", condition: .when(platforms: [.linux]))
            ],
            swiftSettings: [.swiftLanguageMode(.v5)]),
        .testTarget(
            name: "VellumCoreTests", dependencies: ["VellumCore"],
            resources: [.copy("Fixtures")],
            swiftSettings: [.swiftLanguageMode(.v5)])
    ]
)
