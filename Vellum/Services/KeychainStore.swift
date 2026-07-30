import Foundation
import Security
import os

/// Thin wrapper over the macOS Keychain for generic Vellum credentials.
/// Callers choose a service namespace; the AI service remains the default.
///
/// All secrets are physically stored inside ONE keychain item — a JSON "vault"
/// mapping "service/account" to the secret. macOS grants keychain access per
/// item and per read, and this app is ad-hoc signed (new signature every
/// build), so one item per secret meant one password prompt per secret per
/// read. A single vault item, read once per launch and cached, caps that at
/// one prompt total. Legacy per-secret items are folded into the vault on the
/// first load of every launch until none remain.
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
    /// That extra term is the only difference from `AppDefaults`' guard, which
    /// shares the hosted-process half of the detection so the two cannot drift.
    private static var isRunningTests: Bool {
        UITestLaunchConfiguration.isEnabled || TestEnvironment.isHostedTestProcess
    }

    /// In-memory stand-in used instead of the keychain while under test, so
    /// set/get/delete still round-trip within a test process. Keyed by the
    /// same "service/account" vault key as the real vault.
    private static let testStore = OSAllocatedUnfairLock<[String: String]>(initialState: [:])

    private static let vaultService = "com.vellum.vault"
    private static let vaultAccount = "vault"
    /// Service namespaces that previously stored one keychain item per secret.
    private static let legacyServices = ["com.vellum.ai", "com.vellum.integrations"]

    /// Vault contents plus the keychain item's modification date, used to
    /// detect writes from another running Vellum instance before overwriting.
    private struct VaultState {
        var entries: [String: String]
        var modDate: Date?   // nil when no vault item exists yet
    }

    private static let lock = NSLock()
    /// In-memory copy of the vault, loaded from the Keychain at most once per
    /// launch. Guarded by `lock`; nil until the first successful load.
    nonisolated(unsafe) private static var cache: VaultState?

    /// File descriptor used to `flock` vault commits across processes: several
    /// Vellum instances (worktree builds share the bundle id, and so this
    /// path and the vault item) may run at once, and an unserialized
    /// whole-item read-modify-write would let one instance revert another's
    /// secrets. -1 when the lock file can't be opened; commits then proceed
    /// with in-process locking only.
    private static let commitLockFD: Int32 = {
        let dir = WebLibrary.appDataDir
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return open(dir.appendingPathComponent("keychain-vault.lock").path, O_CREAT | O_RDWR, 0o600)
    }()

    /// Returns the stored secret for an account, or nil if absent/unreadable.
    static func get(_ account: String, service: String = service) -> String? {
        if isRunningTests { return testStore.withLock { $0[vaultKey(account, service)] } }
        lock.lock()
        defer { lock.unlock() }
        return loadVaultLocked()?.entries[vaultKey(account, service)]
    }

    /// Stores (or updates) the secret for an account. An empty value deletes it.
    /// Returns `true` only when the Keychain reflects the requested state, so
    /// callers can avoid dropping the plaintext copy before the write lands.
    @discardableResult
    static func set(_ account: String, _ value: String, service: String = service) -> Bool {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return delete(account, service: service)
        }
        if isRunningTests {
            testStore.withLock { $0[vaultKey(account, service)] = trimmed }
            return true
        }
        lock.lock()
        defer { lock.unlock() }
        return commitLocked([vaultKey(account, service): trimmed])
    }

    /// Removes the secret for an account. Returns `true` when the account is
    /// absent afterwards (either deleted now or already missing).
    @discardableResult
    static func delete(_ account: String, service: String = service) -> Bool {
        if isRunningTests {
            testStore.withLock { $0[vaultKey(account, service)] = nil }
            return true
        }
        lock.lock()
        defer { lock.unlock() }
        return commitLocked([vaultKey(account, service): nil])
    }

    private static func vaultKey(_ account: String, _ service: String) -> String {
        "\(service)/\(account)"
    }

    /// Returns the vault, reading it from the Keychain on the first call of
    /// the launch and reconciling any leftover legacy items into it. Nil means
    /// the vault item exists but is unreadable (denied prompt, corrupt data) —
    /// callers must treat that as "unavailable", never as "empty". Failures
    /// are not cached, so a denied prompt can be retried later in the launch.
    /// Call with `lock` held.
    private static func loadVaultLocked() -> VaultState? {
        if let cache { return cache }
        guard let state = readVaultItem() else { return nil }
        cache = state
        reconcileLegacyItemsLocked()
        return cache
    }

    /// Applies account mutations (value = nil deletes) on top of the current
    /// vault and persists the result as the single keychain item. Call with
    /// `lock` held.
    private static func commitLocked(_ mutations: [String: String?]) -> Bool {
        // A vault that exists but can't be read must fail the write: rewriting
        // from an empty in-memory copy would destroy every other secret.
        guard var state = loadVaultLocked() else { return false }
        // Serialize the probe→merge→write→probe sequence against other Vellum
        // instances. Every vault writer runs this code (pre-vault builds only
        // write legacy items, which reconciliation folds in later), so holding
        // the file lock makes the whole-item update atomic across processes.
        // Fail closed when the lock is unavailable: an unserialized write
        // could revert another instance's secrets, while a failed set() just
        // leaves the caller's plaintext fallback in place for a later retry.
        guard commitLockFD >= 0 else { return false }
        while flock(commitLockFD, LOCK_EX) != 0 {
            guard errno == EINTR else { return false }
        }
        defer { flock(commitLockFD, LOCK_UN) }
        // Another instance may have rewritten the vault since we cached it.
        // The modification date is readable without an access prompt, so
        // detect that case and re-read before mutating — a whole-item write
        // from a stale cache would revert the other instance's secrets. The
        // fresh read can prompt, but only in this rare conflict case.
        if probeModDate() != state.modDate {
            guard let fresh = readVaultItem() else { return false }
            state = fresh
        }
        var entries = state.entries
        for (key, value) in mutations {
            if let value {
                entries[key] = value
            } else {
                entries.removeValue(forKey: key)
            }
        }
        if entries == state.entries {
            cache = state
            return true
        }

        let baseQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: vaultService,
            kSecAttrAccount as String: vaultAccount,
        ]
        guard !entries.isEmpty else {
            let status = SecItemDelete(baseQuery as CFDictionary)
            guard status == errSecSuccess || status == errSecItemNotFound else { return false }
            cache = VaultState(entries: [:], modDate: nil)
            return true
        }
        guard let data = try? JSONEncoder().encode(entries) else { return false }
        let status = SecItemUpdate(baseQuery as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var addQuery = baseQuery
            addQuery[kSecValueData as String] = data
            addQuery[kSecAttrLabel as String] = "Vellum"
            guard SecItemAdd(addQuery as CFDictionary, nil) == errSecSuccess else { return false }
        } else if status != errSecSuccess {
            return false
        }
        cache = VaultState(entries: entries, modDate: probeModDate())
        return true
    }

    /// One full read of the vault item. Returns an empty state when no item
    /// exists, or nil when an item exists but can't be read.
    private static func readVaultItem() -> VaultState? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: vaultService,
            kSecAttrAccount as String: vaultAccount,
            kSecReturnData as String: true,
            kSecReturnAttributes as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return VaultState(entries: [:], modDate: nil) }
        guard status == errSecSuccess,
              let item = result as? [String: Any],
              let data = item[kSecValueData as String] as? Data,
              let entries = try? JSONDecoder().decode([String: String].self, from: data)
        else { return nil }
        return VaultState(entries: entries, modDate: item[kSecAttrModificationDate as String] as? Date)
    }

    /// The vault item's current modification date (nil when absent).
    /// Attribute-only queries never trigger an access prompt.
    private static func probeModDate() -> Date? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: vaultService,
            kSecAttrAccount as String: vaultAccount,
            kSecReturnAttributes as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let attributes = result as? [String: Any] else { return nil }
        return attributes[kSecAttrModificationDate as String] as? Date
    }

    /// Folds any leftover per-secret legacy items into the vault. Runs on the
    /// first vault load of every launch (enumeration is prompt-free), so an
    /// item whose migration was previously denied or failed keeps being
    /// retried until it lands. A legacy item is deleted only once its value
    /// is provably in the persisted vault. Call with `lock` held, after
    /// `cache` is populated.
    private static func reconcileLegacyItemsLocked() {
        var mutations: [String: String?] = [:]
        var pending: [(service: String, account: String)] = []
        let entries = cache?.entries ?? [:]
        for legacyService in legacyServices {
            for account in legacyAccounts(in: legacyService) {
                let key = vaultKey(account, legacyService)
                if entries[key] != nil {
                    // Already migrated (or superseded by a newer vault write);
                    // the leftover is a failed earlier cleanup. Retry it.
                    legacyDelete(account: account, service: legacyService)
                    continue
                }
                guard let value = legacyRead(account: account, service: legacyService) else { continue }
                guard !value.isEmpty else {
                    legacyDelete(account: account, service: legacyService)
                    continue
                }
                mutations[key] = value
                pending.append((legacyService, account))
            }
        }
        guard !mutations.isEmpty else { return }
        if commitLocked(mutations) {
            for item in pending {
                legacyDelete(account: item.account, service: item.service)
            }
        }
    }

    /// Lists the account names stored under a legacy service.
    private static func legacyAccounts(in service: String) -> [String] {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecMatchLimit as String: kSecMatchLimitAll,
            kSecReturnAttributes as String: true,
        ]
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let items = result as? [[String: Any]] else { return [] }
        return items.compactMap { $0[kSecAttrAccount as String] as? String }
    }

    private static func legacyRead(account: String, service: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private static func legacyDelete(account: String, service: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(query as CFDictionary)
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
