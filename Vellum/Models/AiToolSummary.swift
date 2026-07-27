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
                title: clipped("Searched for “\(query)”", limit: 240),
                detail: clipped(detail, limit: 160),
                sources: Array(sources.prefix(8))
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

    /// Strictly recognizes the receipt formats emitted by older Vellum builds.
    /// Returning nil (rather than an empty list) is important: arbitrary prose
    /// headed "Actions:" must remain ordinary message content.
    static func parseLegacyActions(_ text: String, messageId: String) -> [AiToolSummary]? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.isEmpty == false else { return nil }
        let lines = trimmed.split(separator: "\n", omittingEmptySubsequences: false)
            .map(String.init)

        // A short-lived older build persisted the raw search result. Accept only
        // the exact header + page-source grammar, never arbitrary suffix text.
        let sources = searchSources(from: trimmed)
        if let first = lines.first,
           fullMatch(first, pattern: #"- Found \d+ pages? with a match(?: \(showing first \d+\))?:"#),
           firstInteger(in: first) == sources.count,
           sources.isEmpty == false,
           lines.dropFirst().allSatisfy({
               $0.isEmpty || fullMatch($0, pattern: #"page \d+ — ["“].+["”]"#)
           }) {
            return assigningStableIds([
                AiToolSummary(
                    title: "Document search",
                    detail: "\(sources.count) \(sources.count == 1 ? "page" : "pages")",
                    sources: Array(sources.prefix(8))
                )
            ], messageId: messageId)
        }

        // The long-lived format was a list of one-line receipts. Require every
        // line to match a result string that the historical tool engine emitted.
        let compact = lines.compactMap(legacyCompactSummary)
        guard compact.count == lines.count, compact.isEmpty == false else { return nil }
        return assigningStableIds(compact, messageId: messageId)
    }

    private static func legacyCompactSummary(_ line: String) -> AiToolSummary? {
        guard line.hasPrefix("- ") else { return nil }
        let receipt = String(line.dropFirst(2))

        if fullMatch(receipt, pattern: #"Searched the document for “.+”\."#) {
            return AiToolSummary(title: clipped(receipt, limit: 240), detail: "Document search")
        }
        if fullMatch(receipt, pattern: #"Read page \d+\."#) {
            let page = pageNumber(from: receipt)
            return AiToolSummary(
                title: page.map { "Read page \($0)" } ?? "Read a page",
                detail: "Document source",
                destinationPage: page
            )
        }

        let knownWritePatterns = [
            #"Navigated to page \d+\."#,
            #"Added note on page \d+\."#,
            #"Highlighted ".+" on page \d+\."#,
            #"Skipped addNote: empty text\."#,
            #"Skipped addHighlight: no text provided to locate\."#,
            #"Skipped addHighlight: couldn't find ".+" on page \d+\."#,
            #"Skipped unknown tool: .+\."#,
        ]
        guard knownWritePatterns.contains(where: { fullMatch(receipt, pattern: $0) })
        else { return nil }
        return AiToolSummary(
            title: clipped(receipt, limit: 240),
            detail: "Document action",
            destinationPage: pageNumber(from: receipt)
        )
    }

    private static func assigningStableIds(
        _ summaries: [AiToolSummary],
        messageId: String
    ) -> [AiToolSummary] {
        summaries.enumerated().map { summaryIndex, original in
            var summary = original
            let signature = [
                summary.title,
                summary.detail ?? "",
                summary.destinationPage.map(String.init) ?? "",
            ].joined(separator: "\u{1f}")
            summary.id = stableId("\(messageId)\u{1f}\(summaryIndex)\u{1f}\(signature)")
            summary.sources = summary.sources.enumerated().map { sourceIndex, originalSource in
                var source = originalSource
                let sourceSignature = [
                    source.page.map(String.init) ?? "",
                    source.excerpt,
                ].joined(separator: "\u{1f}")
                source.id = stableId(
                    "\(messageId)\u{1f}\(summaryIndex)\u{1f}\(sourceIndex)\u{1f}\(sourceSignature)"
                )
                return source
            }
            return summary
        }
    }

    /// FNV-1a is deliberately simple and deterministic across launches. Swift's
    /// `Hasher` is randomized and would recreate DisclosureGroup identity.
    private static func stableId(_ value: String) -> String {
        var hash: UInt64 = 14_695_981_039_346_656_037
        for byte in value.utf8 {
            hash ^= UInt64(byte)
            hash &*= 1_099_511_628_211
        }
        return "legacy-\(String(hash, radix: 16))"
    }

    private static func fullMatch(_ text: String, pattern: String) -> Bool {
        guard let regex = try? NSRegularExpression(pattern: "^(?:\(pattern))$") else {
            return false
        }
        return regex.firstMatch(
            in: text,
            range: NSRange(text.startIndex..<text.endIndex, in: text)
        ) != nil
    }

    private static func firstInteger(in text: String) -> Int? {
        guard let range = text.range(of: #"\d+"#, options: .regularExpression) else {
            return nil
        }
        return Int(text[range])
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
    private var legacyReceipt: (answer: String, summaries: [AiToolSummary])? {
        guard role == .assistant,
              toolSummaries == nil,
              let range = content.range(of: "\n\nActions:\n", options: .backwards),
              let summaries = AiToolSummary.parseLegacyActions(
                  String(content[range.upperBound...]),
                  messageId: id
              )
        else { return nil }
        let answer = String(content[..<range.lowerBound])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return (answer, summaries)
    }

    /// Answer text without a strictly recognized legacy tool-receipt suffix.
    var displayContent: String {
        legacyReceipt?.answer ?? content
    }

    /// New messages use persisted structured summaries. Recognized older
    /// messages are upgraded at presentation time without changing their data.
    var displayToolSummaries: [AiToolSummary] {
        if let toolSummaries { return toolSummaries }
        return legacyReceipt?.summaries ?? []
    }

    /// Keeps compact prior tool use available to follow-up turns without
    /// resending raw legacy search/page payloads.
    var promptContent: String {
        guard role == .assistant else { return content }
        if let toolSummaries, toolSummaries.isEmpty == false {
            return contentWithCompactActions(answer: content, summaries: toolSummaries)
        }
        guard let legacyReceipt else { return content }
        return contentWithCompactActions(
            answer: legacyReceipt.answer,
            summaries: legacyReceipt.summaries
        )
    }

    private func contentWithCompactActions(
        answer: String,
        summaries: [AiToolSummary]
    ) -> String {
        let actions = summaries.map { "- \($0.title)" }.joined(separator: "\n")
        return "\(answer)\n\nActions:\n\(actions)"
    }
}
