// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "VellumLinux",
    products: [.executable(name: "vellum-linux", targets: ["VellumLinux"])],
    dependencies: [.package(path: "../Packages/VellumCore")],
    targets: [
        .systemLibrary(name: "CGtk", pkgConfig: "gtk4", providers: [.apt(["libgtk-4-dev"])]),
        .target(name: "CShell", dependencies: ["CGtk"], linkerSettings: [.linkedLibrary("dl")]),
        .systemLibrary(name: "CPdfium", pkgConfig: "pdfium"),
        .target(name: "CPdfiumJob", dependencies: ["CPdfium"]),
        .target(name: "LinuxReader",
                dependencies: ["CPdfiumJob", "CShell", .product(name: "VellumCore", package: "VellumCore")],
                swiftSettings: [.swiftLanguageMode(.v5)]),
        .testTarget(name: "LinuxReaderTests", dependencies: ["LinuxReader"]),
        .executableTarget(name: "VellumLinux",
                          dependencies: ["CShell", "LinuxReader", .product(name: "VellumCore", package: "VellumCore")],
                          swiftSettings: [.swiftLanguageMode(.v5)])
    ]
)
