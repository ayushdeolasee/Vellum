import Foundation

struct AiPromptParameters {
    var conversation: String
    var context: String
    var latestUserRequest: String
}

enum AiPrompts {
    static let maxContextCharacters = 120_000
    /// Per-reference text cap so a single quoted reply or selection can't bloat
    /// the prompt, plus an overall cap on the joined referenced block.
    static let maxReferenceCharacters = 8_000
    static let maxReferencedBlockCharacters = 32_000

    static func nativeSystemPrompt() throws -> String {
        try loadTemplate(named: "tool-mode-native")
    }

    static func buildNativeToolUserPrompt(_ parameters: AiPromptParameters) -> String {
        [
            "### Recent Conversation",
            parameters.conversation,
            "",
            "### Document Context",
            parameters.context,
            "",
            "### Latest User Request",
            parameters.latestUserRequest,
        ].joined(separator: "\n")
    }

    static func buildConversationBlock(_ messages: [AiMessage]) -> String {
        messages.suffix(10).map { "\($0.role.rawValue.uppercased()): \($0.content)" }
            .joined(separator: "\n")
    }

    static func buildContextBlock(pageTexts: [Int: String], context: AiContextSnapshot) -> String {
        let orderedPages = pageTexts.keys.sorted()
        let fullText = orderedPages.map { "[Page \($0)] \(pageTexts[$0] ?? "")" }
            .joined(separator: "\n")
        let boundedFullText: String
        if fullText.count > maxContextCharacters {
            let end = fullText.index(fullText.startIndex, offsetBy: maxContextCharacters)
            boundedFullText = String(fullText[..<end]) + "\n[truncated]"
        } else {
            boundedFullText = fullText
        }

        let visibleText = context.visiblePages
            .map { "[Page \($0)] \(pageTexts[$0] ?? "")" }
            .joined(separator: "\n")
        let currentAnnotations = context.annotations
            .filter { $0.pageNumber == context.currentPage }
            .suffix(50)
            .map(annotationLine)
            .joined(separator: "\n")
        let allAnnotations = context.annotations.suffix(200)
            .map { annotation in
                "- (\(annotation.type.rawValue)) p.\(annotation.pageNumber) color=\(annotation.color ?? "none") text=\(quoted(annotation.positionData?.selectedText ?? "")) note=\(quoted(annotation.content ?? ""))"
            }
            .joined(separator: "\n")
        let image = context.currentPageImage.map {
            "attached (\($0.width)x\($0.height), \($0.mediaType))"
        } ?? "none"

        let referenced = boundedReferencedBlock(context.references.map(referenceLine).joined(separator: "\n"))

        return [
            "User-referenced context (the user explicitly attached these to this message — prioritize them):",
            referenced.isEmpty ? "(none)" : referenced,
            "",
            "Document title: \(context.title ?? "Untitled")",
            "Total pages: \(context.numPages)",
            "Current page: \(context.currentPage)",
            "Visible pages: \(context.visiblePages.isEmpty ? "none" : context.visiblePages.map(String.init).joined(separator: ", "))",
            "Current page image: \(image)",
            "",
            "Visible page text:",
            visibleText.isEmpty ? "(none)" : visibleText,
            "",
            "Current page annotations:",
            currentAnnotations.isEmpty ? "(none)" : currentAnnotations,
            "",
            "Annotations:",
            allAnnotations.isEmpty ? "(none)" : allAnnotations,
            "",
            "Full PDF text:",
            boundedFullText.isEmpty ? "(text extraction pending)" : boundedFullText,
        ].joined(separator: "\n")
    }

    private static func referenceLine(_ reference: AiReference) -> String {
        switch reference.kind {
        case let .selection(text, page):
            return "- [selected text, p.\(page)] \(quoted(bounded(text)))"
        case let .highlight(text, page):
            return "- [existing highlight, p.\(page)] \(quoted(bounded(text)))"
        case let .region(image, page):
            return "- [region snapshot, p.\(page)] image attached (\(image.width)x\(image.height))"
        case let .pageSnapshot(image, page):
            return "- [page snapshot, p.\(page)] image attached (\(image.width)x\(image.height))"
        case let .quote(text, _):
            return "- [quoted from an earlier assistant reply] \(quoted(bounded(text)))"
        }
    }

    /// Truncate a single reference's text so one large selection/quote can't
    /// dominate the prompt.
    private static func bounded(_ text: String) -> String {
        guard text.count > maxReferenceCharacters else { return text }
        let end = text.index(text.startIndex, offsetBy: maxReferenceCharacters)
        return String(text[..<end]) + "…[truncated]"
    }

    /// Cap the whole referenced block after joining, in case many references add
    /// up past the limit even when each fits under the per-item cap.
    private static func boundedReferencedBlock(_ block: String) -> String {
        guard block.count > maxReferencedBlockCharacters else { return block }
        let end = block.index(block.startIndex, offsetBy: maxReferencedBlockCharacters)
        return String(block[..<end]) + "\n[referenced context truncated]"
    }

    private static func annotationLine(_ annotation: Annotation) -> String {
        "- (\(annotation.type.rawValue)) color=\(annotation.color ?? "none") text=\(quoted(annotation.positionData?.selectedText ?? "")) note=\(quoted(annotation.content ?? ""))"
    }

    private static func quoted(_ string: String) -> String {
        "\"\(string)\""
    }

    private static func loadTemplate(named name: String) throws -> String {
        guard let url = Bundle.main.url(forResource: name, withExtension: "md", subdirectory: "prompts")
            ?? Bundle.main.url(forResource: name, withExtension: "md") else {
            throw AiPromptError.missingTemplate(name)
        }
        return try String(contentsOf: url, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

enum AiPromptError: LocalizedError {
    case missingTemplate(String)

    var errorDescription: String? {
        switch self {
        case .missingTemplate(let name): return "Missing AI prompt template: \(name).md"
        }
    }
}
