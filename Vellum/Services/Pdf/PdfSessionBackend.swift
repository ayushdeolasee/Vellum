import Foundation
import PDFKit
import CoreGraphics

// PDF document sessions — port of src-tauri/src/pdf_session.rs plus the
// command surface of pdf_annotations.rs (open/validate, get/create/update/
// delete annotations, metadata, bytes). A session is just a canonicalized
// path; like the Rust code, every operation loads the file fresh from disk,
// mutates, and rewrites it atomically.
//
// All disk I/O + PDFKit parse/serialize/rewrite runs on a dedicated background
// `PdfDocumentIO` actor (never the main thread) and is serialized per document.
// The Tauri backend got this for free from a background command thread + a
// per-file lock; the earlier port pinned everything to @MainActor, so every
// annotation move/edit/read blocked the UI for the full read+parse+serialize+
// write cost (~15s on a large PDF) and stacked multiple full-file copies in
// memory. The @MainActor `PdfDocumentSession` is now a thin facade that hops to
// the actor, releasing the main thread for the duration of the work.

@MainActor
final class PdfSessionBackend {
    /// open_file: validate the extension, canonicalize, require a file, parse,
    /// and read (title, page_count, last_page). The parse runs off the main
    /// thread on the session's IO actor.
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

        let io = PdfDocumentIO(path: canonical)
        let info = try await io.open()
        return PdfDocumentSession(io: io, path: canonical, info: info)
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

// MARK: - Session facade

/// Thin @MainActor facade satisfying the @MainActor `DocumentSession` protocol.
/// Holds only the Sendable `DocumentInfo`; every operation delegates to the
/// background `PdfDocumentIO` actor, so the `await` performs a real actor hop
/// that releases the main thread while the file work runs.
@MainActor
final class PdfDocumentSession: DocumentSession {
    let path: String
    let info: DocumentInfo
    private let io: PdfDocumentIO

    init(io: PdfDocumentIO, path: String, info: DocumentInfo) {
        self.io = io
        self.path = path
        self.info = info
    }

    /// save_session: annotation/metadata mutations are written immediately, so
    /// save is a synchronization no-op.
    func save() async throws {}

    /// close_session runs the same no-op sync; the manager drops the session.
    func close() async throws {}

    func readPdfBytes() async throws -> Data { try await io.readPdfBytes() }

    func annotations(pageNumber: Int?) async throws -> [Annotation] {
        try await io.annotations(pageNumber: pageNumber)
    }

    func createAnnotation(_ input: CreateAnnotationInput) async throws -> Annotation {
        try await io.createAnnotation(input)
    }

    func updateAnnotation(_ input: UpdateAnnotationInput) async throws -> Bool {
        try await io.updateAnnotation(input)
    }

    func deleteAnnotation(id: String) async throws -> Bool {
        try await io.deleteAnnotation(id: id)
    }

    func setMetadata(key: String, value: String) async throws {
        try await io.setMetadata(key: key, value: value)
    }

    func ensureDocumentId() async throws -> String {
        try await io.ensureDocumentId()
    }
}

// MARK: - Background file engine

/// Owns all PDF disk I/O and PDFKit/CGPDF parse-serialize-rewrite work for one
/// open document. Being an `actor`, its calls run off the main thread on the
/// cooperative pool AND are serialized per instance, so overlapping mutations
/// to the same file can't interleave or clobber each other. PDFDocument /
/// CGPDFDocument values stay local to each call and never cross the actor
/// boundary, so no Sendable guarantees are required of them.
actor PdfDocumentIO {
    let path: String

    /// The document's resolved /VellumDocId: read at open, set the first time a
    /// mutation lazily stamps one. nil means "no stamp seen yet this session"
    /// (the file has never carried a doc id, or one hasn't been read/stamped).
    private var docId: String?

    /// The page-text cache's storage key for this session, resolved ONCE at open
    /// (docId-at-open ?? pathKey) and used for every refreshHash even after a
    /// mid-session docId stamp — session-stable by design, matching the key the
    /// lookup/persister were created with. Defaults to the path hash; open()
    /// promotes it to the docId when the file already carried one.
    private var cacheKey: String

    init(path: String) {
        self.path = path
        cacheKey = PageTextCache.pathKey(path)
    }

    /// Parse a freshly opened document and read (title, page_count, last_page,
    /// doc_id). Never stamps — opening a file the user hasn't invested in must
    /// not modify it.
    func open() throws -> DocumentInfo {
        let document = try PdfDocumentLoader.loadRaw(path: path)
        let (title, pageCount, lastPage, docId) = PdfMetadata.documentInfo(document: document, path: path)
        self.docId = docId
        // Session-stable cache key: the docId if the file already carries one,
        // else the path hash. A docId stamped LATER this session does not change
        // it — the persister/lookup keyed the whole session by this value.
        if let docId, !docId.isEmpty { cacheKey = docId }
        return DocumentInfo(
            kind: .pdf,
            pdfPath: path,
            title: title,
            pageCount: pageCount,
            lastPage: lastPage,
            docId: docId)
    }

    /// Return the document's stable id, stamping /VellumDocId lazily if the file
    /// has none yet. Semantics (never surfaces stamping failure to the caller):
    /// - already resolved this session → return it;
    /// - present on disk → read and return it (no write);
    /// - absent → stamp via the normal metadata write path and return the UUID;
    /// - stamp write fails (read-only dir, locked file) → bare-hex sha256 of the
    ///   full file bytes, persisting nothing (stable precisely because the file
    ///   can't be rewritten);
    /// - file unreadable → sha256 of the canonical path (today's path identity).
    func ensureDocumentId() async throws -> String {
        if let docId { return docId }
        if let raw = try? PdfDocumentLoader.loadRaw(path: path),
           let existing = PdfMetadata.documentId(raw) {
            docId = existing
            return existing
        }
        do {
            // A full rewrite whose only change is the piggybacked doc_id stamp
            // (writeAndRefreshCache runs stampDocIdIfNeeded before writing).
            let (document, _) = try PdfDocumentLoader.loadForMutation(path: path)
            let data = try serialize(document)
            try await writeAndRefreshCache(data)
            if let docId { return docId }
            throw SessionServiceError.io("Failed to stamp document id")
        } catch {
            if let data = try? Data(contentsOf: URL(fileURLWithPath: path)) {
                return DocumentIdentity.byteHash(data)
            }
            return DocumentIdentity.sha256Hex(path)
        }
    }

    /// read_pdf_bytes: the CURRENT file contents, re-read from disk each call.
    func readPdfBytes() throws -> Data {
        do {
            return try Data(contentsOf: URL(fileURLWithPath: path))
        } catch {
            throw SessionServiceError.io("Failed to read PDF at \(path): \(error.localizedDescription)")
        }
    }

    // MARK: Annotations

    /// get_annotations: every supported page annotation plus outline bookmarks,
    /// sorted by page_number then created_at (string compare, stable).
    func annotations(pageNumber: Int?) throws -> [Annotation] {
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
    func createAnnotation(_ input: CreateAnnotationInput) async throws -> Annotation {
        let (document, raw) = try PdfDocumentLoader.loadForMutation(path: path)
        guard input.pageNumber >= 1, input.pageNumber <= raw.numberOfPages else {
            throw SessionServiceError.invalidDocument("Page \(input.pageNumber) does not exist")
        }

        let id = input.id ?? UUID().uuidString.lowercased()
        let now = PdfDates.rfc3339Now()

        if input.type == .bookmark {
            let title = input.content?.isEmpty == false ? input.content : nil
            let normalized = try serialize(document)
            let patched = try PdfBookmarks.createBookmarkIncrement(
                normalizedData: normalized, pageNumber: input.pageNumber, id: id,
                content: title, now: now)
            try await saveThroughPdfKit(patched)
            return Annotation(
                id: id,
                type: .bookmark,
                pageNumber: input.pageNumber,
                color: nil,
                content: title,
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
        try await writeAndRefreshCache(data)

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

    /// update_annotation: outline bookmarks first (only their title/content is
    /// mutable), then page annotations matched by /NM or derived ids
    /// (third-party annotations included; un-NM'd ones get stamped with their
    /// derived id). Only provided fields change; /M and /VellumUpdatedAt
    /// always refresh.
    func updateAnnotation(_ input: UpdateAnnotationInput) async throws -> Bool {
        let (document, raw) = try PdfDocumentLoader.loadForMutation(path: path)

        if PdfBookmarks.containsBookmark(document: raw, id: input.id) {
            // Color and position don't apply to outline items; an update
            // carrying neither field is a no-op on an existing record.
            guard let content = input.content else { return true }
            let pageNumber = PdfBookmarks.readBookmarks(document: raw, pageNumber: nil)
                .first { $0.id == input.id }?.pageNumber ?? 1
            let normalized = try serialize(document)
            guard let patched = try PdfBookmarks.updateBookmarkIncrement(
                normalizedData: normalized,
                id: input.id,
                content: content,
                defaultTitle: PdfBookmarks.defaultTitle(pageNumber: pageNumber),
                now: PdfDates.rfc3339Now())
            else {
                return false
            }
            try await saveThroughPdfKit(patched)
            return true
        }

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
        try await writeAndRefreshCache(data)
        return true
    }

    /// delete_annotation: outline bookmarks first, then page annotations;
    /// false when the id is unknown.
    func deleteAnnotation(id: String) async throws -> Bool {
        let (document, raw) = try PdfDocumentLoader.loadForMutation(path: path)

        if PdfBookmarks.containsBookmark(document: raw, id: id) {
            let normalized = try serialize(document)
            guard let patched = try PdfBookmarks.deleteBookmarkIncrement(normalizedData: normalized, id: id) else {
                return false
            }
            try await saveThroughPdfKit(patched)
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
            try await saveThroughPdfKit(patched)
            return true
        }

        page.removeAnnotation(annotation)
        let data = try serialize(document)
        try await writeAndRefreshCache(data)
        return true
    }

    /// set_metadata: `page_count` is ignored; everything else lands in the
    /// Info dictionary and rewrites the file.
    func setMetadata(key: String, value: String) async throws {
        if key == "page_count" { return }
        let (document, _) = try PdfDocumentLoader.loadForMutation(path: path)
        let normalized = try serialize(document)
        let patched = try PdfMetadata.setMetadataIncrement(normalizedData: normalized, key: key, value: value)
        try await saveThroughPdfKit(patched)
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
    static func findAnnotation(
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
    private static func deleteAnnotationIncrement(
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

    private func serialize(_ document: PDFDocument) throws -> Data {
        guard let data = document.dataRepresentation() else {
            throw SessionServiceError.io("Failed to write annotated PDF: PDFKit produced no data")
        }
        return data
    }

    /// The outcome of preparing a doc-id stamp for a write: the (possibly)
    /// stamped bytes plus, when a fresh stamp was embedded, the UUID to COMMIT
    /// onto the actor ONCE the atomic write lands durably (`pendingStamp`). It is
    /// nil when nothing needs deferring — the file already carried an id (read
    /// off disk and committed immediately, since it is already persisted) or one
    /// was already resolved this session.
    private struct StampPlan {
        var data: Data
        var pendingStamp: String?
    }

    /// Lazy /VellumDocId stamp, folded into a write that was happening anyway
    /// (§3): if this session has never seen a doc id, take the SAME pending UUID
    /// every session stamping this path agrees on (PdfDocIdRegistry — so two
    /// split panes never mint divergent ids) and append a single incremental Info
    /// update carrying doc_id (one extra object, no second full rewrite). `data`
    /// must be classic-xref PDFKit serializer output — annotation byte patches
    /// preserve that shape, so both write chokepoints qualify. A one-time CGPDF
    /// re-check picks up an id another session already landed in these bytes.
    ///
    /// The actor's `docId` is deliberately NOT set for a fresh stamp here: the
    /// caller commits `pendingStamp` only after `PdfAtomicWriter.save` succeeds,
    /// so a failed write (read-only dir, disk full) can never leave the actor
    /// claiming a UUID that isn't in the file (would key data unrecoverably).
    private func stampDocIdIfNeeded(_ data: Data) throws -> StampPlan {
        if docId != nil { return StampPlan(data: data, pendingStamp: nil) }
        if let raw = PdfDocumentLoader.cgDocument(from: data),
           let existing = PdfMetadata.documentId(raw) {
            // Already on disk in these bytes — safe to commit now (persisted).
            docId = existing
            PdfDocIdRegistry.clear(forPath: path)
            return StampPlan(data: data, pendingStamp: nil)
        }
        let uuid = PdfDocIdRegistry.pendingOrAssign(forPath: path)
        let stamped = try PdfMetadata.setMetadataIncrement(
            normalizedData: data, entries: [(key: "doc_id", value: uuid)])
        return StampPlan(data: stamped, pendingStamp: uuid)
    }

    /// Commit a deferred stamp onto the actor after its bytes are durably on
    /// disk, and retire the registry's pending entry so later readers resolve the
    /// id from the file.
    private func commitStamp(_ plan: StampPlan) {
        guard let pending = plan.pendingStamp else { return }
        docId = pending
        PdfDocIdRegistry.clear(forPath: path)
    }

    /// Atomically write already-serialized PDF data and re-key the page-text
    /// cache to the rewrite (text-neutral; see saveThroughPdfKit). Stamps a
    /// doc_id first if the file lacks one, so first-annotation writes carry it.
    private func writeAndRefreshCache(_ data: Data) async throws {
        let plan = try stampDocIdIfNeeded(data)
        try PdfAtomicWriter.save(plan.data, toPath: path)
        commitStamp(plan)
        await PageTextCache.shared.refreshHash(key: cacheKey, data: plan.data)
    }

    /// Reload increment-patched data through PDFKit and write the resulting
    /// clean full rewrite (single xref, no /Prev) atomically. Stamps a doc_id
    /// (§3) onto the clean re-serialized bytes if the file lacks one.
    private func saveThroughPdfKit(_ patchedData: Data) async throws {
        guard let document = PDFDocument(data: patchedData) else {
            throw SessionServiceError.io("Failed to write annotated PDF: PDFKit rejected updated document")
        }
        let plan = try stampDocIdIfNeeded(try serialize(document))
        try PdfAtomicWriter.save(plan.data, toPath: path)
        commitStamp(plan)
        // In-app rewrites are text-neutral, so the persistent page-text cache
        // re-keys (refreshes its validation hash) instead of invalidating; the
        // IO actor serializes writes per document and the quit path awaits this,
        // so the refresh always completes before a reopen or termination
        // (issue #37 PR B).
        await PageTextCache.shared.refreshHash(key: cacheKey, data: plan.data)
    }
}
