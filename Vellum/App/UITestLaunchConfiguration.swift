import Foundation

/// Process-boundary configuration for a UI-test runner.
///
/// The iPad target has no XCUITest bundle today (macOS #87 added one; iOS did
/// not), so `isEnabled` is always false here and every switch below is inert.
/// The type is still ported verbatim-in-shape because `WebLibrary.appDataDir`,
/// `PageTextCache` and `KeychainStore` read it, and because an iOS UI-test
/// target would need exactly these seams.
enum UITestLaunchConfiguration {
    static let isEnabled = ProcessInfo.processInfo.arguments.contains("--ui-testing")

    /// The shipping app's bundle identifier. If a UI-test configuration is ever
    /// added it must carry a DIFFERENT identifier; the reset below refuses to
    /// run under the production one rather than wipe a real user's library.
    private static let productionBundleIdentifier = "com.ayushdeolasee.vellum"

    static var storageRoot: URL? {
        guard isEnabled,
              let path = value(after: "--ui-test-storage-root"),
              !path.isEmpty
        else { return nil }
        return URL(fileURLWithPath: path, isDirectory: true)
    }

    /// Runs before any store reads UserDefaults. Returns a document path to open.
    @discardableResult
    static func prepare() -> String? {
        guard isEnabled else { return nil }

        if ProcessInfo.processInfo.arguments.contains("--ui-test-reset-state"),
           let bundleIdentifier = Bundle.main.bundleIdentifier {
            if bundleIdentifier == productionBundleIdentifier {
                FileHandle.standardError.write(Data("""
                    [UITest] Refusing --ui-test-reset-state: this build uses the \
                    production bundle identifier \(productionBundleIdentifier).

                    """.utf8))
            } else {
                UserDefaults.standard.removePersistentDomain(forName: bundleIdentifier)
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
            // Through `AppDefaults`, the same door `WorkspaceService.load` reads
            // from. Seeding `.standard` directly would only be equivalent as
            // long as this process resolves to `.standard`, and if that ever
            // stopped holding the restoration test would not fail — it would
            // find no workspace at all and still reach a usable Home screen.
            AppDefaults.current.set("{not valid workspace json", forKey: "vellum.workspace")
        }

        if let root = storageRoot {
            try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
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
