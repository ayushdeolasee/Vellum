import Foundation

final class IntegrationFixtureBundleToken {}

enum FixtureLoader {
    static func data(_ path: String, _ name: String) throws -> Data {
        let bundle = Bundle(for: IntegrationFixtureBundleToken.self)
        if let url = bundle.url(forResource: name, withExtension: "json", subdirectory: "Fixtures/\(path)") {
            return try Data(contentsOf: url)
        }
        // Bundle resolution can flake in app-hosted test runs; the fixtures are
        // plain source files, so fall back to reading them from the repo. Warn
        // loudly so a real bundle-resource regression doesn't hide behind the
        // fallback on the machine that built the binary.
        FileHandle.standardError.write(Data("⚠️ FixtureLoader: bundle lookup failed for Fixtures/\(path)/\(name).json — using #filePath fallback\n".utf8))
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        return try Data(contentsOf: root.appendingPathComponent("Fixtures/\(path)/\(name).json"))
    }
}
