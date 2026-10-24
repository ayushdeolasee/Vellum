import CryptoKit
import Foundation

// EPUB sessions. Opening validates and parses the package off the main actor
// and derives the book's docId from its bytes, so moving or reimporting an
// identical file keeps its scratchpad, conversations and reading position
// while a changed edition gets a separate identity. The session keeps the
// archive open for on-demand resource reads; nothing is extracted to disk.

/// Content-derived EPUB identity.
enum EpubIdentity {
    /// Bare-hex sha256 of the file's bytes, streamed. A canonical storage key.
    static func contentDocId(fileAt url: URL) throws -> String {
        let handle: FileHandle
        do {
            handle = try FileHandle(forReadingFrom: url)
        } catch {
            throw SessionServiceError.io("Failed to read EPUB at \(url.path): \(error.localizedDescription)")
        }
        defer { try? handle.close() }
        var hasher = SHA256()
        while true {
            try Task.checkCancellation()
            let chunk: Data?
            do {
                chunk = try handle.read(upToCount: 1024 * 1024)
            } catch {
                throw SessionServiceError.io("Failed to read EPUB at \(url.path): \(error.localizedDescription)")
            }
            guard let chunk, !chunk.isEmpty else { break }
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}

/// A validated, parsed book with its archive open for resource reads.
struct EpubBook: Sendable {
    let path: String
    let docId: String
    let publication: EpubPublication
    let container: EpubContainer

    /// Synchronous and blocking: call from a background task only.
    static func load(path: String, limits: EpubContainer.Limits = .standard) throws -> EpubBook {
        let url = URL(fileURLWithPath: path).resolvingSymlinksInPath().standardizedFileURL
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), !isDirectory.boolValue else {
            throw SessionServiceError.io("No EPUB file at \(path)")
        }
        let docId = try EpubIdentity.contentDocId(fileAt: url)
        try Task.checkCancellation()
        let container = try EpubContainer(url: url, limits: limits)
        try Task.checkCancellation()
        let publication = try EpubPackageParser.parse(container: container)
        return EpubBook(path: url.path, docId: docId, publication: publication, container: container)
    }
}

@MainActor
final class EpubSessionBackend {
    private let limits: EpubContainer.Limits

    init(limits: EpubContainer.Limits = .standard) {
        self.limits = limits
    }

    func open(path: String, sessionId: String) async throws -> EpubDocumentSession {
        let limits = limits
        let loading = Task.detached(priority: .userInitiated) {
            try EpubBook.load(path: path, limits: limits)
        }
        let book = try await withTaskCancellationHandler {
            try await loading.value
        } onCancel: {
            loading.cancel()
        }
        try Task.checkCancellation()
        return EpubDocumentSession(book: book)
    }
}

@MainActor
final class EpubDocumentSession: DocumentSession {
    let book: EpubBook
    let info: DocumentInfo
    private var isClosed = false

    var publication: EpubPublication { book.publication }

    init(book: EpubBook) {
        self.book = book
        let fallbackTitle = URL(fileURLWithPath: book.path).deletingPathExtension().lastPathComponent
        info = DocumentInfo(
            kind: .epub,
            pdfPath: book.path,
            title: book.publication.metadata.title ?? fallbackTitle,
            pageCount: book.publication.spine.count,
            lastPage: nil,
            docId: book.docId)
    }

    /// Reads one archive resource off the main actor.
    func resourceData(at path: String) async throws -> Data {
        guard !isClosed else { throw SessionServiceError.invalidDocument("This EPUB is closed") }
        let container = book.container
        return try await Task.detached(priority: .userInitiated) {
            try container.data(at: path)
        }.value
    }

    func save() async throws {}

    func close() async throws {
        isClosed = true
    }

    func readPdfBytes() async throws -> Data {
        throw SessionServiceError.invalidDocument("This tab is an EPUB book, not a PDF")
    }

    func annotations(pageNumber: Int?) async throws -> [Annotation] { [] }

    func createAnnotation(_ input: CreateAnnotationInput) async throws -> Annotation {
        throw Self.annotationsUnavailable
    }

    func updateAnnotation(_ input: UpdateAnnotationInput) async throws -> Bool {
        throw Self.annotationsUnavailable
    }

    func deleteAnnotation(id: String) async throws -> Bool {
        throw Self.annotationsUnavailable
    }

    /// Reading progress is tracked by the position service, not in the book.
    func setMetadata(key: String, value: String) async throws {}

    func ensureDocumentId() async throws -> String { book.docId }

    private static let annotationsUnavailable = SessionServiceError.invalidDocument(
        "Highlights and notes are not available for EPUB books yet")
}
