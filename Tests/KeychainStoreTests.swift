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

@Suite("Keychain vault", .serialized, .isolatedStorage)
struct KeychainStoreTests {
    private let aiService = "com.vellum.ai"
    private let integrationsService = "com.vellum.integrations"

    @Test("Cold unavailable credentials remain retryable and distinct from missing")
    func unavailableCredentialRecoversAfterUnlock() {
        let fake = FakeKeychain()
        fake.seedVault(["com.vellum.integrations/read-later.readwise": "retained-token"])
        fake.vaultIsReadable = false
        KeychainStore.withBackend(fake.backend) {
            #expect(KeychainStore.read("read-later.readwise", service: integrationsService) == .unavailable)
            #expect(fake.writeCount == 0)
            #expect(fake.deleteCount == 0)
            fake.vaultIsReadable = true
            #expect(KeychainStore.read("read-later.readwise", service: integrationsService) == .value("retained-token"))
            #expect(KeychainStore.read("not-configured", service: integrationsService) == .missing)
        }
    }

    @Test("Unavailable legacy reads and enumeration recover in the same process")
    func legacyFailuresRetryAfterUnlock() {
        for existingVault in [false, true] {
            let fake = FakeKeychain()
            if existingVault { fake.seedVault(["com.vellum.ai/gemini": "known-ai"]) }
            fake.seedLegacy(service: integrationsService, account: "read-later.readwise", value: "legacy-token")
            fake.unavailableLegacyServices = [integrationsService]
            KeychainStore.withBackend(fake.backend) {
                #expect(KeychainStore.read("read-later.readwise", service: integrationsService) == .unavailable)
                if existingVault { #expect(KeychainStore.get("gemini") == "known-ai") }
                fake.unavailableLegacyServices = []
                fake.unreadableLegacyAccounts = ["read-later.readwise"]
                #expect(KeychainStore.read("read-later.readwise", service: integrationsService) == .unavailable)
                #expect(fake.legacyDeleteCount == 0)
                fake.unreadableLegacyAccounts = []
                #expect(KeychainStore.read("read-later.readwise", service: integrationsService) == .value("legacy-token"))
                #expect(KeychainStore.read("missing", service: integrationsService) == .missing)
            }
        }
    }

    @Test("Failed legacy writes and commit locks preserve the source and retry")
    func failedLegacyMigrationRetries() {
        for lockFailure in [false, true] {
            let fake = FakeKeychain()
            fake.seedLegacy(service: integrationsService, account: "read-later.readwise", value: "legacy-token")
            fake.vaultWriteSucceeds = lockFailure
            fake.commitLockIsAvailable = !lockFailure
            KeychainStore.withBackend(fake.backend) {
                #expect(KeychainStore.read("read-later.readwise", service: integrationsService) == .unavailable)
                #expect(fake.legacyValue(service: integrationsService, account: "read-later.readwise") == "legacy-token")
                #expect(fake.legacyDeleteCount == 0)
                fake.vaultWriteSucceeds = true
                fake.commitLockIsAvailable = true
                #expect(KeychainStore.read("read-later.readwise", service: integrationsService) == .value("legacy-token"))
            }
        }
    }

    @Test("Separate background copy requires an unlocked source and verified destination")
    func separateIntegrationMigrationPreservesForegroundKeys() {
        for verificationFailure in [false, true] {
            let fake = FakeKeychain()
            fake.seedVault(["com.vellum.ai/gemini": "ai-key",
                            "com.vellum.integrations/read-later.readwise": "token"])
            KeychainStore.withBackend(fake.backend, separateIntegrations: true) {
                #expect(KeychainStore.get("gemini") == "ai-key")
                fake.vaultIsReadable = false
                #expect(KeychainStore.read("read-later.readwise", service: integrationsService) == .unavailable)
                #expect(fake.integrationItems.isEmpty)
                #expect(KeychainStore.get("gemini") == "ai-key")
                fake.vaultIsReadable = true
                fake.integrationWriteSucceeds = verificationFailure
                fake.integrationVerificationSucceeds = !verificationFailure
                #expect(KeychainStore.read("read-later.readwise", service: integrationsService) == .unavailable)
                #expect(fake.vaultEntries?["com.vellum.integrations/read-later.readwise"] == "token")
                fake.integrationWriteSucceeds = true
                fake.integrationVerificationSucceeds = true
                #expect(KeychainStore.read("read-later.readwise", service: integrationsService) == .value("token"))
                #expect(fake.vaultEntries == ["com.vellum.ai/gemini": "ai-key"])
                fake.vaultIsReadable = false
                #expect(KeychainStore.read("read-later.readwise", service: integrationsService) == .value("token"))
                #expect(KeychainStore.get("gemini") == "ai-key")
            }
            // A fresh process has no plaintext foreground cache while locked.
            KeychainStore.withBackend(fake.backend, separateIntegrations: true) {
                #expect(KeychainStore.read("gemini") == .unavailable)
                #expect(KeychainStore.read("read-later.readwise", service: integrationsService) == .value("token"))
            }
        }
    }

    @Test("Interrupted copy cleanup retries, conflicts preserve both, reconnect and delete do not resurrect")
    func separateIntegrationConflictAndDeletion() {
        let fake = FakeKeychain()
        let key = "com.vellum.integrations/read-later.readwise"
        fake.seedVault([key: "original"])
        fake.vaultDeleteSucceeds = false
        KeychainStore.withBackend(fake.backend, separateIntegrations: true) {
            #expect(KeychainStore.read("read-later.readwise", service: integrationsService) == .value("original"))
            #expect(fake.vaultEntries?[key] == "original")
            fake.vaultDeleteSucceeds = true
            #expect(KeychainStore.read("read-later.readwise", service: integrationsService) == .value("original"))
            #expect(fake.vaultEntries == nil)
            // An older app can reintroduce a source after successful migration.
            fake.seedVault([key: "new-source"])
            #expect(KeychainStore.read("read-later.readwise", service: integrationsService) == .unavailable)
            #expect(fake.integrationItems["read-later.readwise"] == "original")
            #expect(fake.vaultEntries?[key] == "new-source")
            fake.vaultDeleteSucceeds = false
            #expect(!KeychainStore.set("read-later.readwise", "reconnected", service: integrationsService))
            #expect(fake.integrationItems["read-later.readwise"] == "original")
            #expect(fake.vaultEntries?[key] == "new-source")
            #expect(KeychainStore.read("read-later.readwise", service: integrationsService) == .unavailable)
            fake.vaultDeleteSucceeds = true
            #expect(KeychainStore.set("read-later.readwise", "reconnected", service: integrationsService))
            #expect(KeychainStore.read("read-later.readwise", service: integrationsService) == .value("reconnected"))
            fake.seedVault([key: "retained-source"])
            fake.vaultDeleteSucceeds = false
            #expect(!KeychainStore.delete("read-later.readwise", service: integrationsService))
            #expect(fake.integrationItems["read-later.readwise"] == "reconnected")
            fake.vaultDeleteSucceeds = true
            #expect(KeychainStore.delete("read-later.readwise", service: integrationsService))
            #expect(fake.integrationItems.isEmpty)
            #expect(KeychainStore.read("read-later.readwise", service: integrationsService) == .missing)
        }
    }

    @Test("Compare-value cleanup cannot erase a source changed during copy")
    func separateIntegrationCleanupKeepsChangedSource() {
        let fake = FakeKeychain()
        let key = "com.vellum.integrations/read-later.readwise"
        fake.seedVault([key: "original"])
        fake.changeVaultOnIntegrationWrite = [key: "changed-during-copy"]
        KeychainStore.withBackend(fake.backend, separateIntegrations: true) {
            #expect(KeychainStore.read("read-later.readwise", service: integrationsService) == .unavailable)
            #expect(fake.vaultEntries?[key] == "changed-during-copy")
            #expect(fake.integrationItems["read-later.readwise"] == "original")
            #expect(fake.deleteCount == 0)
        }
    }

    @Test("Cleanup comparisons reread source bytes even with an unchanged modification date")
    func separateIntegrationCleanupChecksSameTimestamp() {
        for sourceInitiallyPresent in [false, true] {
            let fake = FakeKeychain()
            let key = "com.vellum.integrations/read-later.readwise"
            var original = ["com.vellum.ai/gemini": "cached-ai"]
            if sourceInitiallyPresent { original[key] = "old-source" }
            fake.seedVault(original)
            let timestamp = fake.vaultModDate
            fake.changeVaultOnIntegrationWrite = ["com.vellum.ai/gemini": "cached-ai", key: "concurrent-source"]
            fake.preserveVaultDateOnIntegrationWrite = true
            KeychainStore.withBackend(fake.backend, separateIntegrations: true) {
                #expect(KeychainStore.get("gemini") == "cached-ai")
                #expect(!KeychainStore.set("read-later.readwise", "requested-token", service: integrationsService))
                #expect(fake.vaultModDate == timestamp)
                #expect(fake.vaultEntries?[key] == "concurrent-source")
                #expect(fake.integrationItems["read-later.readwise"] == "requested-token")
                #expect(fake.writeCount == 0)
                #expect(fake.deleteCount == 0)
            }
        }
    }

    @Test("Destination-only reconnect failures restore old bytes, uncertain rollback is explicit")
    func reconnectRollbackAndUncertainty() {
        for verificationFailure in [false, true] {
            let fake = FakeKeychain()
            fake.seedVault(["com.vellum.ai/gemini": "retained-ai"])
            fake.integrationItems["read-later.readwise"] = "old-token"
            fake.makeVaultUnreadableOnIntegrationWrite = !verificationFailure
            fake.integrationVerificationResults = verificationFailure ? [false, true] : []
            KeychainStore.withBackend(fake.backend, separateIntegrations: true) {
                #expect(KeychainStore.writeCredential("read-later.readwise", "new-token", service: integrationsService) == .failed)
                #expect(fake.integrationItems["read-later.readwise"] == "old-token")
                #expect(fake.integrationWriteCount == 2)
                #expect(fake.maximumLockDepth == 1)
                #expect(fake.lockDepth == 0)
                fake.vaultIsReadable = true
                #expect(KeychainStore.read("read-later.readwise", service: integrationsService) == .value("old-token"))
                #expect(fake.vaultEntries == ["com.vellum.ai/gemini": "retained-ai"])
            }
        }
        let fake = FakeKeychain()
        fake.seedVault(["com.vellum.ai/gemini": "retained-ai"])
        fake.integrationItems["read-later.readwise"] = "old-token"
        fake.makeVaultUnreadableOnIntegrationWrite = true
        fake.integrationWriteResults = [true, false]
        KeychainStore.withBackend(fake.backend, separateIntegrations: true) {
            #expect(KeychainStore.writeCredential("read-later.readwise", "new-token", service: integrationsService) == .needsReview)
            #expect(fake.integrationItems["read-later.readwise"] == "new-token")
            #expect(fake.lockDepth == 0)
        }
    }

    @Test("Failed legacy cleanup restores the sole foreground source before deleting a new destination")
    func reconnectRollbackPreservesSoleSource() {
        let fake = FakeKeychain()
        let key = "com.vellum.integrations/read-later.readwise"
        fake.seedVault([key: "old-token"])
        // A legacy denial introduced after destination verification forces a
        // failure after source cleanup has already committed.
        fake.denyLegacyOnIntegrationWrite = "read-later.readwise"
        KeychainStore.withBackend(fake.backend, separateIntegrations: true) {
            #expect(KeychainStore.writeCredential("read-later.readwise", "new-token", service: integrationsService) == .failed)
            #expect(fake.integrationItems.isEmpty)
            #expect(fake.vaultEntries?[key] == "old-token")
            #expect(fake.maximumLockDepth == 1)
            #expect(fake.lockDepth == 0)
        }
    }

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

    @MainActor
    @Test("Loading an unavailable provider keeps its saved key and model")
    func unavailableProviderPreservesCredentials() {
        let fake = FakeKeychain()
        fake.seedVault(["com.vellum.ai/gemini": "retained-key"])
        let previous = AppDefaults.current.object(forKey: AiPersistence.settingsKey)
        defer {
            if let previous {
                AppDefaults.current.set(previous, forKey: AiPersistence.settingsKey)
            } else {
                AppDefaults.current.removeObject(forKey: AiPersistence.settingsKey)
            }
        }
        AppDefaults.current.set(
            #"{"provider":"gemini","model":"saved-model"}"#,
            forKey: AiPersistence.settingsKey)
        KeychainStore.withBackend(fake.backend) {
            let settings = AiPersistence.loadSettings()
            #if os(iOS)
            #expect(settings.provider == .openai)
            #else
            #expect(settings.provider == .gemini)
            #endif
            #expect(settings.model == "saved-model")
            #expect(settings.apiKey == "retained-key")
            #expect(fake.writeCount == 0)
            #expect(fake.deleteCount == 0)
        }
    }

    /// The first read of a launch is the expensive one (full item read, legacy
    /// enumeration, possibly a commit and a password prompt) and it is
    /// reachable synchronously from `@MainActor` callers. `prewarm` moves it
    /// off the caller's thread so those callers only ever hit the cache.
    @Test("Development prewarm loads its vault without legacy access")
    func developmentPrewarmAvoidsProductionLegacyCredentials() {
        let fake = FakeKeychain()
        fake.seedVault([
            "com.vellum.ai/gemini": "g1",
            "com.vellum.ai/chatgpt-tokens": "retired",
        ])
        fake.seedLegacy(
            service: aiService, account: "chatgpt-tokens", value: "retired")
        let loaded = DispatchSemaphore(value: 0)
        fake.onRead = { loaded.signal() }

        KeychainStore.withBackend(fake.backend) {
            KeychainStore.prewarm(profile: .development)
            #expect(loaded.wait(timeout: .now() + 5) == .success)
            #expect(fake.readWasOnMainThread == false)
            #expect(KeychainStore.get("gemini") == "g1")
            #expect(fake.readCount == 1, "the warmed cache serves the first get")
            #expect(fake.vaultEntries?["com.vellum.ai/chatgpt-tokens"] == "retired")
            #expect(fake.legacyValue(service: aiService, account: "chatgpt-tokens") == "retired")
            #expect(fake.legacyAccountListCount == 0)
            #expect(fake.legacyReadCount == 0)
            #expect(fake.legacyDeleteCount == 0)
        }
    }

    @Test("Production prewarm removes retired ChatGPT credentials")
    func productionPrewarmPurgesRetiredCredentials() {
        let fake = FakeKeychain()
        fake.seedVault([
            "com.vellum.ai/gemini": "g1",
            "com.vellum.ai/chatgpt-tokens": "retired",
        ])
        fake.seedLegacy(
            service: aiService, account: "chatgpt-tokens", value: "retired")
        let loaded = DispatchSemaphore(value: 0)
        fake.onRead = { loaded.signal() }

        KeychainStore.withBackend(fake.backend) {
            KeychainStore.prewarm(profile: .production)
            #expect(loaded.wait(timeout: .now() + 5) == .success)
            #expect(KeychainStore.get("gemini") == "g1")
            #expect(fake.vaultEntries?["com.vellum.ai/chatgpt-tokens"] == nil)
            #expect(fake.legacyValue(service: aiService, account: "chatgpt-tokens") == nil)
            #expect(fake.legacyReadCount == 1)
            #expect(fake.legacyDeleteCount > 0)
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
    var vaultWriteSucceeds = true
    var vaultDeleteSucceeds = true
    var unavailableLegacyServices: Set<String> = []
    var integrationItems: [String: String] = [:]
    var integrationIsReadable = true
    var integrationWriteSucceeds = true
    var integrationVerificationSucceeds = true
    var integrationVerificationResults: [Bool] = []
    var integrationWriteResults: [Bool] = []
    var makeVaultUnreadableOnIntegrationWrite = false
    var denyLegacyOnIntegrationWrite: String?
    private(set) var integrationWriteCount = 0
    private(set) var maximumLockDepth = 0
    var changeVaultOnIntegrationWrite: [String: String]?
    var preserveVaultDateOnIntegrationWrite = false
    private var awaitingIntegrationVerification = false
    var commitLockIsAvailable = true
    /// service -> account -> item.
    var legacy: [String: [String: StoredItem]] = [:]
    /// Legacy accounts that enumerate but refuse to be read.
    var unreadableLegacyAccounts: Set<String> = []
    /// Signalled from `readVaultItem`, so a background load can be awaited.
    var onRead: (@Sendable () -> Void)?

    private(set) var readCount = 0
    private(set) var probeCount = 0
    private(set) var writeCount = 0
    private(set) var deleteCount = 0
    private(set) var legacyAccountListCount = 0
    private(set) var legacyReadCount = 0
    private(set) var legacyDeleteCount = 0
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

    func seedVault(_ entries: [String: String], at date: Date? = nil) {
        vaultEntries = entries
        vaultModDate = date ?? tick()
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
            probeModDate: { [self] in
                probeCount += 1
                return vaultEntries == nil ? nil : vaultModDate
            },
            writeVault: { [self] entries in
                writeCount += 1
                guard vaultWriteSucceeds else { return false }
                vaultEntries = entries
                vaultModDate = tick()
                return true
            },
            deleteVault: { [self] in
                deleteCount += 1
                guard vaultDeleteSucceeds else { return false }
                vaultEntries = nil
                vaultModDate = nil
                return true
            },
            legacyAccounts: { [self] service in
                legacyAccountListCount += 1
                guard !unavailableLegacyServices.contains(service) else { return .unavailable }
                return .accounts((legacy[service] ?? [:]).keys.sorted())
            },
            legacyRead: { [self] account, service in
                legacyReadCount += 1
                guard !unreadableLegacyAccounts.contains(account) else { return .unavailable }
                guard let item = legacy[service]?[account] else { return .missing }
                return .value(KeychainStore.LegacyItem(value: item.value, modDate: item.modDate))
            },
            legacyDelete: { [self] account, service in
                legacyDeleteCount += 1
                legacy[service]?[account] = nil
            },
            acquireCommitLock: { [self] in
                guard commitLockIsAvailable else { return false }
                lockDepth += 1
                maximumLockDepth = max(maximumLockDepth, lockDepth)
                return true
            },
            releaseCommitLock: { [self] in
                lockDepth -= 1
            },
            readIntegration: { [self] account in
                guard integrationIsReadable else { return .unavailable }
                if awaitingIntegrationVerification {
                    awaitingIntegrationVerification = false
                    let verifies = integrationVerificationResults.isEmpty
                        ? integrationVerificationSucceeds : integrationVerificationResults.removeFirst()
                    if !verifies { return .unavailable }
                }
                return integrationItems[account].map(KeychainStore.CredentialRead.value) ?? .missing
            },
            writeIntegration: { [self] account, value in
                integrationWriteCount += 1
                let succeeds = integrationWriteResults.isEmpty ? integrationWriteSucceeds : integrationWriteResults.removeFirst()
                guard succeeds else { return false }
                integrationItems[account] = value
                if makeVaultUnreadableOnIntegrationWrite {
                    makeVaultUnreadableOnIntegrationWrite = false
                    vaultIsReadable = false
                }
                if let denied = denyLegacyOnIntegrationWrite {
                    denyLegacyOnIntegrationWrite = nil
                    unreadableLegacyAccounts.insert(denied)
                }
                if let changed = changeVaultOnIntegrationWrite {
                    changeVaultOnIntegrationWrite = nil
                    seedVault(changed, at: preserveVaultDateOnIntegrationWrite ? vaultModDate : nil)
                }
                awaitingIntegrationVerification = true
                return true
            },
            deleteIntegration: { [self] account in
                integrationItems[account] = nil
                return true
            })
    }
}
