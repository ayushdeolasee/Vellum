import Foundation

// The home screen's search corpus.
//
// Everything the app can open — a recently opened document, a saved webpage, a
// document that carries notes/chat in the library, and (later) an article from
// a connected read-later service — is normalized into one `HomeSearchItem`. The
// point is that the user should not have to know WHICH list a thing lives in:
// they type a few letters and every source is ranked against the same query.
//
// Deliberately free of any SwiftUI/AppKit reference and fully `Sendable`: the
// corpus is built and matched on `HomeSearchEngine` (an actor, off the main
// thread) and only the finished, ranked sections cross back to the main actor.

/// Which shelf a result belongs to. The raw values double as the on-screen
/// section order when browsing (search mode re-orders by best score).
enum HomeSearchSection: Int, Hashable, Sendable, CaseIterable, Comparable {
    case recents
    case documents
    case webpages
    case readLater

    static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }

    var title: String {
        switch self {
        case .recents: "Recents"
        case .documents: "Documents"
        case .webpages: "Webpages"
        case .readLater: "Read Later"
        }
    }

    /// Section-header glyph. Kept to the same SF Symbols vocabulary the rest of
    /// the chrome uses (`doc.text` / `globe` for the two document kinds).
    var systemImage: String {
        switch self {
        case .recents: "clock"
        case .documents: "doc.text"
        case .webpages: "globe"
        case .readLater: "bookmark"
        }
    }
}

/// What opening a result actually does. Mirrors the two entry points the
/// welcome screen has always had (`AppStore.openFile(path:)` / `openUrl(_:)`).
enum HomeSearchTarget: Hashable, Sendable {
    /// A file on disk. `recordedPath` is the path exactly as the recents list
    /// stored it, which differs from `path` when a moved PDF was re-resolved
    /// through its docId — the opener drops the stale entry first so the
    /// re-record on a successful open cannot leave a duplicate (design §7, the
    /// behavior the previous library rows had).
    case file(path: String, recordedPath: String)
    case url(String)

    /// The string handed to `AppStore` to open this target.
    var openKey: String {
        switch self {
        case .file(let path, _): path
        case .url(let url): url
        }
    }
}

/// Small status flags rendered as trailing glyphs on a result row. An OptionSet
/// rather than a bag of Bools so a row can carry several without the item type
/// growing a flag per source.
struct HomeSearchBadges: OptionSet, Hashable, Sendable {
    let rawValue: Int

    /// The user explicitly saved this webpage to the library.
    static let saved = HomeSearchBadges(rawValue: 1 << 0)
    /// A local snapshot exists, so the page opens without a network round trip.
    static let offline = HomeSearchBadges(rawValue: 1 << 1)
    /// The document has notes and/or an AI conversation attached.
    static let notes = HomeSearchBadges(rawValue: 1 << 2)
    /// A PDF whose file is no longer where we last saw it.
    static let missing = HomeSearchBadges(rawValue: 1 << 3)
}

/// Pre-folded text for one item, computed once when the corpus is built so a
/// keystroke never re-lowercases the whole library. Split into fields rather
/// than one blob because WHERE a token matches is most of the relevance signal:
/// "swift" in a title means something very different from "swift" buried in a
/// file path.
struct HomeSearchHaystack: Hashable, Sendable {
    /// The display title, folded.
    let title: String
    /// First letter of each title word ("Attention Is All You Need" → "aiayn"),
    /// so an acronym the user remembers finds the document.
    let initials: String
    /// The short name: a PDF's filename, or a webpage's host.
    let name: String
    /// The full locator: absolute path or full URL.
    let location: String
    /// Anything else cheap and worth matching (page counts, source name).
    let extra: String

    init(title: String, name: String, location: String, extra: String = "") {
        let foldedTitle = HomeSearchText.fold(title)
        self.title = foldedTitle
        initials = HomeSearchText.initials(ofFolded: foldedTitle)
        self.name = HomeSearchText.fold(name)
        self.location = HomeSearchText.fold(location)
        self.extra = HomeSearchText.fold(extra)
    }
}

/// One openable thing, normalized across every source.
struct HomeSearchItem: Identifiable, Hashable, Sendable {
    /// Unique within the corpus: `"<providerId>:<identity>"`.
    let id: String
    /// Cross-provider dedupe key — the resolved file path for PDFs, the URL for
    /// webpages. The same document reached through two sources (a recent that
    /// is also a saved page) collapses to one row so results never stutter.
    let identity: String
    let section: HomeSearchSection
    let kind: DocumentKind
    let target: HomeSearchTarget
    /// Primary line: the document's own title when it has one.
    let title: String
    /// Secondary line: filename for PDFs, host + path for webpages.
    let subtitle: String
    /// Trailing metadata line ("12 pages · Yesterday").
    let detail: String
    /// Full-fidelity tooltip (the absolute path / URL).
    let tooltip: String
    /// When this was last opened or saved — drives recency sort and the
    /// relevance recency boost. Nil when no source could supply one.
    let date: Date?
    /// The only mutable field, and only for one reason: when two providers
    /// describe the same document, `HomeSearchEngine.deduplicated` keeps the
    /// higher-priority row and UNIONS the badges of the ones it discards. A
    /// recently opened article that is also bookmarked and also carries notes
    /// is one row that says all three things, rather than the recents row
    /// silently losing what the other sources knew about it.
    var badges: HomeSearchBadges
    let canRevealInFinder: Bool
    let haystack: HomeSearchHaystack
    /// The `documents/<key>/` folder this item's `meta.json` lives under, when
    /// the source knows it. Renaming needs it and cannot re-derive it: for a
    /// PDF the key is the stamped `/VellumDocId` when there is one, which only
    /// the recents record and the library folder actually know. Nil for a
    /// remote read-later result, which has no local metadata to write.
    ///
    /// A `var` with a default so the three providers can opt in without every
    /// test fixture in the suite having to name it.
    var storageKey: String?

    /// Row glyph, matching the icons the previous welcome list used.
    var systemImage: String { kind == .web ? "globe" : "doc.text" }
}

// MARK: - Link detection

/// Recognizes a query that is really a link the user pasted, so the search
/// field can double as the URL bar.
///
/// Deliberately conservative but never destructive: a hit only ADDS a pinned
/// "open this webpage" row above the results, so a false positive costs one
/// extra row and a false negative costs nothing (⌘L and the Open buttons are
/// still there). That framing is what lets the rules stay simple.
enum HomeSearchLinkDetector {
    /// Bare `name.ext` tokens that are far more likely to be a filename the
    /// user is searching for than a hostname they want to visit.
    private static let documentExtensions: Set<String> = [
        "pdf", "md", "txt", "rtf", "doc", "docx", "epub", "html", "htm", "json",
        "png", "jpg", "jpeg", "gif", "svg", "zip", "vellum", "vellumweb",
    ]

    static func url(in query: String) -> String? {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.contains(where: \.isWhitespace) else { return nil }
        let lower = trimmed.lowercased()

        if lower.hasPrefix("http://") || lower.hasPrefix("https://") {
            // A scheme is an unambiguous statement of intent — accept as long as
            // there is actually a host after it.
            guard let host = URL(string: trimmed)?.host, !host.isEmpty else { return nil }
            return trimmed
        }
        // Any other scheme (file:, mailto:, javascript:) is not ours to open.
        // A bare colon is enough to disqualify: "mailto:a@example.com" has no
        // "://" but is still not a page, and a schemeless host:port is rare
        // enough that refusing it only costs the pinned row.
        guard !lower.contains(":"), !lower.contains("@"), !lower.hasPrefix("/") else { return nil }

        // Split host from path: "arxiv.org/abs/1706.03762" → "arxiv.org".
        let host = lower.split(separator: "/", maxSplits: 1).first.map(String.init) ?? lower
        guard let dot = host.lastIndex(of: "."), host.first != ".", !host.hasSuffix(".") else {
            return nil
        }
        let tld = String(host[host.index(after: dot)...])
        guard tld.count >= 2, tld.allSatisfy(\.isLetter) else { return nil }
        // The label before the dot has to be a real label, not "".
        guard host.dropLast(tld.count + 1).contains(where: { $0.isLetter || $0.isNumber }) else {
            return nil
        }
        // "notes.md" is a search, not a destination — unless a path or a www.
        // prefix makes the intent explicit.
        if documentExtensions.contains(tld),
           !lower.contains("/"), !lower.hasPrefix("www.") {
            return nil
        }
        return trimmed
    }
}

// MARK: - Date labels

/// The compact, right-aligned date column on a result row. Recent dates read as
/// words ("Today", "Tuesday") because that is how people remember when they
/// last touched something; anything older falls back to a real date, dropping
/// the year while it is still the current one.
///
/// Uses `Date.FormatStyle` rather than a cached `DateFormatter` so it is safe to
/// call from the background corpus build without a `nonisolated(unsafe)` static.
enum HomeSearchDateLabel {
    static func short(for date: Date?, now: Date = Date(), calendar: Calendar = .current) -> String {
        guard let date else { return "" }
        if calendar.isDateInToday(date) { return "Today" }
        if calendar.isDateInYesterday(date) { return "Yesterday" }
        let days = calendar.dateComponents([.day], from: date, to: now).day ?? 0
        if days > 0, days < 7 { return date.formatted(.dateTime.weekday(.wide)) }
        if calendar.isDate(date, equalTo: now, toGranularity: .year) {
            return date.formatted(.dateTime.day().month(.abbreviated))
        }
        return date.formatted(.dateTime.day().month(.abbreviated).year())
    }
}

// MARK: - Text folding

/// Case- and diacritic-insensitive text handling shared by the corpus builder
/// and the ranker. Both sides MUST fold identically or a query would never
/// match its own index, so the folding lives in exactly one place.
enum HomeSearchText {
    /// Fold to the canonical (locale-independent) case- and diacritic-free
    /// form. `locale: nil` asks for the canonical mapping rather than a
    /// locale-sensitive one — the corpus must not re-index when the user's
    /// region changes, and the Turkish dotless-i rule would otherwise make
    /// "I" stop matching "index" for tr_TR users.
    static func fold(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive],
                     locale: nil)
    }

    /// Split an already-folded string into word runs on anything that is not a
    /// letter or a digit, so "read-later_v2.pdf" yields read/later/v2/pdf.
    static func words(inFolded text: String) -> [Substring] {
        text.split(whereSeparator: { !$0.isLetter && !$0.isNumber })
    }

    /// First character of each word of an already-folded title.
    static func initials(ofFolded title: String) -> String {
        String(words(inFolded: title).compactMap(\.first))
    }

    /// Split a raw user query into folded, non-empty search tokens. Every token
    /// must match for an item to qualify, which is what makes "att need" behave
    /// the way people expect.
    static func tokens(in query: String) -> [String] {
        words(inFolded: fold(query)).map(String.init)
    }

    /// Does any word of `text` start with `token`? This is the match people
    /// mean by "starts with" — "need" should find "Attention Is All You Need"
    /// even though the title does not begin with it.
    static func hasWordPrefix(_ text: String, _ token: String) -> Bool {
        words(inFolded: text).contains { $0.hasPrefix(token) }
    }
}
