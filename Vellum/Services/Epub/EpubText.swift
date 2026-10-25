import Foundation

/// One chapter only; no DOM, resources, or whole-book cache is retained.
struct EpubChapterText: Hashable, Sendable {
    let chapterHref: String
    let text: String

    var utf16Count: Int { text.utf16.count }

    func quote(in range: NSRange) -> String? {
        let source = text as NSString
        guard Self.valid(range, in: source) else { return nil }
        return source.substring(with: range)
    }

    func anchor(in range: NSRange, contextUTF16: Int = 32) -> EpubTextAnchor? {
        let source = text as NSString
        guard range.length > 0, Self.valid(range, in: source) else { return nil }
        let end = range.location + range.length
        let context = min(max(0, contextUTF16), 256)
        var before = max(0, range.location - context)
        var after = end + min(context, source.length - end)
        if !Self.boundary(before, in: source) { before += 1 }
        if !Self.boundary(after, in: source) { after -= 1 }
        return EpubTextAnchor(
            chapterHref: chapterHref, quote: source.substring(with: range),
            prefix: source.substring(with: NSRange(location: before, length: range.location - before)),
            suffix: source.substring(with: NSRange(location: end, length: after - end)),
            startUTF16: range.location, endUTF16: end)
    }

    /// Exact, case-sensitive and Unicode-literal. Never chooses the first duplicate.
    func resolve(_ anchor: EpubTextAnchor) -> NSRange? {
        guard anchor.chapterHref == chapterHref, !anchor.quote.isEmpty else { return nil }
        let source = text as NSString
        if let start = anchor.startUTF16, let end = anchor.endUTF16,
            start >= 0, end >= start, end <= source.length
        {
            let range = NSRange(location: start, length: end - start)
            if Self.matches(anchor.quote, range: range, in: source) { return range }
        }
        var resolved: NSRange?
        var cursor = 0
        while cursor < source.length {
            let match = source.range(
                of: anchor.quote, options: .literal,
                range: NSRange(location: cursor, length: source.length - cursor))
            guard match.location != NSNotFound else { break }
            let end = match.location + match.length
            let prefixLength = anchor.prefix.utf16.count
            let suffixLength = anchor.suffix.utf16.count
            if Self.valid(match, in: source), prefixLength <= match.location,
                suffixLength <= source.length - end,
                Self.matches(
                    anchor.prefix,
                    range: NSRange(location: match.location - prefixLength, length: prefixLength), in: source),
                Self.matches(anchor.suffix, range: NSRange(location: end, length: suffixLength), in: source)
            {
                if resolved != nil { return nil }
                resolved = match
            }
            cursor = match.location + 1  // Include overlapping occurrences in ambiguity checks.
        }
        return resolved
    }

    /// Literal normalized-text search, capped at 200 matches per chapter.
    func search(_ query: String, limit: Int = 50) throws -> [EpubTextAnchor] {
        let query = EpubTextExtractor.normalizeWhitespace(query)
        guard !query.isEmpty, limit > 0 else { return [] }
        let source = text as NSString
        var results: [EpubTextAnchor] = []
        var cursor = 0
        while cursor < source.length, results.count < min(limit, 200) {
            try Task.checkCancellation()
            let match = source.range(
                of: query, options: .literal,
                range: NSRange(location: cursor, length: source.length - cursor))
            guard match.location != NSNotFound else { break }
            if let anchor = anchor(in: match) { results.append(anchor) }
            cursor = match.location + max(1, match.length)
        }
        return results
    }

    private static func matches(_ quote: String, range: NSRange, in source: NSString) -> Bool {
        valid(range, in: source) && range.length == quote.utf16.count
            && source.compare(quote, options: .literal, range: range) == .orderedSame
    }

    private static func valid(_ range: NSRange, in source: NSString) -> Bool {
        range.location >= 0 && range.location <= source.length && range.length >= 0
            && range.length <= source.length - range.location && boundary(range.location, in: source)
            && boundary(range.location + range.length, in: source)
    }

    private static func boundary(_ offset: Int, in source: NSString) -> Bool {
        guard offset > 0, offset < source.length else { return true }
        return !(0xD800...0xDBFF).contains(source.character(at: offset - 1))
            || !(0xDC00...0xDFFF).contains(source.character(at: offset))
    }
}

/// Actor entry point: archive I/O and parsing execute off the main actor.
/// Calls are awaited directly; there are no detached or unowned task handles.
actor EpubTextWorker {
    func chapter(
        container: EpubContainer, chapterHref: String,
        limits: EpubTextExtractor.Limits = .standard
    ) throws -> EpubChapterText {
        try Task.checkCancellation()
        guard limits.maxInputBytes > 0 else { throw EpubTextError.limitExceeded("input bytes") }
        let data = try container.data(at: chapterHref, maxSize: UInt64(limits.maxInputBytes))
        return try EpubTextExtractor.extract(xhtml: data, chapterHref: chapterHref, limits: limits)
    }

    func extract(
        xhtml: Data, chapterHref: String,
        limits: EpubTextExtractor.Limits = .standard
    ) throws -> EpubChapterText {
        try EpubTextExtractor.extract(xhtml: xhtml, chapterHref: chapterHref, limits: limits)
    }

    func search(
        container: EpubContainer, chapterHref: String, query: String, limit: Int = 50,
        limits: EpubTextExtractor.Limits = .standard
    ) throws -> [EpubTextAnchor] {
        try chapter(container: container, chapterHref: chapterHref, limits: limits).search(query, limit: limit)
    }

    func quote(
        container: EpubContainer, anchor: EpubTextAnchor,
        limits: EpubTextExtractor.Limits = .standard
    ) throws -> String? {
        let chapter = try chapter(container: container, chapterHref: anchor.chapterHref, limits: limits)
        guard let range = chapter.resolve(anchor) else { return nil }
        return chapter.quote(in: range)
    }
}
