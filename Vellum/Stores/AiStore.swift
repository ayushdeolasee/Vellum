import Foundation
import Observation
import UniformTypeIdentifiers

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
    /// throw. `AiPersistence` decodes the whole file as `[AiMessage]`, which is
    /// all-or-nothing — one unreadable reference would silently discard the
    /// user's entire conversation. Unreadable entries are dropped instead.
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
    var chatgptModel: String = "gpt-5.5"
    var opencodeModel: String = "claude-opus-4-8"
    var opencodeApiKey: String = ""
    var opencodeGoModel: String = "glm-5.2"
    var opencodeGoApiKey: String = ""
    /// Model ids the user has pinned to the top of the model selector.
    var pinnedModels: [String] = []
    var reasoningEffort: AiThinkingMode = .auto

    func isConfigured(chatGPTSignedIn: Bool) -> Bool {
        switch provider {
        case .gemini:
            hasValue(apiKey) && hasValue(model)
        case .openai:
            hasValue(openaiApiKey) && hasValue(openaiModel)
        case .openrouter:
            hasValue(openrouterApiKey) && hasValue(openrouterModel)
        case .chatgpt:
            chatGPTSignedIn && hasValue(chatgptModel)
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
    /// 1-indexed page → whitespace-normalized extracted text.
    private(set) var pageTexts: [Int: String] = [:]
    private(set) var settings = AiSettings()

    /// Keeps this pane's settings synchronized with changes made in Settings.
    @ObservationIgnored private var settingsObserver: NSObjectProtocol?

    /// Context the user has attached to the next message (selection, highlight,
    /// snapshot, or an AI-reply quote). Rendered as chips in the composer.
    private(set) var composerReferences: [AiReference] = []

    /// A pending, one-shot request for the AppKit composer to take first
    /// responder, set by every "Add to AI Chat" style action.
    ///
    /// A one-shot *token* rather than a Bool or a monotonic counter, for two
    /// reasons the simpler shapes get wrong. A Bool can't distinguish two
    /// consecutive attach actions, so the second wouldn't refocus a composer the
    /// user had clicked away from. A counter is never "spent": the AppKit
    /// representable remembers the last value it fulfilled in its coordinator,
    /// so when the inspector is closed and reopened, the rebuilt coordinator
    /// starts at zero, sees a non-zero count, and steals focus for an attach the
    /// user performed minutes ago. Consumption clears it here in the store — the
    /// single place both the old and the new coordinator agree on — so a
    /// fulfilled request can't replay, and each split pane's `AiStore` owns its
    /// own token so two panes can't collide.
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
    var ensureExtractedHandler: ((Set<Int>?) async -> Int)?

    init() {
        settings = AiPersistence.loadSettings()
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
        NotificationCenter.default.post(name: .vellumAiSettingsChanged, object: nil)
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
        await ensureExtractedHandler?(pages) ?? 0
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
    /// pending one, so a late `updateNSView` from a torn-down composer can't
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
            documentId: document.docId)
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
    /// rather than render an empty frame. Returns `Data`, not `NSImage`, so the
    /// resolution logic is testable headlessly.
    func referencePreviewData(for reference: AiReference) -> Data? {
        let base64 = reference.image?.base64Data.isEmpty == false
            ? reference.image?.base64Data
            : referenceImageCache[reference.id]?.base64Data
        guard let base64, !base64.isEmpty else { return nil }
        return Data(base64Encoded: base64)
    }

    // MARK: - Attachment drops

    /// Take a drop routed here from the sidebar's single AppKit drag catcher (see
    /// `SidebarDropCatcher` / `SidebarPanelStack`) when the AI tab is visible. A
    /// Finder file payload is classified off the main actor and its images are
    /// attached as reference chips (non-image files are declined with a notice);
    /// raw image bytes (Preview / a browser) are normalized and attached as an
    /// image reference.
    ///
    /// Lives on the store, not the view, because the sidebar routes every drop
    /// through one destination that dispatches to whichever store owns the visible
    /// tab — the panels no longer own a drop target of their own. See
    /// `SidebarDropRoutingTests` for why stacked panels can't each register one.
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
    /// drag-and-drop and the picker's ("+" → Attach image…) entry point. Any
    /// non-image files in the drop are declined with a single notice that names
    /// them, so a mixed drop still lands its images and the rest is explained
    /// rather than silently dropped; folders and unreadable paths get the
    /// distinct "folder or unreadable" notice.
    func attachFiles(at urls: [URL]) {
        // App sandbox is off (project.yml), so the URL needs no security-scoped
        // bookmark — plain file reads are enough.
        let sessionId = app?.activeTabId
        Task { [weak self] in
            let results = await Task.detached(priority: .userInitiated) {
                urls.map { (name: $0.lastPathComponent, attachment: aiFileAttachment(from: $0)) }
            }.value
            guard let self, self.app?.activeTabId == sessionId else { return }

            var rejected: [String] = []    // readable, but not an attachable image
            var unreadable: [String] = []  // folders / missing / unreadable paths
            for result in results {
                switch result.attachment {
                case let .image(snapshot, name):
                    self.attachIfCurrent(
                        AiReference(kind: .image(image: snapshot, name: name)), session: sessionId)
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
        let sessionId = app?.activeTabId
        Task { [weak self] in
            let snapshot = await Task.detached(priority: .userInitiated) {
                aiImageSnapshot(from: data)
            }.value
            guard let self, let snapshot, self.app?.activeTabId == sessionId else { return }
            self.addReference(AiReference(kind: .image(image: snapshot, name: name)))
        }
    }

    /// A pane's AiStore is shared by all of its tabs, and a tab switch wipes the
    /// composer — so a decode that finishes after the switch would otherwise drop
    /// document A's image into document B's next message. Same session capture
    /// `submit` uses.
    private func attachIfCurrent(_ reference: AiReference, session: String?) {
        guard app?.activeTabId == session else { return }
        addReference(reference)
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
    /// Returns the removed conversation so the caller can register a reliable
    /// Undo. Composer attachments are deliberately left alone: they belong to
    /// the next message, not to the transcript being cleared.
    ///
    /// Also cancels any in-flight request so a completing response can't
    /// re-append the messages we just cleared.
    @discardableResult
    func clearConversation() -> AiConversationClearTransaction? {
        guard !messages.isEmpty,
              let document = app?.document,
              let sessionId = app?.activeTabId else { return nil }
        let transaction = AiConversationClearTransaction(
            document: document, sessionId: sessionId, removedMessages: messages)
        cancelActiveRequest()
        AiPersistence.saveConversation(for: document, messages: [])
        messages = []
        error = nil
        return transaction
    }

    /// Restore only the messages removed by this transaction. Messages created
    /// after the clear stay at the end of the conversation.
    @discardableResult
    func undoClear(_ transaction: AiConversationClearTransaction) -> Bool {
        guard let document = currentDocument(for: transaction) else { return false }
        let current = AiPersistence.loadConversation(for: document)
        let currentIds = Set(current.map(\.id))
        let restored = transaction.removedMessages.filter { !currentIds.contains($0.id) } + current
        AiPersistence.saveConversation(for: document, messages: restored)
        if isShowing(transaction, document: document) {
            cancelActiveRequest()
            // Read back rather than showing `restored`: the save applies the
            // message/reference/tool-summary caps, so the un-capped array would
            // display more than was persisted and silently shrink on the next
            // tab switch.
            messages = AiPersistence.loadConversation(for: document)
            error = nil
        }
        return true
    }

    /// Remove only this transaction's original messages. Any messages added
    /// after the clear (or after Undo) remain intact.
    @discardableResult
    func redoClear(_ transaction: AiConversationClearTransaction) -> Bool {
        guard let document = currentDocument(for: transaction) else { return false }
        let removedIds = Set(transaction.removedMessages.map(\.id))
        let remaining = AiPersistence.loadConversation(for: document)
            .filter { !removedIds.contains($0.id) }
        AiPersistence.saveConversation(for: document, messages: remaining)
        if isShowing(transaction, document: document) {
            cancelActiveRequest()
            messages = remaining
            error = nil
        }
        return true
    }

    /// Resolve through the transaction's tab rather than the clear-time
    /// `DocumentInfo`: a first post-clear write can stamp the PDF and change its
    /// storage key while this tab remains the same document. The path/kind guard
    /// keeps a stale undo transaction from following a reused tab into another
    /// document.
    private func currentDocument(for transaction: AiConversationClearTransaction) -> DocumentInfo? {
        guard let document = app?.tabs.first(where: { $0.id == transaction.sessionId })?.document,
              isSameDocument(document, transaction.document) else { return nil }
        return document
    }

    private func isShowing(
        _ transaction: AiConversationClearTransaction, document targetDocument: DocumentInfo
    ) -> Bool {
        guard app?.activeTabId == transaction.sessionId, let activeDocument = app?.document else {
            return false
        }
        return isSameDocument(activeDocument, targetDocument)
    }

    private func isSameDocument(_ lhs: DocumentInfo, _ rhs: DocumentInfo) -> Bool {
        lhs.kind == rhs.kind && lhs.pdfPath == rhs.pdfPath
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
        var context = context
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

        // The transcript keeps its own copy of what was attached — the composer
        // chips are cleared on submit, so without this the sent message would
        // give no sign it carried any context at all (issue #58). Pixels are
        // stripped for storage; the model still receives the full-resolution
        // images below, built from `context.references`.
        //
        // Hand the pixels to the session cache first: it is the only thing that
        // survives the strip, and it's what makes tapping a snapshot or
        // screenshot chip show the image for the rest of this session.
        rememberReferenceImages(context.references)
        let userMessage = AiPersistence.makeMessage(
            role: .user,
            content: trimmed,
            references: context.references.map(\.strippingImageData)
        )
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

        // First AI message on a not-yet-stamped PDF: lazily stamp /VellumDocId
        // through the session so this document's conversation lands in a stable,
        // rename-proof `documents/<docId>/` folder rather than the path-hash
        // fallback (mirrors ScratchpadStore's first-write stamp; design §3).
        // Done AFTER the UI append (the stamp rewrites the whole PDF, which
        // would visibly stall the composer on large files) but before the first
        // persist so every save this turn targets the stamped key — no mid-turn
        // rekey. Best-effort: a read-only PDF that can't be stamped keeps its
        // nil docId and persists under the path key, which the next open's
        // rekey carries over. syncDocumentId already no-ops once an id exists,
        // so later messages skip the round-trip.
        if documentAtStart.kind == .pdf, documentAtStart.docId?.isEmpty ?? true {
            await app.syncDocumentId(sessionId: sessionIdAtStart)
            guard !Task.isCancelled, app.activeTabId == sessionIdAtStart else {
                // Abandon the turn: cancelled or the pane switched documents
                // mid-stamp (its context reloads anyway). Mirror
                // cancelActiveRequest's reset so no stream state dangles.
                streamingMessageId = nil
                activity = .idle
                return
            }
        }
        let documentForPersist = app.document ?? documentAtStart
        let messagesWithUser = Array(messages.dropLast())
        AiPersistence.saveConversation(for: documentForPersist, messages: messagesWithUser)

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
            // Pull model: the default slice only carries the current page, so
            // make sure that page (and what's on screen) is extracted before the
            // prompt is built — the background 1→N walk may not have reached a
            // deep page the user jumped to. Whole-doc extraction happens lazily
            // inside `searchDocument`. Sub-ms and invisible when already indexed.
            activity = .indexing
            _ = await ensureExtracted(pages: Set([context.currentPage] + context.visiblePages))
            guard !Task.isCancelled, app.activeTabId == sessionIdAtStart else { return }
            activity = .thinking

            let conversation = AiPrompts.buildConversationBlock(Self.promptHistory(from: messagesWithUser))
            let parameters = AiPromptParameters(
                conversation: conversation.isEmpty ? "(start of conversation)" : conversation,
                context: AiPrompts.buildContextBlock(pageTexts: pageTexts, context: context),
                latestUserRequest: trimmed
            )
            // Built once and shared by every provider path. Clients with an
            // Anthropic-style cache_control breakpoint (OpenRouter, OpenCode Zen)
            // send the stable/volatile halves as separate parts; the rest send
            // `prompt.joined` (PR A.5).
            let prompt = AiPrompts.buildNativeToolUserPrompt(parameters)
            let engine = AiToolEngine(store: self, app: app, annotations: annotationStore)
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
            case .chatgpt:
                guard let chatgptAuth else {
                    throw AiClientError.message("Sign in with ChatGPT in AI settings.")
                }
                let model = settingsAtStart.chatgptModel.trimmingCharacters(in: .whitespacesAndNewlines)
                result = try await ChatGPTClient(auth: chatgptAuth).generate(
                    model: model.isEmpty ? "gpt-5.5" : model,
                    systemPrompt: try AiPrompts.nativeSystemPrompt(),
                    prompt: prompt,
                    images: images,
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

            // Cancelled mid-request (e.g. the user cleared the conversation):
            // drop the result without persisting or re-appending messages.
            guard !Task.isCancelled else { return }

            // The answer and the trace of what produced it are persisted as two
            // separate things. Raw tool payloads remain model-only: they reach
            // neither `content` nor the bounded excerpts in `toolSummaries`.
            var assistantMessage = AiPersistence.makeMessage(
                role: .assistant,
                content: Self.assistantAnswerText(reply: result.reply),
                id: assistantId
            )
            assistantMessage.toolSummaries = engine.displayActions.isEmpty
                ? nil
                : AiPersistence.sanitizeToolSummaries(engine.displayActions)
            let completed = AiPersistence.limitedMessages(messagesWithUser + [
                assistantMessage
            ])
            AiPersistence.saveConversation(for: documentForPersist, messages: completed)
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
            AiPersistence.saveConversation(for: documentForPersist, messages: failed)
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
