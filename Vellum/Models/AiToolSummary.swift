import Foundation

/// A compact, persisted account of one document tool used to produce an AI reply.
///
/// Raw tool payloads can contain thousands of characters and are intentionally
/// never stored here. Sources retain only a short excerpt and an optional page
/// locator so the transcript stays readable and can offer an explicit jump.
struct AiToolSummary: Codable, Equatable, Identifiable, Sendable {
    struct Source: Codable, Equatable, Identifiable, Sendable {
        var id: String
        var page: Int?
        var excerpt: String

        init(id: String = UUID().uuidString.lowercased(), page: Int?, excerpt: String) {
            self.id = id
            self.page = page
            self.excerpt = excerpt
        }
    }

    var id: String
    var title: String
    var detail: String?
    var sources: [Source]
    var destinationPage: Int?

    init(
        id: String = UUID().uuidString.lowercased(),
        title: String,
        detail: String? = nil,
        sources: [Source] = [],
        destinationPage: Int? = nil
    ) {
        self.id = id
        self.title = title
        self.detail = detail
        self.sources = sources
        self.destinationPage = destinationPage
    }

    static func make(action: AiToolAction, result: String) -> AiToolSummary? {
        switch action.tool {
        case "searchDocument":
            let query = (action.args.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard query.isEmpty == false else { return nil }
            let sources = searchSources(from: result)
            let count = sources.count
            let detail = count == 0
                ? result.trimmingCharacters(in: .whitespacesAndNewlines)
                : "\(count) \(count == 1 ? "page" : "pages")"
            return AiToolSummary(
                title: "Searched for “\(query)”",
                detail: clipped(detail, limit: 160),
                sources: sources
            )

        case "getPageText":
            let page = pageNumber(from: result) ?? roundedPage(action.args.pageNumber)
            let body = result
                .split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: true)
                .dropFirst()
                .first
                .map(String.init) ?? ""
            let source = Source(page: page, excerpt: clipped(body, limit: 280))
            return AiToolSummary(
                title: page.map { "Read page \($0)" } ?? "Read a page",
                detail: "Document source",
                sources: source.excerpt.isEmpty ? [] : [source],
                destinationPage: page
            )

        case "getAnnotations":
            return AiToolSummary(
                title: "Read annotations",
                detail: clipped(result, limit: 160)
            )

        default:
            let page = pageNumber(from: result) ?? roundedPage(action.args.pageNumber)
            return AiToolSummary(
                title: clipped(result, limit: 160),
                detail: "Document action",
                destinationPage: page
            )
        }
    }

    /// Converts the pre-structured "Actions:" suffix used by older Vellum
    /// versions into the same compact presentation. This prevents an existing
    /// multi-page retrieval transcript from remaining permanently oversized.
    static func fromLegacyActions(_ text: String) -> [AiToolSummary] {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.isEmpty == false else { return [] }

        let sources = searchSources(from: trimmed)
        if sources.isEmpty == false {
            let firstLine = trimmed.split(separator: "\n").first.map(String.init) ?? "Document search"
            return [AiToolSummary(
                title: firstLine.removingListMarker(),
                detail: "\(sources.count) \(sources.count == 1 ? "page" : "pages")",
                sources: sources
            )]
        }

        let lines = trimmed.split(separator: "\n", omittingEmptySubsequences: false)
        guard let first = lines.first.map(String.init) else { return [] }
        let title = first.removingListMarker()
        let page = pageNumber(from: title)
        let excerpt = lines.dropFirst().joined(separator: "\n")
        if excerpt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false {
            return [AiToolSummary(
                title: page.map { "Read page \($0)" } ?? title,
                detail: "Document source",
                sources: [Source(page: page, excerpt: clipped(excerpt, limit: 280))],
                destinationPage: page
            )]
        }

        return [AiToolSummary(
            title: clipped(title, limit: 160),
            detail: "Document action",
            destinationPage: page
        )]
    }

    private static func searchSources(from result: String) -> [Source] {
        result.split(separator: "\n").compactMap { rawLine in
            let line = String(rawLine)
            guard line.hasPrefix("page "),
                  let separator = line.range(of: " — ") else { return nil }
            let pageText = line[line.index(line.startIndex, offsetBy: 5)..<separator.lowerBound]
            guard let page = Int(pageText) else { return nil }
            var excerpt = String(line[separator.upperBound...])
            excerpt = excerpt.trimmingCharacters(in: CharacterSet(charactersIn: "\"“”"))
            if excerpt.hasPrefix("…") { excerpt.removeFirst() }
            if excerpt.hasSuffix("…") { excerpt.removeLast() }
            return Source(page: page, excerpt: clipped(excerpt, limit: 280))
        }
    }

    private static func pageNumber(from result: String) -> Int? {
        let pattern = #"(?:[Pp]age|page)\s+(\d+)"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(
                in: result,
                range: NSRange(result.startIndex..<result.endIndex, in: result)
              ),
              let range = Range(match.range(at: 1), in: result) else { return nil }
        return Int(result[range])
    }

    private static func roundedPage(_ value: Double?) -> Int? {
        guard let value, value.isFinite else { return nil }
        return max(1, Int(value.rounded()))
    }

    private static func clipped(_ text: String, limit: Int) -> String {
        let normalized = text
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard normalized.count > limit else { return normalized }
        return String(normalized.prefix(limit)).trimmingCharacters(in: .whitespaces) + "…"
    }
}

extension AiMessage {
    /// Answer text without the legacy inline tool-receipt suffix.
    var displayContent: String {
        guard toolSummaries == nil,
              let range = content.range(of: "\n\nActions:\n", options: .backwards)
        else { return content }
        return String(content[..<range.lowerBound])
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// New messages use persisted structured summaries. Older messages are
    /// upgraded at presentation time, leaving their on-disk representation intact.
    var displayToolSummaries: [AiToolSummary] {
        if let toolSummaries { return toolSummaries }
        guard let range = content.range(of: "\n\nActions:\n", options: .backwards)
        else { return [] }
        return AiToolSummary.fromLegacyActions(String(content[range.upperBound...]))
    }

    /// Keeps a compact receipt of prior tool use available to follow-up turns.
    /// The model needs to know which document operations already ran, but not
    /// the excerpts that were intentionally omitted from transcript storage.
    var promptContent: String {
        guard let toolSummaries, toolSummaries.isEmpty == false else { return content }
        let actions = toolSummaries.map { "- \($0.title)" }.joined(separator: "\n")
        return "\(content)\n\nActions:\n\(actions)"
    }
}

private extension String {
    func removingListMarker() -> String {
        hasPrefix("- ") ? String(dropFirst(2)) : self
    }
}
