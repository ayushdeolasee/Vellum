import Foundation
import Testing
@testable import Vellum

struct ReadLaterModelsTests {
    @Test func providerScopeIsExactlyReadwiseAndRaindrop() {
        #expect(IntegrationProvider.allCases == [.readwise, .raindrop])
    }

    @Test func itemMappingNormalizesUserVisibleFields() throws {
        let item = try #require(ReadLaterItem(
            provider: .raindrop,
            vendorID: " 42 ",
            sourceURL: URL(string: "https://example.com/article"),
            title: "  ",
            author: " Ada ",
            excerpt: " Notes ",
            tags: ["swift", " swift ", "", "research"],
            collectionIDs: ["b", "a", "b"],
            savedAt: nil,
            updatedAt: nil
        ))

        #expect(item.vendorID == "42")
        #expect(item.title == "example.com")
        #expect(item.author == "Ada")
        #expect(item.excerpt == "Notes")
        #expect(item.tags == ["research", "swift"])
        #expect(item.collectionIDs == ["a", "b"])
    }

    @Test func invalidSourceSchemesAreRejected() {
        let item = ReadLaterItem(
            provider: .readwise,
            vendorID: "1",
            sourceURL: URL(string: "file:///tmp/private.pdf"),
            title: "Private",
            savedAt: nil,
            updatedAt: nil
        )
        #expect(item == nil)
    }

    @Test func snapshotNeverPersistsReadwiseSignedURL() async throws {
        let item = try #require(ReadLaterItem(provider: .readwise, vendorID: "1", sourceURL: URL(string: "https://example.com/article"), title: "Article", kind: .pdf, savedAt: nil, updatedAt: nil, pdfRetrieval: .readwiseItem(id: "1")))
        let snapshot = ProviderSnapshot(provider: .readwise, accountFingerprint: "f", connectionGeneration: 1, items: [item], collections: [], committedBoundary: nil, tentativePagination: nil, lastSuccessfulSync: nil, lastFullSweep: nil, skippedRecordCount: 0)
        let encoded = String(decoding: try JSONEncoder.integrations.encode(snapshot), as: UTF8.self)
        #expect(encoded.contains("raw_source_url") == false)
        #expect(encoded.contains("signed") == false)

        // Asserted against the bytes the cache actually writes too, so swapping
        // the snapshot encoder can never quietly start persisting a signed URL.
        let root = try IntegrationTemporaryRoot.make()
        defer { try? FileManager.default.removeItem(at: root) }
        try await IntegrationsCache(root: root).save(snapshot)
        let persisted = String(decoding: try Data(contentsOf: root.appendingPathComponent("readwise/snapshot.json")), as: UTF8.self)
        #expect(persisted.contains("raw_source_url") == false)
        #expect(persisted.contains("signed") == false)
    }

    @Test func tentativeWalkStateRoundTripsThroughTheSnapshot() async throws {
        let item = try makeIntegrationItem(provider: .raindrop, id: "1", updatedAt: Date(timeIntervalSince1970: 1_700_000_000))
        let walk = TentativePagination(
            walkOwnerID: UUID(),
            startedAt: Date(timeIntervalSince1970: 1_700_000_500),
            connectionGeneration: 3,
            accountFingerprint: "f",
            query: IntegrationQueryDescriptor(provider: .raindrop, pageSize: 50, sort: "-created", updatedAfter: nil),
            startingBoundary: nil,
            mode: .full,
            cursor: "2",
            fetchedItems: [item],
            seenIDs: [item.id],
            skippedRecordCount: 1,
            mergeOnly: true
        )
        var snapshot = ProviderSnapshot.empty(provider: .raindrop, fingerprint: "f", generation: 3)
        snapshot.tentativePagination = walk
        let root = try IntegrationTemporaryRoot.make()
        defer { try? FileManager.default.removeItem(at: root) }
        let cache = IntegrationsCache(root: root)
        try await cache.save(snapshot)

        guard case .snapshot(let loaded) = await cache.load(provider: .raindrop) else {
            Issue.record("Expected the saved snapshot back")
            return
        }
        #expect(loaded.tentativePagination == walk)
    }
}
