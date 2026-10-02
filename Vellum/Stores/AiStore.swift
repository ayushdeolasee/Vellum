import Foundation
import Observation
import UniformTypeIdentifiers

// AI assistant state — port of src/stores/ai-store.ts (see macos/specs/SPECS-ai.md).

enum AiRole: String, Codable, Sendable {
    case user
    case assistant
}

enum AiProvider: String, Codable, Sendable, CaseIterable, Identifiable {
    case gemini
    case openai
    case openrouter
    /// OpenCode Zen gateway, authenticated with a pasted `sk-…` API key.
    case opencode
    /// OpenCode Go gateway (low-cost open coding models); its own `sk-…` key,
    /// separate from Zen. See `OpenCodeClient.Gateway`.
    case opencodeGo
}

/// User-selected reasoning/thinking effort, applied to whichever provider is
/// active. Each provider maps it to its own API (Responses `reasoning.effort`,
/// Gemini `thinkingConfig.thinkingBudget`, chat `reasoning_effort`, …).
/// `.auto` preserves Vellum's prior cost-guarded per-provider defaults.
enum AiThinkingMode: String, Codable, Sendable, CaseIterable {
    case auto, instant, low, medium, high

    var label: String {
        switch self {
        case .auto: "Auto"
        case .instant: "Instant"
        case .low: "Low"
        case .medium: "Medium"
        case .high: "High"
        }
    }
    /// The `effort` string for providers that take Responses/OpenAI-style
    /// reasoning effort (nil when the mode shouldn't set one). `.auto` returns nil
    /// (caller supplies the provider's prior default).
    var openAIEffort: String? {
        switch self {
        case .auto: nil
        case .instant: "minimal"
        case .low: "low"
        case .medium: "medium"
        case .high: "high"
        }
    }
}

struct AiMessage: Codable, Equatable, Identifiable, Sendable {
    var id: String
    var role: AiRole
    var content: String
    var createdAt: String
    /// Per-response token/cost telemetry; absent on messages persisted
    /// before telemetry existed and on user messages.
    var usage: AiUsage? = nil
    /// What the user had attached to the composer when they sent this message
    /// (selection, highlight, snapshot, quote, image). Persisted so the
    /// transcript can keep showing *what* a past prompt referenced after the
    /// composer chips are cleared — the reference text is deliberately NOT part
    /// of `content`; it only ever reaches the model through the prompt's
    /// "User-referenced context" block (`AiPrompts.buildContextBlock`). Empty on
    /// assistant messages and on every conversation written before this field
    /// existed.
    ///
    /// Image-carrying references are stored with their base64 pixels dropped —
    /// see `AiReference.strippingImageData`.
    var references: [AiReference] = []

    /// Compact, structured sources and document actions used for this reply.
    /// Optional so conversations persisted before this UI existed decode unchanged,
    /// and so `nil` (never had summaries — eligible for the legacy-receipt upgrade
    /// in `displayToolSummaries`) stays distinguishable from `[]` (ran no tools).
    var toolSummaries: [AiToolSummary]? = nil

    /// Explicit so `encode(to:)` synthesis and the hand-written `init(from:)`
    /// below agree on the on-disk key names. Every stored property must be
    /// listed: an omission here silently drops the field from both the encoded
    /// file and the decode, with no compiler error.
    private enum CodingKeys: String, CodingKey {
        case id, role, content, createdAt, usage, references, toolSummaries
    }
}

extension AiMessage {
    /// Hand-rolled decoding so old transcripts keep loading.
    ///
    /// Two compatibility problems the synthesized initializer can't solve:
    /// `references` is absent from every conversation persisted before this
    /// field existed (handled by `decodeIfPresent` + the `[]` default), and a
    /// reference whose `kind` tag this build doesn't recognise would otherwise
    /// throw — and failing here fails the whole message. Unreadable entries are
    /// dropped instead, so an unknown reference costs the user one chip rather
    /// than the message carrying it. `AiPersistence.decodeMessages` applies the
    /// same idea one level up (`LossyAiMessage`), so a message this initializer
    /// cannot salvage at all costs them that message rather than the whole
    /// conversation.
    ///
    /// Declared in an extension so the memberwise initializer survives (several
    /// call sites build `AiMessage` field-by-field).
    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        role = try container.decode(AiRole.self, forKey: .role)
        content = try container.decode(String.self, forKey: .content)
        createdAt = try container.decode(String.self, forKey: .createdAt)
        usage = try container.decodeIfPresent(AiUsage.self, forKey: .usage)
        // `try?` on the array too: a `references` value that isn't even an array
        // (hand-edited file, future format) degrades to "no references" rather
        // than failing the message.
        let lossy = try? container.decodeIfPresent([LossyAiReference].self, forKey: .references)
        references = lossy?.compactMap(\.value) ?? []
        // Decoded strictly, matching the synthesized behaviour this hand-written
        // initializer replaced. `decodeIfPresent` keeps the nil/[] distinction
        // `displayToolSummaries` relies on to decide whether a legacy "Actions:"
        // receipt should be upgraded.
        toolSummaries = try container.decodeIfPresent([AiToolSummary].self, forKey: .toolSummaries)
    }
}

/// Array element wrapper that turns a failed `AiReference` decode into `nil`
/// instead of failing the enclosing array. See `AiMessage.init(from:)`.
private struct LossyAiReference: Decodable {
    let value: AiReference?

    init(from decoder: any Decoder) throws {
        value = try? AiReference(from: decoder)
    }
}

/// A clear transaction is tied to the exact document and tab that owned it.
/// Undo/Redo can therefore repair that document on disk without ever replacing
/// the transcript of a different tab that happens to be visible later.
struct AiConversationClearTransaction: Equatable, Sendable {
    var document: DocumentInfo
    var sessionId: String
    var removedMessages: [AiMessage]
    var bindingGeneration: UUID
}

/// Coarse phase of an in-flight request, surfaced by the panel's activity
/// indicator. `.streaming` means reply text is actively arriving.
enum AiActivity: Equatable, Sendable {
    case idle
    case thinking
    case reading
    /// Extracting page text on demand before/while a request reads the document
    /// (mainly visible during a whole-document `searchDocument`).
    case indexing
    case streaming
    case tool(String)
}

/// A piece of context the user has explicitly attached to the next message:
/// selected PDF text, an existing highlight, a snapshot (region or full page),
/// or a quote pulled from a previous AI reply. Rendered as chips in the
/// composer and folded into the prompt / image inputs at send time.
/// Persisted alongside the user message it was attached to (`AiMessage
/// .references`), so `Codable` here is a storage format with real users' data
/// behind it — see `Kind`'s hand-written coding below.
struct AiReference: Identifiable, Equatable, Sendable, Codable {
    /// `page` is meaningful for web documents too: the injected content script
    /// paginates an archived page into virtual pages (it reports pageCount and
    /// per-page text, and the AI's scroll/read tools address those numbers), so
    /// a web selection or snapshot carries a real page locator. Don't "fix" this
    /// by making the page optional.
    enum Kind: Equatable, Sendable {
        case selection(text: String, page: Int)
        case highlight(text: String, page: Int)
        case region(image: AiPageImageSnapshot, page: Int)
        case pageSnapshot(image: AiPageImageSnapshot, page: Int)
        case quote(text: String, messageId: String)
        /// An arbitrary image the user dropped on the panel or picked from
        /// Finder. It has no document position at all — unlike the cases above,
        /// which all point back into the open document.
        case image(image: AiPageImageSnapshot, name: String)
    }
    let id: String
    var kind: Kind

    init(id: String = UUID().uuidString.lowercased(), kind: Kind) {
        self.id = id
        self.kind = kind
    }

    /// The image payload, if this reference carries one.
    ///
    /// Exhaustive on purpose — no `default`. This is the gate `strippingImageData`
    /// checks before deciding a reference has nothing to strip, so a future
    /// image-carrying `Kind` case that fell through a `default: return nil` would
    /// not merely mis-render a chip: its full base64 pixels would be written to
    /// `conversations.json` on every turn, silently defeating the whole point of
    /// stripping. Listing every case makes adding one a compile error here, the
    /// same way it already is in `strippingImageData` and `text`.
    var image: AiPageImageSnapshot? {
        switch kind {
        case let .region(image, _), let .pageSnapshot(image, _), let .image(image, _): return image
        case .selection, .highlight, .quote: return nil
        }
    }

    /// The user-visible excerpt this reference carries, or nil for the
    /// image-only kinds (which have a descriptor but no text).
    var text: String? {
        switch kind {
        case let .selection(text, _), let .highlight(text, _), let .quote(text, _): return text
        case .region, .pageSnapshot, .image: return nil
        }
    }

    /// The 1-indexed document page this reference points at, or nil when it has
    /// no document position (an assistant quote, an image from outside the doc).
    var page: Int? {
        switch kind {
        case let .selection(_, page), let .highlight(_, page),
             let .region(_, page), let .pageSnapshot(_, page):
            return page
        case .quote, .image:
            return nil
        }
    }

    /// A copy safe to keep inside a persisted message: the base64 pixels are
    /// dropped, leaving the descriptor (page, dimensions, media type, name).
    ///
    /// One page snapshot is ~200 KB of base64 and a message may carry
    /// `AiStore.maxImageReferences` of them, while `conversations.json` is
    /// re-encoded and rewritten in full on every turn — keeping the pixels would
    /// turn a few-KB transcript into megabytes of rewrite churn for data nothing
    /// reads back. The transcript's sent-reference chips are icon+label only
    /// (deliberately: see `SentReferenceChips`), so nothing visible is lost. The
    /// model still gets the full-resolution image — `sendMessage` builds its
    /// image inputs from the live `AiContextSnapshot.references`, never from the
    /// persisted message.
    var strippingImageData: AiReference {
        guard image != nil else { return self }
        var copy = self
        switch kind {
        case let .region(image, page):
            copy.kind = .region(image: image.strippingPixels, page: page)
        case let .pageSnapshot(image, page):
            copy.kind = .pageSnapshot(image: image.strippingPixels, page: page)
        case let .image(image, name):
            copy.kind = .image(image: image.strippingPixels, name: name)
        case .selection, .highlight, .quote:
            break  // unreachable: `image` is nil for these, guarded above
        }
        return copy
    }

    /// A copy whose excerpt is truncated to `limit` characters. Image-only kinds
    /// come back unchanged. Used by `AiPersistence.limit` to bound what one
    /// message can write to disk, mirroring the cap on `AiMessage.content`.
    func truncatingText(to limit: Int) -> AiReference {
        guard let text, text.count > limit else { return self }
        let end = text.index(text.startIndex, offsetBy: limit)
        let clipped = String(text[..<end]) + "…"
        var copy = self
        switch kind {
        case let .selection(_, page): copy.kind = .selection(text: clipped, page: page)
        case let .highlight(_, page): copy.kind = .highlight(text: clipped, page: page)
        case let .quote(_, messageId): copy.kind = .quote(text: clipped, messageId: messageId)
        case .region, .pageSnapshot, .image:
            break  // unreachable: `text` is nil for these, guarded above
        }
        return copy
    }
}

extension AiReference.Kind: Codable {
    /// The persisted discriminator. Hand-written rather than leaning on Swift's
    /// synthesized enum encoding because these strings land in users'
    /// `conversations.json` permanently: synthesis derives the key from the Swift
    /// case name, so a later rename or a reordered payload would silently make
    /// every previously saved reference undecodable. Adding a case here is safe
    /// (old builds drop what they can't read — see `AiMessage.init(from:)`);
    /// changing a string is not.
    private enum Tag: String, Codable {
        case selection, highlight, region, pageSnapshot, quote, image
    }

    private enum CodingKeys: String, CodingKey {
        case tag, text, page, image, messageId, name
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(Tag.self, forKey: .tag) {
        case .selection:
            self = .selection(
                text: try container.decode(String.self, forKey: .text),
                page: try container.decode(Int.self, forKey: .page))
        case .highlight:
            self = .highlight(
                text: try container.decode(String.self, forKey: .text),
                page: try container.decode(Int.self, forKey: .page))
        case .region:
            self = .region(
                image: try container.decode(AiPageImageSnapshot.self, forKey: .image),
                page: try container.decode(Int.self, forKey: .page))
        case .pageSnapshot:
            self = .pageSnapshot(
                image: try container.decode(AiPageImageSnapshot.self, forKey: .image),
                page: try container.decode(Int.self, forKey: .page))
        case .quote:
            self = .quote(
                text: try container.decode(String.self, forKey: .text),
                messageId: try container.decode(String.self, forKey: .messageId))
        case .image:
            self = .image(
                image: try container.decode(AiPageImageSnapshot.self, forKey: .image),
                name: try container.decode(String.self, forKey: .name))
        }
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case let .selection(text, page):
            try container.encode(Tag.selection, forKey: .tag)
            try container.encode(text, forKey: .text)
            try container.encode(page, forKey: .page)
        case let .highlight(text, page):
            try container.encode(Tag.highlight, forKey: .tag)
            try container.encode(text, forKey: .text)
            try container.encode(page, forKey: .page)
        case let .region(image, page):
            try container.encode(Tag.region, forKey: .tag)
            try container.encode(image, forKey: .image)
            try container.encode(page, forKey: .page)
        case let .pageSnapshot(image, page):
            try container.encode(Tag.pageSnapshot, forKey: .tag)
            try container.encode(image, forKey: .image)
            try container.encode(page, forKey: .page)
        case let .quote(text, messageId):
            try container.encode(Tag.quote, forKey: .tag)
            try container.encode(text, forKey: .text)
            try container.encode(messageId, forKey: .messageId)
        case let .image(image, name):
            try container.encode(Tag.image, forKey: .tag)
            try container.encode(image, forKey: .image)
            try container.encode(name, forKey: .name)
        }
    }
}

extension AiPageImageSnapshot: Equatable {
    static func == (lhs: AiPageImageSnapshot, rhs: AiPageImageSnapshot) -> Bool {
        lhs.pageNumber == rhs.pageNumber
            && lhs.base64Data == rhs.base64Data
            && lhs.mediaType == rhs.mediaType
    }

    /// The same descriptor with the base64 pixels removed. See
    /// `AiReference.strippingImageData` for why persisting them is a bad trade.
    var strippingPixels: AiPageImageSnapshot {
        var copy = self
        copy.base64Data = ""
        return copy
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
    var opencodeModel: String = "claude-opus-4-8"
    var opencodeApiKey: String = ""
    var opencodeGoModel: String = "glm-5.2"
    var opencodeGoApiKey: String = ""
    /// Model ids the user has pinned to the top of the model selector.
    var pinnedModels: [String] = []
    var reasoningEffort: AiThinkingMode = .auto

    func isConfigured() -> Bool {
        switch provider {
        case .gemini:
            hasValue(apiKey) && hasValue(model)
        case .openai:
            hasValue(openaiApiKey) && hasValue(openaiModel)
        case .openrouter:
            hasValue(openrouterApiKey) && hasValue(openrouterModel)
        case .opencode:
            hasValue(opencodeApiKey) && hasValue(opencodeModel)
        case .opencodeGo:
            hasValue(opencodeGoApiKey) && hasValue(opencodeGoModel)
        }
    }

    private func hasValue(_ value: String) -> Bool {
        !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

struct AiPageImageSnapshot: Codable, Sendable {
    /// Source page for a page/region capture; nil for an arbitrary attached
    /// image (a Finder drop or file pick), which has no document position.
    /// Mirrors `ScratchpadImageCapture.pageNumber`.
    var pageNumber: Int?
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

/// The exact destination a reference capture was started for, captured *before*
/// the `await`. A pane reuses one `AiStore` across every tab it shows, so a page
/// or region snapshot that finishes rendering after the user switched tabs would
/// otherwise land its bytes in the composer of a document it has nothing to do
/// with. Comparing tab id alone isn't enough: a tab can be re-pointed at another
/// document in place (open-in-tab, a web navigation), so the document's kind,
/// path and stamped id are part of the identity too.
struct AiReferenceTarget: Equatable, Sendable {
    var sessionId: String
    var kind: DocumentKind
    var path: String
    var documentId: String?
    var bindingGeneration: UUID? = nil
}

/// Result of locating a phrase in a document (PDF text layer or web content
/// script). The page can differ from the requested one for web documents.
struct LocatedText: Sendable {
    var positionData: PositionData
    var pageNumber: Int
}

/// Request-local output survives cancellation without consulting another
/// document's mutable transcript. Authority stays immutable for the provider turn.
@MainActor
private final class AiDocumentRequest {
    let token: UUID
    let binding: DocumentBinding
    let document: DocumentInfo
    let coordinator: StorageCoordinator?
    let messagesWithUser: [AiMessage]
    let assistantId: String
    var streamedText = ""
    var providerTask: Task<AiProviderResult, Error>?

    init(token: UUID = UUID(), binding: DocumentBinding, document: DocumentInfo,
         coordinator: StorageCoordinator?, messagesWithUser: [AiMessage], assistantId: String) {
        self.token = token
        self.binding = binding
        self.document = document
        self.coordinator = coordinator
        self.messagesWithUser = messagesWithUser
        self.assistantId = assistantId
    }

    var accumulatedHistory: [AiMessage] {
        let text = streamedText.trimmingCharacters(in: .whitespacesAndNewlines)
        return AiPersistence.limitedMessages(messagesWithUser + (text.isEmpty ? [] : [
            AiPersistence.makeMessage(role: .assistant, content: text, id: assistantId)
        ]))
    }
}

@MainActor
@Observable
final class AiStore {
    // Wired in by VellumApp; used by sendMessage's tool engine.
    weak var app: AppStore? {
        didSet {
            app?.aiStore = self
            contextBinding = app?.activeDocumentBinding
        }
    }
    weak var annotationStore: AnnotationStore?
    /// Wired in by VellumApp; used to resolve OpenRouter model capabilities.
    weak var openRouterCatalog: OpenRouterCatalog?

    private(set) var messages: [AiMessage] = []
    /// Current request phase; drives the panel's activity indicator.
    private(set) var activity: AiActivity = .idle
    /// True while a request is in flight — kept as a computed alias so existing
    /// call sites (submit guard, scroll triggers) are unaffected.
    var isThinking: Bool { activity != .idle }
    /// Id of the assistant message currently receiving streamed deltas (nil when
    /// no stream is active). The panel uses it to suppress the activity pill once
    /// text has started arriving.
    private(set) var streamingMessageId: String?
    private(set) var error: String?
    /// Transient notice the AI panel shows as a floating toast when an
    /// attachment drop/pick is declined (a non-image file, or a folder/
    /// unreadable path). Unlike `error`, this NEVER renders inline in the
    /// transcript — it floats over the messages area above the composer and
    /// auto-dismisses. Set by `showAttachmentNotice`, cleared after 15 seconds
    /// or by the toast's × button; nil when nothing is showing. Mirrors
    /// `ScratchpadStore.dropWarning`.
    private(set) var attachmentNotice: String?
    /// The auto-clear timer for `attachmentNotice`; cancelled/reset each time a
    /// new notice is shown so the latest message stays up for its full window.
    @ObservationIgnored private var attachmentNoticeTask: Task<Void, Never>?
    /// The in-flight request task (image capture + sendMessage), held so an
    /// explicit clear can cancel it. Fire-and-forget requests aren't otherwise
    /// interruptible.
    private var sendTask: Task<Void, Never>?
    @ObservationIgnored private var activeRequest: AiDocumentRequest?
    @ObservationIgnored private var promotingRequestToken: UUID?
    @ObservationIgnored private var promotionReloadBinding: DocumentBinding?
    @ObservationIgnored private var contextLoadGeneration = UUID()
    @ObservationIgnored private var contextBinding: DocumentBinding?
    typealias Generate = @MainActor (AiToolEngine, @MainActor (AiStreamEvent) -> Void) async throws -> AiProviderResult
    @ObservationIgnored private let generate: Generate?
    /// 1-indexed page → whitespace-normalized extracted text.
    private(set) var pageTexts: [Int: String] = [:]
    private(set) var settings = AiSettings()

    /// Keeps this pane's settings synchronized with changes made in Settings.
    @ObservationIgnored private var settingsObserver: NSObjectProtocol?

    /// Context the user has attached to the next message (selection, highlight,
    /// snapshot, or an AI-reply quote). Rendered as chips in the composer.
    private(set) var composerReferences: [AiReference] = []

    /// A pending, one-shot request for the SwiftUI composer to take focus (and
    /// raise the keyboard), set by every "Add to AI Chat" style action.
    ///
    /// A one-shot *token* rather than a Bool or a monotonic counter, for two
    /// reasons the simpler shapes get wrong. A Bool can't distinguish two
    /// consecutive attach actions, so the second wouldn't refocus a composer the
    /// user had tapped away from. A counter is never "spent": the observer that
    /// fulfils it remembers the last value it saw in view state, so when the
    /// panel is torn down and remounted, the rebuilt view starts at zero, sees a
    /// non-zero count, and steals focus for an attach the user performed minutes
    /// ago. Consumption clears it here in the store — the single place both the
    /// old and the new panel agree on — so a fulfilled request can't replay, and
    /// each split pane's `AiStore` owns its own token so two panes can't collide.
    private(set) var composerFocusRequest: String?

    /// Session-lifetime pixels for references already attached to a sent
    /// message, keyed by `AiReference.id`.
    ///
    /// Persisted references deliberately carry no base64 pixels (see
    /// `AiReference.strippingImageData`) — one page snapshot is ~200 KB and
    /// `conversations.json` is rewritten in full on every turn. That trade is
    /// still right for *disk*, but it also means a stripped reference has
    /// nothing for the transcript's tap-to-preview to show. This cache keeps the
    /// pixels for the current session only, so previewing a snapshot or
    /// screenshot works for the messages the user just sent; a reference loaded
    /// from a previous session has no entry here and the popover says so
    /// explicitly rather than presenting an empty frame.
    ///
    /// `@ObservationIgnored` on purpose: populating it must not invalidate the
    /// whole transcript, and every read happens inside a popover the user opened
    /// long after the write.
    @ObservationIgnored private var referenceImageCache: [String: AiPageImageSnapshot] = [:]
    /// Insertion order for `referenceImageCache`, oldest first, so the cache can
    /// be trimmed FIFO without an extra timestamp per entry.
    @ObservationIgnored private var referenceImageCacheOrder: [String] = []
    /// How many sent images stay previewable. At `maxImageReferences` (8) per
    /// message this is the last two or three image-bearing turns, ~3 MB of
    /// base64 — enough that previewing what you just sent always works, bounded
    /// so a long session can't grow without limit.
    static let maxCachedReferenceImages = 16

    /// Registered by the PDF viewer: locate a verbatim phrase on a page at
    /// zoom 1 in top-left-origin PDF points (lib/highlight-locator.ts).
    var locatePdfTextHandler: ((Int, String) async -> LocatedText?)?
    /// Registered by the web viewer: window.__locateWebText equivalent.
    var locateWebTextHandler: ((Int, String) async -> LocatedText?)?
    /// Registered by the PDF viewer: JPEG snapshot of a rendered page, max
    /// dimension 1280, quality 0.72 (AiPanel's captureCurrentPageImage).
    var capturePageImageHandler: ((Int) async -> AiPageImageSnapshot?)?
    /// Registered by the PDF viewer: synchronously extract the given 1-indexed
    /// pages' text into `pageTexts` (no idle pacing); `nil` extracts the whole
    /// document. Returns how many pages were newly populated. Web documents load
    /// their full text up front, so none is registered for them.
    ///
    /// - Important: **Nothing installs this on iPad yet** — no file under
    ///   `Vellum/Platform/iOS/` assigns it, so `ensureExtracted` returns 0 and
    ///   `AiToolEngine.getPageText`/`searchDocument` and the per-turn context
    ///   fill read only what the background walk has already produced. That is
    ///   a known parity gap versus macOS (#129 packet 7 §5 R3), not a bug in
    ///   this property. Whoever closes it **must** route the handler's reads
    ///   through `PageTextExtractionGate.shared` at `.onDemand`: it would
    ///   otherwise become a fourth ungated producer of `PDFPage.string` bursts
    ///   and defeat the serialization the gate exists for.
    var ensureExtractedHandler: ((Set<Int>?) async -> Int)?

    init(settings: AiSettings? = nil, generate: Generate? = nil) {
        self.generate = generate
        self.settings = settings ?? AiPersistence.loadSettings()
        guard settings == nil else { return }
        settingsObserver = NotificationCenter.default.addObserver(
            forName: .vellumAiSettingsChanged, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.settings = AiPersistence.loadSettings()
            }
        }
    }

    isolated deinit {
        if let settingsObserver {
            NotificationCenter.default.removeObserver(settingsObserver)
        }
    }

    // MARK: - Contract used by other modules (implemented by the AI module)

    func setSettings(_ settings: AiSettings) {
        self.settings = settings
        AiPersistence.saveSettings(settings)
        // Every other AiStore instance (other panes, the Settings window's own)
        // reloads from disk so the change is window-wide, not just local.
        NotificationCenter.default.post(
            name: .vellumAiSettingsChanged, object: nil,
            userInfo: ["openaiApiKey": settings.openaiApiKey])
    }

    @discardableResult
    func addLocalMessage(role: AiRole, content: String, id: String? = nil) -> String {
        if activeRequest != nil { cancelActiveRequest() }
        let message = AiPersistence.makeMessage(role: role, content: content, id: id)
        messages.append(message)
        persistCurrentMutation(messages)
        return message.id
    }

    func updateLocalMessage(id: String, content: String) {
        if activeRequest != nil { cancelActiveRequest() }
        messages = messages.map { message in
            guard message.id == id else { return message }
            var next = message
            next.content = content
            return next
        }
        persistCurrentMutation(messages)
    }

    func setThinkingState(_ thinking: Bool) {
        activity = thinking ? .thinking : .idle
    }

    /// Surface a coarse activity phase. Used by the tool engine to show the
    /// `.indexing` pill while a whole-document search extracts unindexed pages.
    func setActivity(_ next: AiActivity) {
        activity = next
    }

    /// On-demand text extraction for the request/tool path: fill `pageTexts` for
    /// the given 1-indexed pages (or the whole document when `nil`) with no
    /// pacing. Idempotent with the background walk via `setPageText`'s dedupe.
    @discardableResult
    func ensureExtracted(pages: Set<Int>?) async -> Int {
        let binding = app?.activeDocumentBinding
        let handler = ensureExtractedHandler
        let count = await handler?(pages) ?? 0
        guard !Task.isCancelled, app?.activeDocumentBinding == binding else { return 0 }
        return count
    }

    func setErrorState(_ error: String?) {
        self.error = error
    }

    /// Show `message` as the attachment toast for 15 seconds; re-showing resets
    /// the timer (the prior auto-clear task is cancelled) so the latest message
    /// stays visible for its full window. Mirrors `ScratchpadStore.showWarning`.
    func showAttachmentNotice(_ message: String) {
        attachmentNotice = message
        attachmentNoticeTask?.cancel()
        attachmentNoticeTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(15))
            guard !Task.isCancelled else { return }
            self?.attachmentNotice = nil
        }
    }

    /// Dismiss the attachment toast immediately (the × button), cancelling the
    /// auto-clear timer so a stale task can't clear a later notice.
    func dismissAttachmentNotice() {
        attachmentNoticeTask?.cancel()
        attachmentNoticeTask = nil
        attachmentNotice = nil
    }

    // MARK: - Composer references

    /// Ceiling on image-carrying references in one message. Providers cap both a
    /// single image (Anthropic ~5 MB) and the whole inline request (Gemini
    /// ~20 MB), and a multi-file drop can otherwise queue a dozen photos in one
    /// gesture — blowing the request budget, and the bill.
    static let maxImageReferences = 8

    /// Whether another image can still be attached to the next message.
    var canAttachMoreImages: Bool {
        composerReferences.filter { $0.image != nil }.count < Self.maxImageReferences
    }

    /// Attach a reference, reveal the AI panel so the user sees it land, and ask
    /// the composer for the keyboard — attaching context is always the prelude
    /// to typing a question about it, and without the focus request a keyboard
    /// user is left in the document with the panel open beside them.
    func addReference(_ reference: AiReference) {
        if composerReferences.count >= AiPersistence.maxReferencesPerMessage {
            error = "You can attach at most "
                + "\(AiPersistence.maxReferencesPerMessage) references to one message."
            return
        }
        if reference.image != nil, !canAttachMoreImages {
            error = "You can attach at most \(Self.maxImageReferences) images to one message."
            return
        }
        composerReferences.append(reference)
        app?.workspace?.sidebarTab = .ai
        app?.workspace?.sidebarOpen = true
        composerFocusRequest = UUID().uuidString.lowercased()
    }

    /// Mark a focus request as fulfilled. Ignores a token that is no longer the
    /// pending one, so a late `onChange` delivered from a torn-down panel can't
    /// cancel a newer request the user has just made.
    func consumeComposerFocusRequest(_ request: String) {
        guard composerFocusRequest == request else { return }
        composerFocusRequest = nil
    }

    /// The tab + document a capture started against, to be handed back to
    /// `addCapturedReference` once the bytes are ready. See `AiReferenceTarget`.
    func currentReferenceTarget() -> AiReferenceTarget? {
        guard let app,
              let sessionId = app.activeTabId,
              let document = app.document
        else { return nil }
        return AiReferenceTarget(
            sessionId: sessionId,
            kind: document.kind,
            path: document.pdfPath,
            documentId: document.docId, bindingGeneration: app.activeDocumentBinding?.generation)
    }

    /// Attach bytes produced by an async page/region capture, but only if the
    /// pane is still showing the exact tab and document that started it.
    /// Rendering a page to JPEG takes long enough that a tab switch in between
    /// is ordinary, not a race you have to try to hit.
    @discardableResult
    func addCapturedReference(_ reference: AiReference, target: AiReferenceTarget) -> Bool {
        guard let current = currentReferenceTarget(), current == target else { return false }
        addReference(reference)
        return true
    }

    func removeReference(id: String) {
        composerReferences.removeAll { $0.id == id }
    }

    func clearComposerReferences() {
        composerReferences = []
    }

    // MARK: - Sent-reference image previews

    /// Retain the pixels of every image-bearing reference in `references` so the
    /// transcript can preview them after they've been stripped for storage.
    /// Called from `sendMessage` with the *live* references, before stripping.
    func rememberReferenceImages(_ references: [AiReference]) {
        for reference in references {
            guard let image = reference.image, !image.base64Data.isEmpty else { continue }
            if referenceImageCache.updateValue(image, forKey: reference.id) == nil {
                referenceImageCacheOrder.append(reference.id)
            }
        }
        // FIFO rather than LRU: previews are overwhelmingly opened on the most
        // recent turns, so recency of *insertion* is a good enough proxy and
        // costs no bookkeeping on the read path.
        while referenceImageCacheOrder.count > Self.maxCachedReferenceImages {
            referenceImageCache.removeValue(forKey: referenceImageCacheOrder.removeFirst())
        }
    }

    /// Decoded pixels for a reference shown in the transcript, or nil when there
    /// are none to show.
    ///
    /// Prefers whatever the reference itself carries (a live composer chip, or a
    /// message still being assembled) and falls back to this session's cache for
    /// one whose pixels were stripped on the way to disk. Returns nil for a
    /// reference restored from a previous session — the caller must say so
    /// rather than render an empty frame. Returns `Data`, not `UIImage`, so the
    /// resolution logic is testable headlessly — `SentReferenceChips` does the
    /// `UIImage(data:)` conversion. Do not "improve" this into an image type.
    func referencePreviewData(for reference: AiReference) -> Data? {
        let base64 = reference.image?.base64Data.isEmpty == false
            ? reference.image?.base64Data
            : referenceImageCache[reference.id]?.base64Data
        guard let base64, !base64.isEmpty else { return nil }
        return Data(base64Encoded: base64)
    }

    // MARK: - Attachment drops

    /// Take a drop the AI panel classified out of SwiftUI's `.onDrop` providers
    /// (`AttachmentDrop`). A Files payload is classified off the main actor and
    /// its images are attached as reference chips (non-image files are declined
    /// with a notice); raw image bytes (Photos / a browser) are normalized and
    /// attached as an image reference.
    ///
    /// Lives on the store, not the view, because this is where the images-only
    /// policy, the tab-identity guard and the image cap all live — the panel
    /// registers the drop target (and on iPad it registers two: the panel root
    /// and the composer field), but it must not each grow its own copy of the
    /// policy. macOS routes the same payloads here from its single sidebar drag
    /// catcher; the shape of this entry point is deliberately identical.
    ///
    /// Takes the whole gesture's payload, not one file at a time: a mixed drop
    /// must produce exactly one notice, not one per rejected file.
    func handleDrop(_ payload: AttachmentDropPayload) -> Bool {
        switch payload {
        case let .files(urls):
            attachFiles(at: urls)
        case let .imageData(data, name):
            attachImage(data: data, name: name)
        }
        return true
    }

    /// Read and classify each dropped/picked file off the main actor (a 48MP
    /// photo spends real time in decode + resize), then attach every image as a
    /// chip. Only images can be attached — the images-only policy shared by
    /// drag-and-drop and the attach menu's Files entry. Any non-image files in
    /// the drop are declined with a single notice that names them, so a mixed
    /// drop still lands its images and the rest is explained rather than
    /// silently dropped; folders and unreadable paths get the distinct "folder
    /// or unreadable" notice.
    func attachFiles(at urls: [URL]) {
        let target = currentReferenceTarget()
        Task { [weak self] in
            // iOS deviation from the Mac, and NOT optional: this app IS
            // sandboxed, and every URL that reaches here — from `.fileImporter`
            // or from a Files drag — is security-scoped. Reading one without
            // holding its scope open fails exactly like a missing file, so
            // `aiFileAttachment` would return nil and the user would be told
            // their PNG is "a folder or unreadable". Start/stop must bracket the
            // read itself, hence inside the per-URL map rather than around the
            // detached task. Balanced by `defer`, and only stopped when the
            // start actually succeeded (URLs already inside our own container
            // return false and must not be stopped).
            let results = await Task.detached(priority: .userInitiated) {
                urls.map { url -> (name: String, attachment: AiFileAttachment?) in
                    let scoped = url.startAccessingSecurityScopedResource()
                    defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                    return (name: url.lastPathComponent, attachment: aiFileAttachment(from: url))
                }
            }.value
            guard let self, self.currentReferenceTarget() == target else { return }

            var rejected: [String] = []    // readable, but not an attachable image
            var unreadable: [String] = []  // folders / missing / unreadable paths
            for result in results {
                switch result.attachment {
                case let .image(snapshot, name):
                    self.attachIfCurrent(
                        AiReference(kind: .image(image: snapshot, name: name)), target: target)
                case let .rejected(name):
                    rejected.append(name)
                case nil:
                    unreadable.append(result.name)
                }
            }

            // Warn once for the whole gesture, as a transient toast (NOT an
            // inline transcript error). The images-only notice takes precedence
            // (it's the policy the user is bumping into); a pure folder/
            // unreadable drop still gets its own message.
            if !rejected.isEmpty {
                let verb = rejected.count == 1 ? "wasn't" : "weren't"
                self.showAttachmentNotice(
                    "Only image files can be attached. \(Self.nameList(rejected)) \(verb) added.")
            } else if !unreadable.isEmpty {
                let tail = unreadable.count == 1
                    ? "It's a folder or unreadable."
                    : "They're folders or unreadable."
                self.showAttachmentNotice("Couldn't attach \(Self.nameList(unreadable)). \(tail)")
            }
        }
    }

    /// Format a short name list for a drop notice: `photo.png`, or
    /// `photo.png and 2 more` when several files share the same outcome.
    static func nameList(_ names: [String]) -> String {
        guard let first = names.first else { return "" }
        return names.count == 1 ? first : "\(first) and \(names.count - 1) more"
    }

    /// Normalize already-loaded image bytes off the main actor and attach them.
    func attachImage(data: Data, name: String) {
        let target = currentReferenceTarget()
        Task { [weak self] in
            let snapshot = await Task.detached(priority: .userInitiated) {
                aiImageSnapshot(from: data)
            }.value
            guard let self, let snapshot, self.currentReferenceTarget() == target else { return }
            self.addReference(AiReference(kind: .image(image: snapshot, name: name)))
        }
    }

    /// A pane's AiStore is shared by all of its tabs, and a tab switch wipes the
    /// composer — so a decode that finishes after the switch would otherwise drop
    /// document A's image into document B's next message. Same session capture
    /// `submit` uses.
    private func attachIfCurrent(_ reference: AiReference, target: AiReferenceTarget?) {
        guard currentReferenceTarget() == target else { return }
        addReference(reference)
    }

    /// Restore the persisted conversation for a document (or reset when nil).
    func loadConversationForDocument(
        _ document: DocumentInfo?, coordinator: StorageCoordinator? = nil
    ) async {
        let binding = app?.activeDocumentBinding
        if let app, let document {
            guard let current = app.tabs.first(where: { $0.id == binding?.tabId })?.document,
                  current.kind == document.kind, current.pdfPath == document.pdfPath,
                  DocumentIdentity.storageKey(for: current) == DocumentIdentity.storageKey(for: document)
            else { return }
        }
        cancelActiveRequest()
        let generation = UUID()
        contextLoadGeneration = generation
        if let document { await app?.awaitDocumentPersistence(for: document) }
        guard !Task.isCancelled, contextLoadGeneration == generation,
              app?.activeDocumentBinding == binding else { return }
        let loaded: [AiMessage]
        if let coordinator {
            loaded = await AiPersistence.loadConversation(for: document, coordinator: coordinator)
        } else {
            loaded = AiPersistence.loadConversation(for: document)
        }
        guard !Task.isCancelled, contextLoadGeneration == generation,
              app?.activeDocumentBinding == binding else { return }
        messages = loaded
        contextBinding = binding
        activity = .idle
        streamingMessageId = nil
        composerReferences = []
        error = nil
    }

    /// The UI task may restart for our own docId promotion. Its content remains
    /// the same; retain the immediate user bubble and original extraction state.
    func consumeOwnPromotionReload() -> Bool {
        guard let app, let binding = app.activeDocumentBinding else { return false }
        if promotionReloadBinding == binding {
            promotionReloadBinding = nil
            return true
        }
        if let request = activeRequest, promotingRequestToken == request.token,
           request.document.docId == nil, binding.docId != nil,
           let current = app.tabs.first(where: { $0.id == binding.tabId })?.document,
           current.kind == request.document.kind, current.pdfPath == request.document.pdfPath {
            return true
        }
        return false
    }

    /// Called synchronously by model rebinding, including A→B→A in one UI frame.
    func documentBindingDidChange() {
        let binding = app?.activeDocumentBinding
        guard contextBinding != binding else { return }
        contextBinding = binding
        if consumeOwnPromotionReload() { return }
        cancelActiveRequest()
        contextLoadGeneration = UUID()
        messages = []
        pageTexts = [:]
        annotationStore?.clearAnnotations()
        composerReferences = []
        error = nil
    }

    func registerSendTask(_ task: Task<Void, Never>?) {
        if task != nil { cancelActiveRequest() }
        sendTask = task
    }

    /// Save only the captured owner's accepted output, then revoke authority.
    /// Late callbacks cannot clear a successor's activity or schedule a save.
    func cancelActiveRequest(preservingHistory: Bool = true) {
        if let request = activeRequest {
            request.providerTask?.cancel()
            if preservingHistory {
                persist(request.accumulatedHistory, for: request)
                if app?.activeDocumentBinding == request.binding { messages = request.accumulatedHistory }
            }
        }
        activeRequest = nil
        promotingRequestToken = nil
        promotionReloadBinding = nil
        sendTask?.cancel()
        sendTask = nil
        activity = .idle
        streamingMessageId = nil
    }

    private func isCurrent(_ request: AiDocumentRequest) -> Bool {
        activeRequest === request && !Task.isCancelled
            && app?.activeDocumentBinding == request.binding
    }

    private func persist(_ history: [AiMessage], for request: AiDocumentRequest) {
        guard let app else { return }
        app.enqueueDocumentPersistence(document: request.document, generation: request.binding.generation) { owner in
            AiPersistence.saveConversation(for: owner, messages: history, coordinator: request.coordinator)
            await AiPersistence.awaitPendingFlush()
        }
    }

    /// Explicit edits join the captured owner lane after any older request history.
    private func persistCurrentMutation(_ history: [AiMessage]) {
        guard let app, let document = app.document,
              let binding = app.activeDocumentBinding else { return }
        let coordinator = app.workspace?.storageCoordinator
        let limited = AiPersistence.limitedMessages(history)
        app.enqueueDocumentPersistence(document: document, generation: binding.generation) { owner in
            await AiPersistence.awaitPendingFlush()
            AiPersistence.saveConversation(for: owner, messages: limited, coordinator: coordinator)
            await AiPersistence.awaitPendingFlush()
        }
    }

    @discardableResult
    func clearConversation() -> AiConversationClearTransaction? {
        guard !messages.isEmpty, let app, let document = app.document,
              let binding = app.activeDocumentBinding else { return nil }
        let transaction = AiConversationClearTransaction(
            document: document, sessionId: binding.tabId, removedMessages: messages,
            bindingGeneration: binding.generation)
        cancelActiveRequest(preservingHistory: false)
        persistCurrentMutation([])
        messages = []
        error = nil
        return transaction
    }

    /// Restore the captured owner's messages after its accepted pending writes.
    @discardableResult
    func undoClear(_ transaction: AiConversationClearTransaction) -> Bool {
        guard currentDocument(for: transaction) != nil, let app else { return false }
        let showing = app.activeDocumentBinding?.tabId == transaction.sessionId
        if showing { cancelActiveRequest() }
        let visible = showing ? messages : nil
        let coordinator = app.workspace?.storageCoordinator
        app.enqueueDocumentPersistence(document: transaction.document, generation: transaction.bindingGeneration) { owner in
            await AiPersistence.awaitPendingFlush()
            let current: [AiMessage]
            if let visible { current = visible }
            else if let coordinator { current = await AiPersistence.loadConversation(for: owner, coordinator: coordinator) }
            else { current = AiPersistence.loadConversation(for: owner) }
            let ids = Set(current.map(\.id))
            let restored = AiPersistence.limitedMessages(transaction.removedMessages.filter { !ids.contains($0.id) } + current)
            AiPersistence.saveConversation(for: owner, messages: restored, coordinator: coordinator)
            await AiPersistence.awaitPendingFlush()
        }
        if showing {
            let ids = Set(messages.map(\.id))
            messages = AiPersistence.limitedMessages(transaction.removedMessages.filter { !ids.contains($0.id) } + messages)
            error = nil
        }
        return true
    }

    @discardableResult
    func redoClear(_ transaction: AiConversationClearTransaction) -> Bool {
        guard currentDocument(for: transaction) != nil, let app else { return false }
        let showing = app.activeDocumentBinding?.tabId == transaction.sessionId
        if showing { cancelActiveRequest() }
        let removedIds = Set(transaction.removedMessages.map(\.id))
        let visible = showing ? messages.filter { !removedIds.contains($0.id) } : nil
        let coordinator = app.workspace?.storageCoordinator
        app.enqueueDocumentPersistence(document: transaction.document, generation: transaction.bindingGeneration) { owner in
            await AiPersistence.awaitPendingFlush()
            let remaining: [AiMessage]
            if let visible { remaining = visible }
            else if let coordinator {
                remaining = await AiPersistence.loadConversation(for: owner, coordinator: coordinator).filter { !removedIds.contains($0.id) }
            } else { remaining = AiPersistence.loadConversation(for: owner).filter { !removedIds.contains($0.id) } }
            AiPersistence.saveConversation(for: owner, messages: remaining, coordinator: coordinator)
            await AiPersistence.awaitPendingFlush()
        }
        if showing, let visible { messages = visible; error = nil }
        return true
    }

    /// A later document at the same path must never inherit this Undo. A live
    /// identity promotion is allowed only through the generation-scoped alias.
    private func currentDocument(for transaction: AiConversationClearTransaction) -> DocumentInfo? {
        guard let app, let binding = app.documentBinding(for: transaction.sessionId),
              let document = app.tabs.first(where: { $0.id == transaction.sessionId })?.document,
              document.kind == transaction.document.kind,
              document.pdfPath == transaction.document.pdfPath else { return nil }
        if binding.generation == transaction.bindingGeneration { return document }
        let owner = app.durableDocument(for: transaction.document, generation: transaction.bindingGeneration)
        guard owner.docId != transaction.document.docId, owner.docId == document.docId else { return nil }
        return document
    }

    /// Wipes pageTexts, messages, activity, error (called on doc/tab change).
    func clearDocumentContext() {
        cancelActiveRequest()
        contextLoadGeneration = UUID()
        messages = []
        activity = .idle
        streamingMessageId = nil
        composerReferences = []
        error = nil
        pageTexts = [:]
    }

    /// Whitespace-normalizes and stores extracted page text, returning the
    /// normalized string when it actually stored (nil on a dedupe no-op). The
    /// return lets the PDF viewer feed only genuinely new pages to the
    /// persistent cache without re-normalizing. Line breaks survive as single
    /// "\n"s so `searchDocument` regexes can use `^`/`$` anchors and span
    /// lines; runs of horizontal whitespace collapse to one space.
    @discardableResult
    func setPageText(page: Int, text: String) -> String? {
        let normalized = text
            .replacingOccurrences(of: "\\s*\\n\\s*", with: "\n", options: .regularExpression)
            .replacingOccurrences(of: "[ \\t\\p{Zs}]+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard pageTexts[page] != normalized else { return nil }
        pageTexts[page] = normalized
        return normalized
    }

    /// Bulk-restore page text from the persistent cache. Bypasses setPageText's
    /// per-page whitespace normalization because cached text was already
    /// normalized when first extracted — re-running the regex over a whole
    /// document on every open would be wasted work.
    func restorePageTexts(_ restored: [Int: String]) {
        // Replace, don't merge: an outgoing tab's still-running extraction can
        // write into pageTexts between clearDocumentContext and this restore,
        // and merged stale pages would be skipped (and persisted) as if they
        // belonged to the incoming document.
        pageTexts = restored
    }

    /// Below this many extracted characters the current page is treated as
    /// scanned/low-text and its rendered image is auto-attached so the model
    /// can read it visually. Pages with real text send no image by default —
    /// screenshots are volatile, expensive, and poor cache material (§6).
    static let autoPageImageTextThreshold = 200

    /// Whether the current page's screenshot should be auto-attached: only
    /// when the page looks scanned/low-text (or hasn't been extracted yet, so
    /// a scan with no extractable text still gets visual context).
    static func shouldAutoAttachPageImage(pageText: String?) -> Bool {
        (pageText?.count ?? 0) < autoPageImageTextThreshold
    }

    /// The text persisted as an assistant message: the reply, and nothing else.
    ///
    /// This used to splice the tool receipts onto the end of the answer, which
    /// is why it was called "compose". Receipts are now a structured field on
    /// the message (`toolSummaries`), so the answer stays clean — a reply can
    /// be copied, quoted or turned into a page note without dragging an
    /// "Actions:" list along with it. Kept as a named function rather than an
    /// inline `trimmingCharacters` because it is the one place that defines
    /// what "the assistant's answer" means, and `AiPipelineTests` asserts on
    /// it that no raw tool payload can ever reach a persisted message.
    nonisolated static func assistantAnswerText(reply: String) -> String {
        reply.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The conversation-block slice: everything BEFORE the newest user message.
    /// The newest request is sent separately under "### Latest User Request",
    /// so including it here would duplicate it in every prompt.
    static func promptHistory(from messages: [AiMessage]) -> [AiMessage] {
        guard let lastUserIndex = messages.lastIndex(where: { $0.role == .user }) else {
            return messages
        }
        return Array(messages[..<lastUserIndex])
    }

    /// Full send pipeline: key check, context block, provider dispatch, tool
    /// loop, persistence — see SPECS-ai.md "sendMessage pipeline".
    func sendMessage(_ input: String, context: AiContextSnapshot) async {
        let context = context
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !Task.isCancelled, !trimmed.isEmpty,
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
        guard !AiSharingConsent.needsConsent(for: settingsAtStart.provider) else {
            error = "Review and allow sharing with \(settingsAtStart.provider.displayName) before sending."
            return
        }

        guard let initialBinding = app.activeDocumentBinding else { return }
        if activeRequest != nil { cancelActiveRequest() }
        contextLoadGeneration = UUID()
        rememberReferenceImages(context.references)
        let userMessage = AiPersistence.makeMessage(
            role: .user, content: trimmed, references: context.references.map(\.strippingImageData))
        messages.append(userMessage)
        let messagesWithUser = messages
        let placeholder = AiPersistence.makeMessage(role: .assistant, content: "")
        messages.append(placeholder)
        streamingMessageId = placeholder.id
        activity = .thinking
        error = nil
        let preparing = AiDocumentRequest(
            binding: initialBinding, document: documentAtStart,
            coordinator: app.workspace?.storageCoordinator,
            messagesWithUser: messagesWithUser, assistantId: placeholder.id)
        activeRequest = preparing
        // Keep the user bubble immediate while promotion is owned by the
        // resource queue. Cancellation queues this captured history behind it.
        var binding = initialBinding
        if documentAtStart.kind == .pdf, documentAtStart.docId == nil {
            promotingRequestToken = preparing.token
            let promoted = await app.syncDocumentId(sessionId: sessionIdAtStart)
            guard activeRequest === preparing, !Task.isCancelled,
                  let promoted, app.activeDocumentBinding == promoted else {
                if activeRequest === preparing { cancelActiveRequest() }
                return
            }
            binding = promoted
            promotionReloadBinding = promoted == initialBinding ? nil : promoted
            promotingRequestToken = nil
        }
        guard activeRequest === preparing, !Task.isCancelled,
              app.activeDocumentBinding == binding,
              let document = app.tabs.first(where: { $0.id == binding.tabId })?.document else {
            if activeRequest === preparing { cancelActiveRequest() }
            return
        }
        let request = AiDocumentRequest(
            token: preparing.token, binding: binding, document: document,
            coordinator: preparing.coordinator, messagesWithUser: messagesWithUser,
            assistantId: placeholder.id)
        activeRequest = request
        persist(messagesWithUser, for: request)
        defer {
            if activeRequest === request { cancelActiveRequest() }
        }

        let extract = ensureExtractedHandler
        let locate = document.kind == .web ? locateWebTextHandler : locatePdfTextHandler
        let backend = app.sessions.documentSession(sessionId: binding.tabId)
        let valid: @MainActor () -> Bool = { [weak self] in self?.isCurrent(request) == true }
        let execution = AiToolExecutionContext(
            binding: binding, document: document, currentPage: context.currentPage,
            pageCount: context.numPages, pageTexts: pageTexts, annotations: annotationStore.annotations,
            isCurrent: valid,
            setActivity: { [weak self] next in if valid() { self?.activity = next } },
            extract: { [weak self] pages in
                guard let self, valid() else { throw CancellationError() }
                _ = await extract?(pages)
                guard valid() else { throw CancellationError() }
                return self.pageTexts
            },
            locate: { page, query in
                guard valid() else { return nil }
                let result = await locate?(page, query)
                return valid() ? result : nil
            },
            createAnnotation: { input in
                guard valid(), let backend,
                      backend.info.kind == document.kind, backend.info.pdfPath == document.pdfPath
                else { throw CancellationError() }
                return try await annotationStore.createForAI(
                    input, document: document, binding: binding, backend: backend, isCurrentRequest: valid)
            },
            navigate: { page in if valid() { app.goToPage(page) } })
        let engine = AiToolEngine(context: execution)
        let onEvent: @MainActor (AiStreamEvent) -> Void = { [weak self] event in
            guard let self, self.isCurrent(request) else { return }
            switch event {
            case .status(let label):
                self.activity = label.lowercased().contains("read") ? .reading : .thinking
            case .textDelta(let delta):
                request.streamedText += delta
                self.appendStreamDelta(id: request.assistantId, delta)
                self.activity = .streaming
            case .toolStarted(let summary): self.activity = .tool(summary)
            case .toolFinished: break
            }
        }
        do {
            activity = .indexing
            let texts = try await execution.extract(Set([context.currentPage] + context.visiblePages))
            try execution.checkCurrent()
            activity = .thinking
            let conversation = AiPrompts.buildConversationBlock(Self.promptHistory(from: messagesWithUser))
            let prompt = AiPrompts.buildNativeToolUserPrompt(AiPromptParameters(
                conversation: conversation.isEmpty ? "(start of conversation)" : conversation,
                context: AiPrompts.buildContextBlock(pageTexts: texts, context: context), latestUserRequest: trimmed))
            var images = context.currentPageImage.map { [$0] } ?? []
            images.append(contentsOf: context.references.compactMap(\.image))
            let provider = generate
            let task = Task { @MainActor in
                try execution.checkCurrent()
                if let provider { return try await provider(engine, onEvent) }
                return try await self.generateWithProvider(
                    settingsAtStart: settingsAtStart, prompt: prompt, images: images,
                    sessionIdAtStart: sessionIdAtStart, engine: engine, onEvent: onEvent)
            }
            request.providerTask = task
            let result = try await task.value
            try execution.checkCurrent()
            var assistant = AiPersistence.makeMessage(
                role: .assistant, content: Self.assistantAnswerText(reply: result.reply), id: request.assistantId)
            assistant.toolSummaries = engine.displayActions.isEmpty ? nil : AiPersistence.sanitizeToolSummaries(engine.displayActions)
            let completed = AiPersistence.limitedMessages(messagesWithUser + [assistant])
            persist(completed, for: request)
            messages = completed
            activeRequest = nil
            activity = .idle
            streamingMessageId = nil
        } catch {
            guard isCurrent(request) else { return }
            if error is CancellationError { return }
            let detail = error.localizedDescription
            let streamed = request.streamedText.trimmingCharacters(in: .whitespacesAndNewlines)
            let content = streamed.isEmpty ? "I couldn't complete that request: \(detail)"
                : streamed + "\n\n_(interrupted: \(detail))_"
            let failed = AiPersistence.limitedMessages(messagesWithUser + [
                AiPersistence.makeMessage(role: .assistant, content: content, id: request.assistantId)])
            persist(failed, for: request)
            messages = failed
            activeRequest = nil
            activity = .idle
            streamingMessageId = nil
            self.error = detail
        }
    }

    private func generateWithProvider(
        settingsAtStart: AiSettings, prompt: AiUserPrompt, images: [AiPageImageSnapshot],
        sessionIdAtStart: String, engine: AiToolEngine,
        onEvent: @escaping @MainActor (AiStreamEvent) -> Void
    ) async throws -> AiProviderResult {
        let result: AiProviderResult
        switch settingsAtStart.provider {
        case .gemini:
            let model = settingsAtStart.model.trimmingCharacters(in: .whitespacesAndNewlines)
            result = try await GeminiClient().generate(
                apiKey: settingsAtStart.apiKey.trimmingCharacters(in: .whitespacesAndNewlines),
                model: model.isEmpty ? "gemini-3.1-flash-lite-preview" : model,
                systemPrompt: try AiPrompts.nativeSystemPrompt(),
                prompt: prompt,
                images: images,
                thinkingMode: settingsAtStart.reasoningEffort,
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
                prompt: prompt,
                images: images,
                thinkingMode: settingsAtStart.reasoningEffort,
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
            let supportsVision = AiModelCatalog.supportsVision(
                provider: .openrouter, model: model, catalog: openRouterCatalog)
            let supportsTools = openRouterCatalog?.model(for: model)?.supportsTools ?? true
            result = try await OpenRouterClient().generate(
                apiKey: settingsAtStart.openrouterApiKey.trimmingCharacters(in: .whitespacesAndNewlines),
                model: model,
                systemPrompt: try AiPrompts.nativeSystemPrompt(),
                prompt: prompt,
                images: supportsVision ? images : [],
                allowTools: supportsTools,
                thinkingMode: settingsAtStart.reasoningEffort,
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
                prompt: prompt,
                // Only text-only open models drop the images (page snapshot +
                // user-attached references); the gateway rejects image parts
                // for models that can't read them.
                images: AiModelCatalog.supportsVision(
                    provider: .opencode, model: model, catalog: openRouterCatalog) ? images : [],
                thinkingMode: settingsAtStart.reasoningEffort,
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
                prompt: prompt,
                images: AiModelCatalog.supportsVision(
                    provider: .opencodeGo, model: model, catalog: openRouterCatalog) ? images : [],
                thinkingMode: settingsAtStart.reasoningEffort,
                sessionIdAtStart: sessionIdAtStart,
                toolEngine: engine,
                onEvent: onEvent
            )
        }

        return result
    }

    /// Append a streamed delta to the in-flight assistant message without
    /// persisting on every token (the final content is saved once at the end).
    private func appendStreamDelta(id: String, _ delta: String) {
        guard let index = messages.firstIndex(where: { $0.id == id }) else { return }
        messages[index].content += delta
    }

}
