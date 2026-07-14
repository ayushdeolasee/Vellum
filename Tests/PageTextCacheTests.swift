import XCTest
@testable import Vellum

// Unit tests for the persistent page-text cache (Services/Ai/PageTextCache).
// The actor is pointed at a scratch directory; hash inputs use small synthetic
// Data blobs (identity/validation don't need real PDFs).

@MainActor
final class PageTextCacheTests: XCTestCase {
    private var tempDir: URL!

    override func setUp() async throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("vellum-textcache-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        if let tempDir { try? FileManager.default.removeItem(at: tempDir) }
    }

    // (1) write → lookup round-trip, including empty-string pages and the
    // complete flag.
    func testWriteLookupRoundTripWithEmptyPages() async {
        let cache = PageTextCache(directory: tempDir)
        let path = "/docs/sample.pdf"
        let data = Data("hello world".utf8)
        // lookup always runs before a walk, priming latestHash for write.
        let miss = await cache.lookup(path: path, data: data, title: "Sample")
        XCTAssertNil(miss)

        let pages: [Int: String] = [1: "page one text", 2: "", 3: "third page"]
        await cache.write(path: path, title: "Sample", pageCount: 3, pages: pages, complete: true)

        let restored = await cache.lookup(path: path, data: data, title: "Sample")
        XCTAssertEqual(restored, pages)
        XCTAssertEqual(restored?[2], "", "empty-string (scanned) pages must round-trip")

        let entries = await cache.listEntries()
        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entries[0].pageCount, 3)
        XCTAssertTrue(entries[0].isComplete)
        XCTAssertEqual(entries[0].sourcePath, path)
    }

    // (2) lookup with mutated data (hash mismatch) returns nil and removes the
    // entry (external edit).
    func testLookupHashMismatchRemovesEntry() async {
        let cache = PageTextCache(directory: tempDir)
        let path = "/docs/edited.pdf"
        let original = Data("original".utf8)
        _ = await cache.lookup(path: path, data: original, title: nil)
        await cache.write(path: path, title: nil, pageCount: 1, pages: [1: "text"], complete: true)

        let sameHit = await cache.lookup(path: path, data: original, title: nil)
        XCTAssertNotNil(sameHit, "same bytes hit")

        let mutated = Data("original edited".utf8)
        let mismatch = await cache.lookup(path: path, data: mutated, title: nil)
        XCTAssertNil(mismatch, "edit invalidates")
        let afterMismatch = await cache.listEntries()
        XCTAssertTrue(afterMismatch.isEmpty, "stale entry removed")
        let goneMiss = await cache.lookup(path: path, data: original, title: nil)
        XCTAssertNil(goneMiss, "entry gone: miss")
    }

    // (3) refreshHash before the first flush stamps the refreshed hash into the
    // entry, so a reopen with the new (in-app rewritten) bytes hits.
    func testRefreshHashThenWriteStampsRefreshedHash() async {
        let cache = PageTextCache(directory: tempDir)
        let path = "/docs/doc.pdf"
        let firstBytes = Data("first".utf8)
        _ = await cache.lookup(path: path, data: firstBytes, title: nil) // records first hash

        // In-app write changes the bytes and refreshes the hash BEFORE any flush.
        let newBytes = Data("first-annotated".utf8)
        await cache.refreshHash(path: path, data: newBytes)

        // First flush must stamp the refreshed hash, not the stale first one.
        await cache.write(path: path, title: nil, pageCount: 1, pages: [1: "t"], complete: true)

        let newHit = await cache.lookup(path: path, data: newBytes, title: nil)
        XCTAssertNotNil(newHit, "new bytes hit")
        let staleMiss = await cache.lookup(path: path, data: firstBytes, title: nil)
        XCTAssertNil(staleMiss, "stale bytes miss")
    }

    // (4) corrupt cache-file JSON → lookup returns nil without crashing.
    func testCorruptCacheFileLookupReturnsNil() async throws {
        let cache = PageTextCache(directory: tempDir)
        let path = "/docs/corrupt.pdf"
        let data = Data("bytes".utf8)
        _ = await cache.lookup(path: path, data: data, title: nil)
        await cache.write(path: path, title: nil, pageCount: 1, pages: [1: "text"], complete: true)

        let bodyURL = tempDir.appendingPathComponent("\(PageTextCache.pathKey(path)).json")
        try Data("{ not valid json".utf8).write(to: bodyURL)

        let corruptMiss = await cache.lookup(path: path, data: data, title: nil)
        XCTAssertNil(corruptMiss)
    }

    // (5) evictStale removes only entries older than the cutoff, never excluded
    // paths, and never for a missing source file alone (none of these fake
    // paths exist on disk, yet the fresh + excluded entries survive).
    func testEvictStaleRespectsCutoffAndExclusions() async throws {
        let cache = PageTextCache(directory: tempDir)
        let oldPath = "/docs/old.pdf"
        let freshPath = "/docs/fresh.pdf"
        let excludedPath = "/docs/open.pdf"
        for path in [oldPath, freshPath, excludedPath] {
            _ = await cache.lookup(path: path, data: Data(path.utf8), title: nil)
            await cache.write(path: path, title: nil, pageCount: 1, pages: [1: "t"], complete: true)
        }

        // Backdate old + excluded to the epoch by editing index.json directly.
        let indexURL = tempDir.appendingPathComponent("index.json")
        var index = try JSONDecoder().decode(
            PageTextIndexFile.self, from: Data(contentsOf: indexURL))
        let ancient = ISO8601DateFormatter.recentTimestamp.string(
            from: Date(timeIntervalSince1970: 0))
        index.entries[PageTextCache.pathKey(oldPath)]?.lastOpened = ancient
        index.entries[PageTextCache.pathKey(excludedPath)]?.lastOpened = ancient
        try JSONEncoder().encode(index).write(to: indexURL)

        let cutoff = Date(timeIntervalSince1970: 1_000_000) // after epoch, before now
        await cache.evictStale(olderThan: cutoff, excludingPaths: [excludedPath])

        let survivors = Set(await cache.listEntries().map(\.sourcePath))
        XCTAssertFalse(survivors.contains(oldPath), "old + unexcluded evicted")
        XCTAssertTrue(survivors.contains(freshPath), "fresh kept (newer than cutoff)")
        XCTAssertTrue(survivors.contains(excludedPath), "excluded kept despite being old")
    }
}
