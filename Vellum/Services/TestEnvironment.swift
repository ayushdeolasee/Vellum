import Foundation

/// Whether this process is running tests.
///
/// One definition, shared by the guards that must fail closed under test
/// (`KeychainStore`'s in-memory store, `AppDefaults`' scratch domain), so the
/// detection cannot drift between them. They compose it differently on purpose
/// — see each guard for why.
enum TestEnvironment {
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
