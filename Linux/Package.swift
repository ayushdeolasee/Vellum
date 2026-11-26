// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "VellumLinux",
    products: [.executable(name: "vellum-linux", targets: ["VellumLinux"])],
    targets: [
        .systemLibrary(name: "CGtk", pkgConfig: "gtk4", providers: [.apt(["libgtk-4-dev"])]),
        .target(name: "CShell", dependencies: ["CGtk"], linkerSettings: [.linkedLibrary("dl")]),
        .executableTarget(name: "VellumLinux", dependencies: ["CShell"],
                          swiftSettings: [.swiftLanguageMode(.v5)])
    ]
)
