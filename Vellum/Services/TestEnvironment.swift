import Foundation

/// Whether this process is running tests.
///
/// One definition, shared by the guards that must fail closed under test
/// (`KeychainStore`'s in-memory store, `AppDefaults`' scratch domain), so the
/// detection cannot drift between them. They compose it differently on purpose
/// — see each guard for why.
enum TestEnvironment {
    /// Default scratch storage for unseamed services in a hosted test process.
    /// UI-test apps require an explicit root before they can read any store.
    static var storageRoot: URL? {
        if UITestLaunchConfiguration.isEnabled { return UITestLaunchConfiguration.storageRoot }
        return isHostedTestProcess ? hostedStorageRoot : nil
    }

    private static let hostedStorageRoot: URL = {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("vellum-hosted-tests-\(UUID().uuidString)", isDirectory: true)
        do { try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true) }
        catch { fatalError("Could not create isolated test storage: \(error)") }
        return root
    }()

    /// True inside a *hosted* test bundle: the bundle is injected into the app
    /// process, so it shares the app's `UserDefaults` domain and its file
    /// storage. Detected via the XCTest environment, which is set from process
    /// start (before the bundle is injected), with the class lookup as a
    /// fallback.
    ///
    /// False in the app process an XCUITest launches: that is a second process
    /// boundary, started fresh by `XCUIApplication().launch()`, and it inherits
    /// none of these markers.
    static let isHostedTestProcess: Bool = {
        let env = ProcessInfo.processInfo.environment
        return env["XCTestConfigurationFilePath"] != nil
            || env["XCTestSessionIdentifier"] != nil
            || env["XCTestBundlePath"] != nil
            || NSClassFromString("XCTestCase") != nil
    }()
}
