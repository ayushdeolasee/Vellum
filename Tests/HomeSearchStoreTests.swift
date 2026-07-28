import Foundation
import Testing

@testable import Vellum

// The main-actor half of the home screen's search: keyboard selection, the
// query/filter reset, and which "forget this" actions a row offers.
//
// `HomeSearchStore` is constructed with an engine holding NO providers, so
// nothing here reads the real recents list, web store, or documents directory.
// Everything under test is synchronous state manipulation; the debounced
// `refresh()` path belongs to `HomeSearchEngineTests`, which can drive it
// without a main-actor hop.

private func item(
    id: String,
    section: HomeSearchSection,
    kind: DocumentKind = .web,
    title: String = "Row",
    badges: HomeSearchBadges = []
) -> HomeSearchItem {
    let locator = kind == .web ? "https://x.test/\(id)" : "/docs/\(id).pdf"
    return HomeSearchItem(
        id: id,
        identity: locator,
        section: section,
        kind: kind,
        target: kind == .web ? .url(locator) : .file(path: locator, recordedPath: locator),
        title: title,
        subtitle: locator,
        detail: "",
        tooltip: locator,
        date: nil,
        badges: badges,
        canRevealInFinder: false,
        haystack: HomeSearchHaystack(title: title, name: locator, location: locator))
}

@MainActor
private func store() -> HomeSearchStore {
    HomeSearchStore(engine: HomeSearchEngine(providers: []))
}

@MainActor
@Suite("Home search store removal")
struct HomeSearchStoreRemovalTests {
    /// Dedupe merges a bookmarked article that is also a recent into a single
    /// Recents row. Offering only the action implied by the section would make
    /// un-saving it impossible from this screen — the row is on two shelves and
    /// can be taken off either.
    @Test("A row on both shelves offers both ways to forget it")
    func offersBothRemovals() {
        let both = item(id: "a", section: .recents, badges: [.saved, .offline])
        #expect(store().removalOptions(for: both) == [.recent, .saved])
    }

    @Test("A plain recent offers only Remove from Recent")
    func recentOnly() {
        let plain = item(id: "a", section: .recents, kind: .pdf)
        #expect(store().removalOptions(for: plain) == [.recent])
    }

    @Test("A saved page that was never opened offers only Remove from Saved")
    func savedOnly() {
        let saved = item(id: "a", section: .webpages, badges: [.saved])
        #expect(store().removalOptions(for: saved) == [.saved])
    }

    /// A web document that carries notes but was never bookmarked is NOT
    /// removable as "saved" — offering it would call `WebLibrary.removeSaved`
    /// on a page that is not in the web library, which silently does nothing
    /// and leaves the row on screen looking like a broken button.
    @Test("An annotated but unsaved page offers nothing to remove")
    func annotatedPageIsNotRemovable() {
        let annotated = item(id: "a", section: .webpages, badges: [.notes])
        #expect(store().removalOptions(for: annotated).isEmpty)
    }

    @Test("Library documents are not removable from the home screen")
    func libraryDocumentsAreNotRemovable() {
        let document = item(id: "a", section: .documents, kind: .pdf, badges: [.notes])
        #expect(store().removalOptions(for: document).isEmpty)
    }

    /// Someone who has narrowed to Saved and reaches for a destructive action
    /// means "un-save", whatever else the row happens to be — so that action
    /// leads. Everywhere else recency is the facet this screen is about.
    @Test("The active filter decides which removal leads the menu")
    func filterOrdersTheMenu() {
        let both = item(id: "a", section: .recents, badges: [.saved])
        let subject = store()

        subject.filter = .all
        #expect(subject.removalOptions(for: both) == [.recent, .saved])

        subject.filter = .saved
        #expect(subject.removalOptions(for: both) == [.saved, .recent])

        // Narrowing to Saved must not INVENT an option — a row with only one
        // applicable action still has exactly that one.
        let recentOnly = item(id: "b", section: .recents, kind: .pdf)
        #expect(subject.removalOptions(for: recentOnly) == [.recent])
    }
}

@MainActor
@Suite("Home search store selection")
struct HomeSearchStoreSelectionTests {
    @Test("Escape clears a query, and reports when there was nothing to clear")
    func clearQuery() {
        let subject = store()
        #expect(subject.clearQuery() == false)

        subject.query = "attention"
        subject.selectedId = "a"
        #expect(subject.clearQuery())
        #expect(subject.query.isEmpty)
        #expect(subject.selectedId == nil)
    }

    /// A query that matches nothing and a filter that excludes everything
    /// produce the identical blank screen, so the no-results button lifts both
    /// at once rather than making the user guess which one is to blame.
    @Test("Reset lifts the query and the filter together")
    func resetSearch() {
        let subject = store()
        subject.query = "attention"
        subject.filter = .documents
        subject.selectedId = "a"

        subject.resetSearch()

        #expect(subject.query.isEmpty)
        #expect(subject.filter == .all)
        #expect(subject.selectedId == nil)
        #expect(!subject.isSearching)
    }

    /// Arrow keys clamp rather than wrap: in a relevance-ordered list, wrapping
    /// off the top lands you on the WORST match, which is never what the user
    /// pressing up was reaching for.
    @Test("Arrow navigation clamps at both ends")
    func moveSelectionClamps() {
        let subject = store()
        subject.query = "https://example.com/new"
        // The pasted link contributes the one navigable row without needing a
        // loaded corpus, which is what makes this testable off-disk.
        #expect(subject.navigationOrder == [HomeSearchStore.linkRowId])

        subject.moveSelection(1)
        #expect(subject.selectedId == HomeSearchStore.linkRowId)
        subject.moveSelection(1)
        #expect(subject.selectedId == HomeSearchStore.linkRowId)
        subject.moveSelection(-1)
        #expect(subject.selectedId == HomeSearchStore.linkRowId)
    }

    @Test("Moving with nothing to move through is a no-op, not a crash")
    func moveSelectionOnEmptyList() {
        let subject = store()
        subject.moveSelection(1)
        #expect(subject.selectedId == nil)
        subject.moveSelection(-1)
        #expect(subject.selectedId == nil)
    }

    /// The pinned "open this webpage" row is a row the user can arrow onto and
    /// press return on, so it has to be counted like one — a pasted link that
    /// matches nothing in the library still offers exactly one thing to do.
    @Test("A pasted link counts as a result")
    func linkCountsAsAResult() {
        let subject = store()
        #expect(subject.resultCount == 0)

        subject.query = "https://example.com/article"
        #expect(subject.linkSuggestion == "https://example.com/article")
        #expect(subject.resultCount == 1)

        subject.query = "attention is all you need"
        #expect(subject.linkSuggestion == nil)
        #expect(subject.resultCount == 0)
    }
}
