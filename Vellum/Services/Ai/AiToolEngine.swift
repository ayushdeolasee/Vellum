import Foundation

struct AiToolArguments: Codable, Sendable {
    var pageNumber: Double?
    var text: String?
    var color: String?
    var x: Double?
    var y: Double?
    /// `searchDocument` only: treat `text` (the query) as a regular expression
    /// instead of a literal substring.
    var isRegex: Bool?
}

struct AiToolAction: Codable, Sendable {
    var tool: String
    var args: AiToolArguments
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

    /// Tools that only read already-extracted text; budgeted separately from
    /// writes and never counted against the write cap.
    private static let readTools: Set<String> = ["searchDocument", "getPageText"]

    private unowned let store: AiStore
    private unowned let app: AppStore
    private unowned let annotations: AnnotationStore

    /// Per-request counters (a fresh engine is created for every `sendMessage`).
    private var writeCount = 0
    private var readCount = 0

    /// One-line summaries of what ran, for the "Actions:" list under the reply.
    /// Write tools keep their full result line; read tools get a compact
    /// summary so a multi-KB search/page-text payload (which only the model
    /// needs) never lands in the visible chat bubble.
    private(set) var displayActions: [String] = []

    init(store: AiStore, app: AppStore, annotations: AnnotationStore) {
        self.store = store
        self.app = app
        self.annotations = annotations
    }

    // `actionCount` is retained for call-site compatibility; budgeting now uses
    // the engine's own per-request read/write counters.
    func run(_ action: AiToolAction, sessionIdAtStart: String, actionCount: Int) async -> String {
        if app.activeTabId != sessionIdAtStart {
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
            let result = try await execute(action)
            if isRead {
                readCount += 1
                if let summary = readSummary(action) { displayActions.append(summary) }
            } else {
                writeCount += 1
                displayActions.append(result)
            }
            return result
        } catch {
            return "Action failed: \(String(describing: error))"
        }
    }

    /// Compact user-facing line for a read tool (the full result goes only to
    /// the model).
    private func readSummary(_ action: AiToolAction) -> String? {
        switch action.tool {
        case "searchDocument":
            let query = (action.args.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            return query.isEmpty ? nil : "Searched the document for “\(query)”."
        case "getPageText":
            return "Read page \(clampPage(action.args.pageNumber))."
        default:
            return nil
        }
    }

    private func execute(_ action: AiToolAction) async throws -> String {
        switch action.tool {
        case "getPageText":
            return await getPageText(pageNumber: action.args.pageNumber)

        case "searchDocument":
            return await searchDocument(
                query: action.args.text ?? "",
                isRegex: action.args.isRegex ?? false
            )

        case "goToPage":
            let page = clampPage(action.args.pageNumber)
            app.goToPage(page)
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
            _ = await annotations.addNote(CreateAnnotationInput(
                type: .note,
                pageNumber: page,
                color: nil,
                content: text,
                positionData: position
            ))
            return "Added note on page \(page)."

        case "addHighlight":
            let requestedPage = clampPage(action.args.pageNumber)
            let query = action.args.text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard !query.isEmpty else { return "Skipped addHighlight: no text provided to locate." }
            let color = sanitizeColor(action.args.color)
            let isWeb = app.document?.kind == .web
            let located: LocatedText?
            if isWeb {
                located = await store.locateWebTextHandler?(requestedPage, query)
            } else {
                located = await store.locatePdfTextHandler?(requestedPage, query)
            }
            guard var located,
                  isWeb || !located.positionData.rects.isEmpty else {
                return "Skipped addHighlight: couldn't find \"\(query)\" on page \(requestedPage)."
            }
            let resolvedPage = isWeb ? clampPage(Double(located.pageNumber)) : requestedPage
            if isWeb { located.positionData.selectedText = query }
            _ = await annotations.addHighlight(CreateAnnotationInput(
                type: .highlight,
                pageNumber: resolvedPage,
                color: color,
                content: nil,
                positionData: located.positionData
            ))
            return "Highlighted \"\(query)\" on page \(resolvedPage)."

        default:
            return "Skipped unknown tool: \(action.tool)."
        }
    }

    // MARK: - Read tools (over in-memory pageTexts)

    /// Caps for what a single getPageText call may return: a page read is
    /// bounded so one dense page can't blow the prompt budget, and annotation
    /// echoes are clipped per entry and capped in count (newest kept).
    static let maxPageReadCharacters = 12_000
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
    private func getPageText(pageNumber: Double?) async -> String {
        let page = clampPage(pageNumber)
        if store.pageTexts[page] == nil {
            store.setActivity(.indexing)
            _ = await store.ensureExtracted(pages: [page])
        }
        let text = store.pageTexts[page] ?? ""
        guard !text.isEmpty else {
            return "Page \(page) has no extractable text (it may be a scanned image)."
        }
        var output = Self.boundedPageRead(page: page, text: text)
        if let section = Self.annotationsSection(page: page, annotations: annotations.annotationsForPage(page)) {
            output += "\n\n" + section
        }
        return output
    }

    /// Grep the whole document (already whitespace-normalized in `pageTexts`).
    /// Ensures every page with a text layer is extracted first, then returns the
    /// top matches with surrounding context, output-capped and time-guarded
    /// against a pathological regex.
    private func searchDocument(query: String, isRegex: Bool) async -> String {
        // Literal queries get whitespace-collapsed to match `pageTexts` (which is
        // whitespace-normalized); regex queries are only trimmed so intentional
        // runs of spaces in the pattern aren't silently rewritten.
        let trimmed: String
        if isRegex {
            trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        } else {
            trimmed = query
                .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        guard !trimmed.isEmpty else { return "Skipped searchDocument: empty query." }
        // Validate the regex up front so an invalid pattern fails fast with a
        // clear message rather than silently falling back to a literal search.
        if isRegex, (try? NSRegularExpression(pattern: trimmed, options: [.caseInsensitive])) == nil {
            return "Skipped searchDocument: invalid regular expression."
        }

        // A whole-document read: fill any pages the background walk hasn't
        // reached yet before grepping.
        store.setActivity(.indexing)
        _ = await store.ensureExtracted(pages: nil)

        let snapshot = store.pageTexts
        guard !snapshot.isEmpty else { return "No extractable text in this document yet." }

        // Run the grep off the main actor and race it against a deadline so a
        // pathological regex can't freeze the UI. `performSearch` checks
        // `Task.isCancelled` between pages, so the deadline bounds latency to the
        // timeout plus at most one page's match cost (a single page is capped at
        // `maxPageScanCharacters`) — it doesn't fully prevent a pathological
        // pattern from burning that one page.
        do {
            return try await withThrowingTaskGroup(of: String?.self) { group in
                group.addTask { Self.performSearch(pages: snapshot, query: trimmed, isRegex: isRegex) }
                group.addTask {
                    try await Task.sleep(nanoseconds: 3_000_000_000)
                    throw SearchTimedOut()
                }
                let first = try await group.next()!
                group.cancelAll()
                // `performSearch` returns nil when it observed cancellation mid-scan.
                return first ?? "Skipped searchDocument: the search took too long (possibly a pathological pattern). Try a simpler query."
            }
        } catch is SearchTimedOut {
            return "Skipped searchDocument: the search took too long (possibly a pathological pattern). Try a simpler query."
        } catch is CancellationError {
            // The request was aborted (user cancel / tab switch). Don't stringify
            // this as a tool failure — the whole response is being torn down; the
            // network layer surfaces the cancellation to the caller.
            return "Skipped searchDocument: cancelled."
        } catch {
            return "searchDocument failed: \(String(describing: error))"
        }
    }

    private struct SearchTimedOut: Error {}

    /// Max matches surfaced, chars of context on each side of a match, per-page
    /// scan cap (bounds regex cost), and overall output cap. `nonisolated` so the
    /// off-actor `performSearch`/`snippet` helpers can read them.
    private nonisolated static let maxSearchHits = 8
    private nonisolated static let searchSnippetRadius = 200
    private nonisolated static let maxPageScanCharacters = 100_000
    private nonisolated static let maxSearchOutputCharacters = 4_000

    /// Pure, off-actor grep over a page-text snapshot. Returns the first match on
    /// each page (up to `maxSearchHits` pages) with `±radius` chars of context.
    /// Cooperative: checks `Task.isCancelled` between pages and returns nil if the
    /// deadline fired mid-scan, so the caller can surface the timeout message.
    private nonisolated static func performSearch(pages: [Int: String], query: String, isRegex: Bool) -> String? {
        let regex = isRegex ? try? NSRegularExpression(pattern: query, options: [.caseInsensitive]) : nil
        var hits: [String] = []
        for page in pages.keys.sorted() {
            if Task.isCancelled { return nil }
            guard let raw = pages[page], !raw.isEmpty else { continue }
            let text = raw.count > maxPageScanCharacters ? String(raw.prefix(maxPageScanCharacters)) : raw
            let matchRange: Range<String.Index>?
            if let regex {
                let ns = text as NSString
                matchRange = regex
                    .firstMatch(in: text, options: [], range: NSRange(location: 0, length: ns.length))
                    .flatMap { Range($0.range, in: text) }
            } else {
                matchRange = text.range(of: query, options: .caseInsensitive)
            }
            guard let matchRange else { continue }
            hits.append("page \(page) — \"…\(snippet(around: matchRange, in: text))…\"")
            if hits.count >= maxSearchHits { break }
        }

        guard !hits.isEmpty else {
            return "No matches for \"\(query)\" in the document\(isRegex ? " (regex)" : "")."
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
        let total = app.numPages
        let fallback = total > 0 ? app.currentPage : 1
        guard let value, value.isFinite else { return max(1, fallback) }
        guard total > 0 else { return 1 }
        return min(total, max(1, Int(value.rounded())))
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
