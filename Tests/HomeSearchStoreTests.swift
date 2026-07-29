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

// MARK: - Destructive-removal guards (issue #103)

/// Redirects the recents list at a throwaway `UserDefaults` domain for the life
/// of one suite instance. Swift Testing has no `tearDown`, so the restore rides
/// on `deinit` — same shape as `ScratchRecents` in `InspectorPresentationTests`.
private final class ScratchRecents {
    private let defaults: UserDefaults
    private let suiteName: String

    init() {
        suiteName = "vellum.home-removal.tests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)!
        RecentFilesService.defaultsOverride = defaults
    }

    deinit {
        RecentFilesService.defaultsOverride = nil
        defaults.removePersistentDomain(forName: suiteName)
    }
}

/// Issue #103: both home-screen removals used to fire on a single click of a
/// context-menu item, with no confirmation and no undo. They are not equally
/// recoverable, so they no longer carry the same guard — un-saving deletes the
/// offline snapshot from disk and asks first; dropping a recent edits a list
/// and is undoable. These pin which is which, and that the undoable one really
/// round-trips.
///
/// `.serialized` because `RecentFilesService.defaultsOverride` is process-wide
/// mutable state.
@MainActor
@Suite("Home removal guards", .serialized)
struct HomeRemovalGuardTests {
    private let recents = ScratchRecents()

    /// Seeds newest-last so the resulting list reads in the given order.
    private func seed(_ paths: [String]) {
        for path in paths.reversed() {
            RecentFilesService.record(
                DocumentInfo(kind: .pdf, pdfPath: path, title: nil, pageCount: 1))
        }
    }

    @Test("Only the irreversible removal stops to ask")
    func onlySavedIsGated() {
        #expect(HomeSearchRemoval.saved.requiresConfirmation)
        #expect(!HomeSearchRemoval.recent.requiresConfirmation)
    }

    /// The dialog names the row, so a right-click that landed one row off is
    /// caught before the snapshot is deleted rather than after.
    @Test("The confirmation names the page and says what survives")
    func confirmationCopy() {
        let title = HomeSearchRemoval.saved.confirmationTitle(for: "Attention Is All You Need")
        #expect(title.contains("Attention Is All You Need"))
        #expect(title.contains("Saved"))

        let message = HomeSearchRemoval.saved.confirmationMessage
        #expect(message?.contains("offline copy") == true)
        #expect(message?.contains("Highlights and notes are kept") == true)
        #expect(HomeSearchRemoval.recent.confirmationMessage == nil,
                "an undoable action gets no dialog, so it has no dialog copy")
    }

    @Test("Removing a recent hands back everything Undo needs")
    func removalYieldsATransaction() async throws {
        seed(["/docs/a.pdf", "/docs/b.pdf", "/docs/c.pdf"])
        let subject = store()

        let transaction = try #require(
            await subject.remove(item(id: "b", section: .recents, kind: .pdf), from: .recent))

        #expect(transaction.index == 1)
        #expect(transaction.entry.pdfPath == "/docs/b.pdf")
        #expect(RecentFilesService.getRecent().map(\.pdfPath) == ["/docs/a.pdf", "/docs/c.pdf"])
    }

    /// The whole point of the transaction: the row comes back where it was,
    /// with the timestamp it had. Re-recording it instead would jump it to the
    /// top and claim it had just been opened.
    @Test("Undo puts the row back at its original position and time")
    func undoRoundTrips() async throws {
        seed(["/docs/a.pdf", "/docs/b.pdf", "/docs/c.pdf"])
        let originalOpenedAt = try #require(
            RecentFilesService.getRecent().first { $0.pdfPath == "/docs/b.pdf" }?.openedAt)
        let subject = store()
        let transaction = try #require(
            await subject.remove(item(id: "b", section: .recents, kind: .pdf), from: .recent))

        #expect(subject.undoRecentRemoval(transaction))
        #expect(RecentFilesService.getRecent().map(\.pdfPath)
            == ["/docs/a.pdf", "/docs/b.pdf", "/docs/c.pdf"])
        #expect(RecentFilesService.getRecent()[1].openedAt == originalOpenedAt)

        #expect(subject.redoRecentRemoval(transaction))
        #expect(RecentFilesService.getRecent().map(\.pdfPath) == ["/docs/a.pdf", "/docs/c.pdf"])
    }

    /// An Undo that has been overtaken must not duplicate the row. Re-opening
    /// the document puts it back at the top on its own; ⌘Z afterwards has
    /// nothing left to restore and ends the chain.
    @Test("Undo is a no-op once the document has been re-opened")
    func undoAfterReopenDoesNothing() async throws {
        seed(["/docs/a.pdf", "/docs/b.pdf"])
        let subject = store()
        let transaction = try #require(
            await subject.remove(item(id: "b", section: .recents, kind: .pdf), from: .recent))

        RecentFilesService.record(
            DocumentInfo(kind: .pdf, pdfPath: "/docs/b.pdf", title: nil, pageCount: 1))

        #expect(!subject.undoRecentRemoval(transaction))
        #expect(RecentFilesService.getRecent().map(\.pdfPath) == ["/docs/b.pdf", "/docs/a.pdf"],
                "the re-opened row stays exactly once, at the top where re-opening put it")
    }

    /// Removing a row that is not in the recents list at all still succeeds —
    /// it just has nothing to offer Undo, which is what stops the caller from
    /// registering a ⌘Z that would do nothing.
    @Test("A recent that was already gone offers no Undo")
    func missingRecentOffersNoUndo() async {
        seed(["/docs/a.pdf"])
        let subject = store()

        let transaction = await subject.remove(
            item(id: "zzz", section: .recents, kind: .pdf), from: .recent)

        #expect(transaction == nil)
        #expect(RecentFilesService.getRecent().map(\.pdfPath) == ["/docs/a.pdf"])
    }
}
