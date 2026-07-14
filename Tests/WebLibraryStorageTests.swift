import XCTest
@testable import Vellum

// Unit tests for explicit-save semantics and snapshot-storage management
// (issue #29 Storage PR 0): annotating promotes a page to saved, TTL eviction
// only ever touches derived artifacts of never-kept pages, and the Storage-tab
// listing reports real artifact sizes. The whole web store is pointed at a
// scratch directory via `WebLibrary.storeDirOverride` (same seam pattern as
// `ScratchpadAttachmentStore.directoryOverride`).

@MainActor
final class WebLibraryStorageTests: XCTestCase {
    private var tempDir: URL!

    override func setUp() async throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("vellum-weblibrary-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        WebLibrary.storeDirOverride = tempDir
    }

    override func tearDown() async throws {
        WebLibrary.storeDirOverride = nil
        if let tempDir { try? FileManager.default.removeItem(at: tempDir) }
    }

    // MARK: - Helpers

    /// Timestamp `months` months in the past, in the record writer's format.
    private func timestamp(monthsAgo months: Int) -> String {
        let date = Calendar.current.date(byAdding: .month, value: -months, to: .now) ?? .now
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }

    @discardableResult
    private func makeRecord(
        url: String, saved: Bool, openedMonthsAgo: Int?, annotated: Bool = false
    ) throws -> String {
        let key = WebLibrary.pageKey(url)
        var record = WebPageRecord(url: url)
        record.saved = saved
        record.savedAt = saved ? timestamp(monthsAgo: openedMonthsAgo ?? 0) : nil
        record.openedAt = openedMonthsAgo.map { timestamp(monthsAgo: $0) }
        if annotated {
            record.annotations = [Annotation(
                id: "a1", type: .highlight, pageNumber: 1, color: "#fde68a",
                content: "kept", positionData: nil,
                createdAt: timestamp(monthsAgo: 0), updatedAt: timestamp(monthsAgo: 0))]
        }
        try WebLibrary.saveRecord(record, at: WebLibrary.recordPath(forKey: key))
        return key
    }

    /// Write all three artifact kinds for a key: plain snapshot, managed
    /// archive, and an installed archive dir with one asset.
    private func makeArtifacts(forKey key: String, fill: Int = 100) throws {
        try Data(repeating: 0x61, count: fill)
            .write(to: WebLibrary.snapshotPath(forKey: key))
        try Data(repeating: 0x62, count: fill)
            .write(to: WebLibrary.managedArchivePath(forKey: key))
        let dir = WebLibrary.archiveDir(forKey: key)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data(repeating: 0x63, count: fill)
            .write(to: dir.appendingPathComponent("snapshot.html"))
    }

    private func hasArtifacts(forKey key: String) -> Bool {
        WebLibrary.hasLocalSnapshot(forKey: key)
    }

    private func cutoff(monthsAgo months: Int) -> Date {
        Calendar.current.date(byAdding: .month, value: -months, to: .now) ?? .now
    }

    // MARK: - Explicit save

    // Opening no longer saves; annotating does — and it must set savedAt so the
    // library sort has a timestamp.
    func testCreateAnnotationPromotesPageToSaved() async throws {
        let url = "https://example.com/article"
        let key = WebLibrary.pageKey(url)
        let recordPath = WebLibrary.recordPath(forKey: key)
        try WebLibrary.saveRecord(WebPageRecord(url: url), at: recordPath)
        XCTAssertFalse(WebLibrary.loadRecord(at: recordPath)?.saved ?? true)

        let io = WebDocumentIO(url: url, key: key)
        _ = try await io.createAnnotation(
            CreateAnnotationInput(type: .highlight, pageNumber: 1, content: "hi"),
            storedHighlightColor: "#fde68a")

        let record = WebLibrary.loadRecord(at: recordPath)
        XCTAssertEqual(record?.saved, true, "annotating must promote the page to saved")
        XCTAssertNotNil(record?.savedAt)
        XCTAssertEqual(record?.annotations.count, 1)
    }

    func testCreateAnnotationKeepsExistingSavedAt() async throws {
        let url = "https://example.com/already-saved"
        let key = try makeRecord(url: url, saved: true, openedMonthsAgo: 2)
        let recordPath = WebLibrary.recordPath(forKey: key)
        let originalSavedAt = WebLibrary.loadRecord(at: recordPath)?.savedAt

        let io = WebDocumentIO(url: url, key: key)
        _ = try await io.createAnnotation(
            CreateAnnotationInput(type: .note, pageNumber: 1, content: "note"),
            storedHighlightColor: "#fde68a")

        XCTAssertEqual(WebLibrary.loadRecord(at: recordPath)?.savedAt, originalSavedAt)
    }

    // MARK: - TTL eviction

    func testEvictionRemovesOnlyStaleUnsavedArtifacts() throws {
        let staleUnsaved = try makeRecord(
            url: "https://example.com/stale", saved: false, openedMonthsAgo: 8)
        let staleSaved = try makeRecord(
            url: "https://example.com/saved", saved: true, openedMonthsAgo: 8)
        let staleAnnotated = try makeRecord(
            url: "https://example.com/annotated", saved: false, openedMonthsAgo: 8,
            annotated: true)
        let freshUnsaved = try makeRecord(
            url: "https://example.com/fresh", saved: false, openedMonthsAgo: 1)
        let staleOpenTab = try makeRecord(
            url: "https://example.com/open-tab", saved: false, openedMonthsAgo: 8)
        let noTimestamp = try makeRecord(
            url: "https://example.com/no-stamp", saved: false, openedMonthsAgo: nil)
        for key in [staleUnsaved, staleSaved, staleAnnotated, freshUnsaved, staleOpenTab, noTimestamp] {
            try makeArtifacts(forKey: key)
        }

        WebLibrary.evictStaleUnsavedSnapshots(
            olderThan: cutoff(monthsAgo: 6),
            excludingUrls: ["https://example.com/open-tab"])

        XCTAssertFalse(hasArtifacts(forKey: staleUnsaved), "stale + never kept → evicted")
        XCTAssertTrue(hasArtifacts(forKey: staleSaved), "saved pages are never evicted")
        XCTAssertTrue(hasArtifacts(forKey: staleAnnotated), "annotated pages are never evicted")
        XCTAssertTrue(hasArtifacts(forKey: freshUnsaved), "recently opened pages survive")
        XCTAssertTrue(hasArtifacts(forKey: staleOpenTab), "open tabs are excluded")
        XCTAssertTrue(hasArtifacts(forKey: noTimestamp), "no parseable timestamp → never evict")

        // Eviction only touches derived artifacts — the record (reading state)
        // must survive for every page, including the evicted one.
        XCTAssertNotNil(WebLibrary.loadRecord(at: WebLibrary.recordPath(forKey: staleUnsaved)))
    }

    // MARK: - Storage listing

    func testListSnapshotStorageReportsArtifactSizesLargestFirst() throws {
        let small = try makeRecord(
            url: "https://example.com/small", saved: false, openedMonthsAgo: 1)
        try makeArtifacts(forKey: small, fill: 10)
        let big = try makeRecord(
            url: "https://example.com/big", saved: true, openedMonthsAgo: 1)
        try makeArtifacts(forKey: big, fill: 1000)
        // Record with no artifacts must not appear at all.
        try makeRecord(url: "https://example.com/bare", saved: false, openedMonthsAgo: 1)

        let entries = WebLibrary.listSnapshotStorage()
        XCTAssertEqual(entries.map(\.key), [big, small], "sorted by size descending")
        // Three artifacts of `fill` bytes each (snapshot + archive + dir asset).
        XCTAssertEqual(entries[0].byteSize, 3000)
        XCTAssertEqual(entries[1].byteSize, 30)
        XCTAssertEqual(entries[0].saved, true)
        XCTAssertEqual(entries[1].saved, false)
        XCTAssertNotNil(entries[0].lastOpened)
    }

    func testRemoveAllSnapshotArtifactsKeepsRecords() throws {
        let a = try makeRecord(url: "https://example.com/a", saved: true, openedMonthsAgo: 1)
        let b = try makeRecord(url: "https://example.com/b", saved: false, openedMonthsAgo: 1)
        try makeArtifacts(forKey: a)
        try makeArtifacts(forKey: b)

        WebLibrary.removeAllSnapshotArtifacts()

        XCTAssertFalse(hasArtifacts(forKey: a))
        XCTAssertFalse(hasArtifacts(forKey: b))
        XCTAssertTrue(WebLibrary.listSnapshotStorage().isEmpty)
        XCTAssertNotNil(WebLibrary.loadRecord(at: WebLibrary.recordPath(forKey: a)))
        XCTAssertNotNil(WebLibrary.loadRecord(at: WebLibrary.recordPath(forKey: b)))
        // The saved flag is untouched — only bytes were removed.
        XCTAssertEqual(WebLibrary.loadRecord(at: WebLibrary.recordPath(forKey: a))?.saved, true)
    }

    // MARK: - Timestamp parsing

    func testParseRfc3339AcceptsWriterAndLegacyFormats() {
        // Our own writer (6-digit fraction, +00:00 offset).
        XCTAssertNotNil(WebLibrary.parseRfc3339("2026-07-14T10:20:30.123456+00:00"))
        // ISO8601 with milliseconds and Z.
        XCTAssertNotNil(WebLibrary.parseRfc3339("2026-07-14T10:20:30.123Z"))
        // ISO8601 without fraction.
        XCTAssertNotNil(WebLibrary.parseRfc3339("2026-07-14T10:20:30Z"))
        XCTAssertNil(WebLibrary.parseRfc3339(nil))
        XCTAssertNil(WebLibrary.parseRfc3339(""))
        XCTAssertNil(WebLibrary.parseRfc3339("not a date"))
    }
}
