import Foundation

/// Pre-folded text for one item, computed once when the corpus is built so a
/// keystroke never re-lowercases the whole library. Split into fields rather
/// than one blob because WHERE a token matches is most of the relevance signal:
/// "swift" in a title means something very different from "swift" buried in a
/// file path.
public struct HomeSearchHaystack: Hashable, Sendable {
    /// The display title, folded.
    public let title: String
    /// First letter of each title word ("Attention Is All You Need" → "aiayn"),
    /// so an acronym the user remembers finds the document.
    public let initials: String
    /// The short name: a PDF's filename, or a webpage's host.
    public let name: String
    /// The full locator: absolute path or full URL.
    public let location: String
    /// Anything else cheap and worth matching (page counts, source name).
    public let extra: String

    public init(title: String, name: String, location: String, extra: String = "") {
        let foldedTitle = HomeSearchText.fold(title)
        self.title = foldedTitle
        initials = HomeSearchText.initials(ofFolded: foldedTitle)
        self.name = HomeSearchText.fold(name)
        self.location = HomeSearchText.fold(location)
        self.extra = HomeSearchText.fold(extra)
    }
}

// MARK: - Text folding

/// Case- and diacritic-insensitive text handling shared by the corpus builder
/// and the ranker. Both sides MUST fold identically or a query would never
/// match its own index, so the folding lives in exactly one place.
public enum HomeSearchText {
    /// Fold to the canonical (locale-independent) case- and diacritic-free
    /// form. `locale: nil` asks for the canonical mapping rather than a
    /// locale-sensitive one — the corpus must not re-index when the user's
    /// region changes, and the Turkish dotless-i rule would otherwise make
    /// "I" stop matching "index" for tr_TR users.
    public static func fold(_ text: String) -> String {
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
    public static func tokens(in query: String) -> [String] {
        words(inFolded: fold(query)).map(String.init)
    }

    /// Does any word of `text` start with `token`? This is the match people
    /// mean by "starts with" — "need" should find "Attention Is All You Need"
    /// even though the title does not begin with it.
    public static func hasWordPrefix(_ text: String, _ token: String) -> Bool {
        words(inFolded: text).contains { $0.hasPrefix(token) }
    }
}

/// Text relevance shared by the Apple home screen and the Linux library.
public enum HomeSearchRanker {
    // MARK: - Score weights
    //
    // Absolute values are arbitrary; only their ORDER matters, and the order
    // encodes one rule: a match in a name the user chose (title, filename,
    // host) beats a match in machinery they never see (a deep folder path, a
    // query string). Kept as named constants so a test can assert the ordering
    // rather than a magic number.

    public static let titleExact = 1000
    public static let titlePrefix = 600
    public static let titleWordPrefix = 450
    public static let namePrefix = 400
    public static let titleSubstring = 300
    public static let initialsPrefix = 280
    public static let nameSubstring = 220
    public static let locationSubstring = 140
    public static let extraSubstring = 90

    /// Awarded once when a multi-token query appears contiguously in the title,
    /// so "all you need" outranks an item that merely contains all three words
    /// scattered.
    public static let phraseBonus = 250

    // Deliberately NO general subsequence/fuzzy fallback. It was tried and cut:
    // on a long title almost any short token matches as a subsequence ("example"
    // is one of "…OxCaml to implement…"), which fills the list with results the
    // user cannot see the reason for. Every result must visibly contain what was
    // typed. The one fuzzy affordance that survives is the initials match, which
    // is anchored and therefore explainable.

    /// Score one item against pre-tokenized query terms, or nil when the item
    /// does not match. EVERY token must land somewhere (an AND, not an OR):
    /// typing more words must narrow the list, never widen it.
    public static func score(_ haystack: HomeSearchHaystack, tokens: [String]) -> Int? {
        guard !tokens.isEmpty else { return nil }
        var total = 0
        for token in tokens {
            let best = fieldScore(haystack, token: token)
            guard best > 0 else { return nil }
            total += best
        }
        if tokens.count > 1 {
            // The tokens are folded and split on non-alphanumerics, so rejoining
            // them with single spaces is the normalized phrase — it matches the
            // folded title's own spacing.
            let phrase = tokens.joined(separator: " ")
            if haystack.title.contains(phrase) { total += phraseBonus }
        }
        return total
    }

    /// The best score any single field yields for one token. Ordered cheapest-
    /// and-strongest first, with early exits so a title-prefix hit never pays
    /// for a path scan.
    public static func fieldScore(_ haystack: HomeSearchHaystack, token: String) -> Int {
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
}
