import XCTest
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
    // exist → re-resolves to the moved location.
    func testResolvesMovedPdfViaMeta() throws {
        let docId = "11111111-2222-3333-4444-555555555555"
        // The file "moved" here — write a real file at the new location.
        let movedPath = scratch.appendingPathComponent("moved.pdf").path
        try Data([0x25, 0x50, 0x44, 0x46]).write(to: URL(fileURLWithPath: movedPath))
        // meta.json (keyed by docId) records the current known path.
        let doc = DocumentInfo(
            kind: .pdf, pdfPath: movedPath, title: "Doc", pageCount: 1, lastPage: 1, docId: docId)
        try DocumentDataStore.touch(document: doc)

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

    // docId present but meta.json's last_known_path also gone → recorded path
    // unchanged (never invent a path that doesn't resolve).
    func testResolutionFallsBackWhenMetaPathAlsoMissing() throws {
        let docId = "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee"
        let alsoGone = scratch.appendingPathComponent("also-gone.pdf").path
        let doc = DocumentInfo(
            kind: .pdf, pdfPath: alsoGone, title: "Doc", pageCount: 1, lastPage: 1, docId: docId)
        try DocumentDataStore.touch(document: doc)
        let deadPath = scratch.appendingPathComponent("dead.pdf").path
        let entry = recent(pdfPath: deadPath, docId: docId)
        XCTAssertEqual(RecentFilesService.resolvedPath(for: entry), deadPath)
    }
}
