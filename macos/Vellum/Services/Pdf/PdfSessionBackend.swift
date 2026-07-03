import Foundation

// STUB — replaced by the pdf-persistence module (see macos/specs/SPECS-annotations.md).
// Opens PDF files and round-trips annotations embedded in the PDF itself
// (standard /Highlight, /Text, /Outlines with /NM ids), matching what the Rust
// pdf_annotations.rs writes.

@MainActor
final class PdfSessionBackend {
    func open(path: String, sessionId: String) async throws -> PdfDocumentSession {
        throw SessionServiceError.invalidDocument("PdfSessionBackend not implemented yet")
    }
}

@MainActor
final class PdfDocumentSession: DocumentSession {
    var info: DocumentInfo {
        DocumentInfo(kind: .pdf, pdfPath: "", title: nil, pageCount: nil, lastPage: nil)
    }

    func save() async throws { throw SessionServiceError.invalidDocument("not implemented") }
    func close() async throws { throw SessionServiceError.invalidDocument("not implemented") }
    func readPdfBytes() async throws -> Data { throw SessionServiceError.invalidDocument("not implemented") }
    func annotations(pageNumber: Int?) async throws -> [Annotation] { throw SessionServiceError.invalidDocument("not implemented") }
    func createAnnotation(_ input: CreateAnnotationInput) async throws -> Annotation { throw SessionServiceError.invalidDocument("not implemented") }
    func updateAnnotation(_ input: UpdateAnnotationInput) async throws -> Bool { throw SessionServiceError.invalidDocument("not implemented") }
    func deleteAnnotation(id: String) async throws -> Bool { throw SessionServiceError.invalidDocument("not implemented") }
    func setMetadata(key: String, value: String) async throws { throw SessionServiceError.invalidDocument("not implemented") }
}
