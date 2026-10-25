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
    var coordinator: StorageCoordinator?

    init(limits: EpubContainer.Limits = .standard, coordinator: StorageCoordinator? = nil) {
        self.limits = limits
        self.coordinator = coordinator
    }

    func open(path: String, sessionId: String) async throws -> EpubDocumentSession {
        let limits = limits
        let loading = Task.detached(priority: .userInitiated) {
            let book = try EpubBook.load(path: path, limits: limits)
            return (book, EpubLibraryCatalog.customTitle(docId: book.docId))
        }
        let (book, title) = try await withTaskCancellationHandler {
            try await loading.value
        } onCancel: {
            loading.cancel()
        }
        try Task.checkCancellation()
        return EpubDocumentSession(book: book, coordinator: coordinator, titleOverride: title)
    }
}

@MainActor
final class EpubDocumentSession: DocumentSession {
    let book: EpubBook
    let info: DocumentInfo
    private var isClosed = false
    private var isClosing = false
    private let storage: EpubAnnotationStorage
    private let textIndex: EpubTextIndex
    private struct Operation {
        let mutation: Bool
        let cancel: @Sendable () -> Void
        let drain: Task<Void, Error>
    }
    private var operations: [UUID: Operation] = [:]
    var pendingOperationCount: Int { operations.count }

    var publication: EpubPublication { book.publication }

    init(
        book: EpubBook, coordinator: StorageCoordinator? = nil,
        textLimits: EpubTextIndex.Limits = .init(), titleOverride: String? = nil
    ) {
        self.book = book
        let fallbackTitle = URL(fileURLWithPath: book.path).deletingPathExtension().lastPathComponent
        info = DocumentInfo(
            kind: .epub,
            pdfPath: book.path,
            title: titleOverride ?? book.publication.metadata.title ?? fallbackTitle,
            pageCount: book.publication.spine.count,
            lastPage: nil,
            docId: book.docId,
            titleIsUserDefined: titleOverride == nil ? nil : true)
        storage = EpubAnnotationStorage(document: info, coordinator: coordinator)
        textIndex = EpubTextIndex(book: book, limits: textLimits)
    }

    /// Reads one archive resource off the main actor.
    func resourceData(at path: String) async throws -> Data {
        let container = book.container
        return try await perform {
            try Task.checkCancellation()
            return try container.data(at: path)
        }
    }

    func save() async throws {
        try requireOpen()
        try await drain(Array(operations.values))
        try requireOpen()
    }

    func close() async throws {
        if isClosed { return }
        isClosing = true
        let pending = Array(operations.values)
        for operation in pending where !operation.mutation { operation.cancel() }
        var failure: Error?
        do { try await drain(pending) } catch { failure = error }
        await textIndex.close()
        isClosed = true
        if let failure { throw failure }
    }

    func readPdfBytes() async throws -> Data {
        throw SessionServiceError.invalidDocument("This tab is an EPUB book, not a PDF")
    }

    func annotations(pageNumber: Int?) async throws -> [Annotation] {
        let storage = storage
        return try await perform { try await storage.annotations(pageNumber: pageNumber) }
    }

    func createAnnotation(_ input: CreateAnnotationInput) async throws -> Annotation {
        let storage = storage
        let textIndex = textIndex
        let publication = publication
        return try await perform(mutation: true) {
            let position = try await Self.validatedPosition(
                input.positionData, pageNumber: input.pageNumber, publication: publication, index: textIndex)
            try Task.checkCancellation()
            let now = ISO8601DateFormatter().string(from: Date())
            let annotation = Annotation(
                id: input.id ?? UUID().uuidString.lowercased(), type: input.type, pageNumber: input.pageNumber,
                color: input.color ?? (input.type == .bookmark ? nil : "#fde68a"), content: input.content,
                positionData: position, createdAt: input.createdAt ?? now, updatedAt: now)
            return try await storage.create(annotation)
        }
    }

    func updateAnnotation(_ input: UpdateAnnotationInput) async throws -> Bool {
        let storage = storage
        let index = textIndex
        let publication = publication
        return try await perform(mutation: true) {
            var update = input
            if let position = input.positionData {
                guard let anchor = position.epubAnchor,
                    let spineIndex = publication.spineIndex(path: anchor.chapterHref) else {
                    throw EpubAnnotationError.invalidAnchor
                }
                let page = input.pageNumber ?? spineIndex + 1
                update.positionData = try await Self.validatedPosition(
                    position, pageNumber: page, publication: publication, index: index)
                update.pageNumber = page
            } else if input.pageNumber != nil {
                throw EpubAnnotationError.invalidAnchor
            }
            try Task.checkCancellation()
            return try await storage.update(update)
        }
    }

    func deleteAnnotation(id: String) async throws -> Bool {
        let storage = storage
        return try await perform(mutation: true) { try await storage.delete(id: id) }
    }

    /// Reading progress is tracked by the position service, not in the book.
    func setMetadata(key: String, value: String) async throws { try requireOpen() }

    func ensureDocumentId() async throws -> String {
        try requireOpen()
        return book.docId
    }

    /// Zero-based spine input; metadata and annotation page numbers are one-based.
    func chapterText(spineIndex: Int) async throws -> EpubChapterText {
        let index = textIndex
        return try await perform { try await index.chapter(spineIndex: spineIndex) }
    }

    func chapterMetadata() async throws -> [EpubChapterMetadata] {
        let index = textIndex
        return try await perform { try await index.metadata() }
    }

    func resolveAnchor(_ anchor: EpubTextAnchor) async throws -> EpubTextAnchor? {
        let index = textIndex
        return try await perform { try await index.resolve(anchor) }
    }

    func search(query: String, limit: Int = 100) async throws -> EpubSearchResponse {
        let index = textIndex
        return try await perform { try await index.search(query: query, limit: limit) }
    }

    private nonisolated static func validatedPosition(
        _ position: PositionData?, pageNumber: Int, publication: EpubPublication, index: EpubTextIndex
    ) async throws -> PositionData {
        guard pageNumber > 0, pageNumber <= publication.spine.count else { throw EpubAnnotationError.invalidChapter }
        guard var position, let anchor = position.epubAnchor,
            anchor.chapterHref == publication.spine[pageNumber - 1].path else {
            throw EpubAnnotationError.invalidAnchor
        }
        if anchor.startUTF16 != nil || anchor.endUTF16 != nil {
            guard let start = anchor.startUTF16, let end = anchor.endUTF16,
                start >= 0, end > start else { throw EpubAnnotationError.invalidAnchor }
        }
        guard let canonical = try await index.resolve(anchor, validatingRange: true) else {
            throw EpubAnnotationError.invalidAnchor
        }
        try Task.checkCancellation()
        position.epubAnchor = canonical
        position.selectedText = canonical.quote
        return position
    }

    private func requireOpen() throws {
        try Task.checkCancellation()
        guard !isClosed else { throw SessionServiceError.invalidDocument("This EPUB is closed") }
        guard !isClosing else { throw CancellationError() }
    }

    private func perform<T: Sendable>(
        mutation: Bool = false, _ body: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        try requireOpen()
        let id = UUID()
        let task = Task.detached(priority: .userInitiated, operation: body)
        let drain = Task { _ = try await task.value }
        operations[id] = Operation(mutation: mutation, cancel: { task.cancel() }, drain: drain)
        defer { operations[id] = nil }
        let value = try await withTaskCancellationHandler {
            try await task.value
        } onCancel: { task.cancel() }
        // A completed atomic commit is success even if cancellation arrived too late.
        // Reads, unlike commits, must never publish a stale result.
        if !mutation { try requireOpen() }
        return value
    }

    private func drain(_ pending: [Operation]) async throws {
        var failure: Error?
        for operation in pending {
            do { try await operation.drain.value }
            catch is CancellationError {} catch {
                if operation.mutation, failure == nil { failure = error }
            }
        }
        if let failure { throw failure }
    }
}
