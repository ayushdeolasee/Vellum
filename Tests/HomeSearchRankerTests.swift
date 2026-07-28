import Foundation
import Testing

@testable import Vellum

// The home screen's relevance rules (issue #62). `HomeSearchRanker` is a pure
// function over `Sendable` values precisely so it can be pinned here rather
// than by clicking around the welcome screen — every claim the UI makes about
// "the best match is the first row" is asserted below.

// MARK: - Fixtures

/// Build a corpus item without going near disk. Mirrors what the real
/// providers emit, including the folded haystack.
private func item(
    id: String,
    section: HomeSearchSection = .documents,
    kind: DocumentKind = .pdf,
    title: String,
    name: String? = nil,
    location: String? = nil,
    extra: String = "",
    date: Date? = nil,
    badges: HomeSearchBadges = []
) -> HomeSearchItem {
    let shortName = name ?? "\(title).pdf"
    let locator = location ?? "/Users/reader/Documents/\(shortName)"
    return HomeSearchItem(
        id: id,
        identity: locator,
        section: section,
        kind: kind,
        target: kind == .web ? .url(locator) : .file(path: locator, recordedPath: locator),
        title: title,
        subtitle: shortName,
        detail: "",
        tooltip: locator,
        date: date,
        badges: badges,
        canRevealInFinder: kind == .pdf,
        haystack: HomeSearchHaystack(
            title: title, name: shortName, location: locator, extra: extra))
}

/// A date `days` before the fixed `now` used across these tests.
private let now = Date(timeIntervalSince1970: 1_800_000_000)
private func daysAgo(_ days: Double) -> Date { now.addingTimeInterval(-days * 86_400) }

private func rank(
    _ corpus: [HomeSearchItem],
    _ query: String,
    filter: HomeSearchFilter = .all,
    sort: HomeSearchSortOrder = .recent,
    limit: Int = 200
) -> [HomeSearchItem] {
    HomeSearchRanker.results(
        corpus: corpus, query: query, filter: filter, sort: sort, now: now, limit: limit
    ).flatMap(\.items)
}

// MARK: - Text folding

@Suite("Home search text folding")
struct HomeSearchTextTests {
    @Test("Folding erases case and diacritics so 'resume' finds 'Résumé'")
    func foldsCaseAndDiacritics() {
        #expect(HomeSearchText.fold("Résumé") == "resume")
        #expect(HomeSearchText.fold("ÄNGSTRÖM") == "angstrom")
    }

    @Test("Queries tokenize on any non-alphanumeric run")
    func tokenizesOnPunctuation() {
        #expect(HomeSearchText.tokens(in: "  read-later_v2 (draft) ") == ["read", "later", "v2", "draft"])
        #expect(HomeSearchText.tokens(in: "   ").isEmpty)
    }

    @Test("Initials come from title word starts")
    func buildsInitials() {
        let haystack = HomeSearchHaystack(
            title: "Attention Is All You Need", name: "1706.03762.pdf", location: "/tmp/a.pdf")
        #expect(haystack.initials == "aiayn")
    }

    @Test("Word prefixes match mid-title words")
    func wordPrefixMatchesInteriorWords() {
        #expect(HomeSearchText.hasWordPrefix("attention is all you need", "need"))
        #expect(!HomeSearchText.hasWordPrefix("attention is all you need", "eed"))
    }
}

// MARK: - Field weighting

@Suite("Home search field weighting")
struct HomeSearchFieldScoreTests {
    private let haystack = HomeSearchHaystack(
        title: "Deep Residual Learning",
        name: "resnet.pdf",
        location: "/Users/reader/papers/vision/resnet.pdf",
        extra: "library")

    @Test("A title match always outranks the same word buried in a path")
    func titleBeatsPath() {
        let title = HomeSearchRanker.fieldScore(haystack, token: "residual")
        let path = HomeSearchRanker.fieldScore(haystack, token: "vision")
        #expect(title > path)
        #expect(path == HomeSearchRanker.locationSubstring)
    }

    @Test("Weights are ordered title-prefix > word-prefix > name-prefix > substring")
    func weightOrdering() {
        #expect(HomeSearchRanker.titleExact > HomeSearchRanker.titlePrefix)
        #expect(HomeSearchRanker.titlePrefix > HomeSearchRanker.titleWordPrefix)
        #expect(HomeSearchRanker.titleWordPrefix > HomeSearchRanker.namePrefix)
        #expect(HomeSearchRanker.namePrefix > HomeSearchRanker.titleSubstring)
        #expect(HomeSearchRanker.titleSubstring > HomeSearchRanker.nameSubstring)
        #expect(HomeSearchRanker.nameSubstring > HomeSearchRanker.locationSubstring)
        #expect(HomeSearchRanker.locationSubstring > HomeSearchRanker.extraSubstring)
    }

    @Test("A filename prefix scores even when the title says nothing")
    func filenamePrefix() {
        #expect(HomeSearchRanker.fieldScore(haystack, token: "resn") == HomeSearchRanker.namePrefix)
    }

    @Test("A multi-letter acronym matches by initials")
    func initialsPrefixScores() {
        let acronym = HomeSearchHaystack(
            title: "Attention Is All You Need", name: "x.pdf", location: "/tmp/x.pdf")
        #expect(HomeSearchRanker.fieldScore(acronym, token: "ai") == HomeSearchRanker.initialsPrefix)
        #expect(HomeSearchRanker.fieldScore(acronym, token: "aiay") == HomeSearchRanker.initialsPrefix)
        // …but only in order: "yai" is not how the title starts.
        #expect(HomeSearchRanker.fieldScore(acronym, token: "yai") == 0)
    }

    /// Regression: a general subsequence fallback used to live here, and it
    /// made "example" (from a pasted URL) match "…OxCaml to implement…" —
    /// a result with no visible reason for being in the list. Every match must
    /// be a real substring/prefix the user can see.
    @Test("Scattered letters are not a match")
    func noFuzzySubsequenceMatching() {
        let longTitle = HomeSearchHaystack(
            title: "Jane Street Blog — Using OxCaml to implement type-safe reference counting",
            name: "blog.janestreet.com",
            location: "https://blog.janestreet.com/oxcaml-typesafe-reference-counting")
        #expect(HomeSearchRanker.fieldScore(longTitle, token: "example") == 0)
        // The letters really are in there in order — that is exactly the trap.
        #expect(HomeSearchRanker.fieldScore(longTitle, token: "jnstr") == 0)
        // An anchored acronym is still fine: it is explainable.
        #expect(HomeSearchRanker.fieldScore(longTitle, token: "jsb") == HomeSearchRanker.initialsPrefix)
        // A genuine substring still matches.
        #expect(HomeSearchRanker.fieldScore(longTitle, token: "oxcaml") > 0)
    }
}

// MARK: - Recency

@Suite("Home search recency")
struct HomeSearchRecencyTests {
    @Test("Recency decays through fixed buckets")
    func buckets() {
        #expect(HomeSearchRanker.recencyBonus(for: daysAgo(0.2), now: now) == 120)
        #expect(HomeSearchRanker.recencyBonus(for: daysAgo(3), now: now) == 80)
        #expect(HomeSearchRanker.recencyBonus(for: daysAgo(20), now: now) == 40)
        #expect(HomeSearchRanker.recencyBonus(for: daysAgo(200), now: now) == 15)
        #expect(HomeSearchRanker.recencyBonus(for: daysAgo(900), now: now) == 0)
        #expect(HomeSearchRanker.recencyBonus(for: nil, now: now) == 0)
    }

    @Test("A far-future timestamp is not rewarded")
    func clockSkewIsNotRewarded() {
        #expect(HomeSearchRanker.recencyBonus(for: daysAgo(-30), now: now) == 0)
        // Within a day of "now" still counts as today, skew or not.
        #expect(HomeSearchRanker.recencyBonus(for: daysAgo(-0.5), now: now) == 120)
    }

    @Test("Recency breaks a tie between two equally good textual matches")
    func recencyBreaksTies() {
        let corpus = [
            item(id: "old", title: "Kalman Filters", date: daysAgo(400)),
            item(id: "new", title: "Kalman Filters", date: daysAgo(1)),
        ]
        #expect(rank(corpus, "kalman").map(\.id) == ["new", "old"])
    }

    @Test("Recency never outweighs a much better textual match")
    func textBeatsRecency() {
        let corpus = [
            item(id: "titled", title: "Kalman Filters", date: daysAgo(900)),
            item(
                id: "pathOnly", title: "Unrelated Notes",
                location: "/Users/reader/kalman/notes.pdf", date: daysAgo(0.1)),
        ]
        #expect(rank(corpus, "kalman").map(\.id) == ["titled", "pathOnly"])
    }
}

// MARK: - Matching semantics

@Suite("Home search matching")
struct HomeSearchMatchingTests {
    @Test("Every query token must match — more words narrows, never widens")
    func tokensAreAnded() {
        let corpus = [
            item(id: "both", title: "Attention Is All You Need"),
            item(id: "one", title: "Attention Economy"),
        ]
        #expect(rank(corpus, "attention").count == 2)
        #expect(rank(corpus, "attention need").map(\.id) == ["both"])
    }

    @Test("Tokens may land in different fields")
    func tokensMayMatchDifferentFields() {
        let corpus = [
            item(
                id: "split", title: "Deep Residual Learning", name: "resnet.pdf",
                location: "/Users/reader/vision/resnet.pdf")
        ]
        #expect(rank(corpus, "residual vision").map(\.id) == ["split"])
        #expect(rank(corpus, "residual nowhere").isEmpty)
    }

    /// Isolating the phrase bonus takes some care. The obvious version of this
    /// test — a short contiguous title against a long scattered one — passes
    /// whether or not the bonus exists, because the short title also wins on
    /// `titlePrefix` vs `titleWordPrefix`. Deleting `phraseBonus` outright left
    /// it green.
    ///
    /// So both fixtures below are built to score IDENTICALLY on every other
    /// axis: each matches both tokens as a word prefix (450 + 450) and neither
    /// has a date, which leaves contiguity as the only difference between them.
    /// The scattered title is also alphabetically first, so that if the bonus
    /// were removed the tie-break would actively reverse the expected order
    /// rather than happening to preserve it.
    @Test("A contiguous phrase outranks the same words scattered")
    func phraseBonus() {
        let contiguous = item(id: "phrase", title: "Attention Is All You Need")
        let scattered = item(id: "scattered", title: "A Need Not You")
        let tokens = HomeSearchText.tokens(in: "you need")

        let contiguousScore = HomeSearchRanker.score(contiguous, tokens: tokens, now: now)
        let scatteredScore = HomeSearchRanker.score(scattered, tokens: tokens, now: now)

        // Exactly the bonus apart — not merely "greater than", which a change
        // to any other weight could also satisfy.
        #expect(contiguousScore == (scatteredScore ?? 0) + HomeSearchRanker.phraseBonus)
        #expect(rank([scattered, contiguous], "you need").map(\.id) == ["phrase", "scattered"])
    }

    @Test("An acronym finds the paper")
    func acronymSearch() {
        let corpus = [
            item(id: "attention", title: "Attention Is All You Need"),
            item(id: "other", title: "Something Else Entirely"),
        ]
        #expect(rank(corpus, "aiayn").map(\.id) == ["attention"])
    }

    @Test("Search is diacritic- and case-insensitive")
    func foldedSearch() {
        let corpus = [item(id: "cv", title: "Résumé — 2026")]
        #expect(rank(corpus, "RESUME").map(\.id) == ["cv"])
    }

    @Test("A webpage is findable by its host")
    func hostSearch() {
        let corpus = [
            item(
                id: "post", section: .webpages, kind: .web,
                title: "Attention Is All You Need", name: "arxiv.org",
                location: "https://arxiv.org/abs/1706.03762")
        ]
        #expect(rank(corpus, "arxiv").map(\.id) == ["post"])
    }

    @Test("An empty or whitespace query browses instead of matching")
    func emptyQueryBrowses() {
        let corpus = [item(id: "a", title: "A"), item(id: "b", title: "B")]
        #expect(rank(corpus, "").count == 2)
        #expect(rank(corpus, "   ").count == 2)
    }

    @Test("A query nothing matches yields no sections at all")
    func noMatches() {
        let corpus = [item(id: "a", title: "Kalman Filters")]
        #expect(HomeSearchRanker.results(corpus: corpus, query: "xylophone", now: now).isEmpty)
    }

    /// A query made only of punctuation, symbols, or emoji folds away to zero
    /// tokens — but it is NOT an empty query. Browsing the whole library for it
    /// would contradict the screen's own chrome: the store still reports
    /// `isSearching`, so the bar reads "N results" and the top row is
    /// auto-selected, meaning ↩ would open an arbitrary document the user never
    /// searched for. Nothing was typed that any result visibly contains, so the
    /// honest answer is no matches.
    @Test(
        "A query that folds to zero tokens matches nothing rather than everything",
        arguments: ["???", "—", "🎉", "!!! ...", "· ·"])
    func unmatchableQueryIsNotABrowse(query: String) {
        let corpus = [item(id: "a", title: "Kalman Filters"), item(id: "b", title: "Attention")]
        #expect(HomeSearchRanker.results(corpus: corpus, query: query, now: now).isEmpty)
    }

    /// The counterpart to the above: genuinely blank input is still a browse,
    /// which is what makes the empty field show the library.
    @Test("Blank input still browses", arguments: ["", " ", "\n\t "])
    func blankQueryStillBrowses(query: String) {
        let corpus = [item(id: "a", title: "A"), item(id: "b", title: "B")]
        #expect(rank(corpus, query).count == 2)
    }

    /// A pathological paste must not be treated as a link and must not match
    /// everything; it should simply find nothing, quickly.
    @Test("A very long query narrows to nothing instead of matching everything")
    func veryLongQuery() {
        let corpus = [item(id: "a", title: "Kalman Filters")]
        let query = String(repeating: "kalman ", count: 2_000)
        // Every token is "kalman", which the title does contain, so this one
        // still matches — the point is that it terminates and stays correct.
        #expect(rank(corpus, query).map(\.id) == ["a"])
        #expect(rank(corpus, String(repeating: "z", count: 100_000)).isEmpty)
    }
}

// MARK: - Sections, filtering, ordering

@Suite("Home search sections")
struct HomeSearchSectionTests {
    private var mixed: [HomeSearchItem] {
        [
            item(id: "r1", section: .recents, title: "Recent Paper", date: daysAgo(1)),
            item(
                id: "w1", section: .webpages, kind: .web, title: "Saved Article",
                name: "example.com", location: "https://example.com/article", date: daysAgo(2)),
            item(id: "d1", section: .documents, title: "Library Paper", date: daysAgo(3)),
        ]
    }

    @Test("Browsing groups by section in the fixed section order")
    func browseSectionOrder() {
        let sections = HomeSearchRanker.results(corpus: mixed, query: "", now: now)
        #expect(sections.map(\.section) == [.recents, .documents, .webpages])
    }

    @Test("Searching puts the section holding the best hit first")
    func searchSectionOrderFollowsBestHit() {
        let sections = HomeSearchRanker.results(corpus: mixed, query: "saved", now: now)
        #expect(sections.first?.section == .webpages)
    }

    @Test("The kind filter drops the other kind entirely")
    func kindFilter() {
        #expect(rank(mixed, "", filter: .webpages).map(\.id) == ["w1"])
        #expect(rank(mixed, "", filter: .documents).map(\.id).sorted() == ["d1", "r1"])
        #expect(rank(mixed, "", filter: .all).count == 3)
    }

    /// "Saved" narrows by STATE, not kind, and it has to read the badge rather
    /// than the section: `HomeSearchEngine.deduplicated` merges a bookmarked
    /// page that is also a recent into a RECENTS row carrying the saved badge,
    /// and that row must still be reachable under this filter — otherwise
    /// reading an article makes it disappear from your saved shelf.
    @Test("The Saved filter follows the badge, wherever the row ended up")
    func savedFilter() {
        let corpus = [
            item(
                id: "r1", section: .recents, kind: .web, title: "Read And Saved",
                name: "a.test", location: "https://a.test/x", date: daysAgo(1),
                badges: [.saved, .offline]),
            item(
                id: "w1", section: .webpages, kind: .web, title: "Only Saved",
                name: "b.test", location: "https://b.test/y", date: daysAgo(2),
                badges: [.saved]),
            item(
                id: "w2", section: .webpages, kind: .web, title: "Merely Annotated",
                name: "c.test", location: "https://c.test/z", date: daysAgo(3),
                badges: [.notes]),
            item(id: "d1", section: .documents, title: "A PDF", date: daysAgo(4)),
        ]
        #expect(rank(corpus, "", filter: .saved).map(\.id).sorted() == ["r1", "w1"])
        // …and it composes with a query rather than replacing it.
        #expect(rank(corpus, "saved", filter: .saved).map(\.id) == ["r1", "w1"])
        // A webpage nobody bookmarked is not "saved" just because it is a page.
        #expect(!rank(corpus, "", filter: .saved).contains { $0.id == "w2" })
    }

    @Test("Browse sorting honours the sort order, with undated items last")
    func browseSorting() {
        let corpus = [
            item(id: "b", section: .documents, title: "Beta", date: daysAgo(10)),
            item(id: "a", section: .documents, title: "Alpha", date: daysAgo(1)),
            item(id: "z", section: .documents, title: "Zulu", date: nil),
        ]
        #expect(rank(corpus, "", sort: .recent).map(\.id) == ["a", "b", "z"])
        #expect(rank(corpus, "", sort: .name).map(\.id) == ["a", "b", "z"])

        let renamed = [
            item(id: "y", section: .documents, title: "Yankee", date: daysAgo(1)),
            item(id: "a", section: .documents, title: "Alpha", date: daysAgo(10)),
        ]
        #expect(rank(renamed, "", sort: .recent).map(\.id) == ["y", "a"])
        #expect(rank(renamed, "", sort: .name).map(\.id) == ["a", "y"])
    }

    @Test("Ordering is total, so identical items never reshuffle between runs")
    func orderingIsDeterministic() {
        let corpus = (1...20).map { index in
            item(id: "id\(index)", section: .documents, title: "Same Title", date: nil)
        }
        let first = rank(corpus, "same").map(\.id)
        let second = rank(corpus.reversed(), "same").map(\.id)
        #expect(first == second)
    }

    @Test("Results are capped at the limit")
    func limitCapsResults() {
        let corpus = (1...50).map { item(id: "id\($0)", title: "Paper \($0)") }
        #expect(rank(corpus, "paper", limit: 10).count == 10)
    }

    @Test("Recents lead on an otherwise exact tie")
    func recentsWinTies() {
        let stamp = daysAgo(5)
        let corpus = [
            item(id: "doc", section: .documents, title: "Overlap", date: stamp),
            item(id: "rec", section: .recents, title: "Overlap", date: stamp),
        ]
        #expect(rank(corpus, "overlap").first?.id == "rec")
    }
}

// MARK: - Pasted-link lookup

@Suite("Home search link lookup")
struct HomeSearchLinkLookupTests {
    private var library: [HomeSearchItem] {
        [
            item(
                id: "saved", section: .webpages, kind: .web, title: "The Article",
                name: "example.com", location: "https://www.example.com/article", date: daysAgo(3)),
            item(
                id: "other", section: .webpages, kind: .web, title: "Elsewhere",
                name: "other.test", location: "https://other.test/thing", date: daysAgo(3)),
            item(id: "pdf", section: .documents, title: "Some Paper", date: daysAgo(3)),
        ]
    }

    @Test("Pasting a URL finds the copy already in the library")
    func findsExistingCopy() {
        #expect(rank(library, "https://example.com/article").map(\.id) == ["saved"])
        // …however the two spellings differ on scheme, "www.", trailing slash.
        #expect(rank(library, "http://www.example.com/article/").map(\.id) == ["saved"])
    }

    @Test("A pasted site root finds the saved article beneath it, and vice versa")
    func partialOverlapMatches() {
        #expect(rank(library, "example.com").map(\.id) == ["saved"])
        #expect(rank(library, "https://example.com/article/section-2").map(\.id) == ["saved"])
    }

    @Test("A pasted URL is a lookup, not a bag of words")
    func linkIsNotTokenized() {
        // Regression: tokenizing turned "https" and "com" into query terms that
        // every webpage in the library matched, and the fuzzy fallback then
        // dragged in unrelated PDFs.
        #expect(rank(library, "https://nothing.test/nope").isEmpty)
        #expect(rank(library, "https://example.com/article").count == 1)
    }

    @Test("Link keys normalize scheme, www, and trailing slash")
    func linkKeyNormalization() {
        let expected = "example.com/a"
        #expect(HomeSearchRanker.linkKey("https://www.example.com/a/") == expected)
        #expect(HomeSearchRanker.linkKey("HTTP://Example.com/A") == expected)
        #expect(HomeSearchRanker.linkKey("example.com/a") == expected)
    }

    @Test("An exact link match outranks a merely overlapping one")
    func exactOutranksPartial() {
        let corpus = [
            item(
                id: "root", section: .webpages, kind: .web, title: "Root",
                name: "example.com", location: "https://example.com", date: daysAgo(3)),
            item(
                id: "exact", section: .webpages, kind: .web, title: "Exact",
                name: "example.com", location: "https://example.com/a", date: daysAgo(3)),
        ]
        #expect(rank(corpus, "https://example.com/a").map(\.id) == ["exact", "root"])
        #expect(HomeSearchRanker.linkExact > HomeSearchRanker.linkPartial)
    }
}

// MARK: - Link detection

@Suite("Home search link detection")
struct HomeSearchLinkDetectorTests {
    @Test(
        "Explicit and implicit links are recognized",
        arguments: [
            "https://arxiv.org/abs/1706.03762",
            "http://example.com",
            "example.com",
            "www.notes.md",
            "arxiv.org/abs/1706.03762",
            "sub.domain.co.uk/path?q=1",
        ])
    func recognizesLinks(_ candidate: String) {
        #expect(HomeSearchLinkDetector.url(in: candidate) == candidate)
    }

    @Test(
        "Searches are not mistaken for links",
        arguments: [
            "",
            "   ",
            "attention is all you need",
            "notes.md",
            "report.pdf",
            "archive.zip",
            "/Users/reader/paper.pdf",
            "mailto:someone@example.com",
            "file:///tmp/x.pdf",
            "justaword",
            "trailing.",
            ".leading",
            "no.1",
        ])
    func rejectsNonLinks(_ candidate: String) {
        #expect(HomeSearchLinkDetector.url(in: candidate) == nil)
    }

    @Test("Surrounding whitespace is trimmed off a pasted link")
    func trimsPastedLink() {
        #expect(HomeSearchLinkDetector.url(in: "  https://example.com/a  ") == "https://example.com/a")
    }
}

// MARK: - Date labels

@Suite("Home search date labels")
struct HomeSearchDateLabelTests {
    // `Calendar.isDateInToday` is relative to the WALL CLOCK, not to the `now`
    // argument, so these anchor on the real current date rather than the fixed
    // `now` the ranking tests use.
    private let today = Date()
    private let calendar = Calendar.current

    @Test("Near dates read as words")
    func nearDates() {
        #expect(HomeSearchDateLabel.short(for: today, now: today, calendar: calendar) == "Today")
        let yesterday = calendar.date(byAdding: .day, value: -1, to: today)
        #expect(
            HomeSearchDateLabel.short(for: yesterday, now: today, calendar: calendar) == "Yesterday")
    }

    @Test("A missing date renders as nothing at all, not a placeholder")
    func missingDate() {
        #expect(HomeSearchDateLabel.short(for: nil, now: today, calendar: calendar).isEmpty)
    }

    @Test("Distant dates fall back to a real date")
    func distantDates() {
        let old = calendar.date(byAdding: .day, value: -800, to: today)
        let label = HomeSearchDateLabel.short(for: old, now: today, calendar: calendar)
        #expect(!label.isEmpty)
        #expect(label != "Today")
        #expect(label != "Yesterday")
        // Two years back must carry the year — "12 Mar" alone would be a lie.
        let year = calendar.component(.year, from: old ?? today)
        #expect(label.contains(String(year)))
    }
}
