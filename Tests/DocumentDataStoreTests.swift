import XCTest
@testable import Vellum

// Coverage for the per-document data store and the scratchpad retarget onto it:
// folder-backed note round-trips, the relative<->scheme image-ref rewrites,
// lazy migration out of the legacy UserDefaults blob, the path-hash -> docId
// rekey, and the delete-means-delete / per-document GC contracts.

@MainActor
final class DocumentDataStoreTests: XCTestCase {
    private var root: URL!
    private var legacyPool: URL!

    override func setUp() async throws {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("vellum-docstore-\(UUID().uuidString)")
        root = base.appendingPathComponent("documents")
        legacyPool = base.appendingPathComponent("legacy-attachments")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: legacyPool, withIntermediateDirectories: true)
        DocumentDataStore.rootDirectoryOverride = root
        ScratchpadAttachmentStore.directoryOverride = legacyPool
        ScratchpadAttachmentStore.activeDirectory = nil
    }

    override func tearDown() async throws {
        DocumentDataStore.rootDirectoryOverride = nil
        ScratchpadAttachmentStore.directoryOverride = nil
        ScratchpadAttachmentStore.activeDirectory = nil
        UserDefaults.standard.removeObject(forKey: ScratchpadPersistence.notesKey)
        // Restore write perms in case a test left a folder read-only, so the
        // scratch tree can be torn down cleanly.
        if let root {
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o755], ofItemAtPath: root.path)
            try? FileManager.default.removeItem(at: root.deletingLastPathComponent())
        }
    }

    private func pdfDocument(path: String, docId: String? = nil) -> DocumentInfo {
        DocumentInfo(kind: .pdf, pdfPath: path, title: "Doc", pageCount: 1, lastPage: 1, docId: docId)
    }

    private func exists(_ url: URL) -> Bool {
        FileManager.default.fileExists(atPath: url.path)
    }

    // MARK: - Note round-trip

    func testScratchpadRoundTripsUnderOverrideRoot() throws {
        let key = "roundtripkey"
        try DocumentDataStore.saveScratchpad(forKey: key, text: "hello world")
        XCTAssertEqual(DocumentDataStore.loadScratchpad(forKey: key), "hello world")
        XCTAssertTrue(exists(DocumentDataStore.scratchpadPath(forKey: key)))
        XCTAssertTrue(DocumentDataStore.scratchpadExists(forKey: key))
    }

    func testPersistenceSaveWritesRelativeAndLoadsScheme() throws {
        let key = "refkey"
        ScratchpadAttachmentStore.activeDirectory = DocumentDataStore.attachmentsDir(forKey: key)
        let id = try XCTUnwrap(
            ScratchpadAttachmentStore.save(data: Data([1, 2, 3]), fileExtension: "jpg"))
        let scheme = "Note ![x](vellum-scratchpad://\(id)) end"

        try ScratchpadPersistence.save(forKey: key, schemeText: scheme)

        // On disk the ref is portable relative Markdown.
        let onDisk = DocumentDataStore.loadScratchpad(forKey: key)
        XCTAssertTrue(onDisk.contains("attachments/\(id).jpg"), "persisted: \(onDisk)")
        XCTAssertFalse(onDisk.contains("vellum-scratchpad://"))
        // Load hands the editor back its scheme form.
        XCTAssertEqual(ScratchpadPersistence.load(forKey: key), scheme)
    }

    // MARK: - Rewrites

    func testRelativeToSchemeMultipleRefs() {
        let a = "aaaaaaaa-1111-2222-3333-444444444444"
        let b = "bbbbbbbb"
        let text = "![p](attachments/\(a).jpg) mid ![q](attachments/\(b).png)"
        let out = ScratchpadPersistence.relativeToScheme(text)
        XCTAssertEqual(
            out,
            "![p](vellum-scratchpad://\(a)) mid ![q](vellum-scratchpad://\(b))")
    }

    func testRelativeToSchemeBareRef() {
        let a = "abcabc"
        XCTAssertEqual(
            ScratchpadPersistence.relativeToScheme("![p](attachments/\(a))"),
            "![p](vellum-scratchpad://\(a))")
    }

    func testSchemeToRelativeUsesResolvedExtension() {
        let a = "deadbeef-0000"
        let out = ScratchpadPersistence.schemeToRelative(
            "![p](vellum-scratchpad://\(a))", extensionFor: { _ in "png" })
        XCTAssertEqual(out, "![p](attachments/\(a).png)")
    }

    func testSchemeToRelativeFallsBackWhenExtensionUnknown() {
        let a = "deadbeef-0001"
        let out = ScratchpadPersistence.schemeToRelative(
            "![p](vellum-scratchpad://\(a))", extensionFor: { _ in nil })
        XCTAssertEqual(out, "![p](attachments/\(a))")
    }

    func testRewritesLeaveNoRefsAndMalformedUntouched() {
        XCTAssertEqual(ScratchpadPersistence.relativeToScheme("plain text"), "plain text")
        XCTAssertEqual(
            ScratchpadPersistence.schemeToRelative("plain text", extensionFor: { _ in "jpg" }),
            "plain text")
        // No id after the scheme: not a valid ref, must be left alone.
        let malformed = "see vellum-scratchpad:// nothing"
        XCTAssertEqual(
            ScratchpadPersistence.schemeToRelative(malformed, extensionFor: { _ in "jpg" }),
            malformed)
    }

    // MARK: - Lazy migration

    private struct BlobEntry: Codable { var key: String; var text: String }

    private func seedLegacyBlob(_ entries: [BlobEntry]) throws {
        let data = try JSONEncoder().encode(entries)
        UserDefaults.standard.set(data, forKey: ScratchpadPersistence.notesKey)
    }

    private func legacyBlobEntries() throws -> [BlobEntry] {
        guard let data = UserDefaults.standard.data(forKey: ScratchpadPersistence.notesKey)
        else { return [] }
        return try JSONDecoder().decode([BlobEntry].self, from: data)
    }

    func testLazyMigrationMovesNoteAndAttachmentAndClearsBlob() throws {
        let path = "/tmp/legacy-\(UUID().uuidString).pdf"
        let id = "cafebabe-1234"
        // A referenced attachment sitting in the global pool.
        try Data([9, 9, 9]).write(to: legacyPool.appendingPathComponent("\(id).png"))
        let note = "Legacy ![img](vellum-scratchpad://\(id)) note"
        try seedLegacyBlob([BlobEntry(key: path, text: note)])

        let store = ScratchpadStore()
        store.loadForDocument(pdfDocument(path: path))

        let key = DocumentIdentity.sha256Hex(path)
        // scratchpad.md written in relative form.
        XCTAssertTrue(DocumentDataStore.scratchpadExists(forKey: key))
        let onDisk = DocumentDataStore.loadScratchpad(forKey: key)
        XCTAssertTrue(onDisk.contains("attachments/\(id).png"), "persisted: \(onDisk)")
        // Editor received the scheme form.
        XCTAssertEqual(store.text, note)
        // Attachment copied into the doc's folder.
        XCTAssertTrue(exists(
            DocumentDataStore.attachmentsDir(forKey: key).appendingPathComponent("\(id).png")))
        // Blob entry removed.
        XCTAssertTrue(try legacyBlobEntries().isEmpty)
        // Blob now empty → the whole shared attachment pool is reclaimed.
        XCTAssertFalse(exists(legacyPool.appendingPathComponent("\(id).png")))
        XCTAssertFalse(exists(legacyPool), "empty legacy blob reclaims the pool dir")
    }

    /// Migration writes scratchpad.md FIRST: if that write fails, nothing is
    /// copied into the doc folder (so per-doc GC can't reap half-migrated
    /// attachments) and the blob entry survives for the next open to retry —
    /// then a retry against a writable folder completes cleanly.
    func testMigrationWritesNoteBeforeCopyingAttachmentsAndRetries() throws {
        let path = "/tmp/mig-order-\(UUID().uuidString).pdf"
        let id = "feedface-9999"
        try Data([5, 5, 5]).write(to: legacyPool.appendingPathComponent("\(id).png"))
        try seedLegacyBlob([BlobEntry(key: path,
                                      text: "Note ![i](vellum-scratchpad://\(id))")])
        let key = DocumentIdentity.sha256Hex(path)
        ScratchpadAttachmentStore.activeDirectory = DocumentDataStore.attachmentsDir(forKey: key)

        // Make the documents root read-only so the scratchpad.md write fails.
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: root.path)

        ScratchpadPersistence.migrateLegacyIfNeeded(document: pdfDocument(path: path), key: key)

        // Note write failed → NOTHING copied into the doc folder, blob retained,
        // and the pool original is untouched (recoverable).
        XCTAssertFalse(DocumentDataStore.scratchpadExists(forKey: key))
        XCTAssertFalse(exists(DocumentDataStore.attachmentsDir(forKey: key)
            .appendingPathComponent("\(id).png")),
            "no attachment may be copied when the note write failed")
        XCTAssertEqual(try legacyBlobEntries().map(\.key), [path], "blob entry kept for retry")
        XCTAssertTrue(exists(legacyPool.appendingPathComponent("\(id).png")))

        // Restore writability and retry — now it completes fully.
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: root.path)
        ScratchpadPersistence.migrateLegacyIfNeeded(document: pdfDocument(path: path), key: key)

        XCTAssertTrue(DocumentDataStore.scratchpadExists(forKey: key))
        XCTAssertTrue(exists(DocumentDataStore.attachmentsDir(forKey: key)
            .appendingPathComponent("\(id).png")), "retry copies the attachment")
        XCTAssertTrue(try legacyBlobEntries().isEmpty, "retry drops the blob entry")
    }

    func testLazyMigrationCopiesSharedAttachmentForSecondNote() throws {
        // Two still-unmigrated notes reference the SAME attachment id in the pool.
        let id = "cafef00d-5678"
        try Data([1, 2, 3]).write(to: legacyPool.appendingPathComponent("\(id).png"))
        let path1 = "/tmp/shared1-\(UUID().uuidString).pdf"
        let path2 = "/tmp/shared2-\(UUID().uuidString).pdf"
        try seedLegacyBlob([
            BlobEntry(key: path1, text: "One ![i](vellum-scratchpad://\(id))"),
            BlobEntry(key: path2, text: "Two ![i](vellum-scratchpad://\(id))"),
        ])

        // Migrate the first note.
        let key1 = DocumentIdentity.sha256Hex(path1)
        ScratchpadAttachmentStore.activeDirectory = DocumentDataStore.attachmentsDir(forKey: key1)
        ScratchpadPersistence.migrateLegacyIfNeeded(document: pdfDocument(path: path1), key: key1)

        // Attachment copied into doc1 AND still present in the shared pool for
        // the second, unmigrated note; the pool is not reclaimed while the blob
        // still holds an entry.
        XCTAssertTrue(exists(
            DocumentDataStore.attachmentsDir(forKey: key1).appendingPathComponent("\(id).png")))
        XCTAssertTrue(exists(legacyPool.appendingPathComponent("\(id).png")),
                      "shared attachment must survive for the unmigrated note")
        XCTAssertEqual(try legacyBlobEntries().map(\.key), [path2])

        // Migrate the second note — it must still find the shared attachment.
        let key2 = DocumentIdentity.sha256Hex(path2)
        ScratchpadAttachmentStore.activeDirectory = DocumentDataStore.attachmentsDir(forKey: key2)
        ScratchpadPersistence.migrateLegacyIfNeeded(document: pdfDocument(path: path2), key: key2)

        XCTAssertTrue(exists(
            DocumentDataStore.attachmentsDir(forKey: key2).appendingPathComponent("\(id).png")),
            "second note recovered the shared attachment (copy, not move)")
        XCTAssertTrue(try legacyBlobEntries().isEmpty)
        // Blob finally empty → pool reclaimed.
        XCTAssertFalse(exists(legacyPool))
    }

    // Non-force touch must NOT create a meta-only folder for a merely-opened doc.
    func testTouchDoesNotCreateMetaOnlyFolder() throws {
        let key = "openonly"
        try DocumentDataStore.touch(document: pdfDocument(path: "/tmp/open.pdf", docId: key))
        XCTAssertFalse(exists(DocumentDataStore.metaPath(forKey: key)),
                       "a bare open must not stamp a synced folder")
        XCTAssertFalse(exists(DocumentDataStore.documentDir(forKey: key)))

        // But once data exists, a bare touch refreshes meta.
        try DocumentDataStore.saveScratchpad(forKey: key, text: "note")
        try DocumentDataStore.touch(document: pdfDocument(path: "/tmp/open.pdf", docId: key))
        XCTAssertTrue(exists(DocumentDataStore.metaPath(forKey: key)))
    }

    func testLazyMigrationSkippedWhenScratchpadExists() throws {
        let path = "/tmp/legacy-\(UUID().uuidString).pdf"
        let key = DocumentIdentity.sha256Hex(path)
        try DocumentDataStore.saveScratchpad(forKey: key, text: "folder note")
        try seedLegacyBlob([BlobEntry(key: path, text: "blob note")])

        let store = ScratchpadStore()
        store.loadForDocument(pdfDocument(path: path))

        // Folder note wins; blob is left intact for its own (unmigrated) doc.
        XCTAssertEqual(store.text, "folder note")
        XCTAssertEqual(try legacyBlobEntries().count, 1)
    }

    // MARK: - Rekey

    func testRekeyMovesFallbackFolderToStampedKey() throws {
        let path = "/tmp/stamp-\(UUID().uuidString).pdf"
        let pathKey = DocumentIdentity.sha256Hex(path)
        let docId = "11111111-2222-3333-4444-555555555555"
        // Seed data in the path-hash fallback folder (as if written pre-stamp).
        try DocumentDataStore.saveScratchpad(forKey: pathKey, text: "carried note")
        let fallbackAttachments = DocumentDataStore.attachmentsDir(forKey: pathKey)
        try FileManager.default.createDirectory(
            at: fallbackAttachments, withIntermediateDirectories: true)
        try Data([1]).write(to: fallbackAttachments.appendingPathComponent("ab.jpg"))

        let store = ScratchpadStore()
        store.loadForDocument(pdfDocument(path: path, docId: docId))

        XCTAssertFalse(exists(DocumentDataStore.documentDir(forKey: pathKey)),
                       "old fallback folder must be gone")
        XCTAssertEqual(DocumentDataStore.loadScratchpad(forKey: docId), "carried note")
        XCTAssertTrue(exists(
            DocumentDataStore.attachmentsDir(forKey: docId).appendingPathComponent("ab.jpg")))
        XCTAssertEqual(store.text, "carried note")
    }

    func testRekeyMergesNewestWinsOnCollision() throws {
        let path = "/tmp/merge-\(UUID().uuidString).pdf"
        let pathKey = DocumentIdentity.sha256Hex(path)
        let docId = "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee"
        // Destination (docId) already has an older note; source (pathKey) newer.
        try DocumentDataStore.saveScratchpad(forKey: docId, text: "old")
        try setModDate(DocumentDataStore.scratchpadPath(forKey: docId), daysAgo: 2)
        try DocumentDataStore.saveScratchpad(forKey: pathKey, text: "new")

        DocumentDataStore.rekey(from: pathKey, to: docId)

        XCTAssertEqual(DocumentDataStore.loadScratchpad(forKey: docId), "new")
        XCTAssertFalse(exists(DocumentDataStore.documentDir(forKey: pathKey)))
    }

    private func setModDate(_ url: URL, daysAgo: Int) throws {
        let date = Calendar.current.date(byAdding: .day, value: -daysAgo, to: .now) ?? .now
        try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: url.path)
    }

    /// A rekey whose file move fails part-way must leave the SOURCE intact rather
    /// than delete it after destroying the destination — both copies survive for
    /// an idempotent retry on the next load.
    func testRekeyPartialFailurePreservesSource() throws {
        let pathKey = "partial-src"
        let docId = "partial-dst"
        // Source holds a NEWER note; destination an older one — newest-wins would
        // try to swap the source in.
        try DocumentDataStore.saveScratchpad(forKey: pathKey, text: "new source")
        try DocumentDataStore.saveScratchpad(forKey: docId, text: "old dest")
        try setModDate(DocumentDataStore.scratchpadPath(forKey: docId), daysAgo: 3)

        // Make the destination folder read-only so the replacement swap fails.
        let dstDir = DocumentDataStore.documentDir(forKey: docId)
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: dstDir.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: dstDir.path) }

        DocumentDataStore.rekey(from: pathKey, to: docId)

        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: dstDir.path)
        // Source survived (write failed → not removed); destination untouched.
        XCTAssertTrue(exists(DocumentDataStore.documentDir(forKey: pathKey)),
                      "a failed merge must not delete the source")
        XCTAssertEqual(DocumentDataStore.loadScratchpad(forKey: pathKey), "new source")
        XCTAssertEqual(DocumentDataStore.loadScratchpad(forKey: docId), "old dest",
                       "destination is preserved when its replacement could not land")
    }

    /// A leftover meta-ONLY folder under the path hash (a pre-round-1 on-open
    /// touch) collapses on rekey: its stale meta is dropped, the destination's
    /// meta wins, and the source folder is removed so it can't surface as a bogus
    /// orphan in the Storage pane.
    func testRekeyCollapsesMetaOnlySourceDestinationMetaWins() throws {
        let pathKey = "metaonly-src"
        let docId = "metaonly-dst"
        // Destination is a real document folder (note + its own meta).
        try DocumentDataStore.saveScratchpad(forKey: docId, text: "real note")
        try DocumentDataStore.touch(
            document: pdfDocument(path: "/tmp/dst.pdf", docId: docId), force: true)
        let dstTitleBefore = DocumentDataStore.loadMeta(forKey: docId)?.title

        // Source is a stale meta-ONLY folder (distinct title).
        let srcDoc = DocumentInfo(kind: .pdf, pdfPath: "/tmp/src.pdf", title: "STALE",
                                  pageCount: 1, lastPage: 1, docId: pathKey)
        try DocumentDataStore.touch(document: srcDoc, force: true)
        XCTAssertFalse(DocumentDataStore.hasDataFiles(forKey: pathKey), "source is meta-only")

        DocumentDataStore.rekey(from: pathKey, to: docId)

        XCTAssertFalse(exists(DocumentDataStore.documentDir(forKey: pathKey)),
                       "meta-only source folder must collapse")
        XCTAssertEqual(DocumentDataStore.loadScratchpad(forKey: docId), "real note")
        XCTAssertEqual(DocumentDataStore.loadMeta(forKey: docId)?.title, dstTitleBefore,
                       "destination meta wins; the stale source meta is dropped")
    }

    // MARK: - Emoji-safe ref rewrite (UTF-16 vs Character offsets)

    /// An emoji BEFORE a scheme ref must not shift the rewrite: NSRegularExpression
    /// reports UTF-16 offsets, so the conversion must use Range(_:in:), not
    /// String.index(offsetBy:) which counts grapheme clusters.
    func testSchemeToRelativeHandlesEmojiBeforeRef() {
        let id = "deadbeef-0002"
        let text = "🎉😀 note ![p](vellum-scratchpad://\(id)) tail"
        let out = ScratchpadPersistence.schemeToRelative(text, extensionFor: { _ in "png" })
        XCTAssertEqual(out, "🎉😀 note ![p](attachments/\(id).png) tail")
        // Round-trips back to the scheme form unchanged.
        XCTAssertEqual(ScratchpadPersistence.relativeToScheme(out), text)
    }

    /// Two refs separated by an emoji both rewrite to the correct spans.
    func testSchemeToRelativeHandlesEmojiBetweenRefs() {
        let a = "aaaa-1111"
        let b = "bbbb-2222"
        let text = "![x](vellum-scratchpad://\(a)) 🚀 ![y](vellum-scratchpad://\(b))"
        let out = ScratchpadPersistence.schemeToRelative(text, extensionFor: { _ in "jpg" })
        XCTAssertEqual(out, "![x](attachments/\(a).jpg) 🚀 ![y](attachments/\(b).jpg)")
    }

    // MARK: - Delete-means-delete

    func testClearingNoteRemovesFileAttachmentAndFolder() throws {
        let key = "deletekey"
        ScratchpadAttachmentStore.activeDirectory = DocumentDataStore.attachmentsDir(forKey: key)
        let id = try XCTUnwrap(
            ScratchpadAttachmentStore.save(data: Data([7]), fileExtension: "jpg"))
        try ScratchpadPersistence.save(
            forKey: key, schemeText: "note ![x](vellum-scratchpad://\(id))")
        XCTAssertTrue(DocumentDataStore.scratchpadExists(forKey: key))

        // Clearing the note deletes everything for the document.
        try ScratchpadPersistence.save(forKey: key, schemeText: "")

        XCTAssertFalse(DocumentDataStore.scratchpadExists(forKey: key))
        XCTAssertNil(ScratchpadAttachmentStore.fileURL(for: id))
        XCTAssertFalse(exists(DocumentDataStore.documentDir(forKey: key)),
                       "empty document folder must be removed")
    }

    func testFolderKeptWhenMetaButPrunedWhenNoData() throws {
        let key = "metakey"
        // force: a bare (non-force) touch no longer creates a meta-only folder;
        // this test needs the meta stamp present to prove prune removes it.
        try DocumentDataStore.touch(document: pdfDocument(path: "/tmp/meta.pdf", docId: key), force: true)
        XCTAssertTrue(exists(DocumentDataStore.metaPath(forKey: key)))
        // meta.json alone is not data.
        XCTAssertFalse(DocumentDataStore.hasDataFiles(forKey: key))
        DocumentDataStore.pruneEmptyDocumentDir(forKey: key)
        XCTAssertFalse(exists(DocumentDataStore.documentDir(forKey: key)))
    }

    // MARK: - Per-document GC isolation

    func testGCDoesNotTouchAnotherDocumentsAttachments() throws {
        let keyA = "docA"
        let keyB = "docB"
        let dirA = DocumentDataStore.attachmentsDir(forKey: keyA)
        let dirB = DocumentDataStore.attachmentsDir(forKey: keyB)
        try FileManager.default.createDirectory(at: dirA, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: dirB, withIntermediateDirectories: true)
        try Data([1]).write(to: dirA.appendingPathComponent("aa.jpg"))
        try Data([2]).write(to: dirB.appendingPathComponent("bb.jpg"))

        // GC document A against an empty reference set — deletes A's file only.
        ScratchpadAttachmentStore.collectGarbage(in: dirA, referencedIds: [])

        XCTAssertFalse(exists(dirA.appendingPathComponent("aa.jpg")))
        XCTAssertTrue(exists(dirB.appendingPathComponent("bb.jpg")),
                      "another document's attachment must be untouched")
    }

    // MARK: - F3 #3: read-only session when the note is stuck in iCloud

    /// When a document's note exists only as an unmaterialized iCloud placeholder,
    /// the ScratchpadStore pauses persistence and shows a banner instead of
    /// presenting an editable empty note whose saves would be silently refused —
    /// no write reaches disk and the real-but-evicted copy is untouched.
    func testStuckInICloudNotePausesPersistence() throws {
        let doc = pdfDocument(path: "/tmp/stuck-\(UUID().uuidString).pdf")
        let key = DocumentIdentity.storageKey(for: doc)
        let dir = DocumentDataStore.documentDir(forKey: key)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        // Evicted: only the `.scratchpad.md.icloud` placeholder, no real bytes.
        let placeholder = WebICloud.placeholderURL(for: DocumentDataStore.scratchpadPath(forKey: key))
        try Data("stub".utf8).write(to: placeholder)

        let store = ScratchpadStore()
        store.loadForDocument(doc)
        XCTAssertTrue(store.isPersistencePaused, "an evicted note pauses persistence")
        XCTAssertNotNil(store.dropWarning, "a banner explains why editing is paused")

        // Typing while paused must not schedule or perform any write.
        store.text = "user typed something the sync would swallow"
        store.flush()
        XCTAssertFalse(
            exists(DocumentDataStore.scratchpadPath(forKey: key)),
            "no real note file is written while paused")
        XCTAssertTrue(exists(placeholder), "the evicted placeholder is untouched")

        // Loading a document whose note IS available clears the pause.
        let ok = pdfDocument(path: "/tmp/ok-\(UUID().uuidString).pdf")
        store.loadForDocument(ok)
        XCTAssertFalse(store.isPersistencePaused)
        XCTAssertNil(store.dropWarning)
    }

    // MARK: - F3 #4: Storage-pane delete of an open document's notes

    /// After the Storage pane deletes a document's notes on disk, an open pane's
    /// ScratchpadStore must drop its live text WITHOUT saving — otherwise its
    /// quit-flush would rewrite the just-deleted markdown (resurrection).
    func testDiscardNotesForExternalDeleteDoesNotResurrect() throws {
        let doc = pdfDocument(path: "/tmp/del-\(UUID().uuidString).pdf")
        let key = DocumentIdentity.storageKey(for: doc)

        let store = ScratchpadStore()
        store.loadForDocument(doc)
        store.text = "important note"
        store.flush()  // persist synchronously
        XCTAssertTrue(DocumentDataStore.scratchpadExists(forKey: key))

        // Storage pane deletes it on disk.
        DocumentDataStore.deleteNotes(forKey: key)
        XCTAssertFalse(DocumentDataStore.scratchpadExists(forKey: key))

        // The open pane discards its live note without saving; a later flush must
        // NOT recreate the file.
        store.discardNotesForExternalDelete(matchingKey: key)
        XCTAssertEqual(store.text, "")
        store.flush()
        XCTAssertFalse(
            DocumentDataStore.scratchpadExists(forKey: key),
            "discard-without-save keeps the delete; quit-flush can't resurrect it")

        // A non-matching key is a no-op (doesn't clear an unrelated document).
        store.loadForDocument(doc)
        store.text = "second note"
        store.discardNotesForExternalDelete(matchingKey: "some-other-key")
        XCTAssertEqual(store.text, "second note")
        store.flush()
    }
}
