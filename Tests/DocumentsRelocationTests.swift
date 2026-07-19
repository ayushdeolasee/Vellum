import XCTest
@testable import Vellum

// Storage PR 3 (design §5 tier 3 + §7): the per-document `documents/` store joins
// the relocatable storage-location machinery. Covers layout resolution per mode
// (including the degraded fallback), relocation of `documents/<key>/` folders
// between layouts (records rule: custom keeps documents local), the collision
// merge, the interrupted-move resume via the launch sweep, and the
// iCloud-evicted-placeholder read-degrades / save-refuses-to-clobber guards.
//
// Uses the same scratch-dir seams as WebStorageLocationTests
// (`WebLibrary.storeDirOverride` / `.layoutOverride`,
// `DocumentDataStore.rootDirectoryOverride`).
@MainActor
final class DocumentsRelocationTests: XCTestCase {
    private var tempDir: URL!
    private var storeDir: URL!
    private var prettyRoot: URL!

    override func setUp() async throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("vellum-docsreloc-tests-\(UUID().uuidString)")
        storeDir = tempDir.appendingPathComponent("appsupport-web", isDirectory: true)
        prettyRoot = tempDir.appendingPathComponent("cloud/Vellum", isDirectory: true)
        try FileManager.default.createDirectory(at: storeDir, withIntermediateDirectories: true)
        WebLibrary.storeDirOverride = storeDir
    }

    override func tearDown() async throws {
        WebLibrary.storeDirOverride = nil
        WebLibrary.layoutOverride = nil
        WebStorageSettings.modeOverride = nil
        WebStorageSettings.customRootOverride = nil
        WebStorageSettings.icloudDriveRootOverride = nil
        DocumentDataStore.rootDirectoryOverride = nil
        WebICloud.materializeOverride = nil
        WebStorageMigrator.clearPendingRelocation()
        if let tempDir { try? FileManager.default.removeItem(at: tempDir) }
    }

    // The documents/ home for the local (Application Support) layout, derived
    // from the overridden store dir just as production derives it from appData.
    private var localDocuments: URL { WebStorageLayout.localDocumentsDir(storeDir: storeDir) }

    private var localLayout: WebStorageLayout { .local(storeDir: storeDir) }
    private var icloudLayout: WebStorageLayout {
        .pretty(root: prettyRoot, recordsInRoot: true, localStoreDir: storeDir)
    }
    private var customLayout: WebStorageLayout {
        .pretty(root: prettyRoot, recordsInRoot: false, localStoreDir: storeDir)
    }

    /// Write a document folder with the three synced files under `documentsDir`.
    @discardableResult
    private func makeDocumentFolder(
        in documentsDir: URL, key: String, note: String
    ) throws -> URL {
        let dir = documentsDir.appendingPathComponent(key, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data(note.utf8).write(to: dir.appendingPathComponent("scratchpad.md"))
        try Data("[]".utf8).write(to: dir.appendingPathComponent("conversations.json"))
        try Data("{}".utf8).write(to: dir.appendingPathComponent("meta.json"))
        return dir
    }

    private func exists(_ url: URL) -> Bool {
        FileManager.default.fileExists(atPath: url.path)
    }

    // MARK: - Layout resolution per mode

    func testDocumentsDirPerMode() {
        // Local: documents sit next to web/ under the (overridden) app-data base.
        XCTAssertEqual(localLayout.documentsDir, localDocuments)

        // iCloud: documents sync under the root, next to the records.
        XCTAssertEqual(
            icloudLayout.documentsDir,
            prettyRoot.appendingPathComponent(".vellum/documents", isDirectory: true))
        XCTAssertEqual(
            icloudLayout.documentsDir.deletingLastPathComponent(),
            icloudLayout.recordsDir.deletingLastPathComponent(),
            "documents live beside records under .vellum in iCloud mode")

        // Custom: documents stay LOCAL (custom mode's meaning is the visible
        // web-pages folder; notes/records don't sync there).
        XCTAssertEqual(customLayout.documentsDir, localDocuments)
    }

    func testResolvePerModeAndDegradedFallback() {
        // iCloud root present → pretty layout with documents under the root.
        // icloudDriveRoot existence-checks the drive dir, so create it first.
        let iCloudDrive = tempDir.appendingPathComponent("iCloudDrive", isDirectory: true)
        try? FileManager.default.createDirectory(at: iCloudDrive, withIntermediateDirectories: true)
        WebStorageSettings.icloudDriveRootOverride = iCloudDrive
        let icloudResolved = WebStorageLayout.resolve(mode: .icloud, storeDir: storeDir)
        XCTAssertTrue(icloudResolved.documentsDir.path.contains("/.vellum/documents"))

        // iCloud root missing → degrades to local documents.
        WebStorageSettings.icloudDriveRootOverride =
            tempDir.appendingPathComponent("nonexistent", isDirectory: true)
        let degraded = WebStorageLayout.resolve(mode: .icloud, storeDir: storeDir)
        XCTAssertEqual(degraded.documentsDir, localDocuments)

        // Custom folder present but documents still resolve local.
        let customFolder = tempDir.appendingPathComponent("MyFolder", isDirectory: true)
        try? FileManager.default.createDirectory(at: customFolder, withIntermediateDirectories: true)
        WebStorageSettings.customRootOverride = customFolder
        let customResolved = WebStorageLayout.resolve(mode: .custom, storeDir: storeDir)
        XCTAssertEqual(customResolved.documentsDir, localDocuments)
    }

    func testRootDirectoryResolvesThroughActiveLayoutPerOperation() {
        // No rootDirectoryOverride: DocumentDataStore.rootDirectory follows the
        // active layout, so a mode change takes effect on the next operation.
        WebLibrary.layoutOverride = icloudLayout
        XCTAssertEqual(DocumentDataStore.rootDirectory, icloudLayout.documentsDir)

        WebLibrary.layoutOverride = localLayout
        XCTAssertEqual(DocumentDataStore.rootDirectory, localDocuments)

        // The test override still wins (precedence preserved).
        let forced = tempDir.appendingPathComponent("forced-docs", isDirectory: true)
        DocumentDataStore.rootDirectoryOverride = forced
        XCTAssertEqual(DocumentDataStore.rootDirectory, forced)
    }

    // MARK: - Relocation

    func testRelocateLocalToICloudMovesDocumentFolders() throws {
        try makeDocumentFolder(in: localDocuments, key: "doc-a", note: "alpha notes")
        WebLibrary.layoutOverride = icloudLayout

        XCTAssertTrue(WebStorageMigrator.relocate(from: localLayout, to: icloudLayout))

        let moved = icloudLayout.documentsDir
            .appendingPathComponent("doc-a/scratchpad.md")
        XCTAssertTrue(exists(moved))
        XCTAssertEqual(try String(contentsOf: moved, encoding: .utf8), "alpha notes")
        XCTAssertFalse(
            exists(localDocuments.appendingPathComponent("doc-a")),
            "source folder is gone after the move")

        // Idempotent: nothing left to move.
        XCTAssertTrue(WebStorageMigrator.relocate(from: localLayout, to: icloudLayout))
    }

    func testRelocateLocalToCustomLeavesDocumentsLocal() throws {
        try makeDocumentFolder(in: localDocuments, key: "doc-c", note: "stays put")
        WebLibrary.layoutOverride = customLayout

        XCTAssertTrue(WebStorageMigrator.relocate(from: localLayout, to: customLayout))

        // Custom keeps documents local: source == dest documentsDir, no move.
        XCTAssertTrue(exists(localDocuments.appendingPathComponent("doc-c/scratchpad.md")))
        XCTAssertFalse(
            exists(prettyRoot.appendingPathComponent(".vellum/documents/doc-c")),
            "custom mode never moves documents into the pretty root")
    }

    func testRelocateBackRegeneratesLocalAndCleansUp() throws {
        try makeDocumentFolder(in: localDocuments, key: "doc-b", note: "round trip")
        WebLibrary.layoutOverride = icloudLayout
        XCTAssertTrue(WebStorageMigrator.relocate(from: localLayout, to: icloudLayout))
        XCTAssertTrue(exists(icloudLayout.documentsDir.appendingPathComponent("doc-b")))

        WebLibrary.layoutOverride = localLayout
        XCTAssertTrue(WebStorageMigrator.relocate(from: icloudLayout, to: localLayout))

        XCTAssertTrue(exists(localDocuments.appendingPathComponent("doc-b/scratchpad.md")))
        // The pretty documents dir we created is cleaned up once empty.
        XCTAssertFalse(exists(icloudLayout.documentsDir))
    }

    func testRelocateCollisionMergesNewestWins() throws {
        // Same doc key in both homes: destination's scratchpad is NEWER and must
        // win; the source's UNIQUE conversations.json must still carry over.
        let key = "doc-merge"
        let srcDir = try makeDocumentFolder(in: localDocuments, key: key, note: "OLD source note")
        let dstDir = icloudLayout.documentsDir.appendingPathComponent(key, isDirectory: true)
        try FileManager.default.createDirectory(at: dstDir, withIntermediateDirectories: true)
        try Data("NEW dest note".utf8).write(to: dstDir.appendingPathComponent("scratchpad.md"))

        // Force modification times: destination scratchpad newer than source's.
        let old = Date(timeIntervalSince1970: 1_000)
        let new = Date(timeIntervalSince1970: 2_000)
        try FileManager.default.setAttributes(
            [.modificationDate: old], ofItemAtPath: srcDir.appendingPathComponent("scratchpad.md").path)
        try FileManager.default.setAttributes(
            [.modificationDate: new], ofItemAtPath: dstDir.appendingPathComponent("scratchpad.md").path)

        WebLibrary.layoutOverride = icloudLayout
        XCTAssertTrue(WebStorageMigrator.relocate(from: localLayout, to: icloudLayout))

        let mergedNote = dstDir.appendingPathComponent("scratchpad.md")
        XCTAssertEqual(
            try String(contentsOf: mergedNote, encoding: .utf8), "NEW dest note",
            "newer destination file wins the collision")
        XCTAssertTrue(
            exists(dstDir.appendingPathComponent("conversations.json")),
            "source-only file is carried into the merged folder")
        XCTAssertFalse(exists(srcDir), "merged source folder is removed")
    }

    // MARK: - Interrupted-move resume via the launch sweep

    func testInterruptedMoveResumesViaLaunchSweep() throws {
        // Simulate an interrupted local→iCloud relocation: the document folder is
        // still local and the pending marker names the local source. The launch
        // sweep (active layout = iCloud) must finish the move and clear the marker.
        try makeDocumentFolder(in: localDocuments, key: "doc-resume", note: "resume me")
        WebStorageMigrator.recordPendingRelocation(mode: .local, customPath: nil)
        WebLibrary.layoutOverride = icloudLayout

        WebStorageMigrator.sweepAtLaunch()

        XCTAssertTrue(
            exists(icloudLayout.documentsDir.appendingPathComponent("doc-resume/scratchpad.md")),
            "the sweep resumed the documents move")
        XCTAssertFalse(exists(localDocuments.appendingPathComponent("doc-resume")))
        XCTAssertNil(
            UserDefaults.standard.string(forKey: WebStorageSettings.pendingRelocationKey),
            "the resume clears the pending marker")
    }

    // MARK: - Evicted iCloud placeholder: read degrades, save refuses to clobber

    func testEvictedPlaceholderReadDegradesAndSaveRefuses() throws {
        let docs = tempDir.appendingPathComponent("docstore", isDirectory: true)
        DocumentDataStore.rootDirectoryOverride = docs
        let key = "evicted"
        let dir = DocumentDataStore.documentDir(forKey: key)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        // Evicted: only the `.<name>.icloud` placeholders exist, no real bytes.
        let notePlaceholder = WebICloud.placeholderURL(for: DocumentDataStore.scratchpadPath(forKey: key))
        let chatPlaceholder = WebICloud.placeholderURL(for: DocumentDataStore.conversationsPath(forKey: key))
        try Data("placeholder".utf8).write(to: notePlaceholder)
        try Data("placeholder".utf8).write(to: chatPlaceholder)

        // Reads degrade to absent rather than crashing or returning junk.
        XCTAssertEqual(DocumentDataStore.loadScratchpad(forKey: key), "")
        XCTAssertNil(DocumentDataStore.loadConversationsData(forKey: key))

        // Saves refuse to clobber the real-but-evicted copy.
        XCTAssertThrowsError(try DocumentDataStore.saveScratchpad(forKey: key, text: "fresh empty"))
        XCTAssertThrowsError(
            try DocumentDataStore.saveConversationsData(forKey: key, data: Data("[]".utf8)))

        // Empty-note removal is also refused (placeholder left intact).
        DocumentDataStore.removeScratchpad(forKey: key)
        DocumentDataStore.removeConversations(forKey: key)
        XCTAssertTrue(exists(notePlaceholder), "evicted note placeholder is preserved")
        XCTAssertTrue(exists(chatPlaceholder), "evicted chat placeholder is preserved")

        // Once the real bytes materialize, a save proceeds normally.
        try Data("real note".utf8).write(to: DocumentDataStore.scratchpadPath(forKey: key))
        XCTAssertNoThrow(try DocumentDataStore.saveScratchpad(forKey: key, text: "edited"))
        XCTAssertEqual(DocumentDataStore.loadScratchpad(forKey: key), "edited")
    }

    // MARK: - F3 #1: fallback read during a pending relocation

    /// Mode switched Local→iCloud (active layout is iCloud), but the launch sweep
    /// hasn't MOVED this document's folder yet — it still sits in the local dir.
    /// The read paths must fall back to the local copy so the note/chat/meta load
    /// real bytes instead of degrading to empty (which the empty-state save path
    /// could otherwise turn into a delete). A save adopts the note into the ACTIVE
    /// (iCloud) dir.
    func testFallbackReadDuringPendingRelocation() throws {
        // rootDirectoryOverride stays nil so the fallback (local default dir) is
        // active; the store follows the iCloud layout for the ACTIVE dir.
        WebLibrary.layoutOverride = icloudLayout
        let key = "0f0f0f0f-1111-2222-3333-444455556666"
        let dir = try makeDocumentFolder(in: localDocuments, key: key, note: "local note bytes")
        // Write a DECODABLE meta into the fallback location too (makeDocumentFolder
        // writes a placeholder "{}", which the required Meta fields reject).
        let meta = DocumentDataStore.Meta(
            version: 1, kind: "pdf", title: "Local Doc",
            lastKnownPath: "/tmp/local.pdf", lastOpened: WebLibrary.rfc3339Now())
        try WebLibrary.jsonEncoderPretty.encode(meta).write(to: dir.appendingPathComponent("meta.json"))

        XCTAssertEqual(DocumentDataStore.rootDirectory, icloudLayout.documentsDir)
        // Active (iCloud) dir has nothing yet; fallback finds the local copy.
        XCTAssertEqual(DocumentDataStore.loadScratchpad(forKey: key), "local note bytes")
        XCTAssertNotNil(DocumentDataStore.loadConversationsData(forKey: key))
        XCTAssertEqual(DocumentDataStore.loadMeta(forKey: key)?.title, "Local Doc")
        XCTAssertTrue(DocumentDataStore.scratchpadExists(forKey: key))
        XCTAssertTrue(DocumentDataStore.conversationsExist(forKey: key))

        // A save adopts the note into the ACTIVE (iCloud) dir — writes never
        // target the fallback.
        try DocumentDataStore.saveScratchpad(forKey: key, text: "edited in place")
        XCTAssertEqual(
            try String(
                contentsOf: icloudLayout.documentsDir
                    .appendingPathComponent("\(key)/scratchpad.md"), encoding: .utf8),
            "edited in place")
        // The active copy now wins the read.
        XCTAssertEqual(DocumentDataStore.loadScratchpad(forKey: key), "edited in place")
    }

    // MARK: - F3 #2: placeholders materialized before a folder move

    /// A document folder whose iCloud file can't be downloaded is SKIPPED, not
    /// moved as an `.icloud` stub: `relocate` returns false and the source folder
    /// is preserved, and the launch sweep keeps the pending marker for a retry.
    func testUnmaterializablePlaceholderSkipsMoveAndKeepsPendingMarker() throws {
        let key = "doc-evicted"
        let srcDir = localDocuments.appendingPathComponent(key, isDirectory: true)
        try FileManager.default.createDirectory(at: srcDir, withIntermediateDirectories: true)
        // Only an evicted placeholder for scratchpad.md exists locally.
        let placeholder = WebICloud.placeholderURL(for: srcDir.appendingPathComponent("scratchpad.md"))
        try Data("stub".utf8).write(to: placeholder)
        WebICloud.materializeOverride = { _ in false }  // offline: can't download

        WebLibrary.layoutOverride = icloudLayout
        XCTAssertFalse(
            WebStorageMigrator.relocate(from: localLayout, to: icloudLayout),
            "an unmaterializable folder makes relocate report not-clean")
        XCTAssertTrue(exists(srcDir), "the source folder is preserved, not moved as a stub")
        XCTAssertFalse(
            exists(icloudLayout.documentsDir.appendingPathComponent(key)),
            "no stub folder is written at the destination")

        // Via the launch sweep the pending marker is kept for a later retry.
        WebStorageMigrator.recordPendingRelocation(mode: .local, customPath: nil)
        WebStorageMigrator.sweepAtLaunch()
        XCTAssertNotNil(
            UserDefaults.standard.string(forKey: WebStorageSettings.pendingRelocationKey),
            "the skipped move keeps the pending marker")
    }

    /// An iCloud-evicted DESTINATION file counts as EXISTING for the newest-wins
    /// merge — it must be materialized and compared, never treated as absent and
    /// have the source file written in beside its placeholder.
    func testEvictedDestinationCountsAsExistingForNewestWins() throws {
        let key = "doc-dest-evicted"
        // Source (local): an OLDER real note.
        let srcDir = try makeDocumentFolder(in: localDocuments, key: key, note: "SRC old")
        let old = Date(timeIntervalSince1970: 1_000)
        try FileManager.default.setAttributes(
            [.modificationDate: old], ofItemAtPath: srcDir.appendingPathComponent("scratchpad.md").path)

        // Destination (iCloud): only an evicted placeholder for scratchpad.md.
        let dstDir = icloudLayout.documentsDir.appendingPathComponent(key, isDirectory: true)
        try FileManager.default.createDirectory(at: dstDir, withIntermediateDirectories: true)
        let dstNote = dstDir.appendingPathComponent("scratchpad.md")
        try Data("DEST new".utf8).write(to: WebICloud.placeholderURL(for: dstNote))

        // Simulate a successful download: create the real (NEWER) destination file.
        WebICloud.materializeOverride = { url in
            let ph = WebICloud.placeholderURL(for: url)
            guard let bytes = try? Data(contentsOf: ph) else { return false }
            try? bytes.write(to: url)
            try? FileManager.default.removeItem(at: ph)
            try? FileManager.default.setAttributes(
                [.modificationDate: Date(timeIntervalSince1970: 2_000)], ofItemAtPath: url.path)
            return true
        }

        WebLibrary.layoutOverride = icloudLayout
        XCTAssertTrue(WebStorageMigrator.relocate(from: localLayout, to: icloudLayout))

        // Newest (destination) wins; the source's older note did NOT overwrite it,
        // and there is exactly one real note — no stub left beside a rival copy.
        XCTAssertEqual(try String(contentsOf: dstNote, encoding: .utf8), "DEST new")
        XCTAssertFalse(exists(WebICloud.placeholderURL(for: dstNote)), "placeholder was materialized away")
        XCTAssertFalse(exists(srcDir), "merged source folder is removed")
    }
}
