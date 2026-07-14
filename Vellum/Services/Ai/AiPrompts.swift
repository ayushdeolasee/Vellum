import Foundation

struct AiPromptParameters {
    var conversation: String
    var context: String
    var latestUserRequest: String
}

/// The native-tool user prompt split into a cacheable prefix and a per-message
/// tail (PR A.5). Providers that place an Anthropic-style `cache_control`
/// breakpoint (OpenRouter, OpenCode Zen) send `stable` and `volatile` as
/// separate content parts with the breakpoint on their boundary; providers
/// without a breakpoint API (Gemini, OpenAI, ChatGPT) send `joined`.
struct AiUserPrompt {
    /// "### Document Context" header + the session-stable context block.
    var stable: String
    /// "### Recent Conversation" + conversation + "### Latest User Request" +
    /// request — the part that changes every message.
    var volatile: String

    /// The commit-1 fused prompt joins these eight elements with "\n":
    ///   ["### Document Context", context, "", "### Recent Conversation",
    ///    conversation, "", "### Latest User Request", request]
    /// Splitting after the stable half leaves a blank-line "" element between
    /// the two halves, contributing "\n" + "" + "\n" == "\n\n". `stable` ends
    /// at `context` and `volatile` starts at "### Recent Conversation", so
    /// joining with "\n\n" reproduces the fused string byte-for-byte.
    var joined: String { stable + "\n\n" + volatile }
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

    /// Stable-first ordering (Document Context → Recent Conversation → Latest
    /// User Request) so the cacheable prefix — document context — leads and the
    /// per-message volatile tail (conversation + request) trails. See PR A.5.
    /// Returns the two halves split on the section boundary; `AiUserPrompt.joined`
    /// reproduces the fused single-string prompt byte-for-byte.
    static func buildNativeToolUserPrompt(_ parameters: AiPromptParameters) -> AiUserPrompt {
        let stable = [
            "### Document Context",
            parameters.context,
        ].joined(separator: "\n")
        let volatile = [
            "### Recent Conversation",
            parameters.conversation,
            "",
            "### Latest User Request",
            parameters.latestUserRequest,
        ].joined(separator: "\n")
        return AiUserPrompt(stable: stable, volatile: volatile)
    }

    static func buildConversationBlock(_ messages: [AiMessage]) -> String {
        messages.suffix(10).map { "\($0.role.rawValue.uppercased()): \($0.content)" }
            .joined(separator: "\n")
    }

    /// The default per-message context slice (pull model): only the current
    /// page's text + annotations, document metadata, the optional current-page
    /// image, and user-attached references. The model reaches anything else via
    /// the `searchDocument` / `getPageText` tools rather than a full-text dump.
    static func buildContextBlock(pageTexts: [Int: String], context: AiContextSnapshot) -> String {
        let rawCurrent = pageTexts[context.currentPage] ?? ""
        let currentText: String
        if rawCurrent.count > maxContextCharacters {
            let end = rawCurrent.index(rawCurrent.startIndex, offsetBy: maxContextCharacters)
            currentText = String(rawCurrent[..<end]) + "\n[truncated]"
        } else {
            currentText = rawCurrent
        }

        let currentAnnotations = context.annotations
            // Bookmarks carry no content/selectedText, so they'd render as empty
            // noise here — skip them, mirroring getPageText's annotations section.
            .filter { $0.pageNumber == context.currentPage && $0.type != .bookmark }
            .suffix(50)
            .map(annotationLine)
            .joined(separator: "\n")
        let image = context.currentPageImage.map {
            "attached (\($0.width)x\($0.height), \($0.mediaType))"
        } ?? "none"

        let referenced = boundedReferencedBlock(context.references.map(referenceLine).joined(separator: "\n"))

        // Ordered most-stable-first so the leading bytes stay identical across a
        // session and stay cacheable (PR A.5). Session-invariant document
        // metadata and current-page content lead; the volatile tail (visible
        // pages, which shift on scroll, and the per-render image dimensions)
        // follows; the per-message user-referenced block trails last.
        return [
            "Document title: \(context.title ?? "Untitled")",
            "Total pages: \(context.numPages)",
            "Current page: \(context.currentPage)",
            "",
            "Current page text (page \(context.currentPage)):",
            currentText.isEmpty
                ? "(no extractable text on this page — it may be scanned; request a page image, or search other pages)"
                : currentText,
            "",
            "Current page annotations:",
            currentAnnotations.isEmpty ? "(none)" : currentAnnotations,
            "",
            "Visible pages: \(context.visiblePages.isEmpty ? "none" : context.visiblePages.map(String.init).joined(separator: ", "))",
            "Current page image: \(image)",
            "",
            "User-referenced context (the user explicitly attached these to this message — prioritize them):",
            referenced.isEmpty ? "(none)" : referenced,
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
        case let .image(image, name):
            // No page: an attached image comes from outside the document.
            return "- [attached image: \(name)] image attached (\(image.width)x\(image.height))"
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
