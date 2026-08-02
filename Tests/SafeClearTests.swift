import XCTest
@testable import Vellum

// Clear is destructive, so it has to be reversible: these tests pin the Undo/
// Redo contract for both the AI conversation and the scratchpad note, plus the
// attachment-GC rules that make a scratchpad Undo able to put image bytes back.
//
// Two tests from main's suite are deliberately absent on the iPad branch
// (`dc3ac525`): `testAiClearFollowsSameSessionStampForUndoAndRedo` and
// `testScratchpadClearFollowsSameSessionStampForUndoRedoAndAttachments`. They
// assert that a clear survives the document acquiring a durable /VellumDocId
// mid-transaction and rekeying its storage — behaviour packet 6 ports in its
// adapted, path-key form (see the `// TODO(packet 1)` markers in
// `ScratchpadStore`). Restore them with the doc-ID-stamp rekey.

@MainActor
final class SafeClearTests: XCTestCase {
    private var root: URL!
    private var sessions: SafeClearSessionService!
    private var app: AppStore!

    override func setUp() async throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("vellum-safe-clear-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        DocumentDataStore.rootDirectoryOverride = root
        ScratchpadAttachmentStore.directoryOverride = root.appendingPathComponent("legacy")
        // These seams are process-global (#102), so claim all three on the way in
        // as well as releasing them on the way out — this suite must not inherit
        // an attachment directory from whatever ran before it.
        ScratchpadAttachmentStore.activeDirectory = nil
        // The pending-attachment registry and its grace period are process-global
        // for the same reason. The grace period is the one that matters — a test
        // here sets it to 0, and leaving it there would stop every later suite's
        // freshly written attachment from being exempt — so capture the real
        // value rather than asserting a literal. Clearing the registry is defence
        // in depth: its keys are UUIDs, so a leftover entry cannot match anything
        // another test creates.
        savedGracePeriod = ScratchpadAttachmentStore.pendingGracePeriod
        ScratchpadAttachmentStore.resetPending()
        sessions = SafeClearSessionService()
        app = AppStore(sessions: sessions)
    }

    override func tearDown() async throws {
        await AiPersistence.awaitPendingFlush()
        // Drain every sweep this test armed before the next one installs its own
        // attachment directory: `collectGarbage` resolves `directory` when it
        // runs, so a sweep that outlived its test would scan the NEXT test's
        // pool with this test's reference set (#111).
        for store in scratchpadStores { await store.attachmentSweepTask?.value }
        scratchpadStores.removeAll()
        DocumentDataStore.rootDirectoryOverride = nil
        ScratchpadAttachmentStore.directoryOverride = nil
        ScratchpadAttachmentStore.activeDirectory = nil
        ScratchpadAttachmentStore.resetPending()
        ScratchpadAttachmentStore.pendingGracePeriod = savedGracePeriod
        try? FileManager.default.removeItem(at: root)
    }

    private var savedGracePeriod: TimeInterval = 60
    private var scratchpadStores: [ScratchpadStore] = []

    private func open(_ path: String) async -> DocumentInfo {
        await app.openFile(path: path)
        return app.document!
    }

    /// A scratchpad store wired to this suite's `AppStore` and registered so
    /// tearDown can drain its background attachment sweeps.
    private func makeScratchpadStore() -> ScratchpadStore {
        let store = ScratchpadStore()
        store.app = app
        scratchpadStores.append(store)
        return store
    }

    /// Ask for an attachment sweep and wait for it.
    ///
    /// Main prunes inline from `ScratchpadPersistence.save(forKey:schemeText:)`,
    /// because there a note owns its own `attachments/` folder. The iPad keeps
    /// one flat pool shared by every document, so a save cannot know what the
    /// other notes still reference — the sweep hangs off `loadForDocument`
    /// instead, over the whole persisted corpus. Re-loading the same document is
    /// therefore how a test says "a sweep runs here", and joining
    /// `attachmentSweepTask` (`60b7617e`) is how it stops racing one.
    private func sweepAttachments(_ store: ScratchpadStore, _ document: DocumentInfo) async {
        store.loadForDocument(document)
        await store.attachmentSweepTask?.value
    }

    func testAiUndoRedoIsDocumentScopedAndPreservesNewMessages() async throws {
        let store = AiStore()
        store.app = app
        let documentA = await open("/tmp/safe-clear-a-\(UUID().uuidString).pdf")
        store.loadConversationForDocument(documentA)
        store.addLocalMessage(role: .user, content: "old question", id: "old-question")
        store.addLocalMessage(role: .assistant, content: "old answer", id: "old-answer")

        let transaction = try XCTUnwrap(store.clearConversation())
        store.addLocalMessage(role: .user, content: "new work", id: "new-work")
        XCTAssertTrue(store.undoClear(transaction))
        XCTAssertEqual(store.messages.map(\.content), ["old question", "old answer", "new work"])
        XCTAssertTrue(store.redoClear(transaction))
        XCTAssertEqual(store.messages.map(\.content), ["new work"])

        XCTAssertTrue(store.undoClear(transaction))
        let documentB = await open("/tmp/safe-clear-b-\(UUID().uuidString).pdf")
        store.loadConversationForDocument(documentB)
        store.addLocalMessage(role: .user, content: "B stays visible", id: "b-message")
        XCTAssertTrue(store.redoClear(transaction))
        XCTAssertEqual(store.messages.map(\.content), ["B stays visible"])
        XCTAssertEqual(
            AiPersistence.loadConversation(for: documentA).map(\.content),
            ["new work"])
        XCTAssertEqual(
            AiPersistence.loadConversation(for: documentB).map(\.content),
            ["B stays visible"])
    }

    func testScratchpadUndoRestoresAttachmentBytesAndRedoPreservesNewWork() async throws {
        let store = makeScratchpadStore()
        let document = await open("/tmp/safe-note-\(UUID().uuidString).pdf")
        store.loadForDocument(document)
        let bytes = Data([0x89, 0x50, 0x4e, 0x47, 1, 2, 3])
        let id = try XCTUnwrap(ScratchpadAttachmentStore.save(data: bytes, fileExtension: "png"))
        let attachment = try XCTUnwrap(ScratchpadAttachmentStore.fileURL(for: id))
        store.text = "old note\n\n![image](vellum-scratchpad://\(id))"
        store.flush()

        let transaction = try XCTUnwrap(store.clearText())
        store.flush()
        await sweepAttachments(store, document)
        XCTAssertFalse(FileManager.default.fileExists(atPath: attachment.path))
        store.text = "new work"
        store.flush()

        let restoration = try XCTUnwrap(store.undoClear(transaction))
        XCTAssertTrue(store.text.hasSuffix("new work"))
        // The iPad keeps one flat attachment pool, so the restored bytes land
        // back in the same directory they were saved to.
        let restoredAttachment = try XCTUnwrap(ScratchpadAttachmentStore.fileURL(for: id))
        XCTAssertEqual(try Data(contentsOf: restoredAttachment), bytes)

        XCTAssertTrue(store.redoClear(restoration))
        XCTAssertEqual(store.text, "new work")
        await sweepAttachments(store, document)
        XCTAssertFalse(FileManager.default.fileExists(atPath: restoredAttachment.path))
    }

    func testScratchpadUndoForADoesNotReplaceVisibleB() async throws {
        let store = makeScratchpadStore()
        let documentA = await open("/tmp/safe-note-a-\(UUID().uuidString).pdf")
        store.loadForDocument(documentA)
        store.text = "A note"
        store.flush()
        let transaction = try XCTUnwrap(store.clearText())
        store.flush()

        let documentB = await open("/tmp/safe-note-b-\(UUID().uuidString).pdf")
        store.loadForDocument(documentB)
        store.text = "B note"
        XCTAssertNotNil(store.undoClear(transaction))
        XCTAssertEqual(store.text, "B note")
        try await Task.sleep(for: .milliseconds(550))
        XCTAssertEqual(ScratchpadPersistence.load(for: transaction.key), "A note")
        // The iPad's scratchpad is keyed by the document's path, not by the
        // doc-ID storage key packet 1 introduced for the folder-backed stores.
        XCTAssertEqual(
            ScratchpadPersistence.load(
                for: try XCTUnwrap(ScratchpadPersistence.documentKey(documentB))),
            "B note")
    }

    // MARK: - Attachment GC vs. an in-flight markdown reference (#105)

    /// Drop an image and hold its markdown in flight — exactly what the editor's
    /// WebView round trip does — then return the store, the captured markdown,
    /// and the file the bytes landed in.
    private func dropImageHoldingItsReference(
        _ store: ScratchpadStore
    ) throws -> (markdown: String, id: String, attachment: URL) {
        var inFlight: String?
        store.insertMarkdownHandler = { inFlight = $0 }
        store.addImage(
            ScratchpadImageCapture(
                data: Data([0x89, 0x50, 0x4e, 0x47, 9, 9, 9]), fileExtension: "png",
                mediaType: "image/png", width: 1, height: 1, pageNumber: nil),
            label: "Image")
        let markdown = try XCTUnwrap(inFlight, "addImage must produce a reference to insert")
        let id = try XCTUnwrap(ScratchpadAttachmentStore.referencedIds(in: markdown).first)
        let attachment = try XCTUnwrap(ScratchpadAttachmentStore.fileURL(for: id))
        XCTAssertTrue(
            store.text.isEmpty,
            "precondition: the reference has not reached the note yet")
        return (markdown, id, attachment)
    }

    private func exists(_ url: URL) -> Bool {
        FileManager.default.fileExists(atPath: url.path)
    }

    /// The bytes are written before the markdown reference exists. A debounced
    /// save landing in that window computes a reference set that is genuinely
    /// current and genuinely does not mention the new attachment, so #104's
    /// snapshot cutoff cannot tell it from an orphan — the file is older than
    /// the sweep, not newer. Marking it pending at write time is what keeps it.
    func testAttachmentSurvivesASaveFiredBeforeItsReferenceLands() async throws {
        let store = makeScratchpadStore()
        let document = await open("/tmp/pending-gc-\(UUID().uuidString).pdf")
        store.loadForDocument(document)
        let dropped = try dropImageHoldingItsReference(store)

        // The debounced save fires inside the window, and a sweep with it.
        store.flush()
        await sweepAttachments(store, document)
        XCTAssertTrue(
            exists(dropped.attachment),
            "an attachment whose reference is still in flight must not be collected")

        // The round trip completes; the note now points at it.
        store.text = dropped.markdown
        store.flush()
        await sweepAttachments(store, document)
        XCTAssertTrue(exists(dropped.attachment))
    }

    /// The exemption is not permanent. Once the reference has been observed in
    /// saved text the attachment is settled, and from then on ordinary
    /// reachability governs it: deleting the reference collects the bytes.
    func testSettledAttachmentIsCollectedOnceItsReferenceIsRemoved() async throws {
        let store = makeScratchpadStore()
        let document = await open("/tmp/pending-settle-\(UUID().uuidString).pdf")
        store.loadForDocument(document)
        let dropped = try dropImageHoldingItsReference(store)

        // Reference lands and is saved — this is what settles it.
        store.text = dropped.markdown
        store.flush()
        await sweepAttachments(store, document)
        XCTAssertTrue(exists(dropped.attachment))

        // The user deletes the image from the note.
        store.text = "no image here"
        store.flush()
        await sweepAttachments(store, document)
        XCTAssertFalse(
            exists(dropped.attachment),
            "a settled attachment the note no longer references is ordinary garbage")
    }

    /// If the reference never arrives, the exemption lapses and the next sweep
    /// collects the bytes. The window is deliberately generous (a minute against
    /// a round trip of a couple of frames) because the two failure modes are not
    /// symmetric: an exemption held too long only delays a collection that will
    /// still happen, while one released too early deletes bytes the note is
    /// about to point at and leaves a broken image.
    func testPendingExemptionLapsesSoAnAbandonedAttachmentIsStillCollected() async throws {
        ScratchpadAttachmentStore.pendingGracePeriod = 0
        let store = makeScratchpadStore()
        let document = await open("/tmp/pending-lapse-\(UUID().uuidString).pdf")
        store.loadForDocument(document)
        let dropped = try dropImageHoldingItsReference(store)

        // The reference never lands — the editor went away mid-round-trip.
        store.flush()
        await sweepAttachments(store, document)
        XCTAssertFalse(
            exists(dropped.attachment),
            "an attachment past its grace period is collectable like any orphan")
    }

    /// A sweep collects against a reference set captured at some moment, and it
    /// can run after that moment — `pruneOrphanedAttachments` hands the work to
    /// a background task. An attachment written in that gap is absent from the
    /// set but is not garbage, and deleting it leaves a broken image in the note.
    ///
    /// Relocated here from `DocumentDataStoreTests` (`1d9d4469`) and rewritten
    /// for the iPad's global-pool `collectGarbage` (packet 6 §4.5).
    func testGCSparesAttachmentsWrittenAfterTheReferenceSnapshot() throws {
        let dir = ScratchpadAttachmentStore.directory
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let old = dir.appendingPathComponent("old.jpg")
        try Data([1]).write(to: old)

        // Everything already on disk predates the snapshot; the new file does not.
        let referencedAsOf = Date()
        let fresh = dir.appendingPathComponent("fresh.jpg")
        try Data([2]).write(to: fresh)

        ScratchpadAttachmentStore.collectGarbage(
            referencedIds: [], referencedAsOf: referencedAsOf)

        XCTAssertFalse(FileManager.default.fileExists(atPath: old.path),
                       "an attachment older than the snapshot is still collected")
        XCTAssertTrue(FileManager.default.fileExists(atPath: fresh.path),
                      "an attachment written after the snapshot belongs to a later edit")
    }

    func testEmptyClearsAreNoOps() {
        XCTAssertNil(AiStore().clearConversation())
        XCTAssertNil(ScratchpadStore().clearText())
    }

}

@MainActor
private final class SafeClearSessionService: SessionService {
    var opensUnstampedPdfs = false
    private var ensuredDocumentIds: [String: String] = [:]

    func openFile(path: String, sessionId: String) async throws -> DocumentInfo {
        DocumentInfo(
            kind: .pdf, pdfPath: path, title: URL(fileURLWithPath: path).lastPathComponent,
            pageCount: 1, lastPage: 1,
            docId: opensUnstampedPdfs ? nil : UUID().uuidString.lowercased())
    }
    func openWebDocument(url: String, sessionId: String) async throws -> DocumentInfo {
        DocumentInfo(kind: .web, pdfPath: url, title: url, pageCount: 1, lastPage: 1)
    }
    func openVellumwebFile(path: String, sessionId: String) async throws -> DocumentInfo {
        try await openFile(path: path, sessionId: sessionId)
    }
    func saveFile(sessionId: String) async throws {}
    func closeFile(sessionId: String) async throws {}
    func readPdfBytes(sessionId: String) async throws -> Data { Data() }
    func setWebpageSaved(sessionId: String, saved: Bool) async throws {}
    func getWebpageSaved(sessionId: String) async throws -> Bool { false }
    func listSavedWebpages() async throws -> [WebLibraryEntry] { [] }
    func removeSavedWebpage(url: String) async throws {}
    func exportVellumweb(
        sessionId: String, destPath: String, pages: [WebPageText]
    ) async throws -> VellumwebExportSummary {
        VellumwebExportSummary(path: destPath, bytes: 0, assetCount: 0, assetsSkipped: 0)
    }
    func archiveWebpageDefault(
        sessionId: String, pages: [WebPageText], expectedUrl: String
    ) async throws -> Bool { false }
    func getAnnotations(sessionId: String, pageNumber: Int?) async throws -> [Annotation] { [] }
    func createAnnotation(
        sessionId: String, input: CreateAnnotationInput
    ) async throws -> Annotation { throw SessionServiceError.io("unused") }
    func updateAnnotation(sessionId: String, input: UpdateAnnotationInput) async throws -> Bool { false }
    func deleteAnnotation(sessionId: String, id: String) async throws -> Bool { false }
    func setDocumentMetadata(sessionId: String, key: String, value: String) async throws {}
    func ensureDocumentId(sessionId: String) async throws -> String {
        if let id = ensuredDocumentIds[sessionId] { return id }
        let id = UUID().uuidString.lowercased()
        ensuredDocumentIds[sessionId] = id
        return id
    }
}
