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

    /// Resolve (stamping lazily for PDFs) the document's stable id. Web sessions
    /// return their URL-hash key. Never surfaces stamping failure as an error.
    func ensureDocumentId() async throws -> String
}

@MainActor
final class DocumentSessionManager: SessionService {
    let pdfBackend: PdfSessionBackend
    let webBackend: WebSessionBackend

    private(set) var sessions: [String: any DocumentSession] = [:]
    private var openGenerations: [String: UUID] = [:]
    private let openWebSession: (@MainActor (String, String) async throws -> any DocumentSession)?

    func invalidatePendingOpen(sessionId: String) {
        openGenerations[sessionId] = nil
    }

    private func beginOpen(_ sessionId: String) -> UUID {
        let generation = UUID()
        openGenerations[sessionId] = generation
        return generation
    }

    private func admit(_ session: any DocumentSession, sessionId: String, generation: UUID) throws -> DocumentInfo {
        guard !Task.isCancelled, openGenerations[sessionId] == generation else {
            throw CancellationError()
        }
        sessions[sessionId] = session
        return session.info
    }

    init(
        pdfBackend: PdfSessionBackend = PdfSessionBackend(),
        webBackend: WebSessionBackend = WebSessionBackend(),
        openWebSession: (@MainActor (String, String) async throws -> any DocumentSession)? = nil
    ) {
        self.pdfBackend = pdfBackend
        self.webBackend = webBackend
        self.openWebSession = openWebSession
    }

    func documentSession(sessionId: String) -> (any DocumentSession)? { sessions[sessionId] }

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
        let generation = beginOpen(sessionId)
        let session = try await pdfBackend.open(path: path, sessionId: sessionId)
        return try admit(session, sessionId: sessionId, generation: generation)
    }

    func openWebDocument(url: String, sessionId: String) async throws -> DocumentInfo {
        let generation = beginOpen(sessionId)
        let session: any DocumentSession
        if let openWebSession {
            session = try await openWebSession(url, sessionId)
        } else {
            session = try await webBackend.openWebDocument(
                url: url, sessionId: sessionId, replacing: sessions[sessionId] as? WebDocumentSession)
        }
        return try admit(session, sessionId: sessionId, generation: generation)
    }

    func openVellumwebFile(path: String, sessionId: String) async throws -> DocumentInfo {
        let generation = beginOpen(sessionId)
        let session = try await webBackend.openVellumwebFile(path: path, sessionId: sessionId)
        return try admit(session, sessionId: sessionId, generation: generation)
    }

    func saveFile(sessionId: String) async throws {
        try await session(sessionId).save()
    }

    func closeFile(sessionId: String) async throws {
        openGenerations[sessionId] = nil
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

    func ensureDocumentId(sessionId: String) async throws -> String {
        try await session(sessionId).ensureDocumentId()
    }
}
