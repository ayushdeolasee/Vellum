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
    struct VaultState: Sendable, Equatable {
        var entries: [String: String]
        var modDate: Date?   // nil when no vault item exists yet
    }

    /// A legacy per-secret item: its value plus the date it was last written,
    /// which is what decides a value conflict against the vault.
    struct LegacyItem: Sendable, Equatable {
        var value: String
        var modDate: Date?
    }

    /// Every Security-framework and file-lock call the vault logic makes,
    /// behind function properties. Production always runs `.live`; the seam
    /// exists so the read-modify-write rules that carry the real risk — legacy
    /// migration and conflict resolution, the re-read before a write, failing
    /// closed on an unreadable vault — can be tested against an in-memory
    /// keychain instead of the developer's login keychain.
    struct Backend: Sendable {
        /// One full read of the vault item. Empty state when no item exists,
        /// nil when an item exists but can't be read (denied prompt, corrupt).
        var readVaultItem: @Sendable () -> VaultState?
        /// Moves an existing iOS vault to the protection class required by
        /// background refresh. A no-op when absent or already migrated.
        var migrateVaultAccessibility: @Sendable () -> Void
        /// The vault item's modification date, nil when absent. Attribute-only,
        /// so it must never trigger an access prompt.
        var probeModDate: @Sendable () -> Date?
        /// Persists the whole vault. False must leave the stored item as it was.
        var writeVault: @Sendable ([String: String]) -> Bool
        /// Removes the vault item. True also when it was already absent.
        var deleteVault: @Sendable () -> Bool
        /// Account names stored under a legacy per-secret service.
        var legacyAccounts: @Sendable (_ service: String) -> [String]
        /// A legacy item's value and modification date, nil when unreadable.
        var legacyRead: @Sendable (_ account: String, _ service: String) -> LegacyItem?
        var legacyDelete: @Sendable (_ account: String, _ service: String) -> Void
        /// Cross-process commit lock. False means it was not acquired within
        /// the deadline, and the commit must fail rather than race.
        var acquireCommitLock: @Sendable () -> Bool
        var releaseCommitLock: @Sendable () -> Void

        static let live = Backend(
            readVaultItem: { KeychainStore.liveReadVaultItem() },
            migrateVaultAccessibility: { KeychainStore.liveMigrateVaultAccessibility() },
            probeModDate: { KeychainStore.liveProbeModDate() },
            writeVault: { KeychainStore.liveWriteVault($0) },
            deleteVault: { KeychainStore.liveDeleteVault() },
            legacyAccounts: { KeychainStore.liveLegacyAccounts(in: $0) },
            legacyRead: { KeychainStore.liveLegacyRead(account: $0, service: $1) },
            legacyDelete: { KeychainStore.liveLegacyDelete(account: $0, service: $1) },
            acquireCommitLock: { KeychainStore.liveAcquireCommitLock() },
            releaseCommitLock: { KeychainStore.liveReleaseCommitLock() })
    }

    private static let lock = NSLock()
    /// In-memory copy of the vault, loaded from the Keychain at most once per
    /// launch (plus a re-read whenever the item's mod date says another
    /// instance wrote it). Guarded by `lock`; nil until the first load.
    nonisolated(unsafe) private static var cache: VaultState?
    /// Non-nil only while a test drives the vault logic through a fake
    /// keychain. Guarded by `lock`.
    nonisolated(unsafe) private static var backendOverride: Backend?

    /// True while the in-memory stand-in must be used instead of the Keychain:
    /// a test process that has NOT installed a vault backend. Installing one
    /// (`withBackend`, tests only) opts that test into the real vault logic
    /// against a fake keychain, which is what makes this file testable without
    /// ever reaching the login keychain. Call with `lock` held.
    private static var usesTestStoreLocked: Bool {
        backendOverride == nil && isRunningTests
    }

    /// Call with `lock` held.
    private static var backendLocked: Backend {
        backendOverride ?? .live
    }

    /// Returns the stored secret for an account, or nil if absent/unreadable.
    static func get(_ account: String, service: String = service) -> String? {
        lock.lock()
        defer { lock.unlock() }
        if usesTestStoreLocked { return testStore.withLock { $0[vaultKey(account, service)] } }
        return currentVaultLocked()?.entries[vaultKey(account, service)]
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
        lock.lock()
        defer { lock.unlock() }
        if usesTestStoreLocked {
            testStore.withLock { $0[vaultKey(account, service)] = trimmed }
            return true
        }
        return commitLocked([vaultKey(account, service): trimmed])
    }

    /// Removes the secret for an account. Returns `true` when the account is
    /// absent afterwards (either deleted now or already missing).
    @discardableResult
    static func delete(_ account: String, service: String = service) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if usesTestStoreLocked {
            testStore.withLock { $0[vaultKey(account, service)] = nil }
            return true
        }
        return commitLocked([vaultKey(account, service): nil])
    }

    /// Loads the vault off the main thread so later reads are cache hits.
    ///
    /// The first `get` of a launch does a full keychain read plus a legacy
    /// enumeration/migration and possibly a commit — hundreds of milliseconds,
    /// and potentially a password prompt — and it is reachable synchronously
    /// from `@MainActor` callers such as `AiPersistence.readKey`, i.e.
    /// it can block the UI. Call this once at startup to move that work onto a
    /// background thread. Safe to call any number of times (the load is cached
    /// and serialized on `lock`), and a no-op under test, where the vault is
    /// never touched at all.
    static func prewarm() {
        DispatchQueue.global(qos: .userInitiated).async {
            lock.lock()
            defer { lock.unlock() }
            guard !usesTestStoreLocked else { return }
            _ = loadVaultLocked()
            purgeRemovedCredentialsLocked()
        }
    }

    /// Removes credentials for providers that the app no longer supports.
    private static func purgeRemovedCredentialsLocked() {
        let account = "chatgpt-tokens"
        let key = vaultKey(account, service)
        if cache?.entries[key] != nil {
            _ = commitLocked([key: nil])
        }
        backendLocked.legacyDelete(account, service)
    }

    private static func vaultKey(_ account: String, _ service: String) -> String {
        "\(service)/\(account)"
    }

    /// The vault as it exists right now, re-reading it when another running
    /// Vellum instance has written the item since we cached it. Without this
    /// a token written by another instance stayed invisible until relaunch.
    /// The mod-date probe is attribute-only, so this costs no prompt in the
    /// common (unchanged) case. Call with `lock` held.
    private static func currentVaultLocked() -> VaultState? {
        guard let cached = loadVaultLocked() else { return nil }
        let backend = backendLocked
        guard backend.probeModDate() != cached.modDate else { return cached }
        // A failed refresh must not downgrade a working cache to "unavailable":
        // a stale-but-readable copy is strictly better than nil, which callers
        // surface as a missing credential.
        guard let fresh = backend.readVaultItem() else { return cached }
        cache = fresh
        return fresh
    }

    /// Returns the vault, reading it from the Keychain on the first call of
    /// the launch and reconciling any leftover legacy items into it. Nil means
    /// the vault item exists but is unreadable (denied prompt, corrupt data) —
    /// callers must treat that as "unavailable", never as "empty". Failures
    /// are not cached, so a denied prompt can be retried later in the launch.
    /// Call with `lock` held.
    private static func loadVaultLocked() -> VaultState? {
        if let cache { return cache }
        let backend = backendLocked
        backend.migrateVaultAccessibility()
        guard let state = backend.readVaultItem() else { return nil }
        cache = state
        reconcileLegacyItemsLocked()
        return cache
    }

    /// Applies account mutations (value = nil deletes) on top of the current
    /// vault and persists the result as the single keychain item. Call with
    /// `lock` held.
    private static func commitLocked(_ mutations: [String: String?]) -> Bool {
        let backend = backendLocked
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
        guard backend.acquireCommitLock() else { return false }
        defer { backend.releaseCommitLock() }
        // Another instance may have rewritten the vault since we cached it.
        // The modification date is readable without an access prompt, so
        // detect that case and re-read before mutating — a whole-item write
        // from a stale cache would revert the other instance's secrets. The
        // fresh read can prompt, but only in this rare conflict case.
        if backend.probeModDate() != state.modDate {
            guard let fresh = backend.readVaultItem() else { return false }
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
        guard !entries.isEmpty else {
            guard backend.deleteVault() else { return false }
            cache = VaultState(entries: [:], modDate: nil)
            return true
        }
        guard backend.writeVault(entries) else { return false }
        cache = VaultState(entries: entries, modDate: backend.probeModDate())
        return true
    }

    /// Folds any leftover per-secret legacy items into the vault. Runs on the
    /// first vault load of every launch (enumeration is prompt-free), so an
    /// item whose migration was previously denied or failed keeps being
    /// retried until it lands. A legacy item is deleted only once its value is
    /// provably preserved. Call with `lock` held, after `cache` is populated.
    private static func reconcileLegacyItemsLocked() {
        let backend = backendLocked
        var mutations: [String: String?] = [:]
        var resolved: [(service: String, account: String)] = []
        let entries = cache?.entries ?? [:]
        let vaultDate = cache?.modDate
        for legacyService in legacyServices {
            for account in backend.legacyAccounts(legacyService) {
                let key = vaultKey(account, legacyService)
                // Read before deciding anything. A pre-vault build writes only
                // legacy items, so running one after a migration leaves an item
                // whose value is NEWER than the vault's copy of the same key;
                // deleting it because "the vault already has that key" threw
                // away the token the user had just entered.
                guard let legacy = backend.legacyRead(account, legacyService) else { continue }
                guard !legacy.value.isEmpty else {
                    backend.legacyDelete(account, legacyService)
                    continue
                }
                guard let stored = entries[key] else {
                    mutations[key] = legacy.value
                    resolved.append((legacyService, account))
                    continue
                }
                if stored == legacy.value {
                    // Already in the vault; the leftover is a failed cleanup.
                    backend.legacyDelete(account, legacyService)
                    continue
                }
                // The two disagree, so the later write wins and the dates are
                // the only evidence. The vault's date belongs to the whole item
                // (any secret's write bumps it), so it can only be NEWER than
                // this key's own last write: `legacy > vault` therefore proves
                // the legacy value is the more recent one, while the reverse
                // proves nothing.
                guard let legacyDate = legacy.modDate, let vaultDate, legacyDate > vaultDate else {
                    // Undecidable: keep both. Re-reading this item every launch
                    // costs a prompt at worst; guessing costs a lost secret.
                    continue
                }
                mutations[key] = legacy.value
                resolved.append((legacyService, account))
            }
        }
        guard !mutations.isEmpty else { return }
        if commitLocked(mutations) {
            for item in resolved {
                backend.legacyDelete(item.account, item.service)
            }
        }
    }

    // MARK: - Live backend

    private static func vaultBaseQuery() -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: vaultService,
            kSecAttrAccount as String: vaultAccount,
        ]
    }

    /// One full read of the vault item. Returns an empty state when no item
    /// exists, or nil when an item exists but can't be read.
    private static func liveReadVaultItem() -> VaultState? {
        var query = vaultBaseQuery()
        query[kSecReturnData as String] = true
        query[kSecReturnAttributes as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
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

    /// Existing installs used the Keychain default, which is unavailable while
    /// an iOS device is locked. Move the vault to the protection class Apple
    /// documents for background apps before reading it. If the device has not
    /// been unlocked since boot, both this update and the following read fail;
    /// because failed loads are not cached, a later foreground read retries.
    private static func liveMigrateVaultAccessibility() {
        #if os(iOS)
        var query = vaultBaseQuery()
        query[kSecReturnAttributes as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let attributes = result as? [String: Any],
              attributes[kSecAttrAccessible as String] as? String
                != kSecAttrAccessibleAfterFirstUnlock as String
        else { return }
        SecItemUpdate(
            vaultBaseQuery() as CFDictionary,
            [kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock] as CFDictionary)
        #endif
    }

    /// The vault item's current modification date (nil when absent).
    /// Attribute-only queries never trigger an access prompt.
    private static func liveProbeModDate() -> Date? {
        var query = vaultBaseQuery()
        query[kSecReturnAttributes as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let attributes = result as? [String: Any] else { return nil }
        return attributes[kSecAttrModificationDate as String] as? Date
    }

    private static func liveWriteVault(_ entries: [String: String]) -> Bool {
        guard let data = try? JSONEncoder().encode(entries) else { return false }
        var attributes: [String: Any] = [kSecValueData as String: data]
        #if os(iOS)
        attributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        #endif
        let status = SecItemUpdate(
            vaultBaseQuery() as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            var addQuery = vaultBaseQuery()
            addQuery.merge(attributes) { _, new in new }
            addQuery[kSecAttrLabel as String] = "Vellum"
            return SecItemAdd(addQuery as CFDictionary, nil) == errSecSuccess
        }
        return status == errSecSuccess
    }

    private static func liveDeleteVault() -> Bool {
        let status = SecItemDelete(vaultBaseQuery() as CFDictionary)
        return status == errSecSuccess || status == errSecItemNotFound
    }

    /// Lists the account names stored under a legacy service.
    private static func liveLegacyAccounts(in service: String) -> [String] {
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

    /// The value AND modification date of a legacy item: reconciliation needs
    /// the date to resolve a conflict with the vault's copy of the same key.
    private static func liveLegacyRead(account: String, service: String) -> LegacyItem? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecReturnAttributes as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let item = result as? [String: Any],
              let data = item[kSecValueData as String] as? Data,
              let value = String(data: data, encoding: .utf8) else { return nil }
        return LegacyItem(value: value, modDate: item[kSecAttrModificationDate as String] as? Date)
    }

    private static func liveLegacyDelete(account: String, service: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(query as CFDictionary)
    }

    /// File descriptor used to `flock` vault commits across processes: several
    /// Vellum instances (worktree builds share the bundle id, and so this
    /// path and the vault item) may run at once, and an unserialized
    /// whole-item read-modify-write would let one instance revert another's
    /// secrets. -1 when the lock file can't be opened; commits then fail.
    private static let commitLockFD: Int32 = {
        let dir = WebLibrary.appDataDir
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return open(dir.appendingPathComponent("keychain-vault.lock").path, O_CREAT | O_RDWR, 0o600)
    }()

    /// How long a commit will wait for the cross-process lock before failing.
    /// A blocking `LOCK_EX` was unbounded: an instance sitting on a keychain
    /// password prompt holds the lock for as long as the user ignores it, and
    /// every other instance's caller — often the main thread — waited behind
    /// it with no way out. Poll with a deadline instead; a failed `set` is
    /// already a retryable outcome by design.
    private static let commitLockTimeout: TimeInterval = 3
    private static let commitLockPollInterval: useconds_t = 20_000   // 20 ms

    private static func liveAcquireCommitLock() -> Bool {
        guard commitLockFD >= 0 else { return false }
        let deadline = Date().addingTimeInterval(commitLockTimeout)
        while true {
            if flock(commitLockFD, LOCK_EX | LOCK_NB) == 0 { return true }
            // EWOULDBLOCK: held elsewhere, worth retrying. EINTR: a signal cut
            // the call short. Anything else is a broken descriptor rather than
            // contention, so retrying would just burn the deadline.
            guard errno == EWOULDBLOCK || errno == EINTR else { return false }
            guard Date() < deadline else { return false }
            usleep(commitLockPollInterval)
        }
    }

    private static func liveReleaseCommitLock() {
        guard commitLockFD >= 0 else { return }
        flock(commitLockFD, LOCK_UN)
    }

    #if DEBUG
    /// Test-only seam: runs `body` with the vault logic wired to `backend`
    /// instead of the Keychain, starting from a cold cache and restoring the
    /// previous state (backend and cache) afterwards. Installing a backend
    /// also suspends the `isRunningTests` stand-in for the duration, so the
    /// test exercises the real vault code paths — against a fake keychain, so
    /// the login keychain is still never touched. The override is
    /// process-global; suites that use it must be `.serialized`.
    static func withBackend(_ backend: Backend, _ body: () throws -> Void) rethrows {
        lock.lock()
        let previousBackend = backendOverride
        let previousCache = cache
        backendOverride = backend
        cache = nil
        lock.unlock()
        defer {
            lock.lock()
            backendOverride = previousBackend
            cache = previousCache
            lock.unlock()
        }
        try body()
    }
    #endif

    // Account identifiers, one per provider with a stored secret.
    enum Account {
        static let gemini = "gemini"
        static let openai = "openai"
        static let openrouter = "openrouter"
        static let opencode = "opencode"
        static let opencodeGo = "opencode-go"
    }
}
