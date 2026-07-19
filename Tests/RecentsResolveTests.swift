import XCTest
import CoreGraphics
@testable import Vellum

// Recents re-resolution (design §7): a recorded PDF path that no longer exists
// is re-resolved via the document's stable docId through DocumentDataStore's
// meta.json last_known_path (kept fresh by DocumentDataStore.touch). Runs under
// the DocumentDataStore override root so no real library is touched.

@MainActor
final class RecentsResolveTests: XCTestCase {
    private var root: URL!
    private var scratch: URL!

    override func setUp() async throws {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("vellum-recents-\(UUID().uuidString)")
        root = base.appendingPathComponent("documents")
        scratch = base.appendingPathComponent("files")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        DocumentDataStore.rootDirectoryOverride = root
    }

    override func tearDown() async throws {
        DocumentDataStore.rootDirectoryOverride = nil
        if let root { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }
    }

    private func recent(pdfPath: String, docId: String?) -> RecentDocument {
        RecentDocument(
            pdfPath: pdfPath, kind: .pdf, title: "Doc", pageCount: 1,
            openedAt: ISO8601DateFormatter.recentTimestamp.string(from: Date()), docId: docId)
    }

    /// A minimal real PDF, optionally stamped with a /VellumDocId — identity
    /// resolution reads the embedded id, so fixtures need genuine PDFs.
    private func makePdf(at path: String, stampedWith docId: String? = nil) throws {
        var mediaBox = CGRect(x: 0, y: 0, width: 612, height: 792)
        let context = CGContext(URL(fileURLWithPath: path) as CFURL, mediaBox: &mediaBox, nil)!
        context.beginPDFPage(nil)
        context.endPDFPage()
        context.closePDF()
        if let docId {
            try PdfMetadata.stampDocumentId(atPath: path, id: docId)
        }
    }

    // docId field survives a JSON round-trip under the snake_case key.
    func testDocIdRoundTripsThroughCoding() throws {
        let entry = recent(pdfPath: "/tmp/x.pdf", docId: "the-doc-id")
        let data = try JSONEncoder().encode(entry)
        XCTAssertTrue(
            String(data: data, encoding: .utf8)!.contains("\"doc_id\":\"the-doc-id\""),
            "docId serializes under the snake_case key")
        let decoded = try JSONDecoder().decode(RecentDocument.self, from: data)
        XCTAssertEqual(decoded.docId, "the-doc-id")
    }

    // Legacy entries with no doc_id key decode with docId == nil.
    func testLegacyEntryWithoutDocIdDecodes() throws {
        let json = #"{"pdf_path":"/tmp/legacy.pdf","kind":"pdf","opened_at":"2026-01-01T00:00:00Z"}"#
        let decoded = try JSONDecoder().decode(RecentDocument.self, from: Data(json.utf8))
        XCTAssertNil(decoded.docId)
        XCTAssertEqual(decoded.pdfPath, "/tmp/legacy.pdf")
    }

    // Dead recorded path + docId whose meta.json points at a file that DOES
    // exist and carries the matching stamp → re-resolves to the moved location.
    func testResolvesMovedPdfViaMeta() throws {
        let docId = "11111111-2222-3333-4444-555555555555"
        // The file "moved" here — a real stamped PDF at the new location
        // (resolution verifies the embedded id before adopting the path).
        let movedPath = scratch.appendingPathComponent("moved.pdf").path
        try makePdf(at: movedPath, stampedWith: docId)
        // meta.json (keyed by docId) records the current known path.
        let doc = DocumentInfo(
            kind: .pdf, pdfPath: movedPath, title: "Doc", pageCount: 1, lastPage: 1, docId: docId)
        // force: this stands in for a document that acquired data (a note/chat),
        // which is when meta.json is stamped — a bare open no longer writes it.
        try DocumentDataStore.touch(document: doc, force: true)

        // The recent still points at the OLD (now dead) path.
        let deadPath = scratch.appendingPathComponent("old-name.pdf").path
        let entry = recent(pdfPath: deadPath, docId: docId)

        XCTAssertEqual(RecentFilesService.resolvedPath(for: entry), movedPath)
    }

    // Dead path, no docId → returns the recorded path unchanged (genuine dead
    // entry; nothing to re-resolve against).
    func testDeadEntryWithoutDocIdReturnsRecordedPath() {
        let deadPath = scratch.appendingPathComponent("gone.pdf").path
        let entry = recent(pdfPath: deadPath, docId: nil)
        XCTAssertEqual(RecentFilesService.resolvedPath(for: entry), deadPath)
    }

    // A path that still exists is returned as-is even when a docId is present —
    // no meta lookup needed.
    func testExistingPathReturnedUnchanged() throws {
        let livePath = scratch.appendingPathComponent("here.pdf").path
        try Data([1]).write(to: URL(fileURLWithPath: livePath))
        let entry = recent(pdfPath: livePath, docId: "some-id")
        XCTAssertEqual(RecentFilesService.resolvedPath(for: entry), livePath)
    }

    // Path reuse: the recorded path still EXISTS but now holds a DIFFERENT
    // document (unstamped here), while meta.json points at the real file
    // carrying the matching stamp → identity wins over path existence.
    func testPathReuseResolvesByEmbeddedIdentity() throws {
        let docId = "22222222-3333-4444-5555-666666666666"
        let recordedPath = scratch.appendingPathComponent("reused-name.pdf").path
        try makePdf(at: recordedPath)  // an impostor: no /VellumDocId
        let realPath = scratch.appendingPathComponent("real-home.pdf").path
        try makePdf(at: realPath, stampedWith: docId)
        let doc = DocumentInfo(
            kind: .pdf, pdfPath: realPath, title: "Doc", pageCount: 1, lastPage: 1, docId: docId)
        try DocumentDataStore.touch(document: doc, force: true)

        let entry = recent(pdfPath: recordedPath, docId: docId)
        XCTAssertEqual(
            RecentFilesService.resolvedPath(for: entry), realPath,
            "a reused path must lose to the file whose embedded id matches")
    }

    // Dead recorded path and the meta path's file does NOT carry the matching
    // stamp → recorded path unchanged (some other document lives there now).
    func testDeadPathWithMismatchedMetaFileIsNotAdopted() throws {
        let docId = "33333333-4444-5555-6666-777777777777"
        let strangerPath = scratch.appendingPathComponent("stranger.pdf").path
        try makePdf(at: strangerPath, stampedWith: "99999999-8888-7777-6666-555555555555")
        let doc = DocumentInfo(
            kind: .pdf, pdfPath: strangerPath, title: "Doc", pageCount: 1, lastPage: 1, docId: docId)
        try DocumentDataStore.touch(document: doc, force: true)

        let deadPath = scratch.appendingPathComponent("dead.pdf").path
        let entry = recent(pdfPath: deadPath, docId: docId)
        XCTAssertEqual(RecentFilesService.resolvedPath(for: entry), deadPath)
    }

    // docId present but meta.json's last_known_path also gone → recorded path
    // unchanged (never invent a path that doesn't resolve).
    func testResolutionFallsBackWhenMetaPathAlsoMissing() throws {
        let docId = "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee"
        let alsoGone = scratch.appendingPathComponent("also-gone.pdf").path
        let doc = DocumentInfo(
            kind: .pdf, pdfPath: alsoGone, title: "Doc", pageCount: 1, lastPage: 1, docId: docId)
        try DocumentDataStore.touch(document: doc, force: true)
        let deadPath = scratch.appendingPathComponent("dead.pdf").path
        let entry = recent(pdfPath: deadPath, docId: docId)
        XCTAssertEqual(RecentFilesService.resolvedPath(for: entry), deadPath)
    }
}
