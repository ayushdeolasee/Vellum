import Foundation
import Security
import os

/// Thin wrapper over the macOS Keychain for generic Vellum credentials.
/// Callers choose a service namespace; the AI service remains the default.
///
/// macOS secrets share one item; iOS integration tokens have separate
/// background items. Foreground secrets use a JSON "vault"
/// mapping "service/account" to the secret. macOS grants keychain access per
/// item and per read, and this app is ad-hoc signed (new signature every
/// build), so one item per secret meant one password prompt per secret per
/// read. A single vault item, read once per launch and cached, caps that at
/// one prompt total. Legacy per-secret items are folded into the vault on the
/// first load, with unresolved migration retried later in the same process.
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

    private static var vaultService: String { RuntimeProfile.current.keychainVaultService }
    private static let vaultAccount = "vault"
    /// Service namespaces that previously stored one keychain item per secret.
    private static var legacyServices: [String] {
        RuntimeProfile.current.isDevelopment && !isRunningTests
            ? []
            : ["com.vellum.ai", "com.vellum.integrations"]
    }

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

    enum LegacyAccountsRead: Sendable {
        case accounts([String])
        case unavailable
    }

    enum LegacyRead: Sendable {
        case value(LegacyItem)
        case missing
        case unavailable
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
        /// The vault item's modification date, nil when absent. Attribute-only,
        /// so it must never trigger an access prompt.
        var probeModDate: @Sendable () -> Date?
        /// Persists the whole vault. False must leave the stored item as it was.
        var writeVault: @Sendable ([String: String]) -> Bool
        /// Removes the vault item. True also when it was already absent.
        var deleteVault: @Sendable () -> Bool
        /// Account names stored under a legacy per-secret service.
        var legacyAccounts: @Sendable (_ service: String) -> LegacyAccountsRead
        /// A legacy item's value/date, distinguishing absence from denial.
        var legacyRead: @Sendable (_ account: String, _ service: String) -> LegacyRead
        var legacyDelete: @Sendable (_ account: String, _ service: String) -> Void
        /// Cross-process commit lock. False means it was not acquired within
        /// the deadline, and the commit must fail rather than race.
        var acquireCommitLock: @Sendable () -> Bool
        var releaseCommitLock: @Sendable () -> Void
        var readIntegration: @Sendable (String) -> CredentialRead = { _ in .unavailable }
        var writeIntegration: @Sendable (String, String) -> Bool = { _, _ in false }
        var deleteIntegration: @Sendable (String) -> Bool = { _ in false }

        static let live = Backend(
            readVaultItem: { KeychainStore.liveReadVaultItem() },
            probeModDate: { KeychainStore.liveProbeModDate() },
            writeVault: { KeychainStore.liveWriteVault($0) },
            deleteVault: { KeychainStore.liveDeleteVault() },
            legacyAccounts: { KeychainStore.liveLegacyAccounts(in: $0) },
            legacyRead: { KeychainStore.liveLegacyRead(account: $0, service: $1) },
            legacyDelete: { KeychainStore.liveLegacyDelete(account: $0, service: $1) },
            acquireCommitLock: { KeychainStore.liveAcquireCommitLock() },
            releaseCommitLock: { KeychainStore.liveReleaseCommitLock() },
            readIntegration: { KeychainStore.liveReadIntegration($0) },
            writeIntegration: { KeychainStore.liveWriteIntegration($0, value: $1) },
            deleteIntegration: { KeychainStore.liveDeleteIntegration($0) })
    }

    private static let lock = NSLock()
    /// In-memory copy of the vault, loaded from the Keychain at most once per
    /// launch (plus a re-read whenever the item's mod date says another
    /// instance wrote it). Guarded by `lock`; nil until the first load.
    nonisolated(unsafe) private static var cache: VaultState?
    nonisolated(unsafe) private static var unresolvedLegacyServices: Set<String> = []
    nonisolated(unsafe) private static var unresolvedLegacyKeys: Set<String> = []
    #if DEBUG
    nonisolated(unsafe) private static var separateIntegrationsOverride: Bool?
    #endif

    private static var separatesIntegrations: Bool {
        #if DEBUG
        if let separateIntegrationsOverride { return separateIntegrationsOverride }
        #endif
        #if os(iOS)
        return true
        #else
        return false
        #endif
    }
    private static let integrationService = "com.vellum.integrations"
    private static func isBackgroundIntegration(_ account: String, service: String) -> Bool {
        separatesIntegrations && service == integrationService
            && ["read-later.readwise", "read-later.raindrop"].contains(account)
    }
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

    enum CredentialRead: Equatable, Sendable {
        case value(String)
        case missing
        case unavailable
    }

    /// A locked/denied/corrupt vault is retryable, never proof of a missing token.
    static func read(_ account: String, service: String = service) -> CredentialRead {
        lock.lock()
        defer { lock.unlock() }
        if usesTestStoreLocked {
            return testStore.withLock { values in
                values[vaultKey(account, service)].map(CredentialRead.value) ?? .missing
            }
        }
        if isBackgroundIntegration(account, service: service) {
            return readIntegrationLocked(account)
        }
        return readSharedLocked(account, service: service)
    }

    private static func readSharedLocked(_ account: String, service: String) -> CredentialRead {
        let wasLoaded = cache != nil
        guard var vault = currentVaultLocked() else { return .unavailable }
        let key = vaultKey(account, service)
        if let value = vault.entries[key] { return .value(value) }
        if wasLoaded, legacyIsUnresolved(key: key, service: service) {
            reconcileLegacyItemsLocked()
            vault = cache ?? vault
            if let value = vault.entries[key] { return .value(value) }
        }
        return legacyIsUnresolved(key: key, service: service) ? .unavailable : .missing
    }

    private static func legacyIsUnresolved(key: String, service: String) -> Bool {
        unresolvedLegacyServices.contains(service) || unresolvedLegacyKeys.contains(key)
    }

    /// Integration items alone need locked-device background access. A cold
    /// foreground vault read is required before copying a source credential;
    /// a warm plaintext cache is not evidence that migration is unlocked.
    private static func readIntegrationLocked(_ account: String) -> CredentialRead {
        let backend = backendLocked
        switch backend.readIntegration(account) {
        case .value(let value):
            // Locked source bytes do not revoke a verified background copy.
            // Once readable, conflicting source bytes are never guessed away.
            if let fresh = backend.readVaultItem() {
                cache = fresh
                reconcileLegacyItemsLocked()
                if let source = cache?.entries[vaultKey(account, integrationService)] {
                    guard source == value else { return .unavailable }
                    if backend.acquireCommitLock() {
                        defer { backend.releaseCommitLock() }
                        guard backend.readIntegration(account) == .value(value) else { return .unavailable }
                        let removed = commitLocked([vaultKey(account, integrationService): nil],
                            holdingCommitLock: true, expectedValues: [vaultKey(account, integrationService): value])
                        if !removed, sourceConflictsLocked(account, value: value) { return .unavailable }
                    }
                }
            }
            return .value(value)
        case .unavailable: return .unavailable
        case .missing: break
        }
        guard let fresh = backend.readVaultItem() else { return .unavailable }
        cache = fresh
        reconcileLegacyItemsLocked()
        switch readSharedLocked(account, service: integrationService) {
        case .missing: return .missing
        case .unavailable: return .unavailable
        case .value(let value):
            guard backend.acquireCommitLock() else { return .unavailable }
            defer { backend.releaseCommitLock() }
            // Another process may have installed the destination while we waited.
            switch backend.readIntegration(account) {
            case .value(let installed):
                return installed == value ? .value(installed) : .unavailable
            case .unavailable: return .unavailable
            case .missing: break
            }
            let key = vaultKey(account, integrationService)
            guard let source = backend.readVaultItem(), source.entries[key] == value,
                  backend.writeIntegration(account, value),
                  backend.readIntegration(account) == .value(value) else { return .unavailable }
            // An interruption before cleanup leaves two valid copies. Never
            // remove the source unless the separately protected copy verifies.
            let removed = commitLocked([key: nil], holdingCommitLock: true, expectedValues: [key: value])
            if !removed, sourceConflictsLocked(account, value: value) { return .unavailable }
            return .value(value)
        }
    }

    private static func sourceConflictsLocked(_ account: String, value: String) -> Bool {
        guard let source = backendLocked.readVaultItem(),
              let stored = source.entries[vaultKey(account, integrationService)] else { return false }
        return stored != value
    }

    private static func removeSharedIntegrationLocked(_ account: String) -> Bool {
        let key = vaultKey(account, integrationService)
        // Resolve any legacy copy before removing it; denial is not absence.
        let expected: [String: String]
        let absent: Set<String>
        switch readSharedLocked(account, service: integrationService) {
        case .unavailable: return false
        case .value(let value): expected = [key: value]; absent = []
        case .missing: expected = [:]; absent = [key]
        }
        guard !legacyIsUnresolved(key: key, service: integrationService),
              commitLocked([key: nil], expectedValues: expected, expectedMissing: absent),
              let verified = backendLocked.readVaultItem(), verified.entries[key] == nil else { return false }
        cache = verified
        switch backendLocked.legacyRead(account, integrationService) {
        case .missing: return true
        case .unavailable: return false
        case .value:
            backendLocked.legacyDelete(account, integrationService)
            if case .missing = backendLocked.legacyRead(account, integrationService) { return true }
            return false
        }
    }

    /// Compatibility for foreground AI callers that do not expose availability.
    static func get(_ account: String, service: String = service) -> String? {
        guard case .value(let value) = read(account, service: service) else { return nil }
        return value
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
        if isBackgroundIntegration(account, service: service) {
            let backend = backendLocked
            guard backend.acquireCommitLock() else { return false }
            let verified = backend.writeIntegration(account, trimmed)
                && backend.readIntegration(account) == .value(trimmed)
            backend.releaseCommitLock()
            guard verified else { return false }
            _ = removeSharedIntegrationLocked(account)
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
        if isBackgroundIntegration(account, service: service) {
            let backend = backendLocked
            let destination = backend.readIntegration(account)
            guard destination != .unavailable, removeSharedIntegrationLocked(account),
                  backend.acquireCommitLock() else { return false }
            defer { backend.releaseCommitLock() }
            let key = vaultKey(account, service)
            guard let source = backend.readVaultItem(), source.entries[key] == nil,
                  case .missing = backend.legacyRead(account, service),
                  backend.readIntegration(account) == destination else { return false }
            return backend.deleteIntegration(account)
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
    /// never touched at all. Development warms only its isolated vault;
    /// production also migrates and removes legacy production credentials.
    static func prewarm(profile: RuntimeProfile = .current) {
        let allowsLegacyAccess = profile.allowsProductionServices
        DispatchQueue.global(qos: .userInitiated).async {
            lock.lock()
            defer { lock.unlock() }
            guard !usesTestStoreLocked else { return }
            _ = loadVaultLocked(reconcileLegacy: allowsLegacyAccess)
            if allowsLegacyAccess {
                purgeRemovedCredentialsLocked()
            }
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
    private static func loadVaultLocked(reconcileLegacy: Bool = true) -> VaultState? {
        if let cache { return cache }
        guard let state = backendLocked.readVaultItem() else { return nil }
        cache = state
        if reconcileLegacy {
            reconcileLegacyItemsLocked()
        }
        return cache
    }

    /// Applies account mutations (value = nil deletes) on top of the current
    /// vault and persists the result as the single keychain item. Call with
    /// `lock` held.
    private static func commitLocked(_ mutations: [String: String?], holdingCommitLock: Bool = false, expectedValues: [String: String] = [:], expectedMissing: Set<String> = []) -> Bool {
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
        if !holdingCommitLock, !backend.acquireCommitLock() { return false }
        defer { if !holdingCommitLock { backend.releaseCommitLock() } }
        // Another instance may have rewritten the vault since we cached it.
        // The modification date is readable without an access prompt, so
        // detect that case and re-read before mutating — a whole-item write
        // from a stale cache would revert the other instance's secrets. The
        // fresh read can prompt, but only in this rare conflict case.
        if backend.probeModDate() != state.modDate {
            guard let fresh = backend.readVaultItem() else { return false }
            state = fresh
        }
        guard expectedValues.allSatisfy({ state.entries[$0.key] == $0.value }),
              expectedMissing.allSatisfy({ state.entries[$0] == nil }) else { return false }
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
    /// first vault load, and again for missing keys whose migration failed.
    /// A denied enumeration/read or failed copy is not evidence of absence.
    /// A legacy item is deleted only once its value is provably preserved. Call with `lock` held, after `cache` is populated.
    private static func reconcileLegacyItemsLocked() {
        let backend = backendLocked
        unresolvedLegacyServices = []
        unresolvedLegacyKeys = []
        var mutations: [String: String?] = [:]
        var resolved: [(service: String, account: String)] = []
        let entries = cache?.entries ?? [:]
        let vaultDate = cache?.modDate
        for legacyService in legacyServices {
            guard case .accounts(let accounts) = backend.legacyAccounts(legacyService) else {
                unresolvedLegacyServices.insert(legacyService)
                continue
            }
            for account in accounts {
                let key = vaultKey(account, legacyService)
                // Read before deciding anything. A pre-vault build writes only
                // legacy items, so running one after a migration leaves an item
                // whose value is NEWER than the vault's copy of the same key;
                // deleting it because "the vault already has that key" threw
                // away the token the user had just entered.
                let legacy: LegacyItem
                switch backend.legacyRead(account, legacyService) {
                case .value(let item): legacy = item
                case .missing: continue
                case .unavailable:
                    unresolvedLegacyKeys.insert(key)
                    continue
                }
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
        if commitLocked(mutations), let verified = backend.readVaultItem(),
           mutations.allSatisfy({ verified.entries[$0.key] == $0.value }) {
            cache = verified
            for item in resolved {
                backend.legacyDelete(item.account, item.service)
            }
        } else {
            unresolvedLegacyKeys.formUnion(mutations.keys)
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
#if os(iOS)
        // AI credentials remain foreground-only. Existing shared source bytes
        // are read while unlocked before migrating integrations separately.
        let accessibility = item[kSecAttrAccessible as String] as? String
        if accessibility != kSecAttrAccessibleWhenUnlockedThisDeviceOnly as String,
           accessibility != kSecAttrAccessibleWhenUnlocked as String {
            guard SecItemUpdate(vaultBaseQuery() as CFDictionary,
                [kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly] as CFDictionary) == errSecSuccess
            else { return nil }
        }
#endif
        return VaultState(entries: entries, modDate: item[kSecAttrModificationDate as String] as? Date)
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
        // The shared foreground vault must not broaden AI key accessibility.
        attributes[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
#endif
        let status = SecItemUpdate(vaultBaseQuery() as CFDictionary, attributes as CFDictionary)
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
    private static func liveLegacyAccounts(in service: String) -> LegacyAccountsRead {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecMatchLimit as String: kSecMatchLimitAll,
            kSecReturnAttributes as String: true,
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return .accounts([]) }
        guard status == errSecSuccess, let items = result as? [[String: Any]],
              items.allSatisfy({ $0[kSecAttrAccount as String] is String }) else { return .unavailable }
        return .accounts(items.compactMap { $0[kSecAttrAccount as String] as? String })
    }

    /// The value AND modification date of a legacy item: reconciliation needs
    /// the date to resolve a conflict with the vault's copy of the same key.
    private static func liveLegacyRead(account: String, service: String) -> LegacyRead {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecReturnAttributes as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return .missing }
        guard status == errSecSuccess,
              let item = result as? [String: Any],
              let data = item[kSecValueData as String] as? Data,
              let value = String(data: data, encoding: .utf8) else { return .unavailable }
        return .value(LegacyItem(value: value, modDate: item[kSecAttrModificationDate as String] as? Date))
    }

    private static func integrationQuery(_ account: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: vaultService + ".background-integrations",
         kSecAttrAccount as String: account]
    }

    private static func liveReadIntegration(_ account: String) -> CredentialRead {
        var query = integrationQuery(account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return .missing }
        guard status == errSecSuccess, let data = result as? Data,
              let value = String(data: data, encoding: .utf8), !value.isEmpty else { return .unavailable }
        return .value(value)
    }

    private static func liveWriteIntegration(_ account: String, value: String) -> Bool {
        var attributes: [String: Any] = [kSecValueData as String: Data(value.utf8)]
        #if os(iOS)
        attributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        #endif
        let query = integrationQuery(account)
        let status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            return SecItemAdd(query.merging(attributes) { _, new in new } as CFDictionary, nil) == errSecSuccess
        }
        return status == errSecSuccess
    }

    private static func liveDeleteIntegration(_ account: String) -> Bool {
        let status = SecItemDelete(integrationQuery(account) as CFDictionary)
        return status == errSecSuccess || status == errSecItemNotFound
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
    static func withBackend(_ backend: Backend, separateIntegrations: Bool = false, _ body: () throws -> Void) rethrows {
        lock.lock()
        let previousBackend = backendOverride
        let previousCache = cache
        let previousServices = unresolvedLegacyServices
        let previousKeys = unresolvedLegacyKeys
        let previousSeparation = separateIntegrationsOverride
        unresolvedLegacyServices = []
        unresolvedLegacyKeys = []
        separateIntegrationsOverride = separateIntegrations
        backendOverride = backend
        cache = nil
        lock.unlock()
        defer {
            lock.lock()
            backendOverride = previousBackend
            cache = previousCache
            unresolvedLegacyServices = previousServices
            unresolvedLegacyKeys = previousKeys
            separateIntegrationsOverride = previousSeparation
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
