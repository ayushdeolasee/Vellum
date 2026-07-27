import Foundation

/// Process-boundary configuration for the UI-test runner.
///
/// The switches are deliberately inert unless `--ui-testing` is present. This
/// keeps test storage and state deterministic without changing normal launches
/// or teaching individual feature stores about XCUITest.
enum UITestLaunchConfiguration {
    static let isEnabled = ProcessInfo.processInfo.arguments.contains("--ui-testing")

    static var storageRoot: URL? {
        guard isEnabled,
              let path = value(after: "--ui-test-storage-root"),
              !path.isEmpty
        else { return nil }
        return URL(fileURLWithPath: path, isDirectory: true)
    }

    /// Runs before any store reads UserDefaults.
    static func prepare() -> String? {
        guard isEnabled else { return nil }

        let defaults = UserDefaults.standard
        if ProcessInfo.processInfo.arguments.contains("--ui-test-reset-state"),
           let bundleIdentifier = Bundle.main.bundleIdentifier {
            defaults.removePersistentDomain(forName: bundleIdentifier)
        }

        // Avoid the first-launch storage sheet and all iCloud/custom storage
        // resolution. The app-data root itself is redirected by `storageRoot`.
        WebStorageSettings.setMode(.local)

        if ProcessInfo.processInfo.arguments.contains("--ui-test-corrupt-restoration") {
            defaults.set("{not valid workspace json", forKey: "vellum.workspace")
        }

        if let root = storageRoot {
            try? FileManager.default.createDirectory(
                at: root, withIntermediateDirectories: true)
        }

        return value(after: "--ui-test-open-document")
    }

    private static func value(after switchName: String) -> String? {
        let arguments = ProcessInfo.processInfo.arguments
        guard let index = arguments.firstIndex(of: switchName),
              arguments.indices.contains(index + 1)
        else { return nil }
        return arguments[index + 1]
    }
}
