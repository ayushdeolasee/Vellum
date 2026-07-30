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

    @Test func failedManifestWriteRollsBackMovedPDF() async throws {
        let root = try IntegrationTemporaryRoot.make()
        defer { try? FileManager.default.removeItem(at: root) }
        let cache = IntegrationsCache(root: root)
        let temporaryURL = try await cache.temporaryDownloadURL(provider: .raindrop, itemID: "item")
        try Data("%PDF-test".utf8).write(to: temporaryURL)
        let manifestURL = try await cache.manifestURL(provider: .raindrop, itemID: "item")
        try FileManager.default.createDirectory(at: manifestURL, withIntermediateDirectories: true)
        let manifest = IntegrationsCache.DownloadManifest(
            provider: .raindrop,
            itemID: "item",
            revision: "revision",
            etag: nil,
            installedAt: Date(timeIntervalSince1970: 10)
        )

        do {
            _ = try await cache.installDownload(temporaryURL: temporaryURL, manifest: manifest)
            Issue.record("Expected a manifest write failure")
        } catch {
            // The manifest path is deliberately a directory; any write error is expected.
        }

        let existingDownload = try await cache.existingDownload(provider: .raindrop, itemID: "item")
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
