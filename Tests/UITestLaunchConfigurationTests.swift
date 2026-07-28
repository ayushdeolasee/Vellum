import XCTest
@testable import Vellum

// The UI-test launch seams must be completely inert in any process that was not
// launched with `--ui-testing`. That covers every real user launch, and this
// hosted unit-test process is the cheapest place to keep proving it: a
// regression here would redirect a user's storage or wipe their defaults.
final class UITestLaunchConfigurationTests: XCTestCase {
    func testDisabledWithoutTheLaunchArgument() {
        XCTAssertFalse(ProcessInfo.processInfo.arguments.contains("--ui-testing"))
        XCTAssertFalse(UITestLaunchConfiguration.isEnabled)
        XCTAssertNil(
            UITestLaunchConfiguration.storageRoot,
            "Storage redirection must require the launch argument")
    }

    /// `prepare()` is called unconditionally from `VellumApp.init`, so its
    /// no-argument behavior is production behavior: no document to open, and
    /// none of its state mutations applied.
    func testPrepareIsANoOpWhenDisabled() {
        let key = WalkthroughSettings.seenKey
        let priorWalkthrough = UserDefaults.standard.object(forKey: key)
        let priorMode = UserDefaults.standard.object(forKey: WebStorageSettings.modeKey)
        UserDefaults.standard.removeObject(forKey: key)
        defer {
            restore(priorWalkthrough, forKey: key)
            restore(priorMode, forKey: WebStorageSettings.modeKey)
        }

        XCTAssertNil(UITestLaunchConfiguration.prepare())
        XCTAssertFalse(
            WalkthroughSettings.hasSeenWalkthrough,
            "A production launch must not mark the walkthrough as seen")
    }

    /// The keychain guard has to hold for BOTH kinds of test process. This one
    /// is the hosted case (#97's XCTest environment markers); the UI-test case
    /// is the `--ui-testing` argument, since a launched app process inherits
    /// none of those markers.
    func testKeychainUsesTheInMemoryStoreUnderTest() {
        let markers = [
            "XCTestConfigurationFilePath", "XCTestSessionIdentifier", "XCTestBundlePath",
        ]
        let environment = ProcessInfo.processInfo.environment
        XCTAssertTrue(
            markers.contains { environment[$0] != nil },
            "The hosted test process should be detectable from its environment")

        let account = "review-probe-\(UUID().uuidString)"
        XCTAssertNil(KeychainStore.get(account))
        XCTAssertTrue(KeychainStore.set(account, "secret"))
        XCTAssertEqual(KeychainStore.get(account), "secret")
        XCTAssertTrue(KeychainStore.delete(account))
        XCTAssertNil(KeychainStore.get(account))
    }

    private func restore(_ value: Any?, forKey key: String) {
        if let value {
            UserDefaults.standard.set(value, forKey: key)
        } else {
            UserDefaults.standard.removeObject(forKey: key)
        }
    }
}
