import XCTest
@testable import Vellum

// Coverage for the AI-conversation retarget onto DocumentDataStore
// (documents/<storageKey>/conversations.json): folder-backed round-trip incl.
// the per-message usage field, the #48 write-behind cache + coalesced flush,
// empty-save hard-delete, path-hash -> docId rekey, lazy migration out of the
// legacy path-keyed UserDefaults blob, and the message caps. The on-disk store
// is isolated behind DocumentDataStore.rootDirectoryOverride so tests never
// touch a real user's data.
@MainActor
final class AiConversationStoreTests: XCTestCase {
    private var root: URL!

    override func setUp() async throws {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("vellum-aiconv-\(UUID().uuidString)")
        root = base.appendingPathComponent("documents")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        DocumentDataStore.rootDirectoryOverride = root
        UserDefaults.standard.removeObject(forKey: AiPersistence.conversationsKey)
    }

    override func tearDown() async throws {
        // Drain any coalesced flush before the scratch dir is removed so a late
        // detached write can't recreate it.
        await AiPersistence.awaitPendingFlush()
        DocumentDataStore.rootDirectoryOverride = nil
        UserDefaults.standard.removeObject(forKey: AiPersistence.conversationsKey)
        if let root { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }
    }

    /// Unique per test so the static in-memory cache never carries state between
    /// cases (keys derive from the path hash).
    private func pdfDocument(docId: String? = nil) -> DocumentInfo {
        DocumentInfo(
            kind: .pdf, pdfPath: "/tmp/ai-conv-\(UUID().uuidString).pdf",
            title: "Doc", pageCount: 1, lastPage: 1, docId: docId)
    }

    private func fileMessages(forKey key: String) throws -> [AiMessage] {
        let data = try XCTUnwrap(DocumentDataStore.loadConversationsData(forKey: key))
        return try JSONDecoder().decode([AiMessage].self, from: data)
    }

    // MARK: - Round-trip incl. usage

    func testSaveLoadRoundTripIncludingUsageThroughDisk() async throws {
        let doc = pdfDocument()
        let key = DocumentIdentity.storageKey(for: doc)
        var assistant = AiPersistence.makeMessage(role: .assistant, content: "answer")
        assistant.usage = AiUsage(inputTokens: 42, cachedInputTokens: 10, outputTokens: 7, costUSD: 0.0021)
        let user = AiPersistence.makeMessage(role: .user, content: "question")

        AiPersistence.saveConversation(for: doc, messages: [user, assistant])
        await AiPersistence.awaitPendingFlush()

        let onDisk = try fileMessages(forKey: key)
        XCTAssertEqual(onDisk.map(\.content), ["question", "answer"])
        XCTAssertEqual(onDisk.last?.usage, assistant.usage)
        // And loadConversation surfaces the same messages (incl. usage).
        XCTAssertEqual(AiPersistence.loadConversation(for: doc).last?.usage, assistant.usage)
    }

    // MARK: - Write-behind cache

    /// A save is visible to an immediate load via the in-memory cache, before
    /// the coalesced disk flush has run.
    func testSaveIsImmediatelyVisibleBeforeFlush() async {
        let doc = pdfDocument()
        AiPersistence.saveConversation(
            for: doc, messages: [AiPersistence.makeMessage(role: .user, content: "cached")])
        XCTAssertEqual(AiPersistence.loadConversation(for: doc).map(\.content), ["cached"])
        await AiPersistence.awaitPendingFlush()
    }

    /// A cold load (no prior save this process) reads and decodes the folder file.
    func testLoadReadsExistingFileWhenCacheCold() throws {
        let doc = pdfDocument()
        let key = DocumentIdentity.storageKey(for: doc)
        let data = try JSONEncoder().encode(
            [AiPersistence.makeMessage(role: .user, content: "from disk")])
        try DocumentDataStore.saveConversationsData(forKey: key, data: data)
        XCTAssertEqual(AiPersistence.loadConversation(for: doc).map(\.content), ["from disk"])
    }

    /// Two quick saves coalesce into one flush whose final on-disk snapshot is
    /// the SECOND save.
    func testCoalescedFlushLandsLastSnapshot() async throws {
        let doc = pdfDocument()
        let key = DocumentIdentity.storageKey(for: doc)
        AiPersistence.saveConversation(
            for: doc, messages: [AiPersistence.makeMessage(role: .user, content: "first")])
        AiPersistence.saveConversation(
            for: doc, messages: [AiPersistence.makeMessage(role: .user, content: "second")])
        await AiPersistence.awaitPendingFlush()
        XCTAssertEqual(try fileMessages(forKey: key).map(\.content), ["second"])
    }

    // MARK: - Delete semantics

    /// Saving an empty array deletes conversations.json and prunes the now-empty
    /// document folder (clearConversation's hard-delete contract, §8).
    func testEmptySaveDeletesFileAndPrunesFolder() async throws {
        let doc = pdfDocument()
        let key = DocumentIdentity.storageKey(for: doc)
        AiPersistence.saveConversation(
            for: doc, messages: [AiPersistence.makeMessage(role: .user, content: "hi")])
        await AiPersistence.awaitPendingFlush()
        XCTAssertTrue(DocumentDataStore.conversationsExist(forKey: key))

        AiPersistence.saveConversation(for: doc, messages: [])
        await AiPersistence.awaitPendingFlush()

        XCTAssertFalse(DocumentDataStore.conversationsExist(forKey: key))
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: DocumentDataStore.documentDir(forKey: key).path),
            "empty document folder must be removed")
        XCTAssertTrue(AiPersistence.loadConversation(for: doc).isEmpty)
    }

    // MARK: - Failed flush must not lose data

    /// A flush whose disk write fails must NOT mark the conversation clean: the
    /// key stays dirty (data retained in the cache), and a later flush against a
    /// writable location persists it. Regression for "disk-full flush silently
    /// succeeds and the data is lost at quit."
    func testFailedFlushKeepsDataDirtyThenRetriesWhenWritable() async throws {
        let doc = pdfDocument()
        let key = DocumentIdentity.storageKey(for: doc)

        // Point the store at a READ-ONLY documents root so the flush write fails.
        let roRoot = root.deletingLastPathComponent().appendingPathComponent("ro-docs")
        try FileManager.default.createDirectory(at: roRoot, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: roRoot.path)
        DocumentDataStore.rootDirectoryOverride = roRoot

        AiPersistence.saveConversation(
            for: doc, messages: [AiPersistence.makeMessage(role: .user, content: "keepme")])
        await AiPersistence.awaitPendingFlush()

        // The write failed: no file on disk, but the data is NOT lost — the cache
        // still surfaces it (a later flush will retry).
        XCTAssertFalse(DocumentDataStore.conversationsExist(forKey: key),
                       "read-only root: nothing should have landed")
        XCTAssertEqual(AiPersistence.loadConversation(for: doc).map(\.content), ["keepme"],
                       "failed flush must retain the conversation, not drop it")

        // Make the store writable again and trigger another flush; the data lands.
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: roRoot.path)
        DocumentDataStore.rootDirectoryOverride = root
        AiPersistence.saveConversation(
            for: doc, messages: [AiPersistence.makeMessage(role: .user, content: "keepme")])
        await AiPersistence.awaitPendingFlush()

        XCTAssertTrue(DocumentDataStore.conversationsExist(forKey: key))
        XCTAssertEqual(try fileMessages(forKey: key).map(\.content), ["keepme"],
                       "retry against a writable root persists the retained data")
    }

    // MARK: - Cache invalidation on import merge

    /// After a `.vellum` import merges a fresh conversation into the folder file,
    /// `invalidateCachedConversation` drops the in-memory entry AND clears its
    /// pending-write flag, so a stale live save can't be flushed back over the
    /// merge and the next load re-reads disk (STAGE F2 #4).
    func testInvalidateCachedConversationDropsMemoryAndDirtyState() async throws {
        let doc = pdfDocument()
        let key = DocumentIdentity.storageKey(for: doc)

        // A live save: cached in memory and marked dirty (flush pending).
        AiPersistence.saveConversation(
            for: doc, messages: [AiPersistence.makeMessage(role: .user, content: "stale live")])

        // The import writes a DIFFERENT merged conversation to the folder file.
        let merged = try JSONEncoder().encode(
            [AiPersistence.makeMessage(role: .user, content: "merged from import")])
        try DocumentDataStore.saveConversationsData(forKey: key, data: merged)

        // Invalidate: memory + dirty flag gone, so the pending flush has nothing
        // to write for this key and the on-disk merge survives.
        AiPersistence.invalidateCachedConversation(forKey: key)
        await AiPersistence.awaitPendingFlush()
        XCTAssertEqual(try fileMessages(forKey: key).map(\.content), ["merged from import"],
                       "the dropped dirty state must not clobber the imported merge")

        // The next load re-reads the merged file rather than the dropped cache.
        XCTAssertEqual(AiPersistence.loadConversation(for: doc).map(\.content),
                       ["merged from import"])
    }

    // MARK: - Caps

    func testCapsEnforceMessageCountAndCharacters() {
        let doc = pdfDocument()
        var messages = (1...(AiPersistence.maxMessagesPerDocument + 30)).map {
            AiPersistence.makeMessage(role: .user, content: "m\($0)")
        }
        let long = String(repeating: "x", count: AiPersistence.maxMessageCharacters + 500)
        messages.append(AiPersistence.makeMessage(role: .assistant, content: long))

        AiPersistence.saveConversation(for: doc, messages: messages)
        let loaded = AiPersistence.loadConversation(for: doc)

        XCTAssertEqual(loaded.count, AiPersistence.maxMessagesPerDocument)
        XCTAssertFalse(loaded.contains { $0.content == "m1" }, "oldest must roll off")
        let last = loaded.last?.content ?? ""
        XCTAssertTrue(last.hasPrefix(String(repeating: "x", count: AiPersistence.maxMessageCharacters)))
        XCTAssertTrue(last.hasSuffix("[truncated]"), "over-long content must be truncated")
    }

    // MARK: - Rekey (path-hash folder -> stamped docId)

    /// A PDF that acquired its /VellumDocId in a prior session finds its
    /// conversation in the old path-hash folder; loading rekeys the whole folder
    /// over so conversations.json rides along.
    func testLoadRekeysConversationFromPathHashFolder() throws {
        let doc = pdfDocument(docId: "11111111-2222-3333-4444-555555555555")
        let docId = try XCTUnwrap(doc.docId)
        let pathKey = DocumentIdentity.sha256Hex(doc.pdfPath)
        XCTAssertNotEqual(pathKey, docId)

        let data = try JSONEncoder().encode(
            [AiPersistence.makeMessage(role: .user, content: "carried chat")])
        try DocumentDataStore.saveConversationsData(forKey: pathKey, data: data)

        let loaded = AiPersistence.loadConversation(for: doc)
        XCTAssertEqual(loaded.map(\.content), ["carried chat"])
        XCTAssertTrue(DocumentDataStore.conversationsExist(forKey: docId))
        XCTAssertFalse(DocumentDataStore.conversationsExist(forKey: pathKey),
                       "old fallback folder must be gone")
    }

    // MARK: - Lazy migration from the legacy blob

    func testLegacyBlobMigrationCreatesFileRemovesEntryKeepsOthers() throws {
        let docA = pdfDocument()
        let docB = pdfDocument()
        let keyA = DocumentIdentity.storageKey(for: docA)
        try seedLegacyBlob([
            docA.pdfPath: [AiPersistence.makeMessage(role: .user, content: "A question")],
            docB.pdfPath: [AiPersistence.makeMessage(role: .user, content: "B question")],
        ])

        let loaded = AiPersistence.loadConversation(for: docA)

        XCTAssertEqual(loaded.map(\.content), ["A question"])
        XCTAssertTrue(DocumentDataStore.conversationsExist(forKey: keyA))
        // A's entry is removed from the blob; B's stays for its own later open.
        let keys = blobKeys()
        XCTAssertFalse(keys.contains(docA.pdfPath))
        XCTAssertTrue(keys.contains(docB.pdfPath))
    }

    /// Migration is skipped when a folder file already exists — the folder wins.
    func testMigrationSkippedWhenConversationsFileExists() throws {
        let doc = pdfDocument()
        let key = DocumentIdentity.storageKey(for: doc)
        try DocumentDataStore.saveConversationsData(
            forKey: key,
            data: try JSONEncoder().encode(
                [AiPersistence.makeMessage(role: .assistant, content: "folder wins")]))
        try seedLegacyBlob([doc.pdfPath: [AiPersistence.makeMessage(role: .user, content: "blob loses")]])

        XCTAssertEqual(AiPersistence.loadConversation(for: doc).map(\.content), ["folder wins"])
        // Blob left intact (its entry was never migrated).
        XCTAssertTrue(blobKeys().contains(doc.pdfPath))
    }

    // MARK: - Legacy blob helpers (hand-rolled object format)

    private func seedLegacyBlob(_ byPath: [String: [AiMessage]]) throws {
        var object: [String: Any] = [:]
        for (path, messages) in byPath {
            object[path] = try messages.map { message -> [String: Any] in
                let data = try JSONEncoder().encode(message)
                return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
            }
        }
        let data = try JSONSerialization.data(withJSONObject: object)
        UserDefaults.standard.set(
            String(decoding: data, as: UTF8.self), forKey: AiPersistence.conversationsKey)
    }

    private func blobKeys() -> Set<String> {
        guard let raw = UserDefaults.standard.string(forKey: AiPersistence.conversationsKey),
              let data = raw.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return [] }
        return Set(object.keys)
    }

    // MARK: - F3 #3: an evicted conversation is not cached as authoritative

    /// A conversation present only as an unmaterialized iCloud placeholder reads
    /// as empty — but that empty must NOT be cached as authoritative, or a later
    /// load (after the download lands) would keep serving a phantom empty chat.
    func testEvictedConversationIsNotCachedAsAuthoritative() throws {
        let doc = pdfDocument()
        let key = DocumentIdentity.storageKey(for: doc)
        let dir = DocumentDataStore.documentDir(forKey: key)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let placeholder = WebICloud.placeholderURL(for: DocumentDataStore.conversationsPath(forKey: key))
        try Data("stub".utf8).write(to: placeholder)

        // Degrades to empty, without caching that empty.
        XCTAssertTrue(AiPersistence.loadConversation(for: doc).isEmpty)

        // The real bytes now materialize.
        let msgs = [AiPersistence.makeMessage(role: .user, content: "recovered")]
        try FileManager.default.removeItem(at: placeholder)
        try JSONEncoder().encode(msgs).write(to: DocumentDataStore.conversationsPath(forKey: key))

        // The next load re-reads disk (the empty wasn't cached) and finds the chat.
        XCTAssertEqual(AiPersistence.loadConversation(for: doc).map(\.content), ["recovered"])
    }
}
