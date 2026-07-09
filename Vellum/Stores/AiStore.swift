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
    case openrouter
    /// ChatGPT-subscription OAuth (Codex backend); no API key, uses `ChatGPTAuth`.
    case chatgpt
    /// OpenCode Zen gateway, authenticated with a pasted `sk-…` API key.
    case opencode
    /// OpenCode Go gateway (low-cost open coding models); its own `sk-…` key,
    /// separate from Zen. See `OpenCodeClient.Gateway`.
    case opencodeGo
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

/// Coarse phase of an in-flight request, surfaced by the panel's activity
/// indicator. `.streaming` means reply text is actively arriving.
enum AiActivity: Equatable, Sendable {
    case idle
    case thinking
    case reading
    case streaming
    case tool(String)
}

/// A piece of context the user has explicitly attached to the next message:
/// selected PDF text, an existing highlight, a snapshot (region or full page),
/// or a quote pulled from a previous AI reply. Rendered as chips in the
/// composer and folded into the prompt / image inputs at send time.
struct AiReference: Identifiable, Equatable, Sendable {
    enum Kind: Equatable, Sendable {
        case selection(text: String, page: Int)
        case highlight(text: String, page: Int)
        case region(image: AiPageImageSnapshot, page: Int)
        case pageSnapshot(image: AiPageImageSnapshot, page: Int)
        case quote(text: String, messageId: String)
    }
    let id: String
    var kind: Kind

    init(id: String = UUID().uuidString.lowercased(), kind: Kind) {
        self.id = id
        self.kind = kind
    }

    /// The image payload, if this reference carries one.
    var image: AiPageImageSnapshot? {
        switch kind {
        case let .region(image, _), let .pageSnapshot(image, _): return image
        default: return nil
        }
    }
}

extension AiPageImageSnapshot: Equatable {
    static func == (lhs: AiPageImageSnapshot, rhs: AiPageImageSnapshot) -> Bool {
        lhs.pageNumber == rhs.pageNumber
            && lhs.base64Data == rhs.base64Data
            && lhs.mediaType == rhs.mediaType
    }
}

struct AiSettings: Codable, Equatable, Sendable {
    var provider: AiProvider = .gemini
    var model: String = "gemini-3.1-flash-lite-preview"
    var apiKey: String = ""
    var openaiModel: String = "gpt-5.5"
    var openaiApiKey: String = ""
    var openrouterModel: String = ""
    var openrouterApiKey: String = ""
    var chatgptModel: String = "gpt-5.5"
    var opencodeModel: String = "claude-opus-4-8"
    var opencodeApiKey: String = ""
    var opencodeGoModel: String = "glm-5.2"
    var opencodeGoApiKey: String = ""
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
    /// User-attached references (selection / highlight / snapshot / quote).
    var references: [AiReference] = []
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
    /// Wired in by VellumApp; owns the ChatGPT-subscription OAuth lifecycle.
    weak var chatgptAuth: ChatGPTAuth?

    private(set) var messages: [AiMessage] = []
    /// Current request phase; drives the panel's activity indicator.
    private(set) var activity: AiActivity = .idle
    /// True while a request is in flight — kept as a computed alias so existing
    /// call sites (submit guard, TTS, scroll triggers) are unaffected.
    var isThinking: Bool { activity != .idle }
    /// Id of the assistant message currently receiving streamed deltas (nil when
    /// no stream is active). The panel uses it to suppress the activity pill once
    /// text has started arriving.
    private(set) var streamingMessageId: String?
    private(set) var error: String?
    /// The in-flight request task (image capture + sendMessage), held so an
    /// explicit clear can cancel it. Fire-and-forget requests aren't otherwise
    /// interruptible.
    private var sendTask: Task<Void, Never>?
    /// 1-indexed page → whitespace-normalized extracted text.
    private(set) var pageTexts: [Int: String] = [:]
    private(set) var settings = AiSettings()

    /// Context the user has attached to the next message (selection, highlight,
    /// snapshot, or an AI-reply quote). Rendered as chips in the composer.
    private(set) var composerReferences: [AiReference] = []

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
        activity = thinking ? .thinking : .idle
    }

    func setErrorState(_ error: String?) {
        self.error = error
    }

    // MARK: - Composer references

    /// Attach a reference and reveal the AI panel so the user sees it land.
    func addReference(_ reference: AiReference) {
        composerReferences.append(reference)
        app?.sidebarTab = .ai
        app?.sidebarOpen = true
    }

    func removeReference(id: String) {
        composerReferences.removeAll { $0.id == id }
    }

    func clearComposerReferences() {
        composerReferences = []
    }

    /// Restore the persisted conversation for a document (or reset when nil).
    func loadConversationForDocument(_ document: DocumentInfo?) {
        messages = AiPersistence.loadConversation(for: document)
        activity = .idle
        streamingMessageId = nil
        composerReferences = []
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
        activity = .idle
        streamingMessageId = nil
    }

    /// Save an empty list (deleting the document's stored entry) and clear state.
    /// Also cancels any in-flight request so a completing response can't
    /// re-append the messages we just cleared.
    func clearConversation() {
        cancelActiveRequest()
        AiPersistence.saveConversation(for: app?.document, messages: [])
        messages = []
        composerReferences = []
        error = nil
    }

    /// Wipes pageTexts, messages, activity, error (called on doc/tab change).
    func clearDocumentContext() {
        messages = []
        activity = .idle
        streamingMessageId = nil
        composerReferences = []
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
        if settingsAtStart.provider == .opencode,
           settingsAtStart.opencodeApiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            error = "Set your OpenCode Zen API key in AI settings."
            return
        }
        if settingsAtStart.provider == .opencodeGo,
           settingsAtStart.opencodeGoApiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            error = "Set your OpenCode Go API key in AI settings."
            return
        }
        if settingsAtStart.provider == .chatgpt, chatgptAuth?.isSignedIn != true {
            error = "Sign in with ChatGPT in AI settings."
            return
        }

        let userMessage = AiPersistence.makeMessage(role: .user, content: trimmed)
        messages.append(userMessage)
        // Empty assistant placeholder the stream fills in-place. Kept out of the
        // persisted list until it has content so a mid-stream crash leaves no
        // empty bubble behind on reload.
        let assistantPlaceholder = AiPersistence.makeMessage(role: .assistant, content: "")
        messages.append(assistantPlaceholder)
        let assistantId = assistantPlaceholder.id
        streamingMessageId = assistantId
        activity = .thinking
        error = nil
        let messagesWithUser = Array(messages.dropLast())
        AiPersistence.saveConversation(for: documentAtStart, messages: messagesWithUser)

        // Image inputs: the auto page snapshot first, then any snapshot the user
        // explicitly attached as a reference.
        var images: [AiPageImageSnapshot] = []
        if let pageImage = context.currentPageImage { images.append(pageImage) }
        images.append(contentsOf: context.references.compactMap(\.image))

        // Guarded main-actor sink for provider events.
        let onEvent: @MainActor (AiStreamEvent) -> Void = { [weak self] event in
            guard let self, self.app?.activeTabId == sessionIdAtStart else { return }
            switch event {
            case .status(let label):
                self.activity = label.lowercased().contains("read") ? .reading : .thinking
            case .textDelta(let delta):
                self.appendStreamDelta(id: assistantId, delta)
                self.activity = .streaming
            case .toolStarted(let summary):
                self.activity = .tool(summary)
            case .toolFinished:
                break
            }
        }

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
                    images: images,
                    sessionIdAtStart: sessionIdAtStart,
                    toolEngine: engine,
                    onEvent: onEvent
                )
            case .openai:
                let model = settingsAtStart.openaiModel.trimmingCharacters(in: .whitespacesAndNewlines)
                result = try await OpenAIClient().generate(
                    apiKey: settingsAtStart.openaiApiKey.trimmingCharacters(in: .whitespacesAndNewlines),
                    model: model.isEmpty ? "gpt-5.5" : model,
                    systemPrompt: try AiPrompts.nativeSystemPrompt(),
                    userPrompt: AiPrompts.buildNativeToolUserPrompt(parameters),
                    images: images,
                    sessionIdAtStart: sessionIdAtStart,
                    toolEngine: engine,
                    onEvent: onEvent
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
                    images: supportsVision ? images : [],
                    allowTools: supportsTools,
                    sessionIdAtStart: sessionIdAtStart,
                    toolEngine: engine,
                    onEvent: onEvent
                )
            case .chatgpt:
                guard let chatgptAuth else {
                    throw AiClientError.message("Sign in with ChatGPT in AI settings.")
                }
                let model = settingsAtStart.chatgptModel.trimmingCharacters(in: .whitespacesAndNewlines)
                result = try await ChatGPTClient(auth: chatgptAuth).generate(
                    model: model.isEmpty ? "gpt-5.5" : model,
                    systemPrompt: try AiPrompts.nativeSystemPrompt(),
                    userPrompt: AiPrompts.buildNativeToolUserPrompt(parameters),
                    images: images,
                    sessionIdAtStart: sessionIdAtStart,
                    toolEngine: engine,
                    onEvent: onEvent
                )
            case .opencode:
                let model = settingsAtStart.opencodeModel.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !model.isEmpty else {
                    throw AiClientError.message("Choose an OpenCode Zen model in AI settings.")
                }
                result = try await OpenCodeClient(gateway: .zen).generate(
                    apiKey: settingsAtStart.opencodeApiKey.trimmingCharacters(in: .whitespacesAndNewlines),
                    model: model,
                    systemPrompt: try AiPrompts.nativeSystemPrompt(),
                    userPrompt: AiPrompts.buildNativeToolUserPrompt(parameters),
                    // Only text-only open models drop the page image; the gateway
                    // rejects image parts for models that can't read them.
                    image: AiModelCatalog.opencodeSupportsVision(model) ? context.currentPageImage : nil,
                    sessionIdAtStart: sessionIdAtStart,
                    toolEngine: engine,
                    onEvent: onEvent
                )
            case .opencodeGo:
                let model = settingsAtStart.opencodeGoModel.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !model.isEmpty else {
                    throw AiClientError.message("Choose an OpenCode Go model in AI settings.")
                }
                result = try await OpenCodeClient(gateway: .go).generate(
                    apiKey: settingsAtStart.opencodeGoApiKey.trimmingCharacters(in: .whitespacesAndNewlines),
                    model: model,
                    systemPrompt: try AiPrompts.nativeSystemPrompt(),
                    userPrompt: AiPrompts.buildNativeToolUserPrompt(parameters),
                    image: AiModelCatalog.opencodeSupportsVision(model) ? context.currentPageImage : nil,
                    sessionIdAtStart: sessionIdAtStart,
                    toolEngine: engine,
                    onEvent: onEvent
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
            let finalContent = assistantContent.trimmingCharacters(in: .whitespacesAndNewlines)
            let completed = messagesWithUser + [
                AiPersistence.makeMessage(role: .assistant, content: finalContent, id: assistantId)
            ]
            AiPersistence.saveConversation(for: documentAtStart, messages: completed)
            if app.activeTabId == sessionIdAtStart {
                messages = completed
                activity = .idle
                streamingMessageId = nil
            }
        } catch {
            // A cancelled request surfaces here as a URLSession cancellation
            // error — swallow it silently instead of showing a failure banner.
            guard !Task.isCancelled else { return }

            let detail = error.localizedDescription
            // Keep whatever streamed before the failure; otherwise show the error
            // in place of the empty placeholder.
            let streamed = messages.first(where: { $0.id == assistantId })?.content
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let content = streamed.isEmpty
                ? "I couldn't complete that request: \(detail)"
                : streamed + "\n\n_(interrupted: \(detail))_"
            let failed = messagesWithUser + [
                AiPersistence.makeMessage(role: .assistant, content: content, id: assistantId)
            ]
            AiPersistence.saveConversation(for: documentAtStart, messages: failed)
            if app.activeTabId == sessionIdAtStart {
                messages = failed
                activity = .idle
                streamingMessageId = nil
                self.error = detail
            }
        }
    }

    /// Append a streamed delta to the in-flight assistant message without
    /// persisting on every token (the final content is saved once at the end).
    private func appendStreamDelta(id: String, _ delta: String) {
        guard let index = messages.firstIndex(where: { $0.id == id }) else { return }
        messages[index].content += delta
    }

}
