import Foundation
import PDFKit
import CoreGraphics

// PDF document sessions — port of src-tauri/src/pdf_session.rs plus the
// command surface of pdf_annotations.rs (open/validate, get/create/update/
// delete annotations, metadata, bytes). A session is just a canonicalized
// path; like the Rust code, every operation loads the file fresh from disk,
// mutates, and rewrites it atomically.

@MainActor
final class PdfSessionBackend {
    /// open_file: validate the extension, canonicalize, require a file, parse,
    /// and read (title, page_count, last_page).
    func open(path: String, sessionId: String) async throws -> PdfDocumentSession {
        let ext = URL(fileURLWithPath: path).pathExtension.lowercased()
        guard ext == "pdf" else {
            throw SessionServiceError.invalidDocument("Unsupported file type: .\(ext)")
        }

        let canonical = try PdfDocumentLoader.canonicalize(path)
        var isDirectory: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: canonical, isDirectory: &isDirectory)
        guard exists, !isDirectory.boolValue else {
            throw SessionServiceError.invalidDocument("PDF path is not a file: \(canonical)")
        }

        let document = try PdfDocumentLoader.loadRaw(path: canonical)
        let (title, pageCount, lastPage) = PdfMetadata.documentInfo(document: document, path: canonical)

        return PdfDocumentSession(
            path: canonical,
            info: DocumentInfo(
                kind: .pdf,
                pdfPath: canonical,
                title: title,
                pageCount: pageCount,
                lastPage: lastPage))
    }
}

// MARK: - Loading (with stale-xref recovery)

/// load_document port: normal parse, then — only for files carrying the
/// VellumCreatedAt marker (i.e. files we wrote) — a byte-level repair that
/// blanks stale /Prev + /XRefStm pointers in the final trailer and retries.
enum PdfDocumentLoader {
    static func canonicalize(_ path: String) throws -> String {
        var buffer = [CChar](repeating: 0, count: Int(PATH_MAX))
        guard realpath(path, &buffer) != nil else {
            let code = errno
            let message = String(cString: strerror(code))
            throw SessionServiceError.io("Failed to resolve PDF path \(path): \(message) (os error \(code))")
        }
        return String(cString: buffer)
    }

    static func readFile(_ path: String) throws -> Data {
        do {
            return try Data(contentsOf: URL(fileURLWithPath: path))
        } catch {
            throw SessionServiceError.io("Failed to read PDF for recovery: \(error.localizedDescription)")
        }
    }

    static func cgDocument(from data: Data) -> CGPDFDocument? {
        guard let provider = CGDataProvider(data: data as CFData) else { return nil }
        return CGPDFDocument(provider)
    }

    /// Read-only load (CGPDF).
    static func loadRaw(path: String) throws -> CGPDFDocument {
        try load(path: path, make: cgDocument(from:))
    }

    /// Mutation load: PDFKit document + raw CGPDF view of the SAME bytes.
    static func loadForMutation(path: String) throws -> (document: PDFDocument, raw: CGPDFDocument) {
        try load(path: path) { data in
            guard let raw = cgDocument(from: data), let document = PDFDocument(data: data) else {
                return nil
            }
            return (document, raw)
        }
    }

    private static func load<T>(path: String, make: (Data) -> T?) throws -> T {
        let data = try readFile(path)
        if let loaded = make(data) { return loaded }

        var bytes = [UInt8](data)
        guard PdfXrefRepair.containsVellumMarker(bytes), PdfXrefRepair.stripStaleXrefLinks(&bytes) else {
            throw SessionServiceError.invalidDocument("Failed to parse PDF: unreadable or unsupported document")
        }
        guard let repaired = make(Data(bytes)) else {
            throw SessionServiceError.invalidDocument(
                "Failed to parse PDF: unreadable or unsupported document; recovery also failed")
        }
        return repaired
    }
}

// MARK: - Shared serialization gate

/// The single serialization point for EVERY on-disk mutation of a Vellum PDF —
/// annotation create/update/delete, metadata, bookmark increments, and Apple
/// Pencil ink writes. Each of those is a full read-modify-write (parse the whole
/// document, mutate, re-serialize via `PDFDocument.dataRepresentation()`, atomic
/// rename), so two writers to the same file that interleaved would clobber each
/// other's rewrite (the classic lost update). Funnelling them all through one
/// actor makes the writes strictly sequential and — because actors run on the
/// cooperative pool, never the main thread — keeps the MainActor responsive
/// while a textbook-size document is being rewritten.
///
/// The bodies are `@Sendable` synchronous closures: they construct and consume
/// the non-Sendable `CGPDFDocument`/`PDFDocument` values entirely inside
/// themselves, so only Sendable values (paths, `Data`, model structs) ever cross
/// the actor boundary.
actor PdfFileGate {
    static let shared = PdfFileGate()

    /// Run one mutating file operation to completion before the next begins.
    func perform<T: Sendable>(_ body: @Sendable () throws -> T) rethrows -> T {
        try body()
    }
}

/// Reads run OFF the gate, detached from the MainActor. The atomic-rename write
/// path means a reader always observes either the complete previous file or the
/// complete next one — never a torn write — so reads need no serialization with
/// writers and can proceed concurrently, which matters because the sidebar
/// re-reads annotations on every annotations-updated notification.
private func offMainRead<T: Sendable>(
    _ body: @Sendable @escaping () throws -> T
) async throws -> T {
    try await Task.detached(priority: .userInitiated, operation: body).value
}

// MARK: - Session

@MainActor
final class PdfDocumentSession: DocumentSession {
    let path: String
    let info: DocumentInfo

    init(path: String, info: DocumentInfo) {
        self.path = path
        self.info = info
    }

    /// save_session: annotation/metadata mutations are written immediately, so
    /// save is a synchronization no-op.
    func save() async throws {}

    /// close_session runs the same no-op sync; the manager drops the session.
    func close() async throws {}

    /// read_pdf_bytes: the CURRENT file contents, re-read from disk each call.
    func readPdfBytes() async throws -> Data {
        let path = self.path
        return try await offMainRead { try Self.readBytes(path: path) }
    }

    // MARK: Annotations

    /// get_annotations: every supported page annotation plus outline bookmarks,
    /// sorted by page_number then created_at (string compare, stable).
    func annotations(pageNumber: Int?) async throws -> [Annotation] {
        let path = self.path
        return try await offMainRead { try Self.readAnnotations(path: path, pageNumber: pageNumber) }
    }

    /// create_annotation: embed a /Highlight or /Text annotation, or divert
    /// bookmarks to outline creation. Saves the file; returns the full record.
    func createAnnotation(_ input: CreateAnnotationInput) async throws -> Annotation {
        let path = self.path
        return try await PdfFileGate.shared.perform { try Self.performCreate(path: path, input: input) }
    }

    /// update_annotation: only provided fields change; /M and /VellumUpdatedAt
    /// always refresh. Returns false when the id is unknown.
    func updateAnnotation(_ input: UpdateAnnotationInput) async throws -> Bool {
        let path = self.path
        return try await PdfFileGate.shared.perform { try Self.performUpdate(path: path, input: input) }
    }

    /// delete_annotation: outline bookmarks first, then page annotations;
    /// false when the id is unknown.
    func deleteAnnotation(id: String) async throws -> Bool {
        let path = self.path
        return try await PdfFileGate.shared.perform { try Self.performDelete(path: path, id: id) }
    }

    /// set_metadata: `page_count` is ignored; everything else lands in the
    /// Info dictionary and rewrites the file.
    func setMetadata(key: String, value: String) async throws {
        let path = self.path
        try await PdfFileGate.shared.perform { try Self.performSetMetadata(path: path, key: key, value: value) }
    }

    // MARK: Off-main implementations

    nonisolated static func readBytes(path: String) throws -> Data {
        do {
            return try Data(contentsOf: URL(fileURLWithPath: path))
        } catch {
            throw SessionServiceError.io("Failed to read PDF at \(path): \(error.localizedDescription)")
        }
    }

    nonisolated static func readAnnotations(path: String, pageNumber: Int?) throws -> [Annotation] {
        let document = try PdfDocumentLoader.loadRaw(path: path)
        var annotations: [Annotation] = []

        let pageCount = document.numberOfPages
        if pageCount > 0 {
            for page in 1...pageCount {
                if let requested = pageNumber, requested != page { continue }
                guard let pageDictionary = document.page(at: page)?.dictionary else {
                    throw SessionServiceError.invalidDocument("Failed to read PDF page: missing page dictionary")
                }
                let geometry = try PageGeometry(pageDictionary: pageDictionary)
                annotations.append(contentsOf: PdfAnnotationReader.annotations(
                    onPage: pageDictionary, pageNumber: page, geometry: geometry))
            }
        }
        annotations.append(contentsOf: PdfBookmarks.readBookmarks(document: document, pageNumber: pageNumber))

        // Stable sort: page_number asc, then created_at as a plain string.
        return annotations.enumerated()
            .sorted { left, right in
                if left.element.pageNumber != right.element.pageNumber {
                    return left.element.pageNumber < right.element.pageNumber
                }
                if left.element.createdAt != right.element.createdAt {
                    return left.element.createdAt < right.element.createdAt
                }
                return left.offset < right.offset
            }
            .map(\.element)
    }

    /// create_annotation: embed a /Highlight or /Text annotation, or divert
    /// bookmarks to outline creation. Saves the file; returns the full record.
    nonisolated static func performCreate(path: String, input: CreateAnnotationInput) throws -> Annotation {
        let (document, raw) = try PdfDocumentLoader.loadForMutation(path: path)
        guard input.pageNumber >= 1, input.pageNumber <= raw.numberOfPages else {
            throw SessionServiceError.invalidDocument("Page \(input.pageNumber) does not exist")
        }

        let id = input.id ?? UUID().uuidString.lowercased()
        let now = input.createdAt ?? PdfDates.rfc3339Now()

        if input.type == .bookmark {
            let normalized = try serialize(document)
            let patched = try PdfBookmarks.createBookmarkIncrement(
                normalizedData: normalized, pageNumber: input.pageNumber, id: id, now: now)
            try saveThroughPdfKit(patched, path: path)
            return Annotation(
                id: id,
                type: .bookmark,
                pageNumber: input.pageNumber,
                color: nil,
                content: nil,
                positionData: nil,
                createdAt: now,
                updatedAt: now)
        }

        guard let pageDictionary = raw.page(at: input.pageNumber)?.dictionary,
              let page = document.page(at: input.pageNumber - 1)
        else {
            throw SessionServiceError.invalidDocument("Page \(input.pageNumber) does not exist")
        }
        let geometry = try PageGeometry(pageDictionary: pageDictionary)
        let (annotation, position, color, content, patches) = try PdfAnnotationWriter.makeAnnotation(
            input: input, geometry: geometry, id: id, now: now)
        page.addAnnotation(annotation)

        var data = try serialize(document)
        PdfBytePatch.apply(patches, to: &data)
        try PdfAtomicWriter.save(data, toPath: path)

        return Annotation(
            id: id,
            type: input.type,
            pageNumber: input.pageNumber,
            color: color,
            content: content,
            positionData: position,
            createdAt: now,
            updatedAt: now)
    }

    /// update_annotation: matches /NM or derived ids (third-party annotations
    /// included; un-NM'd ones get stamped with their derived id). Never
    /// matches outline bookmarks. Only provided fields change; /M and
    /// /VellumUpdatedAt always refresh.
    nonisolated static func performUpdate(path: String, input: UpdateAnnotationInput) throws -> Bool {
        let (document, raw) = try PdfDocumentLoader.loadForMutation(path: path)
        guard let (pageIndex, annotation) = Self.findAnnotation(id: input.id, in: document, raw: raw) else {
            return false
        }

        PdfAnnotationWriter.setText(annotation, "NM", input.id)
        PdfAnnotationWriter.setText(annotation, "M", PdfDates.pdfDateNow())
        PdfAnnotationWriter.setText(annotation, "VellumUpdatedAt", PdfDates.rfc3339Now())

        if let color = input.color {
            annotation.color = PdfColor.annotationColor(fromHex: color)
        }
        if let content = input.content {
            annotation.contents = content
        }
        if let position = input.positionData {
            guard let pageDictionary = raw.page(at: pageIndex + 1)?.dictionary else {
                throw SessionServiceError.invalidDocument("Failed to read PDF page: missing page dictionary")
            }
            let geometry = try PageGeometry(pageDictionary: pageDictionary)
            let isHighlight = annotation.type == "Highlight"
            try PdfAnnotationWriter.applyPosition(
                annotation, geometry: geometry, position: position, isHighlight: isHighlight)
            if let selectedText = position.selectedText {
                PdfAnnotationWriter.setText(annotation, "VellumSelectedText", selectedText)
            }
        }

        let data = try serialize(document)
        try PdfAtomicWriter.save(data, toPath: path)
        return true
    }

    /// delete_annotation: outline bookmarks first, then page annotations;
    /// false when the id is unknown.
    nonisolated static func performDelete(path: String, id: String) throws -> Bool {
        let (document, raw) = try PdfDocumentLoader.loadForMutation(path: path)

        if PdfBookmarks.containsBookmark(document: raw, id: id) {
            let normalized = try serialize(document)
            guard let patched = try PdfBookmarks.deleteBookmarkIncrement(normalizedData: normalized, id: id) else {
                return false
            }
            try saveThroughPdfKit(patched, path: path)
            return true
        }

        guard let (pageIndex, annotation) = Self.findAnnotation(id: id, in: document, raw: raw),
              let page = document.page(at: pageIndex)
        else {
            return false
        }

        // PDFKit's serializer maps an annotation's PARSED index onto the raw
        // /Annots slot when persisting a removal, so on pages where the two
        // domains diverge (null / non-dictionary slots) removeAnnotation would
        // drop the WRONG entry from the file. Rewrite the page's /Annots at
        // the byte level in that case.
        let rawSlotCount = (raw.page(at: pageIndex + 1)?.dictionary)
            .flatMap { CgPdf.array($0, "Annots") }
            .map(CgPdf.count) ?? 0
        if rawSlotCount != page.annotations.count {
            let normalized = try serialize(document)
            guard let patched = try Self.deleteAnnotationIncrement(
                normalizedData: normalized, id: id, pageNumber: pageIndex + 1)
            else {
                return false
            }
            try saveThroughPdfKit(patched, path: path)
            return true
        }

        page.removeAnnotation(annotation)
        let data = try serialize(document)
        try PdfAtomicWriter.save(data, toPath: path)
        return true
    }

    /// set_metadata: `page_count` is ignored; everything else lands in the
    /// Info dictionary and rewrites the file.
    nonisolated static func performSetMetadata(path: String, key: String, value: String) throws {
        if key == "page_count" { return }
        let (document, _) = try PdfDocumentLoader.loadForMutation(path: path)
        let normalized = try serialize(document)
        let patched = try PdfMetadata.setMetadataIncrement(normalizedData: normalized, key: key, value: value)
        try saveThroughPdfKit(patched, path: path)
    }

    // MARK: Helpers

    /// find_annotation: iterate pages and entries comparing /NM or the derived
    /// `pdf-direct-{page}-{index}` id.
    ///
    /// Derived ids MUST use the same index domain as PdfAnnotationReader: the
    /// raw /Annots slot (CGPDF), not the position in PDFKit's `page.annotations`
    /// array, which omits slots PDFKit cannot instantiate (null / non-dictionary
    /// entries). A separate cursor into `page.annotations` advances only for
    /// slots CGPDF resolves to a dictionary, so both arrays stay aligned.
    nonisolated static func findAnnotation(
        id: String, in document: PDFDocument, raw: CGPDFDocument
    ) -> (pageIndex: Int, annotation: PDFAnnotation)? {
        for pageIndex in 0..<document.pageCount {
            guard let page = document.page(at: pageIndex) else { continue }
            let annotations = page.annotations
            guard !annotations.isEmpty,
                  let pageDictionary = raw.page(at: pageIndex + 1)?.dictionary,
                  let entries = CgPdf.array(pageDictionary, "Annots")
            else { continue }
            var cursor = 0
            for index in 0..<CgPdf.count(entries) {
                guard let dictionary = CgPdf.dictionaryAt(entries, index) else { continue }
                guard cursor < annotations.count else { break }
                let annotation = annotations[cursor]
                cursor += 1
                let annotationId = PdfAnnotationReader.annotationId(
                    dictionary: dictionary, pageNumber: pageIndex + 1, index: index)
                if annotationId == id {
                    return (pageIndex, annotation)
                }
            }
        }
        return nil
    }

    /// Prune one entry from a page's /Annots by rewriting the page object in
    /// an incremental update — used when PDFKit's parsed annotations and the
    /// raw /Annots slots are misaligned. `normalizedData` must be
    /// PDFKit-serializer output (it preserves /Annots slot order, so the
    /// derived-id domain carries over).
    nonisolated private static func deleteAnnotationIncrement(
        normalizedData: Data, id: String, pageNumber: Int
    ) throws -> Data? {
        guard let cg = PdfDocumentLoader.cgDocument(from: normalizedData),
              let pageDictionary = cg.page(at: pageNumber)?.dictionary,
              let entries = CgPdf.array(pageDictionary, "Annots")
        else { return nil }
        var slot: Int?
        for index in 0..<CgPdf.count(entries) {
            guard let dictionary = CgPdf.dictionaryAt(entries, index) else { continue }
            let annotationId = PdfAnnotationReader.annotationId(
                dictionary: dictionary, pageNumber: pageNumber, index: index)
            if annotationId == id {
                slot = index
                break
            }
        }
        guard let slot else { return nil }

        let file = try ClassicPdfFile(data: normalizedData)
        guard let catalogNumber = file.rootNumber,
              let catalog = file.objectSource(catalogNumber),
              let pageObjectNumber = PdfBookmarks.pageObjectNumber(
                in: file, catalog: catalog, pageNumber: pageNumber),
              var pageSource = file.objectSource(pageObjectNumber),
              let annots = pageSource.inlineArray(forKey: "Annots"),
              let pruned = PdfArraySource.removingElement(at: slot, fromArray: annots)
        else { return nil }

        pageSource.setValue(forKey: "Annots", raw: pruned)
        var increment = PdfIncrement(file: file)
        increment.setObject(pageObjectNumber, source: pageSource.sourceBytes)
        return increment.appended()
    }

    nonisolated private static func serialize(_ document: PDFDocument) throws -> Data {
        guard let data = document.dataRepresentation() else {
            throw SessionServiceError.io("Failed to write annotated PDF: PDFKit produced no data")
        }
        return data
    }

    /// Reload increment-patched data through PDFKit and write the resulting
    /// clean full rewrite (single xref, no /Prev) atomically.
    nonisolated private static func saveThroughPdfKit(_ patchedData: Data, path: String) throws {
        guard let document = PDFDocument(data: patchedData) else {
            throw SessionServiceError.io("Failed to write annotated PDF: PDFKit rejected updated document")
        }
        let data = try serialize(document)
        try PdfAtomicWriter.save(data, toPath: path)
    }
}
