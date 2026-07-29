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

/// Gives every test its own throwaway recents domain, installed and removed
/// around the test body rather than on `deinit`. Deterministic teardown matters
/// here: `RecentFilesService.defaultsOverride` is process-global, and a
/// `deinit` that runs late can strip the override out from under a test that is
/// still writing — which would send `record`/`restore` at the developer's real
/// recents list, exactly what the seam exists to prevent.
private struct ScratchRecentsScope: SuiteTrait, TestTrait, TestScoping {
    var isRecursive: Bool { true }

    func scopeProvider(for test: Test, testCase: Test.Case?) -> Self? { self }

    func provideScope(
        for test: Test, testCase: Test.Case?, performing function: () async throws -> Void
    ) async throws {
        let suiteName = "vellum.home-removal.tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        // Restore the PREVIOUS override, not nil: suites run concurrently, and
        // unconditionally clearing would drop whichever other suite is midway
        // through its own writes into `UserDefaults.standard` — which, in a
        // hosted test bundle, is the developer's real recents list.
        let previous = RecentFilesService.defaultsOverride
        RecentFilesService.defaultsOverride = defaults
        defer {
            RecentFilesService.defaultsOverride = previous
            defaults.removePersistentDomain(forName: suiteName)
        }
        try await function()
    }
}

/// Issue #103: both home-screen removals used to fire on a single click of a
/// context-menu item, with no confirmation and no undo. They are not equally
/// recoverable, so they no longer carry the same guard — un-saving deletes the
/// offline snapshot from disk and asks first; dropping a recent edits a list
/// and is undoable.
@MainActor
@Suite("Home removal guards", .serialized, ScratchRecentsScope())
struct HomeRemovalGuardTests {
    /// Seeds newest-first with well-separated timestamps.
    ///
    /// Goes through `restore` rather than `record` because it is the only API
    /// that preserves a given `openedAt`: `record` stamps `Date()`, and several
    /// calls in a tight loop land in the same millisecond, which would leave
    /// every ordering assertion below decided by a coin flip.
    private func seed(_ paths: [String]) {
        for (offset, path) in paths.enumerated() {
            RecentFilesService.restore(entry(path, minutesAgo: offset))
        }
    }

    private func entry(_ path: String, minutesAgo: Int) -> RecentDocument {
        RecentDocument(
            pdfPath: path, kind: .pdf, title: nil, pageCount: 1,
            openedAt: ISO8601DateFormatter.recentTimestamp.string(
                from: Date().addingTimeInterval(-60 * Double(minutesAgo))),
            docId: nil)
    }

    private func recentPaths() -> [String] { RecentFilesService.getRecent().map(\.pdfPath) }

    private func row(_ id: String) -> HomeSearchItem {
        item(id: id, section: .recents, kind: .pdf)
    }

    /// The one-line contract the whole change rests on, plus the only signal the
    /// user gets that two adjacent menu items behave differently.
    @Test("Only the irreversible removal is gated, and its label says so")
    func onlySavedIsGated() {
        #expect(HomeSearchRemoval.saved.requiresConfirmation)
        #expect(HomeSearchRemoval.saved.menuLabel.hasSuffix("…"))
        #expect(!HomeSearchRemoval.recent.requiresConfirmation)
        #expect(!HomeSearchRemoval.recent.menuLabel.hasSuffix("…"))
        #expect(
            HomeSearchRemoval.saved.confirmLabel == HomeSearchRemoval.saved.label,
            "the ellipsis belongs to the menu item that opens the dialog, not to its button")
    }

    @Test("Removing a recent hands back everything Undo needs")
    func removalYieldsATransaction() throws {
        seed(["/docs/a.pdf", "/docs/b.pdf", "/docs/c.pdf"])
        let subject = store()

        let transaction = try #require(subject.removeFromRecent(row("b")))

        #expect(transaction.entry.pdfPath == "/docs/b.pdf")
        #expect(recentPaths() == ["/docs/a.pdf", "/docs/c.pdf"])
    }

    /// The point of the transaction: the row comes back with the timestamp it
    /// had. Re-recording it instead would jump it to the top and claim it had
    /// just been opened.
    @Test("Undo puts the row back in place with its original timestamp")
    func undoRoundTrips() throws {
        seed(["/docs/a.pdf", "/docs/b.pdf", "/docs/c.pdf"])
        let originalOpenedAt = try #require(
            RecentFilesService.getRecent().first { $0.pdfPath == "/docs/b.pdf" }?.openedAt)
        let subject = store()
        let transaction = try #require(subject.removeFromRecent(row("b")))

        #expect(subject.undoRecentRemoval(transaction))
        #expect(recentPaths() == ["/docs/a.pdf", "/docs/b.pdf", "/docs/c.pdf"])
        #expect(RecentFilesService.getRecent()[1].openedAt == originalOpenedAt)

        #expect(subject.redoRecentRemoval(transaction))
        #expect(recentPaths() == ["/docs/a.pdf", "/docs/c.pdf"])
    }

    /// `record` always prepends with `Date()`, so the list is always sorted
    /// newest-first. Reinserting at the index the row was removed from breaks
    /// that as soon as anything is opened in between — and `prefix(maxRecent)`
    /// evicts by position, so an unsorted list can drop a NEWER entry than the
    /// ones it keeps.
    @Test("Undo reinserts by timestamp, not at the old index")
    func undoReinsertsByTimestamp() throws {
        seed(["/docs/a.pdf", "/docs/b.pdf", "/docs/c.pdf"])
        let subject = store()
        let transaction = try #require(subject.removeFromRecent(row("c")))

        // The user opens something else before pressing ⌘Z.
        RecentFilesService.record(
            DocumentInfo(kind: .pdf, pdfPath: "/docs/x.pdf", title: nil, pageCount: 1))

        #expect(subject.undoRecentRemoval(transaction))
        #expect(
            recentPaths() == ["/docs/x.pdf", "/docs/a.pdf", "/docs/b.pdf", "/docs/c.pdf"],
            "c is the oldest, so it belongs last — an index-based restore would put it above b")
    }

    /// An Undo that has been overtaken must not duplicate the row. Re-opening
    /// the document puts it back on its own; ⌘Z afterwards has nothing left to
    /// restore and ends the chain.
    @Test("Undo is a no-op once the document has been re-opened")
    func undoAfterReopenDoesNothing() throws {
        seed(["/docs/a.pdf", "/docs/b.pdf"])
        let subject = store()
        let transaction = try #require(subject.removeFromRecent(row("b")))

        RecentFilesService.record(
            DocumentInfo(kind: .pdf, pdfPath: "/docs/b.pdf", title: nil, pageCount: 1))

        #expect(!subject.undoRecentRemoval(transaction))
        #expect(
            recentPaths() == ["/docs/b.pdf", "/docs/a.pdf"],
            "the re-opened row stays exactly once, at the top where re-opening put it")
    }

    /// The mirror image, and the nastier one: without it, Redo deletes a row the
    /// user has just read, and a further Undo reinstates its stale timestamp —
    /// silently demoting a real visit down the list.
    @Test("Redo refuses once the document has been re-opened")
    func redoAfterReopenDoesNothing() throws {
        seed(["/docs/a.pdf", "/docs/b.pdf"])
        let subject = store()
        let transaction = try #require(subject.removeFromRecent(row("b")))
        #expect(subject.undoRecentRemoval(transaction))

        // The user reads b again: `record` re-stamps openedAt and re-heads it.
        RecentFilesService.record(
            DocumentInfo(kind: .pdf, pdfPath: "/docs/b.pdf", title: nil, pageCount: 1))

        #expect(!subject.redoRecentRemoval(transaction))
        #expect(recentPaths() == ["/docs/b.pdf", "/docs/a.pdf"])
    }

    /// At the cap, the restored row displaces the oldest — and because the list
    /// stays sorted, the one evicted really is the oldest.
    @Test("Restoring into a full list evicts the oldest entry")
    func restoreAtTheCapEvictsTheOldest() throws {
        let paths = (1...RecentFilesService.maxRecent).map { "/docs/\($0).pdf" }
        seed(paths)
        let subject = store()
        let oldest = paths.last!
        let transaction = try #require(subject.removeFromRecent(row("1")))
        #expect(recentPaths().count == RecentFilesService.maxRecent - 1)

        RecentFilesService.record(
            DocumentInfo(kind: .pdf, pdfPath: "/docs/new.pdf", title: nil, pageCount: 1))
        #expect(subject.undoRecentRemoval(transaction))

        let after = recentPaths()
        #expect(after.count == RecentFilesService.maxRecent)
        #expect(after.first == "/docs/new.pdf")
        #expect(!after.contains(oldest), "the oldest row is the one that falls off the end")
        #expect(after.contains("/docs/1.pdf"), "the restored row survives")
    }

    /// Two removals undo last-in-first-out, and each transaction only ever
    /// touches its own row.
    @Test("Stacked removals undo independently")
    func stackedRemovalsUndoIndependently() throws {
        seed(["/docs/a.pdf", "/docs/b.pdf", "/docs/c.pdf"])
        let subject = store()
        let first = try #require(subject.removeFromRecent(row("a")))
        let second = try #require(subject.removeFromRecent(row("c")))
        #expect(recentPaths() == ["/docs/b.pdf"])

        #expect(subject.undoRecentRemoval(second))
        #expect(recentPaths() == ["/docs/b.pdf", "/docs/c.pdf"])
        #expect(subject.undoRecentRemoval(first))
        #expect(recentPaths() == ["/docs/a.pdf", "/docs/b.pdf", "/docs/c.pdf"])
    }

    /// Removing a row that is not in the recents list still succeeds — it just
    /// has nothing to offer Undo, which is what stops the caller registering a
    /// ⌘Z that would do nothing.
    @Test("A recent that was already gone offers no Undo")
    func missingRecentOffersNoUndo() {
        seed(["/docs/a.pdf"])
        let subject = store()

        #expect(subject.removeFromRecent(row("zzz")) == nil)
        #expect(recentPaths() == ["/docs/a.pdf"])
    }

    /// Removal clears the keyboard selection so the highlight cannot survive on
    /// a row that is no longer there.
    @Test("Removing the selected row drops the selection")
    func removalClearsSelection() {
        seed(["/docs/a.pdf"])
        let subject = store()
        subject.selectedId = "a"

        _ = subject.removeFromRecent(row("a"))

        #expect(subject.selectedId == nil)
    }
}

/// Cap behaviour that the `restore` early-out exists for. Split out of the main
/// suite only to keep its longer setup out of the way.
@MainActor
@Suite("Home removal cap behaviour", .serialized, ScratchRecentsScope())
struct HomeRemovalCapTests {
    /// An undo the cap would swallow must report failure, or ⌘Z appears to do
    /// nothing while the Edit menu goes on to offer "Redo Remove from Recent".
    @Test("Undo that the cap would swallow reports failure")
    func undoSwallowedByTheCapFails() throws {
        let cap = RecentFilesService.maxRecent
        // The removed row is the OLDEST, and the list refills to the cap with
        // newer rows before the undo — so there is no room left for it.
        let oldest = RecentDocument(
            pdfPath: "/docs/oldest.pdf", kind: .pdf, title: nil, pageCount: 1,
            openedAt: ISO8601DateFormatter.recentTimestamp.string(
                from: Date().addingTimeInterval(-9999)),
            docId: nil)
        RecentFilesService.restore(oldest)
        for index in 0..<cap {
            RecentFilesService.record(
                DocumentInfo(kind: .pdf, pdfPath: "/docs/new\(index).pdf", title: nil, pageCount: 1))
        }

        #expect(RecentFilesService.getRecent().count == cap)
        #expect(!RecentFilesService.getRecent().contains { $0.pdfPath == "/docs/oldest.pdf" })
        #expect(!RecentFilesService.restore(oldest), "no room, so the undo must not claim success")
        #expect(RecentFilesService.getRecent().count == cap)
    }
}
