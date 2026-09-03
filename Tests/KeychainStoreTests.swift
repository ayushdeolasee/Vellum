import Foundation
import Testing

@testable import Vellum

// The vault is the one place in the app where a bug destroys something the
// user cannot recreate: every API key lives in a single keychain item, rewritten
// whole on every change. Until now none of it was
// testable, because it called the Security framework directly and the test
// guard (`isRunningTests` -> in-memory store) short-circuits every public entry
// point before the vault logic runs.
//
// `KeychainStore.withBackend` is the seam these tests drive: it swaps the
// Security/flock calls for a fake and, for that scope only, opts back into the
// real read-modify-write code. The login keychain is still never touched — the
// fake is the only thing being read or written — and the last test here proves
// the guard is back in force the moment the scope ends.
//
// `.serialized` because the backend override and the vault cache are both
// process-global. That covers this suite; it holds overall only because no
// other Swift Testing suite reaches `KeychainStore` (the ones that build an
// `AiStore`, and so load settings, are all XCTest, which does not run in
// parallel with these). A future suite that does would perturb the exact
// read/write counts asserted below — give it an `InMemoryIntegrationCredentials`
// -style double instead of the real store.

@Suite("Keychain vault", .serialized)
struct KeychainStoreTests {
    private let aiService = "com.vellum.ai"
    private let integrationsService = "com.vellum.integrations"

    // MARK: - Legacy migration

    @Test("Legacy per-secret items are folded into the vault and then removed")
    func legacyItemsMigrateIntoTheVault() {
        let fake = FakeKeychain()
        fake.seedLegacy(service: aiService, account: "gemini", value: "g1")
        fake.seedLegacy(service: integrationsService, account: "read-later.readwise", value: "rw1")

        KeychainStore.withBackend(fake.backend) {
            #expect(KeychainStore.get("gemini") == "g1")
            #expect(KeychainStore.get("read-later.readwise", service: integrationsService) == "rw1")
            #expect(
                fake.vaultEntries == [
                    "com.vellum.ai/gemini": "g1",
                    "com.vellum.integrations/read-later.readwise": "rw1",
                ])
            #expect(fake.legacyValue(service: aiService, account: "gemini") == nil)
            #expect(fake.legacyValue(service: integrationsService, account: "read-later.readwise") == nil)
            #expect(fake.vaultUsesAfterFirstUnlock)
        }
    }

    @Test("A locked existing vault retries its accessibility migration after unlock")
    func existingVaultAccessibilityMigrationRetries() {
        let fake = FakeKeychain()
        fake.seedVault(
            ["com.vellum.integrations/read-later.readwise": "rw1"],
            afterFirstUnlock: false)
        fake.accessibilityMigrationSucceeds = false
        fake.vaultIsReadable = false

        KeychainStore.withBackend(fake.backend) {
            #expect(KeychainStore.get("read-later.readwise", service: integrationsService) == nil)
            #expect(fake.accessibilityMigrationAttemptCount == 1)

            fake.accessibilityMigrationSucceeds = true
            fake.vaultIsReadable = true

            #expect(
                KeychainStore.get("read-later.readwise", service: integrationsService) == "rw1")
            #expect(fake.vaultUsesAfterFirstUnlock)
            #expect(fake.accessibilityMigrationAttemptCount == 2)
            #expect(fake.readCount == 2, "the failed locked-device read must not be cached")
        }
    }

    /// The data-loss case this suite exists for. Sequence: a vault build
    /// migrates the key, the user then runs a PRE-vault build (which sees no
    /// key, since it only reads legacy items) and pastes a fresh token, which
    /// lands as a legacy item. Reconciliation used to delete that item unread
    /// because "the vault already has this key", and the stale copy won.
    @Test("A legacy value newer than the vault's copy wins instead of being deleted")
    func newerLegacyValueSurvivesReconcile() {
        let fake = FakeKeychain()
        fake.seedVault(["com.vellum.ai/gemini": "migrated-then-superseded"])
        fake.seedLegacy(service: aiService, account: "gemini", value: "typed-into-the-old-build")

        KeychainStore.withBackend(fake.backend) {
            #expect(KeychainStore.get("gemini") == "typed-into-the-old-build")
            #expect(fake.vaultEntries?["com.vellum.ai/gemini"] == "typed-into-the-old-build")
            #expect(
                fake.legacyValue(service: aiService, account: "gemini") == nil,
                "the legacy item is deletable once its value is in the vault")
        }
    }

    /// The mirror image: the vault item was written after the legacy item, so
    /// the vault's copy is the one to keep. The legacy item still must not be
    /// deleted — the vault's date covers the WHOLE item, so a later write of
    /// some other secret can make the vault look newer than it is for this key.
    @Test("A legacy value the vault cannot prove it supersedes is kept")
    func olderConflictingLegacyValueIsNotDeleted() {
        let fake = FakeKeychain()
        fake.seedLegacy(service: aiService, account: "gemini", value: "stale")
        fake.seedVault(["com.vellum.ai/gemini": "current"])

        KeychainStore.withBackend(fake.backend) {
            #expect(KeychainStore.get("gemini") == "current")
            #expect(fake.writeCount == 0, "nothing to import means no vault rewrite")
            #expect(
                fake.legacyValue(service: aiService, account: "gemini") == "stale",
                "an undecidable conflict must not destroy the only copy of a value")
        }
    }

    @Test("A legacy item matching the vault is cleaned up without a rewrite")
    func redundantLegacyItemIsDeleted() {
        let fake = FakeKeychain()
        fake.seedLegacy(service: aiService, account: "gemini", value: "g1")
        fake.seedVault(["com.vellum.ai/gemini": "g1"])

        KeychainStore.withBackend(fake.backend) {
            #expect(KeychainStore.get("gemini") == "g1")
            #expect(fake.legacyValue(service: aiService, account: "gemini") == nil)
            #expect(fake.writeCount == 0)
        }
    }

    /// A legacy item that can't be read (denied prompt) is the case that must
    /// keep being retried: skip it, leave it in place, change nothing.
    @Test("An unreadable legacy item is neither imported nor deleted")
    func unreadableLegacyItemIsRetriedLater() {
        let fake = FakeKeychain()
        fake.seedLegacy(service: aiService, account: "gemini", value: "g1")
        fake.unreadableLegacyAccounts = ["gemini"]

        KeychainStore.withBackend(fake.backend) {
            #expect(KeychainStore.get("gemini") == nil)
            #expect(fake.writeCount == 0)
            #expect(fake.legacyValue(service: aiService, account: "gemini") == "g1")
        }
    }

    // MARK: - Cross-instance freshness

    /// Several Vellum builds share a bundle id and therefore this vault. A
    /// token written by one used to stay invisible to the others until relaunch
    /// — long enough for the sync engine to decide the account needs
    /// re-authentication. The mod-date probe is attribute-only, so keeping
    /// reads fresh costs no extra prompt.
    @Test("A read reloads the vault after another instance writes it")
    func staleCacheReloadsOnAnExternalWrite() {
        let fake = FakeKeychain()
        fake.seedVault(["com.vellum.ai/gemini": "g1"])

        KeychainStore.withBackend(fake.backend) {
            #expect(KeychainStore.get("gemini") == "g1")
            #expect(fake.readCount == 1)

            fake.seedVault(["com.vellum.ai/gemini": "g2"])

            #expect(KeychainStore.get("gemini") == "g2")
            #expect(fake.readCount == 2)
            #expect(KeychainStore.get("gemini") == "g2")
            #expect(fake.readCount == 2, "an unchanged mod date must not cost a full read")
        }
    }

    @Test("A failed refresh falls back to the cached copy instead of nil")
    func refreshFailureKeepsTheCachedCopy() {
        let fake = FakeKeychain()
        fake.seedVault(["com.vellum.ai/gemini": "g1"])

        KeychainStore.withBackend(fake.backend) {
            #expect(KeychainStore.get("gemini") == "g1")
            fake.seedVault(["com.vellum.ai/gemini": "g2"])
            fake.vaultIsReadable = false

            #expect(
                KeychainStore.get("gemini") == "g1",
                "stale-but-readable beats nil, which callers report as a missing credential")
        }
    }

    /// The write half of the same problem: the commit re-reads under the
    /// cross-process lock, so a whole-item write built from a stale cache can
    /// never revert the other instance's secrets.
    @Test("A commit re-reads a vault that changed underneath it")
    func commitReReadsBeforeWriting() {
        let fake = FakeKeychain()
        fake.seedVault(["com.vellum.ai/gemini": "g1"])

        KeychainStore.withBackend(fake.backend) {
            #expect(KeychainStore.get("gemini") == "g1")   // warms the stale cache
            // Another instance stores a secret this process has never seen.
            fake.seedVault(["com.vellum.ai/gemini": "g1", "com.vellum.ai/openai": "o1"])

            #expect(KeychainStore.set("openrouter", "r1"))
            #expect(
                fake.vaultEntries == [
                    "com.vellum.ai/gemini": "g1",
                    "com.vellum.ai/openai": "o1",
                    "com.vellum.ai/openrouter": "r1",
                ])
        }
    }

    // MARK: - Failure modes

    /// An unreadable vault must never be treated as an empty one: rewriting
    /// from an empty in-memory copy would wipe every other secret in it.
    @Test("An unreadable vault yields nil reads and failed writes, and is left intact")
    func unreadableVaultFailsClosed() {
        let fake = FakeKeychain()
        fake.seedVault(["com.vellum.ai/gemini": "g1"])
        fake.vaultIsReadable = false

        KeychainStore.withBackend(fake.backend) {
            #expect(KeychainStore.get("gemini") == nil)
            #expect(KeychainStore.set("openai", "o1") == false)
            #expect(fake.writeCount == 0)
            #expect(fake.deleteCount == 0)
            #expect(fake.vaultEntries == ["com.vellum.ai/gemini": "g1"])
        }
    }

    /// The commit lock is bounded now, so "not acquired" is a real outcome. It
    /// has to fail the write rather than proceed unserialized: a failed `set`
    /// leaves the caller's plaintext copy in place for a retry, an unserialized
    /// write can revert another instance.
    @Test("A commit that cannot take the cross-process lock fails without writing")
    func commitFailsWhenTheLockIsUnavailable() {
        let fake = FakeKeychain()
        fake.seedVault(["com.vellum.ai/gemini": "g1"])
        fake.commitLockIsAvailable = false

        KeychainStore.withBackend(fake.backend) {
            #expect(KeychainStore.set("openai", "o1") == false)
            #expect(fake.writeCount == 0)
            #expect(KeychainStore.get("gemini") == "g1", "reads never take the lock")
        }
    }

    @Test("A failed write leaves the stored vault untouched")
    func failedWriteDoesNotMutateTheCache() {
        let fake = FakeKeychain()
        fake.seedVault(["com.vellum.ai/gemini": "g1"])
        fake.vaultWriteSucceeds = false

        KeychainStore.withBackend(fake.backend) {
            #expect(KeychainStore.set("openai", "o1") == false)
            #expect(fake.vaultEntries == ["com.vellum.ai/gemini": "g1"])
            #expect(KeychainStore.get("openai") == nil)
        }
    }

    @Test("Removing the last secret deletes the vault item")
    func emptyVaultIsDeleted() {
        let fake = FakeKeychain()
        fake.seedVault(["com.vellum.ai/gemini": "g1"])

        KeychainStore.withBackend(fake.backend) {
            #expect(KeychainStore.delete("gemini"))
            #expect(fake.deleteCount == 1)
            #expect(fake.vaultEntries == nil)
            #expect(KeychainStore.get("gemini") == nil)
            #expect(fake.lockDepth == 0, "the commit lock is released on every path")
        }
    }

    @Test("Setting an empty value deletes the account")
    func emptyValueDeletes() {
        let fake = FakeKeychain()
        fake.seedVault(["com.vellum.ai/gemini": "g1", "com.vellum.ai/openai": "o1"])

        KeychainStore.withBackend(fake.backend) {
            #expect(KeychainStore.set("gemini", "   "))
            #expect(fake.vaultEntries == ["com.vellum.ai/openai": "o1"])
        }
    }

    // MARK: - Startup

    /// The first read of a launch is the expensive one (full item read, legacy
    /// enumeration, possibly a commit and a password prompt) and it is
    /// reachable synchronously from `@MainActor` callers. `prewarm` moves it
    /// off the caller's thread so those callers only ever hit the cache.
    @Test("prewarm loads the vault off the calling thread")
    func prewarmWarmsTheCacheInTheBackground() {
        let fake = FakeKeychain()
        fake.seedVault(["com.vellum.ai/gemini": "g1"])
        let loaded = DispatchSemaphore(value: 0)
        fake.onRead = { loaded.signal() }

        KeychainStore.withBackend(fake.backend) {
            KeychainStore.prewarm()
            #expect(loaded.wait(timeout: .now() + 5) == .success)
            #expect(fake.readWasOnMainThread == false)
            #expect(KeychainStore.get("gemini") == "g1")
            #expect(fake.readCount == 1, "the warmed cache serves the first get")
        }
    }

    // MARK: - The seam itself

    /// The seam must not become a way for ordinary app code under test to
    /// reach a keychain: outside `withBackend`, the in-memory stand-in is back.
    @Test("The test-store guard is restored once the backend scope ends")
    func theTestStoreGuardSurvivesTheSeam() {
        let fake = FakeKeychain()
        fake.seedVault(["com.vellum.ai/gemini": "g1"])
        KeychainStore.withBackend(fake.backend) {
            #expect(KeychainStore.get("gemini") == "g1")
        }
        let readsDuringTheScope = fake.readCount

        let account = "seam-probe-\(UUID().uuidString)"
        #expect(KeychainStore.get("gemini") != "g1", "the fake is no longer installed")
        #expect(KeychainStore.set(account, "secret"))
        #expect(KeychainStore.get(account) == "secret")
        #expect(KeychainStore.delete(account))
        #expect(fake.readCount == readsDuringTheScope, "no traffic reaches the fake afterwards")
    }
}

/// In-memory stand-in for the two shapes of keychain item the vault talks to:
/// the single vault item and the leftover per-secret legacy items. Mutation
/// dates advance on every write, because the vault's cross-instance conflict
/// detection is built entirely on them.
///
/// `@unchecked Sendable` because `KeychainStore.Backend` holds `@Sendable`
/// closures: every call here happens synchronously on whichever single thread
/// drives the store, with the one exception of `prewarm`'s background load,
/// which the test waits on before touching the fake again.
private final class FakeKeychain: @unchecked Sendable {
    struct StoredItem {
        var value: String
        var modDate: Date
    }

    /// nil = no vault item exists at all (distinct from an empty one).
    var vaultEntries: [String: String]?
    var vaultModDate: Date?
    /// The item exists but its data can't be had — a denied prompt, or a
    /// payload that no longer decodes. Attribute probes still succeed, as they
    /// do on macOS.
    var vaultIsReadable = true
    var vaultUsesAfterFirstUnlock = true
    var accessibilityMigrationSucceeds = true
    var vaultWriteSucceeds = true
    var commitLockIsAvailable = true
    /// service -> account -> item.
    var legacy: [String: [String: StoredItem]] = [:]
    /// Legacy accounts that enumerate but refuse to be read.
    var unreadableLegacyAccounts: Set<String> = []
    /// Signalled from `readVaultItem`, so a background load can be awaited.
    var onRead: (@Sendable () -> Void)?

    private(set) var readCount = 0
    private(set) var accessibilityMigrationAttemptCount = 0
    private(set) var probeCount = 0
    private(set) var writeCount = 0
    private(set) var deleteCount = 0
    private(set) var lockDepth = 0
    private(set) var readWasOnMainThread: Bool?

    private var clock = Date(timeIntervalSince1970: 1_700_000_000)

    /// Advances and returns the modification clock; every stored write gets a
    /// strictly later date than the one before it.
    @discardableResult
    func tick() -> Date {
        clock = clock.addingTimeInterval(1)
        return clock
    }

    func seedVault(
        _ entries: [String: String], at date: Date? = nil, afterFirstUnlock: Bool = true
    ) {
        vaultEntries = entries
        vaultModDate = date ?? tick()
        vaultUsesAfterFirstUnlock = afterFirstUnlock
    }

    func seedLegacy(service: String, account: String, value: String, at date: Date? = nil) {
        legacy[service, default: [:]][account] = StoredItem(value: value, modDate: date ?? tick())
    }

    func legacyValue(service: String, account: String) -> String? {
        legacy[service]?[account]?.value
    }

    var backend: KeychainStore.Backend {
        KeychainStore.Backend(
            readVaultItem: { [self] in
                readCount += 1
                if readWasOnMainThread == nil { readWasOnMainThread = Thread.isMainThread }
                onRead?()
                guard let vaultEntries else {
                    return KeychainStore.VaultState(entries: [:], modDate: nil)
                }
                guard vaultIsReadable else { return nil }
                return KeychainStore.VaultState(entries: vaultEntries, modDate: vaultModDate)
            },
            migrateVaultAccessibility: { [self] in
                guard vaultEntries != nil, !vaultUsesAfterFirstUnlock else { return }
                accessibilityMigrationAttemptCount += 1
                guard accessibilityMigrationSucceeds else { return }
                vaultUsesAfterFirstUnlock = true
                vaultModDate = tick()
            },
            probeModDate: { [self] in
                probeCount += 1
                return vaultEntries == nil ? nil : vaultModDate
            },
            writeVault: { [self] entries in
                writeCount += 1
                guard vaultWriteSucceeds else { return false }
                vaultEntries = entries
                vaultModDate = tick()
                vaultUsesAfterFirstUnlock = true
                return true
            },
            deleteVault: { [self] in
                deleteCount += 1
                vaultEntries = nil
                vaultModDate = nil
                return true
            },
            legacyAccounts: { [self] service in
                (legacy[service] ?? [:]).keys.sorted()
            },
            legacyRead: { [self] account, service in
                guard !unreadableLegacyAccounts.contains(account),
                      let item = legacy[service]?[account] else { return nil }
                return KeychainStore.LegacyItem(value: item.value, modDate: item.modDate)
            },
            legacyDelete: { [self] account, service in
                legacy[service]?[account] = nil
            },
            acquireCommitLock: { [self] in
                guard commitLockIsAvailable else { return false }
                lockDepth += 1
                return true
            },
            releaseCommitLock: { [self] in
                lockDepth -= 1
            })
    }
}
