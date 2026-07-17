import XCTest
@testable import Vellum

// Coverage for the Storage-pane v2 data layer (design §8): the per-document
// inventory join (pure function), the store-level delete contracts, the legacy
// blob list/remove round-trips, and the retention-setting -> cutoff mapping.

@MainActor
final class StorageManagementTests: XCTestCase {
    private var base: URL!
    private var root: URL!

    override func setUp() async throws {
        base = FileManager.default.temporaryDirectory
            .appendingPathComponent("vellum-storagemgmt-\(UUID().uuidString)")
        root = base.appendingPathComponent("documents")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        DocumentDataStore.rootDirectoryOverride = root
    }

    override func tearDown() async throws {
        DocumentDataStore.rootDirectoryOverride = nil
        UserDefaults.standard.removeObject(forKey: ScratchpadPersistence.notesKey)
        UserDefaults.standard.removeObject(forKey: AiPersistence.conversationsKey)
        UserDefaults.standard.removeObject(forKey: StorageHousekeeping.retentionMonthsKey)
        if let base { try? FileManager.default.removeItem(at: base) }
    }

    private func exists(_ url: URL) -> Bool {
        FileManager.default.fileExists(atPath: url.path)
    }

    // MARK: - listDocuments sizes

    func testListDocumentsReportsNoteAndChatBytes() throws {
        let key = "sizekey"
        try DocumentDataStore.saveScratchpad(forKey: key, text: "hello notes")  // 11 bytes
        try DocumentDataStore.saveConversationsData(forKey: key, data: Data(count: 40))
        try DocumentDataStore.touch(
            document: DocumentInfo(kind: .pdf, pdfPath: "/tmp/does-not-exist.pdf",
                                   title: "Sized", pageCount: 1, lastPage: 1, docId: key))

        let entries = DocumentDataStore.listDocuments()
        let entry = try XCTUnwrap(entries.first { $0.key == key })
        XCTAssertEqual(entry.notesBytes, 11)
        XCTAssertEqual(entry.conversationBytes, 40)
        XCTAssertEqual(entry.meta?.title, "Sized")
        // Missing PDF source => orphan candidate.
        XCTAssertFalse(entry.sourceExists)
    }

    func testEvictedNotePlaceholderIsCountedAndDeleted() throws {
        let key = "evictedkey"
        let dir = DocumentDataStore.documentDir(forKey: key)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        // A fake iCloud placeholder standing in for an evicted scratchpad.md,
        // recording the real byte size in its plist (as iCloud Drive does).
        let placeholder = WebICloud.placeholderURL(for: DocumentDataStore.scratchpadPath(forKey: key))
        let plist = try PropertyListSerialization.data(
            fromPropertyList: ["NSURLFileSizeKey": 4096], format: .binary, options: 0)
        try plist.write(to: placeholder)
        try DocumentDataStore.touch(
            document: DocumentInfo(kind: .pdf, pdfPath: "/tmp/evicted.pdf", title: "Evicted",
                                   pageCount: 1, lastPage: 1, docId: key),
            force: true)

        // Listing reports the evicted note's real size, so the row stays visible
        // (a 0-byte row would be dropped by StorageInventory.joinRows).
        let entry = try XCTUnwrap(DocumentDataStore.listDocuments().first { $0.key == key })
        XCTAssertEqual(entry.notesBytes, 4096)

        // Delete removes the placeholder — not just a (non-existent) materialized
        // file — so the "deleted" note can't re-materialize on the next sync.
        DocumentDataStore.deleteNotes(forKey: key)
        XCTAssertFalse(exists(placeholder), "evicted placeholder must be deleted")
    }

    func testListDocumentsWebEntryNeverOrphan() throws {
        let key = "webkey"
        try DocumentDataStore.saveConversationsData(forKey: key, data: Data(count: 5))
        try DocumentDataStore.touch(
            document: DocumentInfo(kind: .web, pdfPath: "https://example.com/a",
                                   title: "Web", pageCount: nil, lastPage: nil, docId: key))
        let entry = try XCTUnwrap(DocumentDataStore.listDocuments().first { $0.key == key })
        XCTAssertTrue(entry.sourceExists, "web docs are never orphans")
    }

    // MARK: - Join helper (pure)

    func testJoinUnionsThreeSourcesByKey() {
        let key = "shared"
        let doc = DocumentDataStore.DocumentDataEntry(
            key: key,
            meta: DocumentDataStore.Meta(
                version: 1, kind: "pdf", title: "My Doc",
                lastKnownPath: "/tmp/x.pdf", lastOpened: WebLibrary.rfc3339Now()),
            notesBytes: 100, conversationBytes: 50, sourceExists: true)
        let cache = PageTextCacheEntry(
            pathKey: key, title: "My Doc", sourcePath: "/tmp/x.pdf", sourceExists: true,
            lastOpened: .now, pageCount: 3, isComplete: true, byteSize: 30)

        let rows = StorageInventory.joinRows(
            documents: [doc], cacheEntries: [cache], webEntries: [])
        XCTAssertEqual(rows.count, 1)
        let row = try! XCTUnwrap(rows.first)
        XCTAssertEqual(row.key, key)
        XCTAssertEqual(row.notesBytes, 100)
        XCTAssertEqual(row.conversationBytes, 50)
        XCTAssertEqual(row.cacheBytes, 30)
        XCTAssertEqual(row.archiveBytes, 0)
        XCTAssertEqual(row.totalBytes, 180)
        XCTAssertEqual(row.title, "My Doc")
        XCTAssertEqual(row.kind, .pdf)
        XCTAssertTrue(row.sourceExists)
    }

    func testJoinAdoptsPathHashCacheSiblingIntoDocIdRow() throws {
        // A document that acquired a docId: its notes live under the docId folder,
        // but its text-cache entry still sits under sha256(last_known_path). The
        // join must fold that sibling into the one docId row (not emit two rows)
        // and record its key for the delete actions.
        let docId = "11111111-2222-3333-4444-555555555555"
        let path = "/tmp/stamped.pdf"
        let doc = DocumentDataStore.DocumentDataEntry(
            key: docId,
            meta: DocumentDataStore.Meta(
                version: 1, kind: "pdf", title: "Stamped",
                lastKnownPath: path, lastOpened: WebLibrary.rfc3339Now()),
            notesBytes: 100, conversationBytes: 0, sourceExists: true)
        let siblingKey = PageTextCache.pathKey(path)
        let cache = PageTextCacheEntry(
            pathKey: siblingKey, title: "Stamped", sourcePath: path, sourceExists: true,
            lastOpened: .now, pageCount: 2, isComplete: true, byteSize: 70)

        let rows = StorageInventory.joinRows(
            documents: [doc], cacheEntries: [cache], webEntries: [])
        XCTAssertEqual(rows.count, 1, "one document must show as one row")
        let row = try XCTUnwrap(rows.first)
        XCTAssertEqual(row.key, docId)
        XCTAssertEqual(row.notesBytes, 100)
        XCTAssertEqual(row.cacheBytes, 70, "the path-hash cache sibling's bytes are adopted")
        XCTAssertEqual(row.adoptedKeys, [siblingKey])
        XCTAssertEqual(row.totalBytes, 170)
    }

    func testJoinWebOnlyRowIsWebKind() {
        let web = WebLibrary.SnapshotStorageEntry(
            key: "webonly", url: "https://example.com", title: "Ex",
            saved: false, hasAnnotations: false, lastOpened: .now, byteSize: 500)
        let rows = StorageInventory.joinRows(
            documents: [], cacheEntries: [], webEntries: [web])
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows.first?.kind, .web)
        XCTAssertEqual(rows.first?.archiveBytes, 500)
        XCTAssertTrue(rows.first?.sourceExists ?? false)
    }

    func testJoinDropsZeroByteRows() {
        // A folder with only meta (no notes/chat/cache/archive) is not listed.
        let doc = DocumentDataStore.DocumentDataEntry(
            key: "metaonly", meta: nil, notesBytes: 0, conversationBytes: 0, sourceExists: true)
        XCTAssertTrue(
            StorageInventory.joinRows(documents: [doc], cacheEntries: [], webEntries: []).isEmpty)
    }

    func testJoinSortBySizeDescending() {
        let small = PageTextCacheEntry(
            pathKey: "s", title: nil, sourcePath: "/a", sourceExists: true,
            lastOpened: .now, pageCount: 1, isComplete: true, byteSize: 10)
        let big = PageTextCacheEntry(
            pathKey: "b", title: nil, sourcePath: "/b", sourceExists: true,
            lastOpened: .now, pageCount: 1, isComplete: true, byteSize: 999)
        let rows = StorageInventory.joinRows(
            documents: [], cacheEntries: [small, big], webEntries: [], sort: .size)
        XCTAssertEqual(rows.map(\.key), ["b", "s"])
    }

    // MARK: - Delete contracts (store funcs individually)

    func testDeleteAllRemovesFolderAndCacheEntryIsSeparate() async throws {
        let key = "deletekey"
        try DocumentDataStore.saveScratchpad(forKey: key, text: "notes")
        try DocumentDataStore.saveConversationsData(forKey: key, data: Data(count: 10))
        XCTAssertTrue(exists(DocumentDataStore.documentDir(forKey: key)))

        // A separate text-cache entry under its own actor + scratch dir.
        let cacheDir = base.appendingPathComponent("cache")
        let cache = PageTextCache(directory: cacheDir)
        _ = await cache.lookup(key: key, path: "/tmp/x.pdf", data: Data([1, 2, 3]), title: "Doc")
        await cache.write(
            key: key, path: "/tmp/x.pdf", title: "Doc", pageCount: 1,
            pages: [1: "text"], complete: true)
        var cacheEntries = await cache.listEntries()
        XCTAssertFalse(cacheEntries.isEmpty)

        // deleteAll removes only the folder — the cache entry is the actor's job.
        DocumentDataStore.deleteAll(forKey: key)
        XCTAssertFalse(exists(DocumentDataStore.documentDir(forKey: key)))
        cacheEntries = await cache.listEntries()
        XCTAssertFalse(cacheEntries.isEmpty, "cache entry survives deleteAll")

        // The view layer then drops the cache entry separately.
        await cache.delete(key: key)
        cacheEntries = await cache.listEntries()
        XCTAssertTrue(cacheEntries.isEmpty)
    }

    func testDeleteNotesKeepsConversation() throws {
        let key = "notesonly"
        try DocumentDataStore.saveScratchpad(forKey: key, text: "notes")
        try DocumentDataStore.saveConversationsData(forKey: key, data: Data(count: 10))

        DocumentDataStore.deleteNotes(forKey: key)
        XCTAssertFalse(DocumentDataStore.scratchpadExists(forKey: key))
        XCTAssertTrue(DocumentDataStore.conversationsExist(forKey: key), "chat untouched")
        // Folder survives because chat remains.
        XCTAssertTrue(exists(DocumentDataStore.documentDir(forKey: key)))
    }

    func testDeleteConversationPrunesEmptyFolder() throws {
        let key = "chatonly"
        try DocumentDataStore.saveConversationsData(forKey: key, data: Data(count: 10))
        DocumentDataStore.deleteConversation(forKey: key)
        XCTAssertFalse(DocumentDataStore.conversationsExist(forKey: key))
        XCTAssertFalse(exists(DocumentDataStore.documentDir(forKey: key)),
                       "folder with no remaining data is pruned")
    }

    // MARK: - Legacy blob list/remove

    private struct BlobEntry: Codable { var key: String; var text: String }

    func testScratchpadLegacyListAndRemove() throws {
        let entries = [
            BlobEntry(key: "/tmp/a.pdf", text: "note a"),
            BlobEntry(key: "/tmp/b.pdf", text: "longer note b"),
        ]
        UserDefaults.standard.set(try JSONEncoder().encode(entries), forKey: ScratchpadPersistence.notesKey)

        let listed = ScratchpadPersistence.listLegacyEntries()
        XCTAssertEqual(Set(listed.map(\.key)), ["/tmp/a.pdf", "/tmp/b.pdf"])
        XCTAssertEqual(listed.first { $0.key == "/tmp/a.pdf" }?.bytes, "note a".utf8.count)

        ScratchpadPersistence.removeLegacyEntry(key: "/tmp/a.pdf")
        let after = ScratchpadPersistence.listLegacyEntries()
        XCTAssertEqual(after.map(\.key), ["/tmp/b.pdf"])
    }

    func testAiLegacyListAndRemove() throws {
        // The legacy conversations blob is a JS object: {"<path>":[<messages>]}.
        let blob = """
        {"/tmp/a.pdf":[{"role":"user","content":"hi"}],\
        "/tmp/b.pdf":[{"role":"assistant","content":"hello there"}]}
        """
        UserDefaults.standard.set(blob, forKey: AiPersistence.conversationsKey)

        let listed = AiPersistence.listLegacyEntries()
        XCTAssertEqual(Set(listed.map(\.key)), ["/tmp/a.pdf", "/tmp/b.pdf"])
        XCTAssertTrue((listed.first?.bytes ?? 0) > 0)

        AiPersistence.removeLegacyEntry(key: "/tmp/a.pdf")
        let after = AiPersistence.listLegacyEntries()
        XCTAssertEqual(after.map(\.key), ["/tmp/b.pdf"])
    }

    // MARK: - Retention mapping

    func testRetentionDefaultsToSixMonths() {
        UserDefaults.standard.removeObject(forKey: StorageHousekeeping.retentionMonthsKey)
        XCTAssertEqual(StorageHousekeeping.retentionMonths, 6)
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let expected = Calendar.current.date(byAdding: .month, value: -6, to: now)
        XCTAssertEqual(StorageHousekeeping.evictionCutoff(now: now), expected)
    }

    func testRetentionMonthsAppliesToCutoff() {
        StorageHousekeeping.setRetentionMonths(3)
        XCTAssertEqual(StorageHousekeeping.retentionMonths, 3)
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let expected = Calendar.current.date(byAdding: .month, value: -3, to: now)
        XCTAssertEqual(StorageHousekeeping.evictionCutoff(now: now), expected)
    }

    func testRetentionNeverSkipsEviction() {
        StorageHousekeeping.setRetentionMonths(nil)
        XCTAssertNil(StorageHousekeeping.retentionMonths)
        XCTAssertNil(StorageHousekeeping.evictionCutoff())
    }
}
