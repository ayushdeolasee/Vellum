import Foundation
import Observation

// AI assistant state — port of src/stores/ai-store.ts (see macos/specs/SPECS-ai.md).
// STUB: the public surface below is the cross-module contract. The AI module
// implements the bodies (persistence, sendMessage pipeline, providers, tool
// engine) — signatures must not change.

enum AiRole: String, Codable, Sendable {
    case user
    case assistant
}

enum AiProvider: String, Codable, Sendable {
    case gemini
    case openai
    case codex
}

enum VoiceMode: String, Codable, Sendable {
    case off
    case pushToTalk = "push-to-talk"
}

struct AiMessage: Codable, Equatable, Identifiable, Sendable {
    var id: String
    var role: AiRole
    var content: String
    var createdAt: String
}

struct AiSettings: Codable, Equatable, Sendable {
    var provider: AiProvider = .gemini
    var model: String = "gemini-3.1-flash-lite-preview"
    var apiKey: String = ""
    var openaiModel: String = "gpt-5.5"
    var openaiApiKey: String = ""
    var codexModel: String = "gpt-5.5"
    var voiceMode: VoiceMode = .off
    var ttsEnabled: Bool = false
}

struct AiPageImageSnapshot: Sendable {
    var pageNumber: Int
    /// Raw base64, no data: prefix.
    var base64Data: String
    /// "image/jpeg"
    var mediaType: String
    var width: Int
    var height: Int
}

/// Snapshot of reader state taken at send time by the AI panel.
struct AiContextSnapshot: Sendable {
    var title: String?
    var numPages: Int
    var currentPage: Int
    var visiblePages: [Int]
    var annotations: [Annotation]
    var currentPageImage: AiPageImageSnapshot?
}

/// Result of locating a phrase in a document (PDF text layer or web content
/// script). The page can differ from the requested one for web documents.
struct LocatedText: Sendable {
    var positionData: PositionData
    var pageNumber: Int
}

@MainActor
@Observable
final class AiStore {
    // Wired in by VellumApp; used by sendMessage's tool engine.
    weak var app: AppStore?
    weak var annotationStore: AnnotationStore?

    private(set) var messages: [AiMessage] = []
    private(set) var isThinking = false
    private(set) var error: String?
    /// 1-indexed page → whitespace-normalized extracted text.
    private(set) var pageTexts: [Int: String] = [:]
    private(set) var settings = AiSettings()

    /// Registered by the PDF viewer: locate a verbatim phrase on a page at
    /// zoom 1 in top-left-origin PDF points (lib/highlight-locator.ts).
    var locatePdfTextHandler: ((Int, String) async -> LocatedText?)?
    /// Registered by the web viewer: window.__locateWebText equivalent.
    var locateWebTextHandler: ((Int, String) async -> LocatedText?)?
    /// Registered by the PDF viewer: JPEG snapshot of a rendered page, max
    /// dimension 1280, quality 0.72 (AiPanel's captureCurrentPageImage).
    var capturePageImageHandler: ((Int) async -> AiPageImageSnapshot?)?

    init() {}

    // MARK: - Contract used by other modules (implemented by the AI module)

    func setSettings(_ settings: AiSettings) {
        self.settings = settings
        // TODO(ai-module): persist to UserDefaults key research-reader-ai-settings-v1
    }

    @discardableResult
    func addLocalMessage(role: AiRole, content: String, id: String? = nil) -> String {
        // TODO(ai-module)
        return id ?? UUID().uuidString.lowercased()
    }

    func updateLocalMessage(id: String, content: String) {
        // TODO(ai-module)
    }

    func setThinkingState(_ thinking: Bool) {
        isThinking = thinking
    }

    func setErrorState(_ error: String?) {
        self.error = error
    }

    /// Restore the persisted conversation for a document (or reset when nil).
    func loadConversationForDocument(_ document: DocumentInfo?) {
        // TODO(ai-module)
    }

    /// Save an empty list (deleting the document's stored entry) and clear state.
    func clearConversation() {
        // TODO(ai-module)
    }

    /// Wipes pageTexts, messages, isThinking, error (called on doc/tab change).
    func clearDocumentContext() {
        messages = []
        isThinking = false
        error = nil
        pageTexts = [:]
    }

    /// Whitespace-normalizes and stores extracted page text (no-op if unchanged).
    func setPageText(page: Int, text: String) {
        let normalized = text
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard pageTexts[page] != normalized else { return }
        pageTexts[page] = normalized
    }

    /// Full send pipeline: key check, context block, provider dispatch, tool
    /// loop, persistence — see SPECS-ai.md "sendMessage pipeline".
    func sendMessage(_ input: String, context: AiContextSnapshot) async {
        // TODO(ai-module)
    }
}
