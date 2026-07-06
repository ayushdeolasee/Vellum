import Foundation
import Observation

// AI assistant state — port of src/stores/ai-store.ts (see macos/specs/SPECS-ai.md).

enum AiRole: String, Codable, Sendable {
    case user
    case assistant
}

enum AiProvider: String, Codable, Sendable {
    case gemini
    case openai
    case codex
    case openrouter
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
    var openrouterModel: String = ""
    var openrouterApiKey: String = ""
    /// Model ids the user has pinned to the top of the model selector.
    var pinnedModels: [String] = []
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
    /// Wired in by VellumApp; used to resolve OpenRouter model capabilities.
    weak var openRouterCatalog: OpenRouterCatalog?

    private(set) var messages: [AiMessage] = []
    private(set) var isThinking = false
    private(set) var error: String?
    /// The in-flight request task (image capture + sendMessage), held so an
    /// explicit clear can cancel it. Fire-and-forget requests aren't otherwise
    /// interruptible.
    private var sendTask: Task<Void, Never>?
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

    init() {
        settings = AiPersistence.loadSettings()
    }

    // MARK: - Contract used by other modules (implemented by the AI module)

    func setSettings(_ settings: AiSettings) {
        self.settings = settings
        AiPersistence.saveSettings(settings)
    }

    @discardableResult
    func addLocalMessage(role: AiRole, content: String, id: String? = nil) -> String {
        let message = AiPersistence.makeMessage(role: role, content: content, id: id)
        messages.append(message)
        AiPersistence.saveConversation(for: app?.document, messages: messages)
        return message.id
    }

    func updateLocalMessage(id: String, content: String) {
        messages = messages.map { message in
            guard message.id == id else { return message }
            var next = message
            next.content = content
            return next
        }
        AiPersistence.saveConversation(for: app?.document, messages: messages)
    }

    func setThinkingState(_ thinking: Bool) {
        isThinking = thinking
    }

    func setErrorState(_ error: String?) {
        self.error = error
    }

    /// Restore the persisted conversation for a document (or reset when nil).
    func loadConversationForDocument(_ document: DocumentInfo?) {
        messages = AiPersistence.loadConversation(for: document)
        isThinking = false
        error = nil
    }

    /// Register the current in-flight request task so it can be cancelled.
    func registerSendTask(_ task: Task<Void, Never>?) {
        sendTask = task
    }

    /// Cancel any in-flight request and stop the thinking indicator.
    func cancelActiveRequest() {
        sendTask?.cancel()
        sendTask = nil
        isThinking = false
    }

    /// Save an empty list (deleting the document's stored entry) and clear state.
    /// Also cancels any in-flight request so a completing response can't
    /// re-append the messages we just cleared.
    func clearConversation() {
        cancelActiveRequest()
        AiPersistence.saveConversation(for: app?.document, messages: [])
        messages = []
        error = nil
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
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let app,
              let annotationStore,
              let sessionIdAtStart = app.activeTabId,
              let documentAtStart = app.document else { return }

        let settingsAtStart = settings
        if settingsAtStart.provider == .openai,
           settingsAtStart.openaiApiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            error = "Set your OpenAI API key in AI settings."
            return
        }
        if settingsAtStart.provider == .gemini,
           settingsAtStart.apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            error = "Set your Gemini API key in AI settings."
            return
        }
        if settingsAtStart.provider == .openrouter,
           settingsAtStart.openrouterApiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            error = "Set your OpenRouter API key in AI settings."
            return
        }

        let userMessage = AiPersistence.makeMessage(role: .user, content: trimmed)
        messages.append(userMessage)
        isThinking = true
        error = nil
        let messagesWithUser = messages
        AiPersistence.saveConversation(for: documentAtStart, messages: messagesWithUser)

        do {
            let conversation = AiPrompts.buildConversationBlock(messagesWithUser)
            let parameters = AiPromptParameters(
                conversation: conversation.isEmpty ? "(start of conversation)" : conversation,
                context: AiPrompts.buildContextBlock(pageTexts: pageTexts, context: context),
                latestUserRequest: trimmed
            )
            let engine = AiToolEngine(store: self, app: app, annotations: annotationStore)
            let result: AiProviderResult
            switch settingsAtStart.provider {
            case .gemini:
                let model = settingsAtStart.model.trimmingCharacters(in: .whitespacesAndNewlines)
                result = try await GeminiClient().generate(
                    apiKey: settingsAtStart.apiKey.trimmingCharacters(in: .whitespacesAndNewlines),
                    model: model.isEmpty ? "gemini-3.1-flash-lite-preview" : model,
                    systemPrompt: try AiPrompts.nativeSystemPrompt(),
                    userPrompt: AiPrompts.buildNativeToolUserPrompt(parameters),
                    image: context.currentPageImage,
                    sessionIdAtStart: sessionIdAtStart,
                    toolEngine: engine
                )
            case .openai:
                let model = settingsAtStart.openaiModel.trimmingCharacters(in: .whitespacesAndNewlines)
                result = try await OpenAIClient().generate(
                    apiKey: settingsAtStart.openaiApiKey.trimmingCharacters(in: .whitespacesAndNewlines),
                    model: model.isEmpty ? "gpt-5.5" : model,
                    systemPrompt: try AiPrompts.nativeSystemPrompt(),
                    userPrompt: AiPrompts.buildNativeToolUserPrompt(parameters),
                    image: context.currentPageImage,
                    sessionIdAtStart: sessionIdAtStart,
                    toolEngine: engine
                )
            case .openrouter:
                let model = settingsAtStart.openrouterModel.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !model.isEmpty else {
                    throw AiClientError.message("Choose an OpenRouter model in AI settings.")
                }
                // Unknown ids (stale cache) default to permissive so we never
                // silently strip a capability the model actually has.
                let capabilities = openRouterCatalog?.model(for: model)
                let supportsVision = capabilities?.supportsVision ?? true
                let supportsTools = capabilities?.supportsTools ?? true
                result = try await OpenRouterClient().generate(
                    apiKey: settingsAtStart.openrouterApiKey.trimmingCharacters(in: .whitespacesAndNewlines),
                    model: model,
                    systemPrompt: try AiPrompts.nativeSystemPrompt(),
                    userPrompt: AiPrompts.buildNativeToolUserPrompt(parameters),
                    image: supportsVision ? context.currentPageImage : nil,
                    allowTools: supportsTools,
                    sessionIdAtStart: sessionIdAtStart,
                    toolEngine: engine
                )
            case .codex:
                let model = settingsAtStart.codexModel.trimmingCharacters(in: .whitespacesAndNewlines)
                let image = context.currentPageImage.map {
                    CodexAiImageInput(base64Data: $0.base64Data, mediaType: $0.mediaType)
                }
                let raw = try await app.sessions.runCodexAi(
                    prompt: AiPrompts.buildToolModePrompt(parameters),
                    model: model.isEmpty ? "gpt-5.5" : model,
                    image: image
                )
                result = await parseAndRunCodex(
                    raw,
                    engine: engine,
                    sessionIdAtStart: sessionIdAtStart,
                    app: app
                )
            }

            // Cancelled mid-request (e.g. the user cleared the conversation):
            // drop the result without persisting or re-appending messages.
            guard !Task.isCancelled else { return }

            let assistantContent: String
            if result.actionResults.isEmpty {
                assistantContent = result.reply
            } else {
                assistantContent = result.reply + "\n\nActions:\n"
                    + result.actionResults.map { "- \($0)" }.joined(separator: "\n")
            }
            let assistant = AiPersistence.makeMessage(
                role: .assistant,
                content: assistantContent.trimmingCharacters(in: .whitespacesAndNewlines)
            )
            let completed = messagesWithUser + [assistant]
            AiPersistence.saveConversation(for: documentAtStart, messages: completed)
            if app.activeTabId == sessionIdAtStart {
                messages = completed
                isThinking = false
            }
        } catch {
            // A cancelled request surfaces here as a URLSession cancellation
            // error — swallow it silently instead of showing a failure banner.
            guard !Task.isCancelled else { return }

            let detail = error.localizedDescription
            let assistant = AiPersistence.makeMessage(
                role: .assistant,
                content: "I couldn't complete that request: \(detail)"
            )
            let failed = messagesWithUser + [assistant]
            AiPersistence.saveConversation(for: documentAtStart, messages: failed)
            if app.activeTabId == sessionIdAtStart {
                messages = failed
                isThinking = false
                self.error = detail
            }
        }
    }

    private func parseAndRunCodex(
        _ raw: String,
        engine: AiToolEngine,
        sessionIdAtStart: String,
        app: AppStore
    ) async -> AiProviderResult {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return AiProviderResult(reply: "I couldn't produce a response.", actionResults: [])
        }
        let jsonText: String
        if let first = trimmed.firstIndex(of: "{"), let last = trimmed.lastIndex(of: "}"), first < last {
            jsonText = String(trimmed[first...last])
        } else {
            jsonText = trimmed
        }
        guard let data = jsonText.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return AiProviderResult(reply: trimmed, actionResults: [])
        }
        let parsedReply = (object["reply"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let reply = parsedReply?.isEmpty == false ? parsedReply! : trimmed
        let rawActions = object["actions"] as? [[String: Any]] ?? []
        var actionResults: [String] = []
        for rawAction in rawActions {
            guard actionResults.count < AiToolEngine.maxActions,
                  app.activeTabId == sessionIdAtStart,
                  let tool = rawAction["tool"] as? String,
                  ["goToPage", "addNote", "addHighlight"].contains(tool),
                  let args = rawAction["args"] as? [String: Any] else { continue }
            let action = AiToolAction(
                tool: tool,
                args: AiToolArguments(
                    pageNumber: (args["pageNumber"] as? NSNumber)?.doubleValue,
                    text: args["text"] as? String,
                    color: args["color"] as? String,
                    x: (args["x"] as? NSNumber)?.doubleValue,
                    y: (args["y"] as? NSNumber)?.doubleValue
                )
            )
            let result = await engine.run(
                action,
                sessionIdAtStart: sessionIdAtStart,
                actionCount: actionResults.count
            )
            actionResults.append(result)
        }
        return AiProviderResult(reply: reply, actionResults: actionResults)
    }
}
