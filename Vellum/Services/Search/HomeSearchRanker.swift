import Foundation

// Relevance scoring and sectioning for the home screen's search field.
//
// This is the whole "search" of the search bar, and it is deliberately a pure
// function over `Sendable` values: no store, no view, no I/O. That buys three
// things — it runs on a background actor without ceremony, its behavior is
// pinned by unit tests (`HomeSearchRankerTests`) rather than by clicking around
// the app, and a future read-later provider inherits the same ranking for free.

/// The kind filter the browse toolbar offers.
enum HomeSearchKindFilter: Int, Hashable, Sendable, CaseIterable {
    case all
    case documents
    case webpages

    var label: String {
        switch self {
        case .all: "All"
        case .documents: "PDFs"
        case .webpages: "Webpages"
        }
    }

    func accepts(_ item: HomeSearchItem) -> Bool {
        switch self {
        case .all: true
        case .documents: item.kind == .pdf
        case .webpages: item.kind == .web
        }
    }
}

/// How the browse list (empty query) is ordered. A query always overrides this
/// with relevance — sorting matches by name would bury the best hit.
enum HomeSearchSortOrder: Int, Hashable, Sendable, CaseIterable {
    case recent
    case name

    var label: String {
        switch self {
        case .recent: "Recently opened"
        case .name: "Name"
        }
    }
}

/// One rendered group of results.
struct HomeSearchResultSection: Identifiable, Hashable, Sendable {
    let section: HomeSearchSection
    let items: [HomeSearchItem]

    var id: HomeSearchSection { section }
}

enum HomeSearchRanker {
    // MARK: - Score weights
    //
    // Absolute values are arbitrary; only their ORDER matters, and the order
    // encodes one rule: a match in a name the user chose (title, filename,
    // host) beats a match in machinery they never see (a deep folder path, a
    // query string). Kept as named constants so a test can assert the ordering
    // rather than a magic number.

    static let titleExact = 1000
    static let titlePrefix = 600
    static let titleWordPrefix = 450
    static let namePrefix = 400
    static let titleSubstring = 300
    static let initialsPrefix = 280
    static let nameSubstring = 220
    static let locationSubstring = 140
    static let extraSubstring = 90

    /// Awarded once when a multi-token query appears contiguously in the title,
    /// so "all you need" outranks an item that merely contains all three words
    /// scattered.
    static let phraseBonus = 250
    /// Recents lead on ties: the thing you touched last is the likeliest answer.
    static let recentsSectionBonus = 30

    // Deliberately NO general subsequence/fuzzy fallback. It was tried and cut:
    // on a long title almost any short token matches as a subsequence ("example"
    // is one of "…OxCaml to implement…"), which fills the list with results the
    // user cannot see the reason for. Every result must visibly contain what was
    // typed. The one fuzzy affordance that survives is the initials match, which
    // is anchored and therefore explainable.

    // MARK: - Link lookup weights

    /// A pasted link that exactly names something already in the library.
    static let linkExact = 900
    /// A pasted link that overlaps something in the library (same page with a
    /// different path depth, or a saved article under a pasted site root).
    static let linkPartial = 500

    // MARK: - Scoring

    /// Score one item against pre-tokenized query terms, or nil when the item
    /// does not match. EVERY token must land somewhere (an AND, not an OR):
    /// typing more words must narrow the list, never widen it.
    static func score(_ item: HomeSearchItem, tokens: [String], now: Date) -> Int? {
        guard !tokens.isEmpty else { return nil }
        var total = 0
        for token in tokens {
            let best = fieldScore(item.haystack, token: token)
            guard best > 0 else { return nil }
            total += best
        }
        if tokens.count > 1 {
            // The tokens are folded and split on non-alphanumerics, so rejoining
            // them with single spaces is the normalized phrase — it matches the
            // folded title's own spacing.
            let phrase = tokens.joined(separator: " ")
            if item.haystack.title.contains(phrase) { total += phraseBonus }
        }
        total += recencyBonus(for: item.date, now: now)
        if item.section == .recents { total += recentsSectionBonus }
        return total
    }

    /// The best score any single field yields for one token. Ordered cheapest-
    /// and-strongest first, with early exits so a title-prefix hit never pays
    /// for a path scan.
    static func fieldScore(_ haystack: HomeSearchHaystack, token: String) -> Int {
        guard !token.isEmpty else { return 0 }
        var best = 0

        let title = haystack.title
        if title == token {
            return titleExact
        }
        if title.hasPrefix(token) {
            best = titlePrefix
        } else if HomeSearchText.hasWordPrefix(title, token) {
            best = titleWordPrefix
        }

        let name = haystack.name
        if best < namePrefix, name.hasPrefix(token) {
            best = namePrefix
        }
        if best < titleSubstring, title.contains(token) {
            best = titleSubstring
        }
        // A two-letter initialism ("ml") is still a useful signal; a one-letter
        // one matches half the library, so it is not.
        if best < initialsPrefix, token.count >= 2, haystack.initials.hasPrefix(token) {
            best = initialsPrefix
        }
        if best < nameSubstring, name.contains(token) {
            best = nameSubstring
        }
        if best < locationSubstring, haystack.location.contains(token) {
            best = locationSubstring
        }
        if best < extraSubstring, !haystack.extra.isEmpty, haystack.extra.contains(token) {
            best = extraSubstring
        }
        return best
    }

    // MARK: - Link lookup

    /// Reduce a URL to the part worth comparing: no scheme, no "www.", no
    /// trailing slash. Two spellings of the same page have to collapse to the
    /// same key or "do I already have this?" answers no for the wrong reason.
    static func linkKey(_ link: String) -> String {
        var value = HomeSearchText.fold(link.trimmingCharacters(in: .whitespacesAndNewlines))
        for scheme in ["https://", "http://"] where value.hasPrefix(scheme) {
            value.removeFirst(scheme.count)
            break
        }
        if value.hasPrefix("www.") { value.removeFirst(4) }
        while value.hasSuffix("/") { value.removeLast() }
        return value
    }

    /// Score an item against a pasted link, or nil when it is unrelated.
    ///
    /// A link is a LOOKUP, not a text search. Tokenizing
    /// "https://example.com/new-article" would ask the corpus for items
    /// containing "https" and "com" — which is every webpage in the library —
    /// so the whole result list becomes noise at exactly the moment the user's
    /// intent is least ambiguous. The only question worth answering is "do I
    /// already have this page?", so that they open their annotated copy instead
    /// of re-fetching it.
    static func linkScore(_ item: HomeSearchItem, key: String) -> Int? {
        guard !key.isEmpty else { return nil }
        let itemKey = linkKey(item.haystack.location)
        guard !itemKey.isEmpty else { return nil }
        if itemKey == key { return linkExact }
        // Either direction: a pasted site root should find the saved article
        // beneath it, and a pasted deep link should find the saved root.
        guard itemKey.hasPrefix(key) || key.hasPrefix(itemKey) else { return nil }
        return linkPartial
    }

    /// Coarse recency buckets rather than a continuous decay: buckets are
    /// stable to assert in tests and cannot let a marginally newer document
    /// leapfrog a much better textual match.
    static func recencyBonus(for date: Date?, now: Date) -> Int {
        guard let date else { return 0 }
        let day: TimeInterval = 86_400
        let age = now.timeIntervalSince(date)
        // Clock skew (or an iCloud record stamped in the future) must not be
        // rewarded beyond "today".
        if age < -day { return 0 }
        if age < day { return 120 }
        if age < 7 * day { return 80 }
        if age < 30 * day { return 40 }
        if age < 365 * day { return 15 }
        return 0
    }

    // MARK: - Sectioned results

    /// Turn the corpus into the sections the home screen renders.
    ///
    /// With no query this is the BROWSE list: every item that passes the kind
    /// filter, grouped by section in the fixed section order and ordered inside
    /// each section by `sort`. With a query it is the SEARCH list: only
    /// matching items, capped at `limit`, with sections ordered by their best
    /// hit so the strongest match is always the first row on screen.
    static func results(
        corpus: [HomeSearchItem],
        query: String,
        filter: HomeSearchKindFilter = .all,
        sort: HomeSearchSortOrder = .recent,
        now: Date = Date(),
        limit: Int = 200
    ) -> [HomeSearchResultSection] {
        let candidates = corpus.filter(filter.accepts)
        // A pasted link takes the lookup path (see `linkScore`) instead of being
        // torn into tokens like "https" and "com".
        if let link = HomeSearchLinkDetector.url(in: query) {
            let key = linkKey(link)
            return relevanceSections(
                candidates.compactMap { candidate in
                    linkScore(candidate, key: key).map { (candidate, $0) }
                },
                limit: limit)
        }

        let tokens = HomeSearchText.tokens(in: query)
        guard !tokens.isEmpty else {
            return browseSections(candidates, sort: sort)
        }

        return relevanceSections(
            candidates.compactMap { candidate in
                score(candidate, tokens: tokens, now: now).map { (candidate, $0) }
            },
            limit: limit)
    }

    /// Sort scored hits by relevance, cap them, and group them into sections
    /// ordered by their own best hit — so the strongest match in the whole
    /// library is always the first row on screen.
    private static func relevanceSections(
        _ scored: [(item: HomeSearchItem, score: Int)], limit: Int
    ) -> [HomeSearchResultSection] {
        var scored = scored
        scored.sort { lhs, rhs in
            if lhs.score != rhs.score { return lhs.score > rhs.score }
            return isOrderedBefore(lhs.item, rhs.item, by: .recent)
        }
        if scored.count > limit { scored.removeLast(scored.count - limit) }

        // Group in encounter order so each section keeps its relevance ranking.
        var grouped: [HomeSearchSection: [HomeSearchItem]] = [:]
        var bestScore: [HomeSearchSection: Int] = [:]
        for entry in scored {
            grouped[entry.item.section, default: []].append(entry.item)
            if bestScore[entry.item.section] == nil { bestScore[entry.item.section] = entry.score }
        }
        return grouped.keys
            .sorted { lhs, rhs in
                let left = bestScore[lhs] ?? 0
                let right = bestScore[rhs] ?? 0
                if left != right { return left > right }
                return lhs < rhs
            }
            .map { HomeSearchResultSection(section: $0, items: grouped[$0] ?? []) }
    }

    private static func browseSections(
        _ items: [HomeSearchItem], sort: HomeSearchSortOrder
    ) -> [HomeSearchResultSection] {
        var grouped: [HomeSearchSection: [HomeSearchItem]] = [:]
        for item in items { grouped[item.section, default: []].append(item) }
        return grouped.keys.sorted().map { section in
            HomeSearchResultSection(
                section: section,
                items: (grouped[section] ?? []).sorted { isOrderedBefore($0, $1, by: sort) })
        }
    }

    /// Total order used for browsing and for breaking relevance ties. Fully
    /// deterministic down to the id so the list never reshuffles between two
    /// identical-looking runs (and so tests can assert exact output).
    static func isOrderedBefore(
        _ lhs: HomeSearchItem, _ rhs: HomeSearchItem, by sort: HomeSearchSortOrder
    ) -> Bool {
        switch sort {
        case .recent:
            switch (lhs.date, rhs.date) {
            case (let left?, let right?) where left != right:
                return left > right
            case (nil, _?):
                // Undated items sort last — they are the ones we know least about.
                return false
            case (_?, nil):
                return true
            default:
                break
            }
        case .name:
            let comparison = lhs.haystack.title.compare(rhs.haystack.title)
            if comparison != .orderedSame { return comparison == .orderedAscending }
        }
        if lhs.haystack.title != rhs.haystack.title { return lhs.haystack.title < rhs.haystack.title }
        return lhs.id < rhs.id
    }
}
