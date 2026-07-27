import Foundation

// The home screen's search back end: owns the registered providers, caches the
// local corpus, and turns a query into ranked sections.
//
// An `actor` rather than a `@MainActor` store, because both halves of the work
// must stay off the main thread: loading walks the documents directory and the
// web store, and matching is O(corpus) per keystroke. The main actor only ever
// awaits a finished `[HomeSearchResultSection]`.

actor HomeSearchEngine {
    /// Providers in DEDUPE PRIORITY order — when the same document reaches us
    /// from two sources, the earlier one wins. Recents first, because a recents
    /// entry carries the freshest "when did I last see this" date and the
    /// re-resolved path for a moved file.
    private let providers: [any HomeSearchProvider]

    /// Everything the snapshot providers last handed over, already deduped.
    private(set) var corpus: [HomeSearchItem] = []
    /// Set once `reload()` has completed at least once, so the UI can tell
    /// "still loading" apart from "genuinely nothing here" and not flash an
    /// empty state on the way in.
    private(set) var hasLoaded = false
    /// Sources that failed, as "<name>: <reason>" — surfaced in the no-results
    /// state so a broken read-later connection is visible rather than silently
    /// narrowing the user's search.
    private(set) var failures: [String] = []

    init(providers: [any HomeSearchProvider] = HomeSearchEngine.defaultProviders()) {
        self.providers = providers
    }

    /// The sources that ship today. All three are local; a connected read-later
    /// account would be appended here (last, so a local copy of an article
    /// always wins the dedupe over the remote one).
    static func defaultProviders() -> [any HomeSearchProvider] {
        [
            RecentDocumentsSearchProvider(),
            SavedWebpagesSearchProvider(),
            LibraryDocumentsSearchProvider(),
        ]
    }

    /// Rebuild the local corpus. Providers load CONCURRENTLY — three
    /// independent disk walks, and the slowest (the web store, which stats a
    /// snapshot per saved page) shouldn't serialize behind the others — then
    /// results are reassembled in provider order so dedupe priority is stable
    /// regardless of which finished first.
    func reload() async {
        let snapshotProviders = providers.enumerated().filter { $0.element.mode == .snapshot }
        var loaded: [Int: [HomeSearchItem]] = [:]
        var problems: [Int: String] = [:]

        await withTaskGroup(of: (Int, [HomeSearchItem], String?).self) { group in
            for (index, provider) in snapshotProviders {
                group.addTask {
                    do {
                        return (index, try await provider.items(matching: ""), nil)
                    } catch {
                        return (index, [], "\(provider.displayName): \(error.localizedDescription)")
                    }
                }
            }
            for await (index, items, problem) in group {
                loaded[index] = items
                if let problem { problems[index] = problem }
            }
        }

        corpus = Self.deduplicated(loaded.keys.sorted().flatMap { loaded[$0] ?? [] })
        failures = problems.keys.sorted().compactMap { problems[$0] }
        hasLoaded = true
    }

    /// Ranked sections for `query`.
    ///
    /// Local matching runs against the cached corpus. Live providers (a hosted
    /// read-later service) are asked for their own hits for this query and
    /// merged in before ranking, so remote articles compete on the same score
    /// scale as local documents instead of being bolted on in a separate list.
    /// They are only consulted for a non-empty query — nobody wants a network
    /// round trip just to render the browse list.
    func results(
        query: String,
        filter: HomeSearchKindFilter = .all,
        sort: HomeSearchSortOrder = .recent,
        now: Date = Date(),
        limit: Int = 200
    ) async -> [HomeSearchResultSection] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        var searchable = corpus

        if !trimmed.isEmpty {
            for provider in providers where provider.mode == .live {
                do {
                    let remote = try await provider.items(matching: trimmed)
                    // Local wins: an article already saved on this Mac should
                    // open the offline copy, not re-fetch it.
                    searchable = Self.deduplicated(searchable + remote)
                    failures.removeAll { $0.hasPrefix("\(provider.displayName): ") }
                } catch {
                    let message = "\(provider.displayName): \(error.localizedDescription)"
                    if !failures.contains(message) { failures.append(message) }
                }
            }
        }

        return HomeSearchRanker.results(
            corpus: searchable, query: trimmed, filter: filter, sort: sort, now: now, limit: limit)
    }

    /// Collapse items describing the same document, keeping the first
    /// occurrence — which, given `providers` is in priority order, is the
    /// highest-priority source's version of it.
    static func deduplicated(_ items: [HomeSearchItem]) -> [HomeSearchItem] {
        var seen = Set<String>()
        seen.reserveCapacity(items.count)
        return items.filter { seen.insert($0.identity).inserted }
    }
}
