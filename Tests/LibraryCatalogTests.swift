import Foundation
import Testing
@testable import Vellum

struct LibraryCatalogTests {
    private let recent = [
        RecentDocument(
            pdfPath: "/Users/reader/Papers/Attention Is All You Need.pdf",
            kind: .pdf,
            title: "Transformers",
            pageCount: 15,
            openedAt: "2026-07-27T10:00:00.000Z"
        ),
        RecentDocument(
            pdfPath: "https://example.com/research/reading-list",
            kind: .web,
            title: "A Useful Reading List",
            pageCount: nil,
            openedAt: "2026-07-26T10:00:00.000Z"
        )
    ]

    private let saved = [
        WebLibraryEntry(
            url: "https://example.com/research/reading-list",
            title: "Saved Reading List",
            pageCount: nil,
            savedAt: "2026-07-25T10:00:00.000Z",
            hasSnapshot: true
        ),
        WebLibraryEntry(
            url: "https://swift.org/blog/swift-6/",
            title: "Swift 6",
            pageCount: nil,
            savedAt: "2026-07-24T10:00:00.000Z",
            hasSnapshot: false
        )
    ]

    @Test("Recent and saved copies of a webpage become one library row", .bug(id: 62))
    func deduplicatesRecentAndSavedWebpages() throws {
        let items = LibraryCatalog.items(
            recent: recent,
            saved: saved,
            query: "",
            filter: .all,
            sort: .recent
        )

        #expect(items.count == 3)
        let readingList = try #require(items.first { $0.key.contains("reading-list") })
        #expect(readingList.isSaved)
        #expect(readingList.isOffline)
        #expect(readingList.recordedRecentKey != nil)
        #expect(readingList.savedKey != nil)
    }

    @Test(
        "Search checks titles, filenames, domains, and URLs",
        arguments: ["transformers", "attention", "example.com", "research/reading-list"]
    )
    func searchesAllVisibleMetadata(query: String) {
        let items = LibraryCatalog.items(
            recent: recent,
            saved: saved,
            query: query,
            filter: .all,
            sort: .recent
        )

        #expect(items.count == 1)
    }

    @Test("Search is case and diacritic insensitive")
    func normalizedSearch() {
        let accented = [
            RecentDocument(
                pdfPath: "/tmp/cafe.pdf",
                kind: .pdf,
                title: "Café Notes",
                pageCount: nil,
                openedAt: "2026-07-27T10:00:00.000Z"
            )
        ]

        let items = LibraryCatalog.items(
            recent: accented,
            saved: [],
            query: "CAFE",
            filter: .all,
            sort: .recent
        )

        #expect(items.map(\.title) == ["Café Notes"])
    }

    @Test(
        "Type and saved filters use the unified rows",
        arguments: [
            (LibraryFilter.pdf, 1),
            (LibraryFilter.web, 2),
            (LibraryFilter.saved, 2)
        ]
    )
    func filtersLibrary(filter: LibraryFilter, expectedCount: Int) {
        let items = LibraryCatalog.items(
            recent: recent,
            saved: saved,
            query: "",
            filter: filter,
            sort: .recent
        )

        #expect(items.count == expectedCount)
    }

    @Test("A query with no matches returns a clear empty result")
    func noResults() {
        let items = LibraryCatalog.items(
            recent: recent,
            saved: saved,
            query: "nothing in this library",
            filter: .all,
            sort: .recent
        )

        #expect(items.isEmpty)
    }

    @Test("Name sort is independent of recency")
    func sortsByName() {
        let items = LibraryCatalog.items(
            recent: recent,
            saved: saved,
            query: "",
            filter: .all,
            sort: .name
        )

        #expect(items.map(\.title) == [
            "A Useful Reading List",
            "Swift 6",
            "Transformers"
        ])
    }

    @Test("Rows for two paths of the same stamped PDF retain unique identities")
    func movedPdfRowsHaveUniqueIDs() {
        let moved = [
            RecentDocument(
                pdfPath: "/old/paper.pdf",
                kind: .pdf,
                title: "Paper",
                pageCount: 1,
                openedAt: "2026-07-26T10:00:00.000Z",
                docId: "stable-document-id"
            ),
            RecentDocument(
                pdfPath: "/new/paper.pdf",
                kind: .pdf,
                title: "Paper",
                pageCount: 1,
                openedAt: "2026-07-27T10:00:00.000Z",
                docId: "stable-document-id"
            )
        ]

        let items = LibraryCatalog.items(
            recent: moved,
            saved: [],
            query: "",
            filter: .all,
            sort: .recent
        )

        #expect(items.count == 2)
        #expect(Set(items.map(\.id)).count == 2)
    }

    @Test("Delete respects the facet the user is filtering")
    func removalTargetMatchesFilter() throws {
        let merged = try #require(LibraryCatalog.items(
            recent: recent,
            saved: saved,
            query: "",
            filter: .all,
            sort: .recent
        ).first { $0.savedKey != nil && $0.recordedRecentKey != nil })

        #expect(LibraryCatalog.removalTarget(for: merged, activeFilter: .all) == .recent)
        #expect(LibraryCatalog.removalTarget(for: merged, activeFilter: .saved) == .saved)
    }
}
