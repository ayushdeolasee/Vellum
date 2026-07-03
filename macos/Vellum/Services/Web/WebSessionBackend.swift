import Foundation

// STUB — replaced by the web module (see macos/specs/SPECS-web.md).
// Opens live webpages and .vellumweb archives, manages the saved-webpage
// library, and persists web annotations, matching the Rust web_page.rs /
// web_archive.rs behavior and on-disk formats.

@MainActor
final class WebSessionBackend {
    func openWebDocument(
        url: String, sessionId: String, replacing: WebDocumentSession?
    ) async throws -> WebDocumentSession {
        throw SessionServiceError.invalidDocument("WebSessionBackend not implemented yet")
    }

    func openVellumwebFile(path: String, sessionId: String) async throws -> WebDocumentSession {
        throw SessionServiceError.invalidDocument("WebSessionBackend not implemented yet")
    }

    func listSavedWebpages() async throws -> [WebLibraryEntry] {
        throw SessionServiceError.invalidDocument("not implemented")
    }

    func removeSavedWebpage(url: String) async throws {
        throw SessionServiceError.invalidDocument("not implemented")
    }
}

@MainActor
final class WebDocumentSession: DocumentSession {
    var info: DocumentInfo {
        DocumentInfo(kind: .web, pdfPath: "", title: nil, pageCount: nil, lastPage: nil)
    }

    func setSaved(_ saved: Bool) async throws { throw SessionServiceError.invalidDocument("not implemented") }
    func isSaved() async throws -> Bool { throw SessionServiceError.invalidDocument("not implemented") }
    func exportVellumweb(destPath: String, pages: [WebPageText]) async throws -> VellumwebExportSummary { throw SessionServiceError.invalidDocument("not implemented") }
    func archiveDefault(pages: [WebPageText], expectedUrl: String) async throws -> Bool { throw SessionServiceError.invalidDocument("not implemented") }

    func save() async throws { throw SessionServiceError.invalidDocument("not implemented") }
    func close() async throws { throw SessionServiceError.invalidDocument("not implemented") }
    func readPdfBytes() async throws -> Data { throw SessionServiceError.invalidDocument("not implemented") }
    func annotations(pageNumber: Int?) async throws -> [Annotation] { throw SessionServiceError.invalidDocument("not implemented") }
    func createAnnotation(_ input: CreateAnnotationInput) async throws -> Annotation { throw SessionServiceError.invalidDocument("not implemented") }
    func updateAnnotation(_ input: UpdateAnnotationInput) async throws -> Bool { throw SessionServiceError.invalidDocument("not implemented") }
    func deleteAnnotation(id: String) async throws -> Bool { throw SessionServiceError.invalidDocument("not implemented") }
    func setMetadata(key: String, value: String) async throws { throw SessionServiceError.invalidDocument("not implemented") }
}
