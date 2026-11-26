// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "VellumCore",
    platforms: [.macOS("26.0"), .iOS("26.0")],
    products: [.library(name: "VellumCore", targets: ["VellumCore"])],
    targets: [
        .target(name: "VellumCore", swiftSettings: [.swiftLanguageMode(.v5)]),
        .testTarget(
            name: "VellumCoreTests", dependencies: ["VellumCore"],
            swiftSettings: [.swiftLanguageMode(.v5)])
    ]
)
