import XCTest
@testable import Vellum

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
        sessions = SafeClearSessionService()
        app = AppStore(sessions: sessions)
    }

    override func tearDown() async throws {
        await AiPersistence.awaitPendingFlush()
        DocumentDataStore.rootDirectoryOverride = nil
        ScratchpadAttachmentStore.directoryOverride = nil
        ScratchpadAttachmentStore.activeDirectory = nil
        try? FileManager.default.removeItem(at: root)
    }

    private func open(_ path: String) async -> DocumentInfo {
        await app.openFile(path: path)
        return app.document!
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
        let store = ScratchpadStore()
        store.app = app
        let document = await open("/tmp/safe-note-\(UUID().uuidString).pdf")
        store.loadForDocument(document)
        let bytes = Data([0x89, 0x50, 0x4e, 0x47, 1, 2, 3])
        let id = try XCTUnwrap(ScratchpadAttachmentStore.save(data: bytes, fileExtension: "png"))
        let attachment = try XCTUnwrap(ScratchpadAttachmentStore.fileURL(for: id))
        store.text = "old note\n\n![image](vellum-scratchpad://\(id))"
        store.flush()

        let transaction = try XCTUnwrap(store.clearText())
        store.flush()
        XCTAssertFalse(FileManager.default.fileExists(atPath: attachment.path))
        store.text = "new work"
        store.flush()

        let restoration = try XCTUnwrap(store.undoClear(transaction))
        XCTAssertTrue(store.text.hasSuffix("new work"))
        let restoredAttachment = try XCTUnwrap(
            ScratchpadAttachmentStore.fileURL(
                for: id, preferredDir: DocumentDataStore.attachmentsDir(forKey: transaction.key)))
        XCTAssertEqual(try Data(contentsOf: restoredAttachment), bytes)

        XCTAssertTrue(store.redoClear(restoration))
        XCTAssertEqual(store.text, "new work")
        XCTAssertFalse(FileManager.default.fileExists(atPath: restoredAttachment.path))
    }

    func testScratchpadUndoForADoesNotReplaceVisibleB() async throws {
        let store = ScratchpadStore()
        store.app = app
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
        XCTAssertEqual(ScratchpadPersistence.load(forKey: transaction.key), "A note")
        XCTAssertEqual(
            ScratchpadPersistence.load(
                forKey: DocumentIdentity.storageKey(for: documentB)),
            "B note")
    }

    func testAiClearFollowsSameSessionStampForUndoAndRedo() async throws {
        sessions.opensUnstampedPdfs = true
        let store = AiStore()
        store.app = app
        let original = await open("/tmp/safe-clear-unstamped-ai-\(UUID().uuidString).pdf")
        XCTAssertNil(original.docId)
        let oldKey = DocumentIdentity.storageKey(for: original)
        store.loadConversationForDocument(original)
        store.addLocalMessage(role: .user, content: "old question", id: "old-question")
        let transaction = try XCTUnwrap(store.clearConversation())

        // This is the first post-clear work path: it stamps the already-open
        // PDF and moves active persistence to the stable doc-ID key.
        let sessionId = try XCTUnwrap(app.activeTabId)
        await app.syncDocumentId(sessionId: sessionId)
        let stamped = try XCTUnwrap(app.document)
        let stampedKey = try XCTUnwrap(stamped.docId)
        XCTAssertNotEqual(stampedKey, oldKey)
        store.loadConversationForDocument(stamped)
        store.addLocalMessage(role: .user, content: "new work", id: "new-work")

        XCTAssertTrue(store.undoClear(transaction))
        XCTAssertEqual(store.messages.map(\.content), ["old question", "new work"])
        await AiPersistence.awaitPendingFlush()
        XCTAssertEqual(AiPersistence.loadConversation(for: stamped).map(\.content), ["old question", "new work"])
        XCTAssertTrue(DocumentDataStore.conversationsExist(forKey: stampedKey))
        XCTAssertFalse(DocumentDataStore.conversationsExist(forKey: oldKey))

        XCTAssertTrue(store.redoClear(transaction))
        XCTAssertEqual(store.messages.map(\.content), ["new work"])
        await AiPersistence.awaitPendingFlush()
        XCTAssertEqual(AiPersistence.loadConversation(for: stamped).map(\.content), ["new work"])
        XCTAssertTrue(DocumentDataStore.conversationsExist(forKey: stampedKey))
        XCTAssertFalse(DocumentDataStore.conversationsExist(forKey: oldKey))
    }

    func testScratchpadClearFollowsSameSessionStampForUndoRedoAndAttachments() async throws {
        sessions.opensUnstampedPdfs = true
        let store = ScratchpadStore()
        store.app = app
        let original = await open("/tmp/safe-clear-unstamped-note-\(UUID().uuidString).pdf")
        XCTAssertNil(original.docId)
        let oldKey = DocumentIdentity.storageKey(for: original)
        store.loadForDocument(original)
        let bytes = Data([0x89, 0x50, 0x4e, 0x47, 1, 2, 3])
        let id = try XCTUnwrap(ScratchpadAttachmentStore.save(data: bytes, fileExtension: "png"))
        store.text = "old note\n\n![image](vellum-scratchpad://\(id))"
        store.flush()
        let transaction = try XCTUnwrap(store.clearText())
        store.text = "new work"
        store.flush()

        // Simulate the first post-clear write acquiring the durable ID before
        // Undo is invoked; the store must rekey the note and sidecar bytes.
        let sessionId = try XCTUnwrap(app.activeTabId)
        await app.syncDocumentId(sessionId: sessionId)
        let stamped = try XCTUnwrap(app.document)
        let stampedKey = try XCTUnwrap(stamped.docId)
        XCTAssertNotEqual(stampedKey, oldKey)
        let oldAttachment = DocumentDataStore.attachmentsDir(forKey: oldKey)
            .appendingPathComponent("\(id).png")
        let stampedAttachment = DocumentDataStore.attachmentsDir(forKey: stampedKey)
            .appendingPathComponent("\(id).png")

        let restoration = try XCTUnwrap(store.undoClear(transaction))
        XCTAssertEqual(store.text, "old note\n\n![image](vellum-scratchpad://\(id))\n\nnew work")
        XCTAssertEqual(ScratchpadPersistence.load(forKey: stampedKey), store.text)
        XCTAssertTrue(FileManager.default.fileExists(atPath: stampedAttachment.path))
        XCTAssertEqual(try Data(contentsOf: stampedAttachment), bytes)
        XCTAssertFalse(DocumentDataStore.scratchpadExists(forKey: oldKey))
        XCTAssertFalse(FileManager.default.fileExists(atPath: oldAttachment.path))

        XCTAssertTrue(store.redoClear(restoration))
        XCTAssertEqual(store.text, "new work")
        XCTAssertEqual(ScratchpadPersistence.load(forKey: stampedKey), "new work")
        XCTAssertFalse(FileManager.default.fileExists(atPath: stampedAttachment.path))
        XCTAssertFalse(DocumentDataStore.scratchpadExists(forKey: oldKey))
        XCTAssertFalse(FileManager.default.fileExists(atPath: oldAttachment.path))
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
