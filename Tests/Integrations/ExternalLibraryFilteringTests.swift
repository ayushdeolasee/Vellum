import Foundation
import Testing
@testable import Vellum

struct ExternalLibraryFilteringTests {
    @Test func raindropDefaultFolderPreferenceRoundTripsAndClears() throws {
        let suiteName = "Vellum.ExternalLibraryFilteringTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let preferences = IntegrationPreferences(defaults: defaults)

        preferences.defaultRaindropCollectionID = "raindrop:collection:10"
        #expect(preferences.defaultRaindropCollectionID == "raindrop:collection:10")

        preferences.defaultRaindropCollectionID = nil
        #expect(preferences.defaultRaindropCollectionID == nil)
    }

    @Test func removedCollectionClearsTheStaleSelection() {
        #expect(ExternalLibraryFilter.reconciledCollectionID("raindrop:collection:old", availableIDs: ["raindrop:collection:new"]) == nil)
        #expect(ExternalLibraryFilter.reconciledCollectionID("raindrop:collection:new", availableIDs: ["raindrop:collection:new"]) == "raindrop:collection:new")
    }

    @Test func normalizedFieldsSupportPaneLocalSearchAndCollectionFilters() throws {
        let item = try #require(ReadLaterItem(provider: .raindrop, vendorID: "1", sourceURL: URL(string: "https://example.com"), title: "Swift Concurrency", author: "Ada", kind: .article, tags: ["actors"], collectionIDs: ["raindrop:collection:10"], savedAt: nil, updatedAt: nil))
        #expect(item.title.localizedCaseInsensitiveContains("swift"))
        #expect(item.tags.contains("actors"))
        #expect(item.collectionIDs.contains("raindrop:collection:10"))
    }
}
