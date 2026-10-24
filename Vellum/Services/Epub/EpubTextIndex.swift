import Foundation

struct EpubChapterMetadata: Codable, Equatable, Sendable {
    let chapterNumber: Int
    let chapterHref: String
    let title: String

    enum CodingKeys: String, CodingKey {
        case chapterNumber = "chapter_number"
        case chapterHref = "chapter_href"
        case title
    }
}

struct EpubSearchResult: Codable, Equatable, Sendable {
    let chapterNumber: Int
    let chapterTitle: String
    let snippet: String
    let anchor: EpubTextAnchor

    enum CodingKeys: String, CodingKey {
        case chapterNumber = "chapter_number"
        case chapterTitle = "chapter_title"
        case snippet, anchor
    }
}

struct EpubSearchResponse: Codable, Equatable, Sendable {
    let results: [EpubSearchResult]
    let chaptersSearched: Int
    /// True when a chapter, result, or total-effort cap could hide additional matches.
    let truncated: Bool

    enum CodingKeys: String, CodingKey {
        case results, truncated
        case chaptersSearched = "chapters_searched"
    }
}

/// Bounded, lazy normalized-text cache. All archive reads, extraction, anchor
/// resolution and search execute on this actor, never on the UI actor.
actor EpubTextIndex {
    struct Limits: Sendable {
        var maxChapters = 256
        var maxResults = 500
        var maxTotalUTF16 = 16 * 1024 * 1024
        var maxTotalInputBytes = 64 * 1024 * 1024
        var maxCachedChapters = 4
        var maxCachedUTF16 = 4 * 1024 * 1024
    }

    private struct Cached {
        let chapter: EpubChapterText
        let inputBytes: Int
    }

    private let book: EpubBook
    private let limits: Limits
    private var cache: [Int: Cached] = [:]
    private var recency: [Int] = []
    private var cachedUTF16 = 0
    private var titles: [String: String]?
    private var closed = false

    init(book: EpubBook, limits: Limits = Limits()) {
        self.book = book
        self.limits = limits
    }

    func chapter(spineIndex: Int) throws -> EpubChapterText {
        try load(spineIndex).chapter
    }

    func metadata() throws -> [EpubChapterMetadata] {
        try checkOpen()
        return try book.publication.spine.enumerated().map { index, item in
            try checkOpen()
            return EpubChapterMetadata(
                chapterNumber: index + 1, chapterHref: item.path,
                title: try title(for: index))
        }
    }

    func resolve(_ anchor: EpubTextAnchor, validatingRange: Bool = false) throws -> EpubTextAnchor? {
        try checkOpen()
        guard let index = book.publication.spineIndex(path: anchor.chapterHref) else { return nil }
        let chapter = try load(index).chapter
        if validatingRange, let start = anchor.startUTF16, let end = anchor.endUTF16 {
            guard start >= 0, end > start, end <= chapter.utf16Count,
                chapter.quote(in: NSRange(location: start, length: end - start)) != nil else { return nil }
        }
        guard let range = chapter.resolve(anchor) else { return nil }
        try Task.checkCancellation()
        return chapter.anchor(in: range)
    }

    func search(query: String, limit: Int = 100) throws -> EpubSearchResponse {
        try checkOpen()
        guard query.utf16.count <= 4096 else { throw EpubTextError.limitExceeded("query UTF-16") }
        let query = EpubTextExtractor.normalizeWhitespace(query)
        let resultLimit = min(max(0, limit), max(0, limits.maxResults), 500)
        guard !query.isEmpty, resultLimit > 0 else {
            return EpubSearchResponse(
                results: [], chaptersSearched: 0, truncated: !query.isEmpty && !book.publication.spine.isEmpty)
        }
        let chapterLimit = min(book.publication.spine.count, max(0, limits.maxChapters), 256)
        let textLimit = min(max(0, limits.maxTotalUTF16), 16 * 1024 * 1024)
        let inputLimit = min(max(0, limits.maxTotalInputBytes), 64 * 1024 * 1024)
        var results: [EpubSearchResult] = []
        var searched = 0
        var totalText = 0
        var totalInput = 0
        var truncated = false
        for index in 0..<chapterLimit {
            try checkOpen()
            guard totalText < textLimit, totalInput < inputLimit else { break }
            let loaded: Cached
            do {
                loaded = try load(index, inputBudget: inputLimit - totalInput, textBudget: textLimit - totalText)
            } catch EpubTextError.limitExceeded(let reason) where reason == "text UTF-16" {
                break
            } catch EpubError.resourceTooLarge where inputLimit - totalInput < 8 * 1024 * 1024 {
                break
            }
            guard loaded.chapter.utf16Count <= textLimit - totalText,
                loaded.inputBytes <= inputLimit - totalInput else { break }
            totalText += loaded.chapter.utf16Count
            totalInput += loaded.inputBytes
            searched += 1
            let remaining = resultLimit - results.count
            let anchors = try loaded.chapter.search(query, limit: min(200, remaining + 1))
            for anchor in anchors.prefix(remaining) {
                results.append(EpubSearchResult(
                    chapterNumber: index + 1, chapterTitle: try title(for: index),
                    snippet: anchor.prefix + anchor.quote + anchor.suffix, anchor: anchor))
            }
            if anchors.count == 200 { truncated = true }
            if results.count == resultLimit {
                return EpubSearchResponse(results: results, chaptersSearched: searched, truncated: true)
            }
        }
        try checkOpen()
        return EpubSearchResponse(
            results: results, chaptersSearched: searched,
            truncated: truncated || searched < book.publication.spine.count)
    }

    func close() {
        closed = true
        cache.removeAll()
        recency.removeAll()
        cachedUTF16 = 0
        titles = nil
    }

    private func load(
        _ index: Int, inputBudget: Int = 8 * 1024 * 1024, textBudget: Int = 2 * 1024 * 1024
    ) throws -> Cached {
        try checkOpen()
        guard book.publication.spine.indices.contains(index) else { throw EpubAnnotationError.invalidChapter }
        if let value = cache[index] {
            recency.removeAll { $0 == index }
            recency.append(index)
            return value
        }
        let href = book.publication.spine[index].path
        var extraction = EpubTextExtractor.Limits.standard
        extraction.maxInputBytes = min(extraction.maxInputBytes, inputBudget)
        extraction.maxTextUTF16 = min(extraction.maxTextUTF16, textBudget)
        let bytes = try book.container.data(at: href, maxSize: UInt64(extraction.maxInputBytes))
        let chapter = try EpubTextExtractor.extract(xhtml: bytes, chapterHref: href, limits: extraction)
        try checkOpen()
        let value = Cached(chapter: chapter, inputBytes: bytes.count)
        let cacheCount = min(max(0, limits.maxCachedChapters), 4)
        let cacheSize = min(max(0, limits.maxCachedUTF16), 4 * 1024 * 1024)
        if cacheCount > 0, chapter.utf16Count <= cacheSize {
            while !recency.isEmpty, cache.count >= cacheCount || cachedUTF16 > cacheSize - chapter.utf16Count {
                let oldest = recency.removeFirst()
                cachedUTF16 -= cache.removeValue(forKey: oldest)?.chapter.utf16Count ?? 0
            }
            cache[index] = value
            recency.append(index)
            cachedUTF16 += chapter.utf16Count
        }
        return value
    }

    private func checkOpen() throws {
        try Task.checkCancellation()
        guard !closed else { throw CancellationError() }
    }

    private func title(for index: Int) throws -> String {
        if titles == nil {
            var lookup: [String: String] = [:]
            try Self.collectTitles(book.publication.toc, into: &lookup)
            titles = lookup
        }
        return titles?[book.publication.spine[index].path] ?? "Chapter \(index + 1)"
    }

    private static func collectTitles(_ entries: [EpubPublication.TocEntry], into lookup: inout [String: String]) throws {
        for entry in entries {
            try Task.checkCancellation()
            if let path = entry.path, lookup[path] == nil { lookup[path] = entry.title }
            try collectTitles(entry.children, into: &lookup)
        }
    }
}
