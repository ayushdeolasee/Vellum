import Foundation
import Security
import os

/// Thin wrapper over the macOS Keychain for storing AI provider API keys as
/// generic passwords. All keys live under one service; the account string is
/// the provider identifier (e.g. "gemini", "openai", "openrouter").
enum KeychainStore {
    static let service = "com.vellum.ai"

    /// Test runs must never touch the real login keychain: the test host is an
    /// ad-hoc-signed Debug build whose signature changes on every rebuild, so
    /// each `xcodebuild test` launch would re-trigger the keychain password
    /// prompt — and tests have no business reading the user's real API keys.
    /// Detected via the XCTest environment (set from process start, before the
    /// test bundle is injected) with the class lookup as a fallback.
    ///
    /// A UI test is a second process boundary: `XCUIApplication().launch()`
    /// starts the app fresh, and that process inherits NONE of the XCTest
    /// environment markers or the XCTestCase class. The `--ui-testing` launch
    /// argument the harness always passes is the only signal available there,
    /// so it counts as "under test" too — otherwise every UI-test launch of an
    /// ad-hoc-signed build would re-prompt for the login keychain password.
    private static let isRunningTests: Bool = {
        if UITestLaunchConfiguration.isEnabled { return true }
        let env = ProcessInfo.processInfo.environment
        return env["XCTestConfigurationFilePath"] != nil
            || env["XCTestSessionIdentifier"] != nil
            || env["XCTestBundlePath"] != nil
            || NSClassFromString("XCTestCase") != nil
    }()

    /// In-memory stand-in used instead of the keychain while under test, so
    /// set/get/delete still round-trip within a test process.
    private static let testStore = OSAllocatedUnfairLock<[String: String]>(initialState: [:])

    /// Returns the stored secret for an account, or nil if absent/unreadable.
    static func get(_ account: String) -> String? {
        if isRunningTests { return testStore.withLock { $0[account] } }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess,
              let data = result as? Data,
              let value = String(data: data, encoding: .utf8) else { return nil }
        return value
    }

    /// Stores (or updates) the secret for an account. An empty value deletes it.
    /// Returns `true` only when the Keychain reflects the requested state, so
    /// callers can avoid dropping the plaintext copy before the write lands.
    @discardableResult
    static func set(_ account: String, _ value: String) -> Bool {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return delete(account)
        }
        if isRunningTests {
            testStore.withLock { $0[account] = trimmed }
            return true
        }
        let data = Data(trimmed.utf8)
        let baseQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        let status = SecItemUpdate(baseQuery as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var addQuery = baseQuery
            addQuery[kSecValueData as String] = data
            return SecItemAdd(addQuery as CFDictionary, nil) == errSecSuccess
        }
        return status == errSecSuccess
    }

    /// Removes the secret for an account. Returns `true` when the account is
    /// absent afterwards (either deleted now or already missing).
    @discardableResult
    static func delete(_ account: String) -> Bool {
        if isRunningTests {
            testStore.withLock { $0[account] = nil }
            return true
        }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        let status = SecItemDelete(query as CFDictionary)
        return status == errSecSuccess || status == errSecItemNotFound
    }

    // Account identifiers, one per provider with a stored secret.
    enum Account {
        static let gemini = "gemini"
        static let openai = "openai"
        static let openrouter = "openrouter"
        static let opencode = "opencode"
        static let opencodeGo = "opencode-go"
        /// JSON blob of the ChatGPT OAuth tokens (access/refresh/id/account id).
        static let chatgptTokens = "chatgpt-tokens"
    }
}
