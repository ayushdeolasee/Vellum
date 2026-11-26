// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "VellumLinux",
    products: [.executable(name: "vellum-linux", targets: ["VellumLinux"])],
    dependencies: [
        .package(path: "../Packages/VellumCore"),
        .package(url: "https://github.com/swift-server/async-http-client.git", exact: "1.37.1")
    ],
    targets: [
        .systemLibrary(name: "CGtk", pkgConfig: "gtk4", providers: [.apt(["libgtk-4-dev"])]),
        .systemLibrary(name: "CWebKit", pkgConfig: "webkitgtk-6.0", providers: [.apt(["libwebkitgtk-6.0-dev"])]),
        .target(name: "CShell", dependencies: ["CGtk", "CWebKit"], linkerSettings: [.linkedLibrary("dl")]),
        .systemLibrary(name: "CPdfium", pkgConfig: "pdfium"),
        .target(name: "CPdfiumJob", dependencies: ["CPdfium"], linkerSettings: [.linkedLibrary("m")]),
        .systemLibrary(name: "CSecret", pkgConfig: "libsecret-1", providers: [.apt(["libsecret-1-dev"])]),
        .target(name: "LinuxServices",
                dependencies: ["CSecret", .product(name: "VellumCore", package: "VellumCore")],
                swiftSettings: [.swiftLanguageMode(.v5)]),
        .target(name: "LinuxHTTP",
                dependencies: [.product(name: "VellumCore", package: "VellumCore"),
                               .product(name: "AsyncHTTPClient", package: "async-http-client")],
                swiftSettings: [.swiftLanguageMode(.v5)]),
        .testTarget(name: "LinuxServicesTests", dependencies: ["LinuxServices", "LinuxHTTP"]),
        .target(name: "LinuxReader",
                dependencies: ["CPdfiumJob", "CShell", .product(name: "VellumCore", package: "VellumCore")],
                swiftSettings: [.swiftLanguageMode(.v5)]),
        .testTarget(name: "LinuxReaderTests", dependencies: ["LinuxReader"]),
        .executableTarget(name: "VellumLinux",
                          dependencies: ["CShell", "LinuxReader", "LinuxServices",
                                         .product(name: "VellumCore", package: "VellumCore")],
                          swiftSettings: [.swiftLanguageMode(.v5)])
    ]
)
