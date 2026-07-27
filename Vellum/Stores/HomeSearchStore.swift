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

    init(engine: HomeSearchEngine = HomeSearchEngine()) {
        self.engine = engine
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

    /// Forget a result. Recents drop out of the recents list; saved webpages
    /// are un-saved (their annotations survive, exactly as the old welcome
    /// screen's "Remove from Saved" did). Library documents are not removable
    /// here — deleting a document's notes belongs to Settings ▸ Storage.
    func remove(_ item: HomeSearchItem, from target: HomeSearchRemoval) async {
        switch target {
        case .recent:
            if case .file(_, let recordedPath) = item.target {
                _ = RecentFilesService.remove(path: recordedPath)
            } else {
                _ = RecentFilesService.remove(path: item.target.openKey)
            }
        case .saved:
            let url = item.target.openKey
            // Blocking disk work — same off-main hop `WebSessionBackend` uses.
            await Task.detached(priority: .userInitiated) {
                try? WebLibrary.removeSaved(rawUrl: url)
            }.value
        }
        if selectedId == item.id { selectedId = nil }
        await load()
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
        await Task.detached(priority: .userInitiated) {
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
