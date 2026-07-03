import Foundation

// Session router — the concrete SessionService. One open document = one
// DocumentSession object keyed by the caller's session id (tab id). PDF
// sessions are produced by PdfSessionBackend (Services/Pdf/), web sessions by
// WebSessionBackend (Services/Web/). This file owns only routing; document
// behavior lives in the backends.

/// Per-open-document operations. Implementations: PdfDocumentSession (PDF files
/// with embedded annotations) and WebDocumentSession (webpages + .vellumweb).
@MainActor
protocol DocumentSession: AnyObject {
    var info: DocumentInfo { get }

    func save() async throws
    func close() async throws
    func readPdfBytes() async throws -> Data

    func annotations(pageNumber: Int?) async throws -> [Annotation]
    func createAnnotation(_ input: CreateAnnotationInput) async throws -> Annotation
    func updateAnnotation(_ input: UpdateAnnotationInput) async throws -> Bool
    func deleteAnnotation(id: String) async throws -> Bool

    func setMetadata(key: String, value: String) async throws
}

@MainActor
final class DocumentSessionManager: SessionService {
    let pdfBackend: PdfSessionBackend
    let webBackend: WebSessionBackend
    let codex: CodexAiClient

    private(set) var sessions: [String: any DocumentSession] = [:]

    init(
        pdfBackend: PdfSessionBackend = PdfSessionBackend(),
        webBackend: WebSessionBackend = WebSessionBackend(),
        codex: CodexAiClient = CodexAiClient()
    ) {
        self.pdfBackend = pdfBackend
        self.webBackend = webBackend
        self.codex = codex
    }

    private func session(_ id: String) throws -> any DocumentSession {
        guard let session = sessions[id] else {
            throw SessionServiceError.sessionNotFound(id)
        }
        return session
    }

    /// Web session lookup for web-only commands (saved-state, export).
    private func webSession(_ id: String, pdfTabMessage: String) throws -> WebDocumentSession {
        guard let session = sessions[id] else {
            throw SessionServiceError.sessionNotFound(id)
        }
        guard let webSession = session as? WebDocumentSession else {
            throw SessionServiceError.invalidDocument(pdfTabMessage)
        }
        return webSession
    }

    // MARK: - Lifecycle

    func openFile(path: String, sessionId: String) async throws -> DocumentInfo {
        let session = try await pdfBackend.open(path: path, sessionId: sessionId)
        sessions[sessionId] = session
        return session.info
    }

    func openWebDocument(url: String, sessionId: String) async throws -> DocumentInfo {
        // Rebind: in-tab navigation reuses the session id against a new URL.
        let session = try await webBackend.openWebDocument(
            url: url, sessionId: sessionId, replacing: sessions[sessionId] as? WebDocumentSession)
        sessions[sessionId] = session
        return session.info
    }

    func openVellumwebFile(path: String, sessionId: String) async throws -> DocumentInfo {
        let session = try await webBackend.openVellumwebFile(path: path, sessionId: sessionId)
        sessions[sessionId] = session
        return session.info
    }

    func saveFile(sessionId: String) async throws {
        try await session(sessionId).save()
    }

    func closeFile(sessionId: String) async throws {
        guard let session = sessions[sessionId] else { return }
        sessions[sessionId] = nil
        try await session.close()
    }

    func readPdfBytes(sessionId: String) async throws -> Data {
        try await session(sessionId).readPdfBytes()
    }

    // MARK: - Web library / archives

    func setWebpageSaved(sessionId: String, saved: Bool) async throws {
        try await webSession(
            sessionId,
            pdfTabMessage: "PDFs are already portable — archiving applies to webpage tabs"
        ).setSaved(saved)
    }

    func getWebpageSaved(sessionId: String) async throws -> Bool {
        try await webSession(
            sessionId, pdfTabMessage: "This tab is a PDF, not a webpage"
        ).isSaved()
    }

    func listSavedWebpages() async throws -> [WebLibraryEntry] {
        try await webBackend.listSavedWebpages()
    }

    func removeSavedWebpage(url: String) async throws {
        try await webBackend.removeSavedWebpage(url: url)
    }

    func exportVellumweb(sessionId: String, destPath: String, pages: [WebPageText]) async throws -> VellumwebExportSummary {
        try await webSession(
            sessionId, pdfTabMessage: "PDFs are already portable — archiving applies to webpage tabs"
        ).exportVellumweb(destPath: destPath, pages: pages)
    }

    func archiveWebpageDefault(sessionId: String, pages: [WebPageText], expectedUrl: String) async throws -> Bool {
        try await webSession(
            sessionId, pdfTabMessage: "PDFs are already portable — archiving applies to webpage tabs"
        ).archiveDefault(pages: pages, expectedUrl: expectedUrl)
    }

    // MARK: - Annotations

    func getAnnotations(sessionId: String, pageNumber: Int?) async throws -> [Annotation] {
        try await session(sessionId).annotations(pageNumber: pageNumber)
    }

    func createAnnotation(sessionId: String, input: CreateAnnotationInput) async throws -> Annotation {
        try await session(sessionId).createAnnotation(input)
    }

    func updateAnnotation(sessionId: String, input: UpdateAnnotationInput) async throws -> Bool {
        try await session(sessionId).updateAnnotation(input)
    }

    func deleteAnnotation(sessionId: String, id: String) async throws -> Bool {
        try await session(sessionId).deleteAnnotation(id: id)
    }

    func setDocumentMetadata(sessionId: String, key: String, value: String) async throws {
        try await session(sessionId).setMetadata(key: key, value: value)
    }

    // MARK: - AI

    func runCodexAi(prompt: String, model: String, image: CodexAiImageInput?) async throws -> String {
        try await codex.run(prompt: prompt, model: model, image: image)
    }
}
