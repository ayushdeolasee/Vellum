import Foundation

struct AiToolArguments: Codable, Sendable {
    var pageNumber: Double?
    var text: String?
    var color: String?
    var x: Double?
    var y: Double?
    /// Legacy tool argument: true is rejected with guidance to use literal text.
    var isRegex: Bool?
    var epubAnchor: EpubTextAnchor? = nil

    static func decodeEpubAnchor(_ value: Any?) -> EpubTextAnchor? {
        guard let value, JSONSerialization.isValidJSONObject(value),
              let data = try? JSONSerialization.data(withJSONObject: value), data.count <= 32_768
        else { return nil }
        return try? JSONDecoder().decode(EpubTextAnchor.self, from: data)
    }

    static var epubAnchorSchema: [String: Any] { [
        "type": "object",
        "description": "EPUB only: exact chapter/passage anchor from context or search. Required for notes; optional for highlights and passage navigation. Never invent offsets.",
        "properties": [
            "chapter_href": ["type": "string"], "quote": ["type": "string"],
            "prefix": ["type": "string"], "suffix": ["type": "string"],
            "start_utf16": ["type": "integer"], "end_utf16": ["type": "integer"],
        ],
        "required": ["chapter_href", "quote", "prefix", "suffix"],
        "additionalProperties": false,
    ] }
}

struct AiToolAction: Codable, Sendable {
    var tool: String
    var args: AiToolArguments
}

@MainActor
struct AiEpubToolContext {
    let metadata: () async throws -> [EpubChapterMetadata]
    let chapter: (Int) async throws -> EpubChapterText
    let search: (String, Int) async throws -> EpubSearchResponse
    let resolve: (EpubTextAnchor) async throws -> EpubTextAnchor?
    let navigate: (AiEpubCitation) -> Void
}

/// Model-only EPUB read result. Persisted summaries retain only bounded locators/excerpts.
struct AiEpubToolResult: Codable, Sendable {
    var detail: String
    var text: String? = nil
    var sources: [AiEpubCitation] = []
    var chaptersSearched: Int? = nil
    var truncated: Bool

    func json() throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return String(decoding: try encoder.encode(self), as: UTF8.self)
    }
}

/// Immutable document authority and captured services for one provider turn.
@MainActor
struct AiToolExecutionContext {
    let binding: DocumentBinding
    let document: DocumentInfo
    let currentPage: Int
    let pageCount: Int
    let pageTexts: [Int: String]
    let annotations: [Annotation]
    let isCurrent: () -> Bool
    let setActivity: (AiActivity) -> Void
    let extract: (Set<Int>?) async throws -> [Int: String]
    let locate: (Int, String) async -> LocatedText?
    let createAnnotation: (CreateAnnotationInput) async throws -> Annotation
    let navigate: (Int) -> Void
    var epub: AiEpubToolContext? = nil

    func checkCurrent() throws {
        guard !Task.isCancelled, isCurrent() else { throw CancellationError() }
    }
}

@MainActor
final class AiToolEngine {
    /// Writes mutate the document/viewport (`goToPage`/`addNote`/`addHighlight`)
    /// and keep the original tight cap. Reads (`searchDocument`/`getPageText`)
    /// are free in-memory lookups, so they get a looser budget — a
    /// search→read→answer chain must fit without starving the write budget.
    static let maxWrites = 5
    static let maxReads = 16
    static let defaultPageWidth = 612.0
    static let defaultPageHeight = 792.0

    /// Tools that only read already-extracted text or in-memory annotations;
    /// budgeted separately from writes and never counted against the write cap.
    private static let readTools: Set<String> = ["searchDocument", "getPageText", "getAnnotations"]

    private let context: AiToolExecutionContext
    private var pageTexts: [Int: String]
    private var annotations: [Annotation]

    /// Per-request counters (a fresh engine is created for every `sendMessage`).
    private var writeCount = 0
    private var readCount = 0
    private var epubSummary: AiToolSummary?

    /// Structured, compact summaries of what ran. Raw tool results remain
    /// model-only; the transcript receives only short excerpts and page locators.
    private(set) var displayActions: [AiToolSummary] = []

    init(context: AiToolExecutionContext) {
        self.context = context
        pageTexts = context.pageTexts
        annotations = context.annotations
    }

    // `actionCount` is retained for call-site compatibility; budgeting now uses
    // the engine's own per-request read/write counters.
    func run(_ action: AiToolAction, sessionIdAtStart: String, actionCount: Int) async -> String {
        if !context.isCurrent() || Task.isCancelled || context.binding.tabId != sessionIdAtStart {
            return "Skipped: the active document changed before this action ran."
        }
        let isRead = Self.readTools.contains(action.tool)
        if isRead {
            if readCount >= Self.maxReads {
                return "Skipped: document-read limit reached for this response."
            }
        } else if writeCount >= Self.maxWrites {
            return "Skipped: action limit reached for this response."
        }
        do {
            try context.checkCurrent()
            epubSummary = nil
            let result = try await execute(action)
            try context.checkCurrent()
            if isRead {
                readCount += 1
            } else {
                writeCount += 1
            }
            if let summary = context.document.kind == .epub
                ? epubSummary : AiToolSummary.make(action: action, result: result) {
                displayActions.append(summary)
            }
            return result
        } catch is CancellationError {
            return "Skipped: the request's document is no longer current."
        } catch {
            return "Action failed: \(String(describing: error))"
        }
    }

    private func execute(_ action: AiToolAction) async throws -> String {
        if context.document.kind == .epub { return try await executeEpub(action) }
        switch action.tool {
        case "getPageText":
            return try await getPageText(pageNumber: action.args.pageNumber)

        case "searchDocument":
            return try await searchDocument(
                query: action.args.text ?? "",
                isRegex: action.args.isRegex ?? false
            )

        case "getAnnotations":
            return getAnnotations(pageNumber: action.args.pageNumber)

        case "goToPage":
            let page = clampPage(action.args.pageNumber)
            try context.checkCurrent()
            context.navigate(page)
            return "Navigated to page \(page)."

        case "addNote":
            let page = clampPage(action.args.pageNumber)
            let text = action.args.text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard !text.isEmpty else { return "Skipped addNote: empty text." }
            let position = PositionData(
                rects: [AnnotationRect(
                    x: sanitizeNonNegative(action.args.x, fallback: 72),
                    y: sanitizeNonNegative(action.args.y, fallback: 96),
                    width: 0,
                    height: 0
                )],
                pageWidth: Self.defaultPageWidth,
                pageHeight: Self.defaultPageHeight,
                selectedText: nil,
                startOffset: nil,
                endOffset: nil,
                prefix: nil,
                suffix: nil,
                viewportOffset: nil
            )
            let created = try await context.createAnnotation(CreateAnnotationInput(
                type: .note,
                pageNumber: page,
                color: nil,
                content: text,
                positionData: position
            ))
            try context.checkCurrent()
            annotations.append(created)
            return "Added note on page \(page)."

        case "addHighlight":
            let requestedPage = clampPage(action.args.pageNumber)
            let query = action.args.text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard !query.isEmpty else { return "Skipped addHighlight: no text provided to locate." }
            let color = sanitizeColor(action.args.color)
            let isWeb = context.document.kind == .web
            let located = await context.locate(requestedPage, query)
            try context.checkCurrent()
            guard var located,
                  isWeb || !located.positionData.rects.isEmpty else {
                return "Skipped addHighlight: couldn't find \"\(query)\" on page \(requestedPage)."
            }
            let resolvedPage = isWeb ? clampPage(Double(located.pageNumber)) : requestedPage
            if isWeb { located.positionData.selectedText = query }
            let created = try await context.createAnnotation(CreateAnnotationInput(
                type: .highlight,
                pageNumber: resolvedPage,
                color: color,
                content: nil,
                positionData: located.positionData
            ))
            try context.checkCurrent()
            annotations.append(created)
            return "Highlighted \"\(query)\" on page \(resolvedPage)."

        default:
            return "Skipped unknown tool: \(action.tool)."
        }
    }

    private func executeEpub(_ action: AiToolAction) async throws -> String {
        guard let epub = context.epub, let docId = context.document.docId else {
            return "Skipped: EPUB reader context is not bound. Reopen the chapter and try again."
        }
        let chapterNumber = clampPage(action.args.pageNumber)
        func citation(_ chapter: EpubChapterMetadata, anchor: EpubTextAnchor? = nil) -> AiEpubCitation? {
            AiEpubCitation(docId: docId, chapterNumber: chapter.chapterNumber,
                           chapterTitle: chapter.title, chapterHref: chapter.chapterHref, anchor: anchor).bounded
        }
        switch action.tool {
        case "searchDocument":
            guard action.args.isRegex != true else { return "Skipped searchDocument: EPUB search is literal, case-sensitive; regex is not supported." }
            let query = action.args.text ?? ""
            guard !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  query.utf16.count <= 512 else { return "Skipped searchDocument: use a nonempty literal query of at most 512 UTF-16 units." }
            context.setActivity(.indexing)
            let response = try await epub.search(query, 8)
            try context.checkCurrent()
            let sources = response.results.prefix(8).compactMap { hit -> AiToolSummary.Source? in
                let chapter = EpubChapterMetadata(chapterNumber: hit.chapterNumber,
                    chapterHref: hit.anchor.chapterHref, title: hit.chapterTitle)
                guard let locator = citation(chapter, anchor: hit.anchor) else { return nil }
                return .init(page: nil, excerpt: String(hit.snippet.prefix(280)), epubCitation: locator)
            }
            let truncated = response.truncated || response.results.count > sources.count
            let detail = "\(sources.count) passages; \(response.chaptersSearched) chapters searched"
                + (truncated ? "; truncated — additional matches may exist" : "")
            epubSummary = AiToolSummary(title: "Searched EPUB for “\(String(query.prefix(120)))”",
                                       detail: detail, sources: sources)
            return try AiEpubToolResult(detail: detail, sources: sources.compactMap(\.epubCitation),
                chaptersSearched: response.chaptersSearched, truncated: truncated).json()

        case "getPageText", "goToPage", "addNote", "addHighlight":
            let chapters = try await epub.metadata()
            try context.checkCurrent()
            guard let chapter = chapters.first(where: { $0.chapterNumber == chapterNumber }) else {
                return "Skipped: no EPUB chapter \(chapterNumber)."
            }
            if action.tool == "getPageText" {
                context.setActivity(.indexing)
                let content = try await epub.chapter(chapterNumber - 1)
                try context.checkCurrent()
                let text = String(content.text.prefix(Self.maxPageReadCharacters))
                let excerpt = String(text.prefix(280))
                let anchor = content.anchor(in: NSRange(location: 0, length: excerpt.utf16.count))
                let locator = citation(chapter, anchor: anchor)
                let truncated = text.utf16.count < content.utf16Count
                let detail = truncated ? "Chapter text truncated at \(Self.maxPageReadCharacters) characters" : "Chapter text"
                epubSummary = AiToolSummary(title: "Read chapter \(chapterNumber)", detail: detail,
                    sources: locator.map { [.init(page: nil, excerpt: excerpt, epubCitation: $0)] } ?? [],
                    destinationEpub: locator)
                return try AiEpubToolResult(detail: detail, text: text, sources: locator.map { [$0] } ?? [],
                                           truncated: truncated).json()
            }
            var anchor = action.args.epubAnchor
            if action.tool == "addHighlight", anchor == nil, let quote = action.args.text {
                anchor = EpubTextAnchor(chapterHref: chapter.chapterHref, quote: quote, prefix: "", suffix: "")
            }
            if let candidate = anchor {
                guard citation(chapter, anchor: candidate) != nil else {
                    return "Skipped: invalid EPUB anchor or chapter mismatch. Read/search the chapter for an exact passage."
                }
                anchor = try await epub.resolve(candidate)
                try context.checkCurrent()
                guard anchor != nil else { return "Skipped: EPUB passage is missing or ambiguous. Supply its exact quote with prefix/suffix context." }
            }
            guard let locator = citation(chapter, anchor: anchor) else { return "Skipped: invalid EPUB chapter locator." }
            if action.tool == "goToPage" {
                try context.checkCurrent()
                epub.navigate(locator)
                epubSummary = AiToolSummary(title: "Navigated to chapter \(chapterNumber)", destinationEpub: locator)
                return try AiEpubToolResult(detail: "Navigated to chapter \(chapterNumber)", sources: [locator], truncated: false).json()
            }
            guard let anchor else { return "Skipped \(action.tool): EPUB annotations require an exact epubAnchor. Read/search the chapter first." }
            let body = action.args.text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard !body.isEmpty else { return "Skipped \(action.tool): empty text." }
            var position = PositionData(rects: [], pageWidth: 0, pageHeight: 0, selectedText: anchor.quote)
            position.epubAnchor = anchor
            let created = try await context.createAnnotation(CreateAnnotationInput(
                type: action.tool == "addNote" ? .note : .highlight, pageNumber: chapterNumber,
                color: action.tool == "addHighlight" ? sanitizeColor(action.args.color) : nil,
                content: action.tool == "addNote" ? body : nil, positionData: position))
            try context.checkCurrent()
            annotations.append(created)
            let detail = action.tool == "addNote" ? "Added note in chapter \(chapterNumber)" : "Highlighted passage in chapter \(chapterNumber)"
            epubSummary = AiToolSummary(title: detail, destinationEpub: locator)
            return try AiEpubToolResult(detail: detail, sources: [locator], truncated: false).json()

        case "getAnnotations":
            let filtered = annotations.filter { action.args.pageNumber == nil || $0.pageNumber == chapterNumber }
            let lines = filtered.prefix(50).map { annotation in
                "- Chapter \(annotation.pageNumber) (\(annotation.type.rawValue))"
                    + fieldSuffix("quote", annotation.positionData?.epubAnchor?.quote)
                    + fieldSuffix("note", annotation.content)
            }
            let detail = "\(filtered.count) EPUB annotations" + (filtered.count > 50 ? " (showing first 50)" : "")
            epubSummary = AiToolSummary(title: "Read annotations", detail: detail)
            return ([detail] + lines).joined(separator: "\n")
        default:
            return "Skipped unknown tool: \(action.tool)."
        }
    }

    // MARK: - Read tools (over in-memory pageTexts)

    /// Caps for what a single getPageText call may return: a page read is
    /// bounded so one dense page can't blow the prompt budget, and annotation
    /// echoes are clipped per entry and capped in count (newest kept).
    nonisolated static let maxPageReadCharacters = 12_000
    static let maxAnnotationReadCharacters = 300
    static let maxAnnotationsPerRead = 20

    static func boundedPageRead(page: Int, text: String) -> String {
        let header = "Page \(page):\n"
        guard text.count > maxPageReadCharacters else { return header + text }
        let clipped = String(text.prefix(maxPageReadCharacters))
        return header + clipped + "\n[truncated — page text continues beyond \(maxPageReadCharacters) characters]"
    }

    /// getPageText appends the page's highlights and notes so the model sees
    /// what the user marked. Highlights quote their selected text (plus any
    /// user comment), notes list their content; bookmarks and empty entries
    /// are skipped; long text is clipped; at most maxAnnotationsPerRead
    /// entries are listed, keeping the NEWEST (input is creation-ordered).
    static func annotationsSection(page: Int, annotations: [Annotation]) -> String? {
        func clip(_ string: String) -> String {
            string.count > maxAnnotationReadCharacters
                ? String(string.prefix(maxAnnotationReadCharacters)) + "…"
                : string
        }
        var lines: [String] = []
        for annotation in annotations {
            let comment = (annotation.content ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            switch annotation.type {
            case .highlight:
                let selected = (annotation.positionData?.selectedText ?? "")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if !selected.isEmpty, !comment.isEmpty {
                    lines.append("- Highlight: \"\(clip(selected))\" — user comment: \(clip(comment))")
                } else if !selected.isEmpty {
                    lines.append("- Highlight: \"\(clip(selected))\"")
                } else if !comment.isEmpty {
                    lines.append("- Highlight comment: \(clip(comment))")
                }
            case .note:
                if !comment.isEmpty { lines.append("- Note: \(clip(comment))") }
            default:
                continue
            }
        }
        guard !lines.isEmpty else { return nil }
        var hidden = 0
        if lines.count > maxAnnotationsPerRead {
            hidden = lines.count - maxAnnotationsPerRead
            lines = Array(lines.suffix(maxAnnotationsPerRead))
        }
        var output = ["User highlights and notes on page \(page):"] + lines
        if hidden > 0 {
            output.append("…and \(hidden) earlier annotations on this page (not shown).")
        }
        return output.joined(separator: "\n")
    }

    /// Read one page's extracted text. Extracts on demand if the background
    /// walk hasn't reached it yet, so it never returns empty for a page that
    /// actually has a text layer.
    private func getPageText(pageNumber: Double?) async throws -> String {
        let page = clampPage(pageNumber)
        if pageTexts[page] == nil {
            context.setActivity(.indexing)
            let extracted = try await context.extract([page])
            try context.checkCurrent()
            pageTexts.merge(extracted) { _, new in new }
        }
        let text = pageTexts[page] ?? ""
        guard !text.isEmpty else {
            return "Page \(page) has no extractable text (it may be a scanned image)."
        }
        var output = Self.boundedPageRead(page: page, text: text)
        if let section = Self.annotationsSection(page: page, annotations: annotations.filter { $0.pageNumber == page }) {
            output += "\n\n" + section
        }
        return output
    }

    /// List the user's annotations (notes + highlights) — whole document by
    /// default, or one page when `pageNumber` is given. The context block only
    /// carries the current page's annotations, so this is how the model reaches
    /// the rest.
    private func getAnnotations(pageNumber: Double?) -> String {
        var list = annotations.sorted { $0.pageNumber < $1.pageNumber }
        var scope = "in this document"
        if let pageNumber {
            let page = clampPage(pageNumber)
            list = list.filter { $0.pageNumber == page }
            scope = "on page \(page)"
        }
        guard !list.isEmpty else { return "No annotations \(scope)." }
        let shown = list.prefix(Self.maxAnnotationLines)
        var lines = shown.map { annotation in
            "- p.\(annotation.pageNumber) (\(annotation.type.rawValue))"
                + fieldSuffix("text", annotation.positionData?.selectedText)
                + fieldSuffix("note", annotation.content)
        }
        if list.count > shown.count {
            lines.append("…and \(list.count - shown.count) more (pass pageNumber to narrow).")
        }
        var output = (["\(list.count) annotation\(list.count == 1 ? "" : "s") \(scope):"] + lines)
            .joined(separator: "\n")
        if output.count > Self.maxSearchOutputCharacters {
            output = String(output.prefix(Self.maxSearchOutputCharacters)) + "\n…[truncated]"
        }
        return output
    }

    private static let maxAnnotationLines = 200
    private static let maxAnnotationFieldCharacters = 200

    /// ` text="…"` fragment for an annotation line; empty when the field is.
    private func fieldSuffix(_ label: String, _ value: String?) -> String {
        guard var value = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty else { return "" }
        if value.count > Self.maxAnnotationFieldCharacters {
            value = String(value.prefix(Self.maxAnnotationFieldCharacters)) + "…"
        }
        return " \(label)=\"\(value)\""
    }

    /// Grep the whole document (`pageTexts` is horizontal-whitespace-normalized
    /// with line breaks preserved as single "\n"s).
    /// Ensures every page with a text layer is extracted first, then returns the
    /// top matches with surrounding context, output-capped. Only bounded literal queries are accepted; untrusted
    /// regular expressions cannot create non-cancellable matching work.
    private func searchDocument(query: String, isRegex: Bool) async throws -> String {
        guard !isRegex else {
            return "Skipped searchDocument: regular expressions are not supported. Use a literal text query."
        }
        guard query.utf16.count <= 512 else { return "Skipped searchDocument: use a query of 512 characters or fewer." }
        let trimmed = query.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "Skipped searchDocument: empty query." }

        // A whole-document read: fill any pages the background walk hasn't
        // reached yet before grepping.
        context.setActivity(.indexing)
        let extracted = try await context.extract(nil)
        try context.checkCurrent()
        pageTexts.merge(extracted) { _, new in new }
        let snapshot = pageTexts
        guard !snapshot.isEmpty else { return "No extractable text in this document yet." }

        let result = await Self.performSearch(pages: snapshot, query: trimmed)
        try context.checkCurrent()
        return result ?? "Skipped searchDocument: cancelled."
    }

    /// Max matches surfaced, chars of context on each side of a match, per-page
    /// scan cap (bounds literal matching cost), and overall output cap. `nonisolated` so the
    /// off-actor `performSearch`/`snippet` helpers can read them.
    private nonisolated static let maxSearchHits = 8
    private nonisolated static let searchSnippetRadius = 200
    private nonisolated static let maxPageScanCharacters = 100_000
    private nonisolated static let maxSearchOutputCharacters = 4_000

    /// Pure, off-actor grep over a page-text snapshot. Returns the first match on
    /// each page (up to `maxSearchHits` pages) with `±radius` chars of context.
    /// Cooperative: checks `Task.isCancelled` between pages and returns nil if the
    /// request was cancelled, so no worker outlives a cancelled provider turn.
    private nonisolated static func performSearch(pages: [Int: String], query: String) async -> String? {
        var hits: [String] = []
        for page in pages.keys.sorted() {
            if Task.isCancelled { return nil }
            guard let raw = pages[page], !raw.isEmpty else { continue }
            let text = raw.count > maxPageScanCharacters ? String(raw.prefix(maxPageScanCharacters)) : raw
            let haystack = text.replacingOccurrences(of: "\n", with: " ")
            let matchRange = haystack.range(of: query, options: .caseInsensitive)
            guard let matchRange else { continue }
            let context = snippet(around: matchRange, in: haystack)
                .replacingOccurrences(of: "\n", with: " ")
            hits.append("page \(page) — \"…\(context)…\"")
            if hits.count >= maxSearchHits { break }
        }

        guard !hits.isEmpty else {
            return "No matches for \"\(query)\" in the document (up to 100,000 characters per page)."
        }
        let header = "Found \(hits.count) page\(hits.count == 1 ? "" : "s") with a match"
            + (hits.count >= maxSearchHits ? " (showing first \(maxSearchHits))" : "") + ":"
        var output = ([header] + hits).joined(separator: "\n")
        if output.count > maxSearchOutputCharacters {
            output = String(output.prefix(maxSearchOutputCharacters)) + "\n…[truncated]"
        }
        return output
    }

    private nonisolated static func snippet(around range: Range<String.Index>, in text: String) -> String {
        let lower = text.index(range.lowerBound, offsetBy: -searchSnippetRadius, limitedBy: text.startIndex) ?? text.startIndex
        let upper = text.index(range.upperBound, offsetBy: searchSnippetRadius, limitedBy: text.endIndex) ?? text.endIndex
        return String(text[lower..<upper])
    }

    private func clampPage(_ value: Double?) -> Int {
        let total = context.pageCount
        let fallback = total > 0 ? context.currentPage : 1
        guard let value, value.isFinite else { return max(1, fallback) }
        guard total > 0 else { return 1 }
        return Int(min(Double(total), max(1, value.rounded())))
    }

    private func sanitizeNonNegative(_ value: Double?, fallback: Double) -> Double {
        guard let value, value.isFinite else { return fallback }
        return max(0, value)
    }

    private func sanitizeColor(_ value: String?) -> String {
        guard let value else { return WorkspaceStore.storedDefaultHighlightColor() }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        let pattern = #"^#(?:[0-9a-f]{3}|[0-9a-f]{4}|[0-9a-f]{6}|[0-9a-f]{8})$|^(?:rgb|rgba|hsl|hsla)\([^)]*\)$|^[a-z]+$"#
        guard trimmed.range(of: pattern, options: [.regularExpression, .caseInsensitive]) != nil else {
            return WorkspaceStore.storedDefaultHighlightColor()
        }
        return trimmed
    }
}
