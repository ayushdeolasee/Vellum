import Foundation
import Observation

// Main-actor state for the home screen: what the user typed, how they want the
// browse list arranged, which row is keyboard-selected, and the last ranked
// result set.
//
// All the actual work — loading sources, matching, ranking — belongs to
// `HomeSearchEngine` (an actor). This type is the thin, observable seam between
// that and SwiftUI: it debounces, it guards against out-of-order results, and
// it owns selection. Nothing here blocks the main thread.

/// A way of forgetting a result from the home screen. Named rather than
/// inferred from the row's section, because one row can support both.
enum HomeSearchRemoval: Hashable, Sendable {
    /// Drop it from the recently-opened list. The document itself, its notes
    /// and its saved copy are all untouched.
    case recent
    /// Un-save the webpage. Its annotations survive — this is the same
    /// "Remove from Saved" the previous welcome screen offered.
    case saved

    /// Menu wording. Both are destructive-looking but neither deletes anything
    /// the user cannot get back by opening the document again, so the labels
    /// say what leaves rather than what is destroyed.
    var label: String {
        switch self {
        case .recent: "Remove from Recent"
        case .saved: "Remove from Saved"
        }
    }

    /// Whether this removal stops to ask (issue #103 — both used to fire on a
    /// single click of a context-menu item with no confirmation and no undo).
    ///
    /// The two are not equally recoverable, so they do not get the same guard.
    /// Un-saving runs `WebLibrary.removeSaved`, which deletes the page's local
    /// snapshots from disk; re-saving means re-fetching, and offline that is
    /// simply gone. Nothing can undo it, so it asks first. Dropping a recent
    /// only filters a `UserDefaults` list, so it takes the cheaper guard — see
    /// `HomeRecentRemovalTransaction` — and stays a single click.
    var requiresConfirmation: Bool {
        switch self {
        case .recent: false
        case .saved: true
        }
    }

    /// Context-menu wording. The trailing ellipsis on a gated action is the
    /// platform's one signal that this item stops to ask while the item next
    /// to it does not — the same distinction Finder draws between "Move to
    /// Trash" and "Delete Immediately…".
    var menuLabel: String { requiresConfirmation ? "\(label)…" : label }

    /// Confirm-button wording. Repeating the menu label (without the ellipsis,
    /// which belongs only to the item that opens a dialog) keeps the dialog's
    /// consequence identical to the action the user reached for.
    var confirmLabel: String { label }

    /// Dialog title. It names the row, so a right-click that landed one row off
    /// is caught here rather than after the offline copy is already gone.
    func confirmationTitle(for documentTitle: String) -> String {
        switch self {
        case .recent: "Remove “\(documentTitle)” from Recent?"
        case .saved: "Remove “\(documentTitle)” from Saved?"
        }
    }

    /// What actually happens, in the terms the user cares about. The reassuring
    /// half matters as much as the warning: annotations surviving is the reason
    /// un-saving is a reasonable thing to do at all.
    var confirmationMessage: String? {
        switch self {
        case .recent: nil
        case .saved:
            // Not "from this Mac": `WebLibrary.removeLocalSnapshots` deletes
            // through `WebICloud.removeItem`, and the web store can live in
            // iCloud Drive — in which case the offline copy leaves every
            // device. A confirmation is the one place that must not understate
            // what it is about to do.
            "The offline copy is deleted here, and from iCloud if your library syncs there. "
                + "Highlights and notes are kept, but saving the page again needs a connection."
        }
    }
}

/// A "Remove from Recent" that can be put back, for session-scoped Undo — the
/// pattern PR #79 introduced for clear-conversation and clear-scratchpad.
///
/// Recents are a `UserDefaults` list sorted newest-first, so undo is exact: the
/// entry goes back with the `openedAt` it had, which is also what decides where
/// it lands. `.saved` has no counterpart here on purpose — its removal destroys
/// files, which is why it carries a confirmation instead.
struct HomeRecentRemovalTransaction: Equatable, Sendable {
    var entry: RecentDocument
}

@MainActor
@Observable
final class HomeSearchStore {
    /// Row id of the pinned "open this link" action. Not a real corpus item, but
    /// it participates in keyboard navigation like one.
    static let linkRowId = "home.linkAction"

    /// How long to wait after the last keystroke before ranking. Long enough
    /// that a fast typist causes one pass instead of ten, short enough to feel
    /// like live filtering.
    static let debounce = Duration.milliseconds(120)

    // MARK: - User-controlled state

    var query = ""
    var filter: HomeSearchFilter = .all
    var sort: HomeSearchSortOrder = .recent
    /// The keyboard-selected row: a `HomeSearchItem.id`, or `linkRowId`.
    var selectedId: String?

    // MARK: - Derived state

    private(set) var sections: [HomeSearchResultSection] = []
    /// `sections` flattened in display order — the list arrow keys walk.
    private(set) var visibleItems: [HomeSearchItem] = []
    /// True until the first corpus load finishes, so the view can hold off the
    /// empty state instead of flashing "nothing here" on the way in.
    private(set) var isLoading = true
    /// True once a load has completed and found nothing at all — a genuine
    /// first run, which gets the hero layout rather than an empty list.
    private(set) var libraryIsEmpty = false
    /// Sources that failed to load, as "<name>: <reason>".
    private(set) var failures: [String] = []

    private let engine: HomeSearchEngine
    /// Monotonic stamp so a slow ranking pass can never overwrite a newer one
    /// (the corpus load and a keystroke can be in flight at the same time).
    private var refreshGeneration = 0

    /// Passing an engine (tests) skips the default providers entirely.
    /// A read-later provider is appended here once the integrations packet lands.
    init(engine: HomeSearchEngine? = nil) {
        self.engine = engine ?? HomeSearchEngine()
    }

    // MARK: - Query shape

    var trimmedQuery: String {
        query.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var isSearching: Bool { !trimmedQuery.isEmpty }

    /// A link the user pasted into the search field, offered as a pinned "open"
    /// row. The search field doubles as the URL bar this way, which is both one
    /// less control on screen and the fastest path from a copied URL to reading
    /// it. Purely additive — it never replaces or suppresses search results.
    var linkSuggestion: String? {
        HomeSearchLinkDetector.url(in: query)
    }

    /// What the "N results" label counts. Includes the pinned link action,
    /// because from the user's side it is a row they can arrow to and open.
    var resultCount: Int { navigationOrder.count }

    /// Every navigable row id in display order, link action first.
    var navigationOrder: [String] {
        (linkSuggestion != nil ? [Self.linkRowId] : []) + visibleItems.map(\.id)
    }

    var selectedItem: HomeSearchItem? {
        guard let selectedId else { return nil }
        return visibleItems.first { $0.id == selectedId }
    }

    /// The `.task(id:)` key: any of these changing means the results are stale.
    /// Bundling them into one key gives a single refresh driver with SwiftUI's
    /// automatic cancellation, instead of three ad-hoc `onChange` tasks racing.
    struct RefreshKey: Equatable {
        var query: String
        var filter: HomeSearchFilter
        var sort: HomeSearchSortOrder
    }

    var refreshKey: RefreshKey { RefreshKey(query: query, filter: filter, sort: sort) }

    // MARK: - Loading

    /// Build (or rebuild) the corpus, then re-rank. Called when the screen
    /// appears and after any action that changes what is in the library.
    func load() async {
        isLoading = true
        await engine.reload()
        failures = await engine.failures
        libraryIsEmpty = await engine.corpus.isEmpty
        isLoading = false
        await refresh()
    }

    /// Re-rank for the current query/filter/sort. Debounces a non-empty query;
    /// the browse list (empty query) updates immediately because there is no
    /// typing to coalesce.
    func refresh() async {
        refreshGeneration += 1
        let generation = refreshGeneration
        let currentQuery = query

        if !currentQuery.isEmpty {
            try? await Task.sleep(for: Self.debounce)
            guard !Task.isCancelled else { return }
        }

        let ranked = await engine.results(query: currentQuery, filter: filter, sort: sort)
        let problems = await engine.failures
        // A newer pass started (or SwiftUI tore this one down) while we were
        // suspended — its answer is the current one, so drop ours.
        guard generation == refreshGeneration, !Task.isCancelled else { return }

        sections = ranked
        visibleItems = ranked.flatMap(\.items)
        failures = problems
        reconcileSelection()
    }

    // MARK: - Selection

    /// Keep the selection meaningful across a result change: hold the current
    /// row if it survived, otherwise pre-select the top hit WHILE SEARCHING so
    /// ↩ opens the obvious answer. Browsing starts with nothing selected — a
    /// highlighted row at rest reads as a mode the user did not ask for.
    private func reconcileSelection() {
        let order = navigationOrder
        if let selectedId, order.contains(selectedId) { return }
        selectedId = isSearching ? order.first : nil
    }

    /// Move the selection by `delta` rows, clamped at both ends (wrapping in a
    /// search list makes it too easy to shoot past the best match).
    func moveSelection(_ delta: Int) {
        let order = navigationOrder
        guard !order.isEmpty else { return }
        guard let current = selectedId, let index = order.firstIndex(of: current) else {
            selectedId = delta >= 0 ? order.first : order.last
            return
        }
        let next = min(order.count - 1, max(0, index + delta))
        selectedId = order[next]
    }

    /// Escape: clear the query if there is one. Returns false when there was
    /// nothing to clear, so the caller can let the key fall through.
    @discardableResult
    func clearQuery() -> Bool {
        guard !query.isEmpty else { return false }
        query = ""
        selectedId = nil
        return true
    }

    /// Undo everything that is currently narrowing the list.
    ///
    /// The no-results state offers this as one button because the user cannot
    /// generally tell which of the two constraints emptied their screen — a
    /// query that matches nothing and a filter that excludes everything look
    /// identical from the outside. Making them clear the query, notice nothing
    /// changed, and then find the filter chip is a puzzle, not an interface.
    func resetSearch() {
        query = ""
        filter = .all
        selectedId = nil
    }

    // MARK: - Mutating the library

    /// Drop a result from the recents list. The document, its notes and its
    /// saved copy are all untouched.
    ///
    /// Synchronous, and deliberately does NOT reload: the caller needs the
    /// transaction in hand to register Undo *before* the corpus rebuild, which
    /// is a recents read plus a stat per saved page plus a documents-directory
    /// walk. Registering after it would leave a window in which ⌘Z popped
    /// whatever was on the window's undo stack beforehand. Callers follow up
    /// with `load()`.
    ///
    /// Returns the transaction needed to undo this, or nil when the entry was
    /// already gone and there is nothing to offer Undo for.
    func removeFromRecent(_ item: HomeSearchItem) -> HomeRecentRemovalTransaction? {
        let path: String
        if case .file(_, let recordedPath) = item.target {
            path = recordedPath
        } else {
            path = item.target.openKey
        }
        // Read the entry BEFORE the write — it is the whole of what Undo needs
        // to put the row back untouched.
        let entry = RecentFilesService.getRecent().first { $0.pdfPath == path }
        _ = RecentFilesService.remove(path: path)
        if selectedId == item.id { selectedId = nil }
        return entry.map(HomeRecentRemovalTransaction.init)
    }

    /// Un-save a webpage: the record and its annotations survive, the offline
    /// snapshot does not. There is no undo for that, which is why the caller
    /// confirms first — see `HomeSearchRemoval.requiresConfirmation`.
    func removeFromSaved(_ item: HomeSearchItem) async {
        let url = item.target.openKey
        // Blocking disk work — same off-main hop `WebSessionBackend` uses.
        await Task.detached(priority: .userInitiated) {
            try? WebLibrary.removeSaved(rawUrl: url)
        }.value
        if selectedId == item.id { selectedId = nil }
        await load()
    }

    /// Put a removed recent back. Returns false when the removal has been
    /// overtaken — the user re-opened the document, so it is in the list again
    /// and there is nothing to restore. The caller uses that to stop the
    /// undo/redo chain instead of duplicating the row.
    @discardableResult
    func undoRecentRemoval(_ transaction: HomeRecentRemovalTransaction) -> Bool {
        guard RecentFilesService.restore(transaction.entry) else { return false }
        Task { await load() }
        return true
    }

    /// Re-apply the removal, but only against the row this transaction
    /// actually removed — see `RecentFilesService.removeIfUnchanged`. Returns
    /// false when the row has since been re-opened, which ends the chain
    /// rather than deleting a document the user has just read.
    @discardableResult
    func redoRecentRemoval(_ transaction: HomeRecentRemovalTransaction) -> Bool {
        guard RecentFilesService.removeIfUnchanged(transaction.entry) else { return false }
        Task { await load() }
        return true
    }

    /// Retitle a result and re-index so the new name is live everywhere.
    ///
    /// The write is a detached task because it touches three on-disk stores;
    /// the reload afterwards is what makes the renamed row re-sort under a
    /// name sort and become findable by its new title without the user having
    /// to do anything.
    func rename(_ item: HomeSearchItem, to newTitle: String) async {
        let target = DocumentRenameService.Target(item: item)
        let title = DocumentRenameService.normalized(newTitle)
        // `apply` reports whether any store accepted the write. Discarded on
        // purpose: the reload below shows whatever actually landed, so there is
        // nothing to tell the user that the refreshed row doesn't already say.
        _ = await Task.detached(priority: .userInitiated) {
            DocumentRenameService.apply(target, title: title)
        }.value
        await load()
    }

    /// Can this result be renamed here? Everything local can. A remote
    /// read-later article cannot — there is no local record to write, and
    /// pretending otherwise would show a rename that silently vanished on the
    /// next refresh.
    func canRename(_ item: HomeSearchItem) -> Bool {
        item.section != .readLater
    }

    /// Which "forget this" actions apply to a result, most relevant first.
    ///
    /// A row can legitimately offer BOTH. Dedupe merges a page that is in the
    /// recents list and also bookmarked into a single Recents row carrying the
    /// saved badge, and those are two genuinely different intentions: "stop
    /// showing me this at the top" versus "take it off my shelf". Offering only
    /// the one implied by the section would make un-saving a recently read
    /// article impossible from this screen.
    ///
    /// The ORDER follows the active filter, which is the same idea PR #75 got
    /// right: someone who has narrowed to Saved and reaches for a destructive
    /// action means un-save, whatever else the row happens to be, so that lands
    /// first. Everywhere else recency is the facet the home screen is about, so
    /// "Remove from Recent" leads.
    func removalOptions(for item: HomeSearchItem) -> [HomeSearchRemoval] {
        var options: [HomeSearchRemoval] = []
        if item.section == .recents { options.append(.recent) }
        // Keyed off the badge, not the section: after dedupe a saved page can
        // surface under Recents, and it is still un-savable there.
        if item.badges.contains(.saved) { options.append(.saved) }
        if filter == .saved { options.reverse() }
        return options
    }
}
