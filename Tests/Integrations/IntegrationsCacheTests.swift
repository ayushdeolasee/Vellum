import Foundation
import Testing
@testable import Vellum

struct IntegrationsCacheTests {
    @Test func missingAndValidSnapshotStates() async throws {
        let root = try IntegrationTemporaryRoot.make()
        defer { try? FileManager.default.removeItem(at: root) }
        let cache = IntegrationsCache(root: root)
        if case .missing = await cache.load(provider: .readwise) {} else { Issue.record("Expected missing cache") }
        let snapshot = ProviderSnapshot.empty(provider: .readwise, fingerprint: "account", generation: 2)
        try await cache.save(snapshot)
        guard case .snapshot(let loaded) = await cache.load(provider: .readwise) else { Issue.record("Expected snapshot"); return }
        #expect(loaded == snapshot)
    }

    @Test func corruptPrimaryRecoversFromLastAtomicBackup() async throws {
        let root = try IntegrationTemporaryRoot.make()
        defer { try? FileManager.default.removeItem(at: root) }
        let cache = IntegrationsCache(root: root)
        var first = ProviderSnapshot.empty(provider: .readwise, fingerprint: "account", generation: 2)
        first.skippedRecordCount = 1
        var second = first
        second.skippedRecordCount = 2
        try await cache.save(first)
        try await cache.save(second)

        let primaryURL = root.appendingPathComponent("readwise/snapshot.json")
        try Data("truncated".utf8).write(to: primaryURL)

        guard case .snapshot(let recovered) = await cache.load(provider: .readwise) else {
            Issue.record("Expected the backup snapshot to recover the corrupt primary")
            return
        }
        #expect(recovered == first)

        guard case .snapshot(let restoredPrimary) = await cache.load(provider: .readwise) else {
            Issue.record("Expected recovery to atomically restore the primary")
            return
        }
        #expect(restoredPrimary == first)
    }

    @Test func snapshotFromAnotherSchemaVersionReSyncsInsteadOfReportingDamage() async throws {
        let root = try IntegrationTemporaryRoot.make()
        defer { try? FileManager.default.removeItem(at: root) }
        let cache = IntegrationsCache(root: root)
        try await cache.save(.empty(provider: .readwise, fingerprint: "account", generation: 2))

        let primaryURL = root.appendingPathComponent("readwise/snapshot.json")
        var envelope = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: primaryURL)) as? [String: Any])
        envelope["version"] = IntegrationsCache.SnapshotEnvelope.currentVersion + 1
        try JSONSerialization.data(withJSONObject: envelope).write(to: primaryURL, options: .atomic)

        if case .missing = await cache.load(provider: .readwise) {} else {
            Issue.record("Expected a snapshot from another schema version to load as missing, not damaged")
        }
    }

    @Test func undecodableSnapshotWithoutABackupIsStillCorrupt() async throws {
        let root = try IntegrationTemporaryRoot.make()
        defer { try? FileManager.default.removeItem(at: root) }
        let cache = IntegrationsCache(root: root)
        try await cache.save(.empty(provider: .readwise, fingerprint: "account", generation: 2))
        try Data("truncated".utf8).write(to: root.appendingPathComponent("readwise/snapshot.json"))

        if case .corrupt = await cache.load(provider: .readwise) {} else {
            Issue.record("Expected unreadable bytes with no backup to report damage")
        }
    }

    @Test func staleDisconnectStagingAndPartFilesAreSweptWhileInFlightWorkSurvives() async throws {
        let root = try IntegrationTemporaryRoot.make()
        defer { try? FileManager.default.removeItem(at: root) }
        let cache = IntegrationsCache(root: root)
        try await cache.save(.empty(provider: .readwise, fingerprint: "account", generation: 1))
        let staging = try await cache.stageDisconnect(provider: .readwise, deleteDownloads: false)
        let partFile = try await cache.temporaryDownloadURL(provider: .readwise, itemID: "item")
        try Data("partial".utf8).write(to: partFile)

        await cache.sweepStaleArtifacts(now: Date())

        #expect(FileManager.default.fileExists(atPath: staging.directory.path))
        #expect(FileManager.default.fileExists(atPath: partFile.path))

        await cache.sweepStaleArtifacts(now: Date().addingTimeInterval(7200))

        #expect(FileManager.default.fileExists(atPath: staging.directory.path) == false)
        #expect(FileManager.default.fileExists(atPath: partFile.path) == false)
    }

    @Test func installReplacesAStaleCopyButRejectsARepeatOfTheSameRevision() async throws {
        let root = try IntegrationTemporaryRoot.make()
        defer { try? FileManager.default.removeItem(at: root) }
        let cache = IntegrationsCache(root: root)
        let first = try await cache.temporaryDownloadURL(provider: .raindrop, itemID: "item")
        try Data("%PDF-first".utf8).write(to: first)
        let installed = try await cache.installDownload(temporaryURL: first, manifest: .init(provider: .raindrop, itemID: "item", revision: "r1"))

        #expect(try await cache.currentDownload(provider: .raindrop, itemID: "item", revision: "r1") == installed)
        #expect(try await cache.currentDownload(provider: .raindrop, itemID: "item", revision: "r2") == nil)

        let duplicate = try await cache.temporaryDownloadURL(provider: .raindrop, itemID: "item")
        try Data("%PDF-duplicate".utf8).write(to: duplicate)
        await #expect(throws: IntegrationError.existingDownload) {
            try await cache.installDownload(temporaryURL: duplicate, manifest: .init(provider: .raindrop, itemID: "item", revision: "r1"))
        }

        let refreshed = try await cache.temporaryDownloadURL(provider: .raindrop, itemID: "item")
        try Data("%PDF-second".utf8).write(to: refreshed)
        let replaced = try await cache.installDownload(temporaryURL: refreshed, manifest: .init(provider: .raindrop, itemID: "item", revision: "r2"))

        #expect(replaced == installed)
        #expect(String(decoding: try Data(contentsOf: replaced), as: UTF8.self) == "%PDF-second")
        #expect(try await cache.currentDownload(provider: .raindrop, itemID: "item", revision: "r1") == nil)
    }

    @Test func failedManifestWriteRollsBackMovedPDF() async throws {
        let root = try IntegrationTemporaryRoot.make()
        defer { try? FileManager.default.removeItem(at: root) }
        let cache = IntegrationsCache(root: root)
        let temporaryURL = try await cache.temporaryDownloadURL(provider: .raindrop, itemID: "item")
        try Data("%PDF-test".utf8).write(to: temporaryURL)
        let manifestURL = try await cache.manifestURL(provider: .raindrop, itemID: "item")
        try FileManager.default.createDirectory(at: manifestURL, withIntermediateDirectories: true)
        let manifest = IntegrationsCache.DownloadManifest(provider: .raindrop, itemID: "item", revision: "revision")

        do {
            _ = try await cache.installDownload(temporaryURL: temporaryURL, manifest: manifest)
            Issue.record("Expected a manifest write failure")
        } catch {
            // The manifest path is deliberately a directory; any write error is expected.
        }

        let existingDownload = try await cache.currentDownload(provider: .raindrop, itemID: "item", revision: "revision")
        #expect(existingDownload == nil)
        #expect(FileManager.default.fileExists(atPath: temporaryURL.path) == false)
    }

    @Test func downloadNamesAreHashDerived() {
        let key = IntegrationsCache.downloadKey(provider: .raindrop, itemID: "../../escape")
        #expect(key.count == 64)
        #expect(key.contains("/") == false)
        #expect(key.contains("..") == false)
    }
}
