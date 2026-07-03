import Foundation

struct AiPromptParameters {
    var conversation: String
    var context: String
    var latestUserRequest: String
}

enum AiPrompts {
    static let maxContextCharacters = 120_000

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

    static func buildToolModePrompt(_ parameters: AiPromptParameters) throws -> String {
        let descriptions = try loadTemplate(named: "tool-descriptions")
        let template = try loadTemplate(named: "tool-mode-system")
            .replacingOccurrences(of: "{{TOOL_DESCRIPTIONS}}", with: descriptions)
        return render(template, replacements: [
            "CONVERSATION": parameters.conversation,
            "CONTEXT": parameters.context,
            "LATEST_USER_REQUEST": parameters.latestUserRequest,
        ])
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

        return [
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

    private static func annotationLine(_ annotation: Annotation) -> String {
        "- (\(annotation.type.rawValue)) color=\(annotation.color ?? "none") text=\(quoted(annotation.positionData?.selectedText ?? "")) note=\(quoted(annotation.content ?? ""))"
    }

    private static func quoted(_ string: String) -> String {
        "\"\(string)\""
    }

    private static func render(_ template: String, replacements: [String: String]) -> String {
        replacements.reduce(template) { result, replacement in
            result.replacingOccurrences(of: "{{\(replacement.key)}}", with: replacement.value)
        }.trimmingCharacters(in: .whitespacesAndNewlines)
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
