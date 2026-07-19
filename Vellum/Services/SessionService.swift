import Foundation

// Native replacement for the Tauri IPC command surface (src/lib/tauri-commands.ts
// → src-tauri/src/commands.rs). One session = one open document, keyed by a
// caller-supplied UUID string (the tab id). Semantics must match the Rust
// implementation exactly — see macos/specs/SPECS-*.md.

enum SessionServiceError: Error, LocalizedError {
    case sessionNotFound(String)
    case invalidDocument(String)
    case io(String)

    var errorDescription: String? {
        switch self {
        case .sessionNotFound(let id): return "No open session: \(id)"
        case .invalidDocument(let message): return message
        case .io(let message): return message
        }
    }
}

@MainActor
protocol SessionService: AnyObject {
    // Document lifecycle
    func openFile(path: String, sessionId: String) async throws -> DocumentInfo
    func openWebDocument(url: String, sessionId: String) async throws -> DocumentInfo
    func openVellumwebFile(path: String, sessionId: String) async throws -> DocumentInfo
    func saveFile(sessionId: String) async throws
    func closeFile(sessionId: String) async throws
    func readPdfBytes(sessionId: String) async throws -> Data

    // Web library / archives
    func setWebpageSaved(sessionId: String, saved: Bool) async throws
    func getWebpageSaved(sessionId: String) async throws -> Bool
    func listSavedWebpages() async throws -> [WebLibraryEntry]
    func removeSavedWebpage(url: String) async throws
    func exportVellumweb(sessionId: String, destPath: String, pages: [WebPageText]) async throws -> VellumwebExportSummary
    /// Auto-archive an opened webpage into the managed library as .vellumweb.
    func archiveWebpageDefault(sessionId: String, pages: [WebPageText], expectedUrl: String) async throws -> Bool

    // Annotations (persisted inside the document / archive)
    func getAnnotations(sessionId: String, pageNumber: Int?) async throws -> [Annotation]
    func createAnnotation(sessionId: String, input: CreateAnnotationInput) async throws -> Annotation
    func updateAnnotation(sessionId: String, input: UpdateAnnotationInput) async throws -> Bool
    func deleteAnnotation(sessionId: String, id: String) async throws -> Bool

    // Reading metadata (last_page, page_count, …) stored on the document
    func setDocumentMetadata(sessionId: String, key: String, value: String) async throws

    /// Resolve the document's stable identity, lazily stamping /VellumDocId into
    /// a PDF that has none. Web documents return their sha256 URL-hash key.
    func ensureDocumentId(sessionId: String) async throws -> String
}

extension Notification.Name {
    /// Fired after an external mutation (e.g. .vellumweb import merging into the
    /// active tab) changes annotations outside the store. (vellum:annotations-updated)
    static let vellumAnnotationsUpdated = Notification.Name("vellum.annotations-updated")
    /// Asks the toolbar to open its "add webpage" URL prompt. (vellum:add-webpage)
    static let vellumAddWebpage = Notification.Name("vellum.add-webpage")
    /// Broadcast after AI settings change so every pane's AiStore reloads the
    /// shared, disk-persisted settings (multiple AiStore instances exist once
    /// panes can be split). (vellum:ai-settings-changed)
    static let vellumAiSettingsChanged = Notification.Name("vellum.ai-settings-changed")
    /// Broadcast after a `.vellum` import installs a sidecar under a storage key
    /// (userInfo["key"]). Any pane showing a document with that key reloads its
    /// scratchpad + conversation so the freshly-merged notes/chat replace stale
    /// live state instead of being clobbered by its next flush. (vellum:sidecar-imported)
    static let vellumDocumentSidecarImported = Notification.Name("vellum.sidecar-imported")
    /// Broadcast after the Storage pane deletes a document's notes and/or chat on
    /// disk (userInfo["keys"]: [String]; userInfo["notes"]/["chat"]: Bool). A pane
    /// showing that document must clear the matching in-memory state WITHOUT
    /// saving, so a live writer's next flush can't rewrite the just-deleted file
    /// (Delete Notes → scratchpad quit-flush; Delete Chat → AI memory cache).
    /// (vellum:document-data-deleted)
    static let vellumDocumentDataDeleted = Notification.Name("vellum.document-data-deleted")
}
