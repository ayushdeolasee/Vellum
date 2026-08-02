import XCTest
@testable import Vellum

// Coverage for the per-document data store: folder-backed note round-trips, the
// path-hash -> docId rekey, and the delete-means-delete / prune contracts.
//
// iPad port scope (parity-129 packet 1 §4 + packet 9 §1.4). Packet 1 lands the
// DocumentDataStore-only half of main's suite; the rest is BLOCKED on packet 6's
// `ScratchpadPersistence` v2 (`save(forKey:schemeText:)`, `load(forKey:)`,
// `relativeToScheme`/`schemeToRelative`, `migrateLegacyIfNeeded`) and the
// `ScratchpadStore` v2 it drives (`attachmentSweepTask`, `isPersistencePaused`,
// `discardNotesForExternalDelete`, `discardAndReload`) plus
// `ScratchpadAttachmentStore.activeDirectory` / the `collectGarbage(in:referencedIds:
// referencedAsOf:)` signature. iPad still has the v1 legacy-blob persister.
//
// HELD BACK for packet 6 — re-add VERBATIM from
// `main@7742a895:Tests/DocumentDataStoreTests.swift`, do not soften:
//   * `testPersistenceSaveWritesRelativeAndLoadsScheme`
//   * `testRelativeToSchemeMultipleRefs`, `testRelativeToSchemeBareRef`,
//     `testSchemeToRelativeUsesResolvedExtension`,
//     `testSchemeToRelativeFallsBackWhenExtensionUnknown`,
//     `testRewritesLeaveNoRefsAndMalformedUntouched`,
//     `testSchemeToRelativeHandlesEmojiBeforeRef`,
//     `testSchemeToRelativeHandlesEmojiBetweenRefs`
//   * `testLazyMigrationMovesNoteAndAttachmentAndClearsBlob`,
//     `testMigrationWritesNoteBeforeCopyingAttachmentsAndRetries`,
//     `testLazyMigrationCopiesSharedAttachmentForSecondNote`,
//     `testLazyMigrationSkippedWhenScratchpadExists`
//   * `testClearingNoteRemovesFileAttachmentAndFolder` — packet 1 §4 lists it as
//     landing now, but its subject is `ScratchpadPersistence.save(forKey:schemeText:)`
//     clearing a note down to nothing, which does not exist on iPad yet.
//   * `testGCDoesNotTouchAnotherDocumentsAttachments` (needs
//     `collectGarbage(in:referencedIds:)`)
//   * `testStuckInICloudNotePausesPersistence`,
//     `testDiscardNotesForExternalDeleteDoesNotResurrect`,
//     `testDiscardAndReloadKeepsImportedNoteOverStaleText`
//
// RELOCATED, not dropped: `testGCSparesAttachmentsWrittenAfterTheReferenceSnapshot`
// moves into `Tests/SafeClearTests.swift` with packet 6 (packet 9 §1.4 / packet 6
// §4.4) — a verbatim copy here would leave it living in both files.

@MainActor
final class DocumentDataStoreTests: XCTestCase {
    private var root: URL!
    /// The legacy shared attachment pool. Nothing in the ported subset writes to
    /// it, but the override is installed anyway so no stray attachment write can
    /// reach the real pool while this suite owns the process.
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
    }

    override func tearDown() async throws {
        DocumentDataStore.rootDirectoryOverride = nil
        ScratchpadAttachmentStore.directoryOverride = nil
        // The legacy notes blob: `AppDefaults.current` is a scratch suite in a
        // hosted test process, never the real user's domain.
        AppDefaults.current.removeObject(forKey: ScratchpadPersistence.notesKey)
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

    private func setModDate(_ url: URL, daysAgo: Int) throws {
        let date = Calendar.current.date(byAdding: .day, value: -daysAgo, to: .now) ?? .now
        try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: url.path)
    }

    // MARK: - Note round-trip

    func testScratchpadRoundTripsUnderOverrideRoot() throws {
        let key = "roundtripkey"
        try DocumentDataStore.saveScratchpad(forKey: key, text: "hello world")
        XCTAssertEqual(DocumentDataStore.loadScratchpad(forKey: key), "hello world")
        XCTAssertTrue(exists(DocumentDataStore.scratchpadPath(forKey: key)))
        XCTAssertTrue(DocumentDataStore.scratchpadExists(forKey: key))
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

    // MARK: - Rekey

    /// Data written into the path-hash fallback folder (pre-stamp) moves wholesale
    /// to the docId folder, attachments included, and the fallback folder is gone.
    ///
    /// iPad adaptation (packet 1 §4): main drives this through
    /// `ScratchpadStore.loadForDocument`, whose implicit rekey + background
    /// attachment sweep + scheme rewrite are `ScratchpadStore` v2 (packet 6). The
    /// DocumentDataStore contract under test is identical when `rekey` is called
    /// directly, so every store-level assertion below is main's, unchanged.
    /// FOLLOW-UP (post-#129, "scratchpad onto DocumentDataStore"): restore
    /// main's `ScratchpadStore`-driven body — `store.loadForDocument(...)` +
    /// `await drainAttachmentSweeps()` + the
    /// `store.text == "carried note ![x](vellum-scratchpad://<id>)"` assertion.
    /// `ScratchpadStore.loadForDocument` cannot drive a rekey while the note
    /// itself lives in the path-keyed UserDefaults blob rather than
    /// `documents/<key>/scratchpad.md`.
    func testRekeyMovesFallbackFolderToStampedKey() throws {
        let path = "/tmp/stamp-\(UUID().uuidString).pdf"
        let pathKey = DocumentIdentity.sha256Hex(path)
        let docId = "11111111-2222-3333-4444-555555555555"
        // Seed data in the path-hash fallback folder (as if written pre-stamp).
        // The note REFERENCES the attachment, which is what a document that
        // carried one across a rekey actually looks like: an attachment no note
        // points at is an orphan, and the sweep every load ends in is right to
        // collect it, so requiring it to survive would pin a value that only
        // holds until that sweep lands (#100). The id has to be a real one —
        // both ref rewrites only recognise `[0-9a-fA-F-]+`, so a prose filename
        // would silently stop counting as a reference and the sweep would reap
        // the file again.
        let attachmentId = "00000000-0000-0000-0000-0000000000ab"
        let attachmentFile = "\(attachmentId).jpg"
        let note = "carried note ![x](attachments/\(attachmentFile))"
        try DocumentDataStore.saveScratchpad(forKey: pathKey, text: note)
        let fallbackAttachments = DocumentDataStore.attachmentsDir(forKey: pathKey)
        try FileManager.default.createDirectory(
            at: fallbackAttachments, withIntermediateDirectories: true)
        try Data([1]).write(to: fallbackAttachments.appendingPathComponent(attachmentFile))

        DocumentDataStore.rekey(from: pathKey, to: docId)

        XCTAssertFalse(exists(DocumentDataStore.documentDir(forKey: pathKey)),
                       "old fallback folder must be gone")
        XCTAssertEqual(DocumentDataStore.loadScratchpad(forKey: docId), note)
        XCTAssertTrue(
            exists(DocumentDataStore.attachmentsDir(forKey: docId)
                .appendingPathComponent(attachmentFile)),
            "the rekey carried the referenced attachment across")
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

    // MARK: - Delete-means-delete

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
}
