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
    /// Sources that failed, keyed by provider id.
    ///
    /// Keyed rather than a flat array so the two writers cannot clobber each
    /// other: `reload()` only ever speaks for the snapshot providers and
    /// `results()` only ever speaks for the live ones, but both used to assign
    /// the whole list, so a corpus reload landing while a live query was in
    /// flight could erase a genuine read-later outage (or resurrect a cleared
    /// one). Keying also retires the `hasPrefix("<name>: ")` string surgery
    /// that clearing a recovered live source previously needed.
    private var failuresByProvider: [String: String] = [:]

    /// Failed sources as "<name>: <reason>" — surfaced in the no-results state
    /// so a broken read-later connection is visible rather than silently
    /// narrowing the user's search. Sorted by provider id so the banner order
    /// is stable between passes.
    var failures: [String] {
        failuresByProvider.keys.sorted().compactMap { failuresByProvider[$0] }
    }

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
        var problems: [Int: (id: String, message: String)] = [:]

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
                if let problem { problems[index] = (providers[index].id, problem) }
            }
        }

        // A load abandoned mid-flight must change NOTHING. The same reasoning
        // that keeps a cancelled live query out of `failures` applies here, and
        // then some: a cancelled task group hands back whatever its children
        // managed before the cancellation propagated, so committing it would
        // both install a half-built corpus (documents silently missing from
        // search) and record every unfinished source as broken. The screen's
        // `.task` is torn down on every pane change, so this is routine, not
        // exotic. Keeping the previous corpus is strictly better than a partial
        // one — the caller that cancelled us is already starting a fresh load.
        guard !Task.isCancelled else { return }

        corpus = Self.deduplicated(loaded.keys.sorted().flatMap { loaded[$0] ?? [] })
        // Replace only what the snapshot providers have to say. A live
        // provider's failure, recorded by `results()`, is none of this pass's
        // business and must survive a corpus rebuild.
        for (_, provider) in snapshotProviders { failuresByProvider[provider.id] = nil }
        for (_, problem) in problems { failuresByProvider[problem.id] = problem.message }
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
        filter: HomeSearchFilter = .all,
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
                    failuresByProvider[provider.id] = nil
                } catch {
                    // A pass abandoned by the debounce is NOT a broken source.
                    // `HomeSearchStore` drives ranking from `.task(id:)`, which
                    // cancels the previous pass on every keystroke, and that
                    // cancellation propagates into the provider — URLSession
                    // surfaces it as `URLError.cancelled`, structured code as
                    // `CancellationError`. Recording either would park a
                    // "Read Later: cancelled" banner under the results of
                    // almost every word the user types. Ask the task, not the
                    // error, so both spellings are covered.
                    if Task.isCancelled { break }
                    failuresByProvider[provider.id] =
                        "\(provider.displayName): \(error.localizedDescription)"
                }
            }
        }

        return HomeSearchRanker.results(
            corpus: searchable, query: trimmed, filter: filter, sort: sort, now: now, limit: limit)
    }

    /// Collapse items describing the same document into one row.
    ///
    /// The surviving row is the FIRST occurrence — which, given `providers` is
    /// in priority order, is the highest-priority source's version of it: the
    /// recents entry, with its freshest date and its re-resolved path for a
    /// moved file. But the discarded duplicates are not simply thrown away,
    /// because each source knows something the others do not. The web library
    /// is the only source that knows a page is bookmarked or has an offline
    /// snapshot; the documents directory is the only source that knows a file
    /// carries notes. So the survivor absorbs their badges, and a recently read
    /// article that is also saved, also offline and also annotated is one row
    /// that says all four things instead of a bare Recents row that says none.
    ///
    /// Items with a blank identity are DROPPED rather than merged. A blank
    /// locator is reachable from every source — a corrupt recents record with
    /// an empty `pdfPath`, a `meta.json` with no `last_known_path`
    /// (`StorageInventory` guards the same case), a web entry with no URL — and
    /// because the identity is the merge key, every one of them would otherwise
    /// collapse into a single row, hiding the rest of the user's back
    /// catalogue behind one entry whose target is `.file(path: "")` and can
    /// therefore only fail to open. Guarding here rather than in each provider
    /// is what makes that true for all of them at once, including any read-later
    /// source added later.
    static func deduplicated(_ items: [HomeSearchItem]) -> [HomeSearchItem] {
        var order: [String] = []
        var merged: [String: HomeSearchItem] = [:]
        order.reserveCapacity(items.count)
        merged.reserveCapacity(items.count)

        for item in items {
            guard !item.identity.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                continue
            }
            if merged[item.identity] == nil {
                merged[item.identity] = item
                order.append(item.identity)
            } else {
                merged[item.identity]?.badges.formUnion(item.badges)
            }
        }
        return order.compactMap { merged[$0] }
    }
}
