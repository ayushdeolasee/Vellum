import XCTest
import PDFKit
import CoreGraphics
import CryptoKit
@testable import Vellum

// DocumentID layer (Services/DocumentIdentity.swift, /VellumDocId stamping in
// Services/Pdf/*). Verifies the lazy stamp piggybacks a mutation, that
// ensureDocumentId is idempotent and degrades gracefully on unwritable files,
// and that DocumentIdentity.storageKey matches the path-hash convention.
@MainActor
final class DocumentIdentityTests: XCTestCase {
    private var tempDir: URL!
    /// CGPDF dictionaries are interior pointers — retain the owning documents.
    private var retainedDocuments: [CGPDFDocument] = []

    override func setUp() async throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("vellum-docid-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        PdfDocIdRegistry.reset()
    }

    override func tearDown() async throws {
        retainedDocuments.removeAll()
        PdfDocIdRegistry.reset()
        if let tempDir {
            try? FileManager.default.removeItem(at: tempDir)
        }
    }

    // MARK: - Fixtures

    /// Multi-page PDF via CoreGraphics (arbitrary third-party-ish producer),
    /// carrying no Vellum keys.
    @discardableResult
    private func makeTestPdf(at url: URL, pages: Int = 2) -> String {
        var mediaBox = CGRect(x: 0, y: 0, width: 612, height: 792)
        let context = CGContext(url as CFURL, mediaBox: &mediaBox, nil)!
        for index in 0..<pages {
            context.beginPDFPage(nil)
            let font = CTFontCreateWithName("Helvetica" as CFString, 24, nil)
            let attributes = [kCTFontAttributeName: font] as CFDictionary
            let text = CFAttributedStringCreate(nil, "Page \(index + 1) hello world" as CFString, attributes)!
            let line = CTLineCreateWithAttributedString(text)
            context.textPosition = CGPoint(x: 72, y: 700)
            CTLineDraw(line, context)
            context.endPDFPage()
        }
        context.closePDF()
        return url.path
    }

    private func makeTestPdf(name: String, pages: Int = 2) -> String {
        makeTestPdf(at: tempDir.appendingPathComponent("\(name).pdf"), pages: pages)
    }

    private func openSession(_ path: String) async throws -> PdfDocumentSession {
        try await PdfSessionBackend().open(path: path, sessionId: UUID().uuidString)
    }

    private func rawDocument(_ path: String) -> CGPDFDocument {
        let document = CGPDFDocument(URL(fileURLWithPath: path) as CFURL)!
        retainedDocuments.append(document)
        return document
    }

    private func highlight(_ x: Double = 72, _ y: Double = 100) -> CreateAnnotationInput {
        CreateAnnotationInput(
            type: .highlight,
            pageNumber: 1,
            color: "#fef08a",
            content: nil,
            positionData: PositionData(
                rects: [AnnotationRect(x: x, y: y, width: 180, height: 16)],
                pageWidth: 612,
                pageHeight: 792,
                selectedText: "selected text",
                startOffset: nil,
                endOffset: nil,
                prefix: nil,
                suffix: nil,
                viewportOffset: nil))
    }

    // MARK: - Tests

    /// The first annotation stamps /VellumDocId in the same rewrite; the id then
    /// round-trips and is stable across further edits and reopens.
    func testStampOnFirstAnnotationRoundTrip() async throws {
        let path = makeTestPdf(name: "stamp-annot")
        let session = try await openSession(path)
        XCTAssertNil(session.info.docId, "opening must never stamp")
        XCTAssertNil(PdfMetadata.documentId(rawDocument(path)), "raw file carries no doc id before any write")

        _ = try await session.createAnnotation(highlight())

        let reopened = try await openSession(path)
        let id = try XCTUnwrap(reopened.info.docId, "first annotation must stamp a doc id")
        XCTAssertEqual(id, id.lowercased())
        XCTAssertNotNil(UUID(uuidString: id), "doc id is a lowercase UUID string")
        XCTAssertEqual(PdfMetadata.documentId(rawDocument(path)), id, "raw Info dict carries /VellumDocId")

        // A second annotation must not re-stamp; the id stays put.
        _ = try await reopened.createAnnotation(highlight(72, 200))
        let again = try await openSession(path)
        XCTAssertEqual(again.info.docId, id, "doc id is stable across further edits")
    }

    /// ensureDocumentId returns the same id every call and rewrites the file
    /// exactly once (the stamp), including across a fresh session.
    func testEnsureDocumentIdIdempotentAndWritesOnce() async throws {
        let path = makeTestPdf(name: "ensure-idem")
        let session = try await openSession(path)
        XCTAssertNil(session.info.docId)

        let id1 = try await session.ensureDocumentId()
        XCTAssertNotNil(UUID(uuidString: id1), "unwritable-free path stamps a UUID")
        let afterFirst = try Data(contentsOf: URL(fileURLWithPath: session.path))

        // Second call on the same session is cached: no write, byte-identical.
        let id2 = try await session.ensureDocumentId()
        XCTAssertEqual(id2, id1)
        let afterSecond = try Data(contentsOf: URL(fileURLWithPath: session.path))
        XCTAssertEqual(afterFirst, afterSecond, "ensureDocumentId must not rewrite once stamped")

        // A fresh session reads the same id from disk and also does not rewrite.
        let reopened = try await openSession(path)
        XCTAssertEqual(reopened.info.docId, id1, "the stamp round-trips across sessions")
        let id3 = try await reopened.ensureDocumentId()
        XCTAssertEqual(id3, id1)
        let afterThird = try Data(contentsOf: URL(fileURLWithPath: session.path))
        XCTAssertEqual(afterSecond, afterThird, "reading an existing id must not rewrite the file")
    }

    /// When the containing directory is unwritable the stamp write fails; the
    /// resolver falls back to a deterministic full-byte sha256 and persists
    /// nothing.
    func testEnsureDocumentIdFallsBackWhenDirectoryReadOnly() async throws {
        let dir = tempDir.appendingPathComponent("ro-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let path = makeTestPdf(at: dir.appendingPathComponent("locked.pdf"))
        let session = try await openSession(path)

        // Remove the owner write bit so the atomic temp-write in this dir fails.
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: dir.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: dir.path) }

        let fileData = try Data(contentsOf: URL(fileURLWithPath: session.path))
        let id = try await session.ensureDocumentId()
        XCTAssertEqual(id, DocumentIdentity.byteHash(fileData), "read-only PDF → full-byte sha256")
        XCTAssertEqual(id.count, 64, "bare-hex sha256 is 64 chars")
        XCTAssertNil(UUID(uuidString: id), "the fallback is a hash, not a UUID")

        // Restore perms and confirm the fallback persisted nothing to disk.
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: dir.path)
        XCTAssertNil(PdfMetadata.documentId(rawDocument(session.path)), "fallback must not stamp the file")
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: session.path)), fileData, "file bytes unchanged")
    }

    /// Two independent PdfDocumentIO actors opening the SAME file (the split-pane
    /// case) must converge on ONE /VellumDocId: the process-wide registry hands
    /// both stampers the same pending UUID, so their first mutations agree even
    /// when neither stamp has hit disk yet. The id then round-trips on reopen.
    func testSplitPaneStampsConvergeOnOneDocId() async throws {
        let path = makeTestPdf(name: "split-converge")
        // Two sessions on the same canonical path (as two panes would hold).
        let a = try await openSession(path)
        let b = try await openSession(path)
        XCTAssertNil(a.info.docId)
        XCTAssertNil(b.info.docId)

        // Both stamp on their first mutation. The IO actor serializes the writes,
        // but the ids are drawn from the shared registry, so they must match.
        _ = try await a.createAnnotation(highlight())
        _ = try await b.createAnnotation(highlight(72, 300))

        let idA = try await a.ensureDocumentId()
        let idB = try await b.ensureDocumentId()
        XCTAssertEqual(idA, idB, "split panes must not mint divergent doc ids")

        let reopened = try await openSession(path)
        XCTAssertEqual(reopened.info.docId, idA, "the single stamped id round-trips")
        XCTAssertEqual(PdfMetadata.documentId(rawDocument(path)), idA)
    }

    /// A failed stamp WRITE must not leave the session claiming a UUID that never
    /// reached the file. With the directory read-only the write throws; the actor
    /// keeps docId nil, so ensureDocumentId degrades to the byte-hash fallback and
    /// the file stays unstamped — no phantom id keying data unrecoverably.
    func testFailedStampWriteDoesNotCachePhantomDocId() async throws {
        let dir = tempDir.appendingPathComponent("ro-stamp-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let path = makeTestPdf(at: dir.appendingPathComponent("locked.pdf"))
        let session = try await openSession(path)
        let before = try Data(contentsOf: URL(fileURLWithPath: path))

        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: dir.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: dir.path) }

        // A mutation whose stamp+write fails must throw and NOT cache a doc id.
        do {
            _ = try await session.createAnnotation(highlight())
            XCTFail("createAnnotation should throw when the directory is read-only")
        } catch {}

        // ensureDocumentId now falls back to the full-byte hash (no phantom UUID).
        let id = try await session.ensureDocumentId()
        XCTAssertEqual(id, DocumentIdentity.byteHash(before), "unstamped file → byte hash, not a cached UUID")
        XCTAssertNil(UUID(uuidString: id), "the fallback is a hash, not a UUID")

        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: dir.path)
        XCTAssertNil(PdfMetadata.documentId(rawDocument(path)), "the file must carry no stamp after a failed write")
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: path)), before, "bytes unchanged after failed stamp")
    }

    /// storageKey uses docId when present, else the sha256(path) hex — identical
    /// to PageTextCache.pathKey / DocumentIdentity.sha256Hex.
    func testStorageKeyResolution() throws {
        let unstamped = DocumentInfo(
            kind: .pdf, pdfPath: "/tmp/example.pdf", title: "x", pageCount: 1, lastPage: nil)
        XCTAssertNil(unstamped.docId)
        XCTAssertEqual(DocumentIdentity.storageKey(for: unstamped), PageTextCache.pathKey("/tmp/example.pdf"))
        XCTAssertEqual(DocumentIdentity.storageKey(for: unstamped), DocumentIdentity.sha256Hex("/tmp/example.pdf"))

        var stamped = unstamped
        stamped.docId = "550e8400-e29b-41d4-a716-446655440000"
        XCTAssertEqual(DocumentIdentity.storageKey(for: stamped), "550e8400-e29b-41d4-a716-446655440000")

        // Web docs carry the URL hash as their docId; storageKey returns it.
        let hash = WebLibrary.pageKey("https://example.com/")
        let web = DocumentInfo(
            kind: .web, pdfPath: "https://example.com/", title: nil,
            pageCount: nil, lastPage: nil, docId: hash)
        XCTAssertEqual(DocumentIdentity.storageKey(for: web), hash)
    }

    /// byteHash is the plain lowercase-hex sha256 of the bytes (not the partial
    /// content-hash validator).
    func testByteHashIsFullSha256() {
        let data = Data("vellum".utf8)
        let expected = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        XCTAssertEqual(DocumentIdentity.byteHash(data), expected)
    }
}
