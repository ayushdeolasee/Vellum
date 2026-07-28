import Foundation

/// Process-boundary configuration for the UI-test runner.
///
/// The switches are deliberately inert unless `--ui-testing` is present. This
/// keeps test storage and state deterministic without changing normal launches
/// or teaching individual feature stores about XCUITest.
enum UITestLaunchConfiguration {
    static let isEnabled = ProcessInfo.processInfo.arguments.contains("--ui-testing")

    /// The shipping app's UserDefaults domain. UI tests run under the
    /// `UITesting` build configuration, which gives the app a dedicated bundle
    /// identifier; if that ever stops being true, the state reset below must
    /// refuse to run rather than delete a real user's library and settings.
    private static let productionBundleIdentifier = "com.vellum.app"

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
            if bundleIdentifier == productionBundleIdentifier {
                // Wrong build configuration: this process shares the installed
                // app's defaults domain. Skip the wipe instead of destroying it.
                FileHandle.standardError.write(Data("""
                    [UITest] Refusing --ui-test-reset-state: this build uses the \
                    production bundle identifier \(productionBundleIdentifier). \
                    Run UI tests with the UITesting configuration.

                    """.utf8))
            } else {
                defaults.removePersistentDomain(forName: bundleIdentifier)
            }
        }

        // Avoid the first-launch storage sheet and all iCloud/custom storage
        // resolution. The app-data root itself is redirected by `storageRoot`.
        WebStorageSettings.setMode(.local)

        // #65 presents the walkthrough sheet on every fresh defaults domain,
        // which is exactly what `--ui-test-reset-state` creates — it would sit
        // modally over Home in every test. Mark it seen unless a test opts in.
        if !ProcessInfo.processInfo.arguments.contains("--ui-test-show-walkthrough") {
            WalkthroughSettings.markSeen()
        }

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
