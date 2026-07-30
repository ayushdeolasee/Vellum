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

    @Test func snapshotNeverPersistsReadwiseSignedURL() throws {
        let item = try #require(ReadLaterItem(provider: .readwise, vendorID: "1", sourceURL: URL(string: "https://example.com/article"), title: "Article", kind: .pdf, savedAt: nil, updatedAt: nil, pdfRetrieval: .readwiseItem(id: "1")))
        let snapshot = ProviderSnapshot(provider: .readwise, accountFingerprint: "f", connectionGeneration: 1, items: [item], collections: [], committedBoundary: nil, tentativePagination: nil, lastSuccessfulSync: nil, lastFullSweep: nil, skippedRecordCount: 0)
        let encoded = String(decoding: try JSONEncoder.integrations.encode(snapshot), as: UTF8.self)
        #expect(encoded.contains("raw_source_url") == false)
        #expect(encoded.contains("signed") == false)
    }
}
