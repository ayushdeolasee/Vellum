// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "VellumLinux",
    products: [.executable(name: "vellum-linux", targets: ["VellumLinux"])],
    targets: [
        .systemLibrary(name: "CGtk", pkgConfig: "gtk4", providers: [.apt(["libgtk-4-dev"])]),
        .target(name: "CShell", dependencies: ["CGtk"], linkerSettings: [.linkedLibrary("dl")]),
        .systemLibrary(name: "CPdfium", pkgConfig: "pdfium"),
        .target(name: "CPdfiumJob", dependencies: ["CPdfium"]),
        .target(name: "LinuxReader", dependencies: ["CPdfiumJob"],
                swiftSettings: [.swiftLanguageMode(.v5)]),
        .testTarget(name: "LinuxReaderTests", dependencies: ["LinuxReader"]),
        .executableTarget(name: "VellumLinux", dependencies: ["CShell", "LinuxReader"],
                          swiftSettings: [.swiftLanguageMode(.v5)])
    ]
)
