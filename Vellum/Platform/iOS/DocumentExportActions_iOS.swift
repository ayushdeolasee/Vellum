#if os(iOS)
import Foundation

/// Identity of the active document — web offline-copy state resets whenever the
/// tab or backing file changes. Mirrors ToolbarView's `DocumentKey` on macOS.
///
/// Lifted out of `PdfChrome_iOS` (where it was `private`) along with the export
/// state machine below, because both toolbars now key their reload on it.
struct DocumentKey_iOS: Hashable {
    var tabId: String?
    var path: String?

    @MainActor
    init(_ appStore: AppStore) {
        tabId = appStore.activeTabId
        path = appStore.document?.pdfPath
    }
}

/// The document file actions shared by the iPad toolbar and the phone reader's
/// More menu (#153 P5): the web offline-copy toggle, the `.vellumweb` export,
/// and the `.vellum` bundle export.
///
/// This is a straight lift out of `PdfToolbar_iOS`, not a reimplementation, and
/// the reason it had to move rather than be copied is the three-part state
/// machine it carries:
///
///   * `saveToggleTask` **serializes** save/remove, so a rapid Remove cannot
///     finish before a slow Save's archive write and get its deletion undone by
///     it;
///   * `saveToggleGeneration` identifies the newest queued toggle, so a
///     superseded one's failure cannot revert the button to a state the user has
///     already toggled away from;
///   * `exporting` and `exportingBundle` are deliberately *separate* guards, so
///     a `.vellum` export and a `.vellumweb` export can never disable each
///     other's menu item.
///
/// None of that survives being retyped from memory on a second surface, and a
/// second copy would drift the moment either one is fixed.
///
/// ## Why the stores are parameters rather than stored properties
///
/// Both call sites read `AppStore` and `AiStore` out of the SwiftUI environment,
/// and on the iPad that pair belongs to the *pane* the toolbar is in. Holding
/// them here would pin this object to whichever pane happened to construct it
/// and quietly export the wrong pane's document after a tab drag. Passing them
/// per call keeps the object pure presentation state — which is all the view
/// needs to observe.
@MainActor
@Observable
final class DocumentExportActions_iOS {
    /// Whether the active web document is kept for offline use. Meaningless for
    /// PDF tabs, and reset by `loadSavedState` whenever the document changes.
    private(set) var pageSaved = false

    /// A `.vellumweb` export is in flight.
    private(set) var exporting = false

    /// A `.vellum` bundle export is in flight. Separate from `exporting` on
    /// purpose — see the type comment.
    private(set) var exportingBundle = false

    /// Serializes save/remove so a rapid Remove can't finish before a slow
    /// Save's archive write and get its deletion undone by it.
    @ObservationIgnored private var saveToggleTask: Task<Void, Never>?
    /// Identifies the newest queued toggle, so a superseded one's failure can't
    /// revert the toolbar to a state the user has already toggled away from.
    @ObservationIgnored private var saveToggleGeneration = 0

    // MARK: - Web offline copy

    /// Reload `pageSaved` for `identity`. Call from `.task(id: DocumentKey_iOS(app))`
    /// so the flag resets whenever the active tab or its backing document changes.
    func loadSavedState(app: AppStore, for identity: DocumentKey_iOS) async {
        pageSaved = false
        guard app.document?.kind == .web, let sessionId = app.activeTabId else { return }
        let saved = (try? await app.sessions.getWebpageSaved(sessionId: sessionId)) ?? false
        if DocumentKey_iOS(app) == identity {
            pageSaved = saved
        }
    }

    /// Save = mark the page kept AND make sure its offline copy exists (the
    /// re-archive covers a copy the user deleted from Settings ▸ Storage).
    /// Remove = un-keep and delete the offline copy; the record — highlights,
    /// notes, reading position — always survives.
    func toggleSavedPage(app: AppStore, ai: AiStore) {
        guard let sessionId = app.activeTabId else { return }
        let next = !pageSaved
        pageSaved = next
        let expectedUrl = app.document?.pdfPath ?? ""
        let pages = pageTexts(ai)
        let prior = saveToggleTask
        saveToggleGeneration += 1
        let generation = saveToggleGeneration
        saveToggleTask = Task {
            await prior?.value
            do {
                try await app.sessions.setWebpageSaved(sessionId: sessionId, saved: next)
                if next {
                    // Best-effort: membership is saved even if the archive
                    // write fails (offline, no snapshot yet) — the copy is
                    // rewritten on the next open of the page.
                    _ = try? await app.sessions.archiveWebpageDefault(
                        sessionId: sessionId, pages: pages, expectedUrl: expectedUrl)
                }
            } catch {
                // Only the newest toggle owns the button: an older one failing
                // behind a queued newer one must not resurrect its own state.
                if app.activeTabId == sessionId, generation == saveToggleGeneration {
                    pageSaved = !next
                }
            }
        }
    }

    // MARK: - Exports

    /// Export the active webpage as a .vellumweb archive. macOS uses NSSavePanel;
    /// iOS writes the archive to a temporary file and hands it to the Files
    /// export picker, which copies it to the destination the user chooses.
    func exportVellumweb(app: AppStore, ai: AiStore) {
        guard !exporting,
              let sessionId = app.activeTabId,
              app.document?.kind == .web else { return }

        let slug = slugifiedTitle(app: app)
        let pages = pageTexts(ai)
        exporting = true
        Task {
            defer { exporting = false }
            let tmp = FileManager.default.temporaryDirectory
                .appendingPathComponent("\(slug).vellumweb")
            try? FileManager.default.removeItem(at: tmp)
            guard (try? await app.sessions.exportVellumweb(
                sessionId: sessionId, destPath: tmp.path, pages: pages)) != nil else { return }
            DocumentPickerCoordinator_iOS.shared.presentExport(urls: [tmp])
        }
    }

    /// Export the active document as a `.vellum` bundle — the document plus its
    /// scratchpad + attachments, and (opt-in, default OFF) the AI conversation.
    /// Available for BOTH PDF and web tabs. macOS uses NSSavePanel; iOS writes
    /// the bundle to a temporary file and hands it to the Files export picker.
    func startBundleExport(app: AppStore, ai: AiStore, includeConversations: Bool) {
        guard !exportingBundle,
              let sessionId = app.activeTabId,
              let document = app.document else { return }
        let pages = pageTexts(ai)
        exportingBundle = true
        Task {
            defer { exportingBundle = false }
            let tmp = FileManager.default.temporaryDirectory
                .appendingPathComponent("\(slugifiedTitle(app: app)).vellum")
            try? FileManager.default.removeItem(at: tmp)
            do {
                try await buildBundle(
                    app: app, sessionId: sessionId, document: document, destination: tmp,
                    includeConversations: includeConversations, pages: pages)
            } catch { return }
            // Not deleted afterwards: the picker copies asynchronously. Same as
            // exportVellumweb; tmp/ is reclaimed by the system.
            DocumentPickerCoordinator_iOS.shared.presentExport(urls: [tmp])
        }
    }

    /// Assemble the bundle content: durable id (lazily stamped), the document
    /// bytes (PDF as-is / a fresh .vellumweb for web), and the class-B sidecar
    /// pulled from DocumentDataStore by storage key.
    private func buildBundle(
        app: AppStore,
        sessionId: String,
        document: DocumentInfo,
        destination: URL,
        includeConversations: Bool,
        pages: [WebPageText]
    ) async throws {
        // The sidecar currently lives under this session's storage key — resolve
        // it BEFORE the stamp changes DocumentInfo.docId.
        let pullKey = DocumentIdentity.storageKey(for: document)
        // Durable id for the manifest (stamps a writable PDF; byte-hash fallback
        // for an unwritable one; URL hash for web).
        let durableId = (try? await app.sessions.ensureDocumentId(sessionId: sessionId))
            ?? pullKey
        await app.syncDocumentId(sessionId: sessionId)

        let documentData: Data
        let documentFile: String
        if document.kind == .web {
            // Reuse the session's .vellumweb writer rather than duplicating it.
            let tmp = FileManager.default.temporaryDirectory
                .appendingPathComponent("\(UUID().uuidString.lowercased()).vellumweb")
            _ = try await app.sessions.exportVellumweb(
                sessionId: sessionId, destPath: tmp.path, pages: pages)
            documentData = try Data(contentsOf: tmp)
            try? FileManager.default.removeItem(at: tmp)
            documentFile = "\(slugifiedTitle(app: app)).vellumweb"
        } else {
            // Read AFTER the stamp so the exported PDF carries /VellumDocId.
            documentData = try await app.sessions.readPdfBytes(sessionId: sessionId)
            let name = (document.pdfPath as NSString).lastPathComponent
            documentFile = VellumBundle.safeName(name) ?? "document.pdf"
        }

        let scratchpad = DocumentDataStore.loadScratchpad(forKey: pullKey)
        let attachments = loadAttachments(forKey: pullKey)
        let conversations = includeConversations
            ? DocumentDataStore.loadConversationsData(forKey: pullKey)
            : nil

        let content = VellumBundle.Content(
            kind: document.kind,
            docId: durableId,
            documentFile: documentFile,
            documentData: documentData,
            title: document.title,
            scratchpad: scratchpad.isEmpty ? nil : scratchpad,
            attachments: attachments,
            conversations: conversations)
        // `VellumBundle.write` hashes and deflates synchronously, and this Task
        // inherits the caller's main-actor isolation — a multi-hundred-MB bundle
        // would freeze the UI for the whole zip. Off-main it is.
        try await Task.detached(priority: .userInitiated) {
            try VellumBundle.write(content, to: destination)
        }.value
    }

    /// Read the document's attachments as (bare filename, bytes) pairs.
    private func loadAttachments(forKey key: String) -> [(name: String, data: Data)] {
        let dir = DocumentDataStore.attachmentsDir(forKey: key)
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: dir.path) else {
            return []
        }
        var out: [(name: String, data: Data)] = []
        for name in names.sorted() {
            if let data = try? Data(contentsOf: dir.appendingPathComponent(name)) {
                out.append((name, data))
            }
        }
        return out
    }

    /// The AI store's extracted page text, in page order — the payload every
    /// web export needs.
    private func pageTexts(_ ai: AiStore) -> [WebPageText] {
        ai.pageTexts
            .sorted { $0.key < $1.key }
            .map { WebPageText(number: $0.key, text: $0.value) }
    }

    /// Slug for the export default filename: lowercased title, non-alphanumeric
    /// runs collapsed to "-", trimmed, max 60 chars, fallback "article".
    func slugifiedTitle(app: AppStore) -> String {
        let title = app.document?.title ?? ""
        var slug = ""
        var lastWasDash = false
        for scalar in title.lowercased().unicodeScalars {
            if (scalar.value >= 97 && scalar.value <= 122)
                || (scalar.value >= 48 && scalar.value <= 57) {
                slug.unicodeScalars.append(scalar)
                lastWasDash = false
            } else if !lastWasDash, !slug.isEmpty {
                slug.append("-")
                lastWasDash = true
            }
        }
        while slug.hasSuffix("-") { slug.removeLast() }
        if slug.count > 60 {
            slug = String(slug.prefix(60))
            while slug.hasSuffix("-") { slug.removeLast() }
        }
        return slug.isEmpty ? "article" : slug
    }
}
#endif
