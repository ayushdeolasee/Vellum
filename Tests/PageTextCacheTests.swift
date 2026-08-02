import XCTest
@testable import Vellum

// Unit tests for the persistent page-text cache (Services/Ai/PageTextCache).
// The actor is pointed at a scratch directory; hash inputs use small synthetic
// Data blobs (identity/validation don't need real PDFs). Entries are keyed by
// the caller's session-stable storage key — these tests pass an explicit key
// (the legacy path hash unless a docId re-key is being exercised).

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
        let key = PageTextCache.pathKey(path)
        let data = Data("hello world".utf8)
        // lookup always runs before a walk, priming latestHash for write.
        let miss = await cache.lookup(key: key, path: path, data: data, title: "Sample")
        XCTAssertNil(miss)

        let pages: [Int: String] = [1: "page one text", 2: "", 3: "third page"]
        await cache.write(
            key: key, path: path, title: "Sample", pageCount: 3, pages: pages, complete: true)

        let restored = await cache.lookup(key: key, path: path, data: data, title: "Sample")
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
        let key = PageTextCache.pathKey(path)
        let original = Data("original".utf8)
        _ = await cache.lookup(key: key, path: path, data: original, title: nil)
        await cache.write(
            key: key, path: path, title: nil, pageCount: 1, pages: [1: "text"], complete: true)

        let sameHit = await cache.lookup(key: key, path: path, data: original, title: nil)
        XCTAssertNotNil(sameHit, "same bytes hit")

        let mutated = Data("original edited".utf8)
        let mismatch = await cache.lookup(key: key, path: path, data: mutated, title: nil)
        XCTAssertNil(mismatch, "edit invalidates")
        let afterMismatch = await cache.listEntries()
        XCTAssertTrue(afterMismatch.isEmpty, "stale entry removed")
        let goneMiss = await cache.lookup(key: key, path: path, data: original, title: nil)
        XCTAssertNil(goneMiss, "entry gone: miss")
    }

    // (3) refreshHash under the explicit key before the first flush stamps the
    // refreshed hash into the entry, so a reopen with the new (in-app rewritten)
    // bytes hits.
    func testRefreshHashThenWriteStampsRefreshedHash() async {
        let cache = PageTextCache(directory: tempDir)
        let path = "/docs/doc.pdf"
        let key = PageTextCache.pathKey(path)
        let firstBytes = Data("first".utf8)
        _ = await cache.lookup(key: key, path: path, data: firstBytes, title: nil) // records first hash

        // In-app write changes the bytes and refreshes the hash BEFORE any flush.
        let newBytes = Data("first-annotated".utf8)
        await cache.refreshHash(key: key, data: newBytes)

        // First flush must stamp the refreshed hash, not the stale first one.
        await cache.write(
            key: key, path: path, title: nil, pageCount: 1, pages: [1: "t"], complete: true)

        let newHit = await cache.lookup(key: key, path: path, data: newBytes, title: nil)
        XCTAssertNotNil(newHit, "new bytes hit")
        let staleMiss = await cache.lookup(key: key, path: path, data: firstBytes, title: nil)
        XCTAssertNil(staleMiss, "stale bytes miss")
    }

    // (4) corrupt cache-file JSON → lookup returns nil without crashing.
    func testCorruptCacheFileLookupReturnsNil() async throws {
        let cache = PageTextCache(directory: tempDir)
        let path = "/docs/corrupt.pdf"
        let key = PageTextCache.pathKey(path)
        let data = Data("bytes".utf8)
        _ = await cache.lookup(key: key, path: path, data: data, title: nil)
        await cache.write(
            key: key, path: path, title: nil, pageCount: 1, pages: [1: "text"], complete: true)

        let bodyURL = tempDir.appendingPathComponent("\(key).json")
        try Data("{ not valid json".utf8).write(to: bodyURL)

        let corruptMiss = await cache.lookup(key: key, path: path, data: data, title: nil)
        XCTAssertNil(corruptMiss)
    }

    // (5) evictStale removes only entries older than the cutoff, never excluded
    // KEYS, and never for a missing source file alone (none of these fake paths
    // exist on disk, yet the fresh + excluded entries survive).
    func testEvictStaleRespectsCutoffAndKeyExclusions() async throws {
        let cache = PageTextCache(directory: tempDir)
        let oldPath = "/docs/old.pdf"
        let freshPath = "/docs/fresh.pdf"
        let excludedPath = "/docs/open.pdf"
        for path in [oldPath, freshPath, excludedPath] {
            let key = PageTextCache.pathKey(path)
            _ = await cache.lookup(key: key, path: path, data: Data(path.utf8), title: nil)
            await cache.write(
                key: key, path: path, title: nil, pageCount: 1, pages: [1: "t"], complete: true)
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
        await cache.evictStale(
            olderThan: cutoff, excludingKeys: [PageTextCache.pathKey(excludedPath)])

        let survivors = Set(await cache.listEntries().map(\.sourcePath))
        XCTAssertFalse(survivors.contains(oldPath), "old + unexcluded evicted")
        XCTAssertTrue(survivors.contains(freshPath), "fresh kept (newer than cutoff)")
        XCTAssertTrue(survivors.contains(excludedPath), "excluded-by-key kept despite being old")
    }

    // (6) A pre-rekey session stored the document under sha256(path). Reopening
    // under a newly-stamped docId key must ADOPT that entry — rename the cache
    // body, re-key the index row — not rebuild from scratch.
    func testLookupMigratesLegacyPathKeyEntry() async {
        let cache = PageTextCache(directory: tempDir)
        let path = "/docs/renamed.pdf"
        let data = Data("stable-bytes".utf8)
        let legacyKey = PageTextCache.pathKey(path)
        let docKey = "11111111-2222-3333-4444-555555555555"

        // Seed an entry under the legacy path-hash key.
        _ = await cache.lookup(key: legacyKey, path: path, data: data, title: "Doc")
        await cache.write(
            key: legacyKey, path: path, title: "Doc", pageCount: 1, pages: [1: "hello"],
            complete: true)
        let legacyFile = tempDir.appendingPathComponent("\(legacyKey).json")
        XCTAssertTrue(FileManager.default.fileExists(atPath: legacyFile.path))

        // Reopen under the stable docId key: lookup adopts + re-keys the entry.
        let migrated = await cache.lookup(key: docKey, path: path, data: data, title: "Doc")
        XCTAssertEqual(migrated, [1: "hello"], "legacy pages carried over under the new key")

        // Body renamed to the new key; legacy file gone; index holds one re-keyed row.
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: legacyFile.path), "legacy body renamed away")
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: tempDir.appendingPathComponent("\(docKey).json").path))
        let entries = await cache.listEntries()
        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entries[0].pathKey, docKey, "entry now keyed by docId")
        XCTAssertEqual(entries[0].sourcePath, path)
    }

    // (7) lookup updates the index entry's display path when the same key is
    // seen at a new location (renamed/moved but same docId).
    func testLookupUpdatesPathWhenSeenAtNewLocation() async {
        let cache = PageTextCache(directory: tempDir)
        let docKey = "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee"
        let oldPath = "/docs/before.pdf"
        let newPath = "/docs/after.pdf"
        let data = Data("same-bytes".utf8)

        _ = await cache.lookup(key: docKey, path: oldPath, data: data, title: "Doc")
        await cache.write(
            key: docKey, path: oldPath, title: "Doc", pageCount: 1, pages: [1: "x"], complete: true)

        _ = await cache.lookup(key: docKey, path: newPath, data: data, title: "Doc")
        let entries = await cache.listEntries()
        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entries[0].sourcePath, newPath, "display path follows the moved file")
    }
}
