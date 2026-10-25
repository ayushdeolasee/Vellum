import Foundation
import Testing
@testable import Vellum

@Suite("EPUB annotation persistence", .serialized, .isolatedStorage)
@MainActor
struct EpubAnnotationTests {
    private func environment(
        fixture: ZipFixture = EpubFixture.epub2(),
        _ body: (EpubDocumentSession, EpubDocumentSession, URL) async throws -> Void
    ) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("epub-annotations-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let oldRoot = DocumentDataStore.rootDirectoryOverride
        let oldWeb = WebLibrary.storeDirOverride
        let oldBooks = EpubLibrary.directoryOverride
        DocumentDataStore.rootDirectoryOverride = root.appendingPathComponent("documents")
        WebLibrary.storeDirOverride = root.appendingPathComponent("web")
        EpubLibrary.directoryOverride = root.appendingPathComponent("Books")
        let suite = "epub-annotations-\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer {
            DocumentDataStore.rootDirectoryOverride = oldRoot
            WebLibrary.storeDirOverride = oldWeb
            EpubLibrary.directoryOverride = oldBooks
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: root)
        }
        try await AppDefaults.withDefaults(defaults) {
            let file = try fixture.write(to: root.appendingPathComponent("book.epub"))
            let backend = EpubSessionBackend()
            let first = try await backend.open(path: file.path, sessionId: "one")
            let second = try await backend.open(path: file.path, sessionId: "two")
            do {
                try await body(first, second, root)
                try await first.close()
                try await second.close()
            } catch {
                try? await first.close()
                try? await second.close()
                throw error
            }
        }
    }

    private func input(_ session: EpubDocumentSession, id: String = UUID().uuidString) async throws -> CreateAnnotationInput {
        let chapter = try await session.chapterText(spineIndex: 0)
        let anchor = try #require(chapter.anchor(in: NSRange(location: 0, length: 5)))
        return CreateAnnotationInput(
            type: .highlight, pageNumber: 1, color: "#123456", content: "note",
            positionData: PositionData(rects: [], pageWidth: 0, pageHeight: 0, epubAnchor: anchor), id: id)
    }

    @Test("Round trip, shared sessions, pin, update, delete and original archive bytes")
    func roundTrip() async throws {
        try await environment { first, second, _ in
            let file = URL(fileURLWithPath: first.book.path)
            let bytes = try Data(contentsOf: file)
            let created = try await first.createAnnotation(input(first, id: "a"))
            #expect(try await second.annotations(pageNumber: nil) == [created])
            #expect(try await second.annotations(pageNumber: 2).isEmpty)
            #expect(try await second.updateAnnotation(.init(id: "a", color: "blue", content: "edited", isPinned: true)))
            #expect(try await second.updateAnnotation(.init(id: "a", isPinned: false)))
            #expect(try await second.annotations(pageNumber: nil).first?.pinned == false)
            #expect(try await second.updateAnnotation(.init(id: "a", isPinned: true)))
            try await second.save()
            let updated = try #require(try await first.annotations(pageNumber: nil).first)
            #expect(updated.pinned && updated.content == "edited" && updated.color == "blue")
            try await first.close()
            let moved = file.deletingLastPathComponent().appendingPathComponent("moved.epub")
            try FileManager.default.copyItem(at: file, to: moved)
            let reopened = try await EpubSessionBackend().open(path: moved.path, sessionId: "reopen")
            do {
                #expect(try await reopened.annotations(pageNumber: nil) == [updated])
                #expect(try await reopened.deleteAnnotation(id: "a"))
                #expect(try await reopened.annotations(pageNumber: nil).isEmpty)
                #expect(try await !reopened.deleteAnnotation(id: "missing"))
                try await reopened.close()
            } catch { try? await reopened.close(); throw error }
            #expect(try Data(contentsOf: file) == bytes)
            #expect(try EpubIdentity.contentDocId(fileAt: file) == first.book.docId)
        }
    }

    @Test("Annotation writes preserve a renamed or explicitly cleared metadata title")
    func preservesRenamedTitle() async throws {
        try await environment { first, second, _ in
            _ = try await first.createAnnotation(input(first, id: "a"))
            let key = first.book.docId
            let renamed = await Task.detached {
                DocumentDataStore.setTitle(forKey: key, title: "Renamed book")
            }.value
            #expect(renamed)
            _ = try await second.createAnnotation(input(second, id: "b"))
            let renamedMeta = await Task.detached { DocumentDataStore.loadMeta(forKey: key) }.value
            #expect(renamedMeta?.title == "Renamed book")
            let cleared = await Task.detached {
                DocumentDataStore.setTitle(forKey: key, title: nil)
            }.value
            #expect(cleared)
            _ = try await first.createAnnotation(input(first, id: "c"))
            let clearedMeta = await Task.detached { DocumentDataStore.loadMeta(forKey: key) }.value
            #expect(clearedMeta != nil && clearedMeta?.title == nil)
        }
    }

    @Test("Concurrent sessions merge against latest records, including different-field updates")
    func concurrentEdits() async throws {
        try await environment { first, second, _ in
            let a = try await input(first, id: "a")
            let b = try await input(second, id: "b")
            async let one = first.createAnnotation(a)
            async let two = second.createAnnotation(b)
            _ = try await (one, two)
            async let pin = first.updateAnnotation(.init(id: "a", isPinned: true))
            async let edit = second.updateAnnotation(.init(id: "a", content: "new"))
            _ = try await (pin, edit)
            let records = try await first.annotations(pageNumber: nil)
            #expect(Set(records.map(\.id)) == ["a", "b"])
            #expect(records.first?.id == "a" && records.first?.pinned == true && records.first?.content == "new")
        }
    }

    @Test("Invalid create ranges and wrong chapters are rejected without sidecar writes")
    func invalidAnchors() async throws {
        try await environment { first, _, _ in
            var candidate = try await input(first)
            candidate.positionData?.epubAnchor?.startUTF16 = -1
            await #expect(throws: EpubAnnotationError.invalidAnchor) { try await first.createAnnotation(candidate) }
            candidate = try await input(first)
            candidate.positionData?.epubAnchor?.endUTF16 = Int.max
            await #expect(throws: EpubAnnotationError.invalidAnchor) { try await first.createAnnotation(candidate) }
            candidate = try await input(first)
            candidate.positionData?.epubAnchor?.endUTF16 = 0
            await #expect(throws: EpubAnnotationError.invalidAnchor) { try await first.createAnnotation(candidate) }
            candidate = try await input(first)
            candidate.positionData?.epubAnchor?.endUTF16 = nil
            await #expect(throws: EpubAnnotationError.invalidAnchor) { try await first.createAnnotation(candidate) }
            candidate = try await input(first)
            candidate.pageNumber = 2
            await #expect(throws: EpubAnnotationError.invalidAnchor) { try await first.createAnnotation(candidate) }
            candidate.pageNumber = 0
            await #expect(throws: EpubAnnotationError.invalidChapter) { try await first.createAnnotation(candidate) }
            candidate = try await input(first)
            candidate.positionData = nil
            await #expect(throws: EpubAnnotationError.invalidAnchor) { try await first.createAnnotation(candidate) }
            #expect(try await first.annotations(pageNumber: nil).isEmpty)
            #expect(!FileManager.default.fileExists(atPath: DocumentDataStore.documentDir(forKey: first.book.docId).path))
        }
    }

    @Test("Ambiguous existing records remain visible; ambiguous and surrogate-splitting creates fail")
    func ambiguousRecords() async throws {
        var fixture = EpubFixture.epub2()
        fixture.items.removeAll { $0.path == "OEBPS/a.html" }
        fixture.add("OEBPS/a.html", "<html><body><p>same same 😀</p></body></html>")
        try await environment(fixture: fixture) { first, _, _ in
            var candidate = try await input(first, id: "ambiguous")
            candidate.positionData?.epubAnchor = EpubTextAnchor(
                chapterHref: "OEBPS/a.html", quote: "same", prefix: "", suffix: "")
            await #expect(throws: EpubAnnotationError.invalidAnchor) { try await first.createAnnotation(candidate) }
            let now = "2026-10-24T00:00:00Z"
            let ambiguous = Annotation(
                id: "ambiguous", type: .highlight, pageNumber: 1, positionData: candidate.positionData,
                createdAt: now, updatedAt: now)
            _ = try await EpubAnnotationStorage(document: first.info, coordinator: nil).create(ambiguous)
            #expect(try await first.annotations(pageNumber: nil) == [ambiguous])
            #expect(try await first.updateAnnotation(.init(id: "ambiguous", isPinned: true)))
            let unchanged = try #require(try await first.annotations(pageNumber: nil).first)
            #expect(unchanged.positionData == ambiguous.positionData && unchanged.pinned)
            await #expect(throws: EpubAnnotationError.invalidAnchor) {
                try await first.updateAnnotation(.init(id: "ambiguous", positionData: candidate.positionData))
            }
            candidate.positionData?.epubAnchor = EpubTextAnchor(
                chapterHref: "OEBPS/a.html", quote: "😀", prefix: "", suffix: "", startUTF16: 11, endUTF16: 12)
            await #expect(throws: EpubAnnotationError.invalidAnchor) { try await first.createAnnotation(candidate) }
        }
    }

    @Test("Unique quote-only anchors canonicalize, unresolved existing records remain editable")
    func existingUnresolved() async throws {
        try await environment { first, _, _ in
            var candidate = try await input(first, id: "resolved")
            candidate.positionData?.epubAnchor?.startUTF16 = nil
            candidate.positionData?.epubAnchor?.endUTF16 = nil
            let created = try await first.createAnnotation(candidate)
            #expect(created.positionData?.epubAnchor?.startUTF16 == 0)
            var unresolved = created
            unresolved.id = "unresolved"
            unresolved.positionData?.epubAnchor?.quote = "not present"
            let storage = EpubAnnotationStorage(document: first.info, coordinator: nil)
            _ = try await storage.create(unresolved)
            #expect(try await first.resolveAnchor(try #require(unresolved.positionData?.epubAnchor)) == nil)
            #expect(try await first.annotations(pageNumber: nil).count == 2)
            #expect(try await first.updateAnnotation(.init(id: "unresolved", content: "still here", isPinned: true)))
            let record = try #require(try await first.annotations(pageNumber: nil).first)
            #expect(record.id == "unresolved" && record.positionData == unresolved.positionData)
        }
    }

    @Test("Annotation-only books are discovered and scratchpad/chat deletion preserves them")
    func inventoryAndPruning() async throws {
        try await environment { first, _, _ in
            _ = try await first.createAnnotation(input(first))
            let key = first.book.docId
            #expect(DocumentDataStore.notesBytes(forKey: key) > 0)
            #expect(DocumentDataStore.listDocuments().first?.notesBytes ?? 0 > 0)
            #expect(DocumentDataStore.listDocumentMetas().first?.hasUserData == true)
            try DocumentDataStore.saveScratchpad(forKey: key, text: "scratch")
            try DocumentDataStore.saveConversationsData(forKey: key, data: Data("[]".utf8))
            DocumentDataStore.deleteNotes(forKey: key)
            DocumentDataStore.deleteConversation(forKey: key)
            #expect(DocumentDataStore.hasDataFiles(forKey: key))
            #expect(try await first.annotations(pageNumber: nil).count == 1)
            #expect(DocumentDataStore.listDocumentMetas().first?.hasUserData == true)
        }
    }

    @Test("Malformed sidecars and duplicate IDs fail without replacing newer bytes")
    func failedWrites() async throws {
        try await environment { first, _, _ in
            let candidate = try await input(first, id: "a")
            _ = try await first.createAnnotation(candidate)
            let path = DocumentDataStore.documentDir(forKey: first.book.docId)
                .appendingPathComponent(DocumentDataStore.epubAnnotationsFilename)
            let original = try Data(contentsOf: path)
            await #expect(throws: EpubAnnotationError.duplicateID) { try await first.createAnnotation(candidate) }
            #expect(try Data(contentsOf: path) == original)
            await #expect(throws: EpubAnnotationError.limitExceeded) {
                try await first.updateAnnotation(.init(id: "a", content: String(repeating: "x", count: 4 * 1024 * 1024)))
            }
            #expect(try Data(contentsOf: path) == original)
            let corrupt = Data("not JSON".utf8)
            try corrupt.write(to: path)
            await #expect(throws: (any Error).self) { try await first.createAnnotation(candidate) }
            #expect(try Data(contentsOf: path) == corrupt)
        }
    }

    @Test("Read/write failure and a concurrently replaced sidecar never commit stale edits")
    func storageFailureAndConflict() async throws {
        try await environment { first, _, _ in
            _ = try await first.createAnnotation(input(first, id: "a"))
            let directory = DocumentDataStore.documentDir(forKey: first.book.docId)
            let path = directory.appendingPathComponent(DocumentDataStore.epubAnnotationsFilename)
            let original = try Data(contentsOf: path)
            let meta = directory.appendingPathComponent("meta.json")
            let metaBytes = try Data(contentsOf: meta)
            try FileManager.default.removeItem(at: meta)
            try FileManager.default.createDirectory(at: meta, withIntermediateDirectories: false)
            await #expect(throws: (any Error).self) {
                try await first.updateAnnotation(.init(id: "a", content: "must not commit"))
            }
            #expect(try Data(contentsOf: path) == original)
            try FileManager.default.removeItem(at: meta)
            try metaBytes.write(to: meta)
            let document = first.info
            let newer = Data("external newer bytes".utf8)
            await #expect(throws: LibraryFileError.retryable) {
                try await DocumentDataStore.withEpubAnnotations(document: document, coordinator: nil) { _ in
                    try newer.write(to: path, options: .atomic)
                    return (Data("stale bytes".utf8), true)
                }
            }
            #expect(try Data(contentsOf: path) == newer)
        }
    }

    @Test("save waits for already accepted writes")
    func saveDrains() async throws {
        try await environment { first, _, _ in
            let candidate = try await input(first, id: "saved")
            let gate = EpubAnnotationTestGate()
            let document = first.info
            let blocking = Task.detached {
                try await DocumentDataStore.withEpubAnnotations(document: document, coordinator: nil) { _ in
                    gate.block()
                    return (nil, true)
                }
            }
            await gate.waitUntilEntered()
            let write = Task { try await first.createAnnotation(candidate) }
            while first.pendingOperationCount == 0 { await Task.yield() }
            var started = false
            var finished = false
            let save = Task { started = true; try await first.save(); finished = true }
            while !started { await Task.yield() }
            #expect(!finished)
            gate.release()
            _ = try await blocking.value
            _ = try await write.value
            try await save.value
            #expect(finished && first.pendingOperationCount == 0)
            #expect(try await first.annotations(pageNumber: nil).map(\.id) == ["saved"])
        }
    }

    @Test("Sidecar JSON and caller-provided title preserve the downstream contracts")
    func sidecarAndTitleContract() async throws {
        try await environment { first, _, _ in
            let titled = EpubDocumentSession(book: first.book, titleOverride: "My renamed title")
            #expect(titled.info.title == "My renamed title" && titled.info.titleIsUserDefined == true)
            #expect(first.info.title == "Old Book" && first.info.titleIsUserDefined != true)
            try await titled.close()
            _ = try await first.createAnnotation(input(first, id: "contract"))
            let path = DocumentDataStore.documentDir(forKey: first.book.docId)
                .appendingPathComponent(DocumentDataStore.epubAnnotationsFilename)
            let json = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: path)) as? [String: Any])
            #expect(json["doc_id"] as? String == first.book.docId && json["version"] as? Int == 1)
            let annotation = try #require((json["annotations"] as? [[String: Any]])?.first)
            #expect(annotation["page_number"] as? Int == 1)
            let position = try #require(annotation["position_data"] as? [String: Any])
            let anchor = try #require(position["epub_anchor"] as? [String: Any])
            #expect(anchor["chapter_href"] as? String == "OEBPS/a.html")
            #expect(anchor["start_utf16"] as? Int == 0 && anchor["end_utf16"] as? Int == 5)
        }
    }

    @Test("Cancelled queued mutations do not write; close drains accepted mutations")
    func cancellationAndClose() async throws {
        try await environment { first, second, _ in
            let candidate = try await input(first, id: "cancelled")
            let gate = EpubAnnotationTestGate()
            let firstDocument = first.info
            let holder = Task.detached {
                try await DocumentDataStore.withEpubAnnotations(document: firstDocument, coordinator: nil) { _ in
                    gate.block()
                    return (nil, true)
                }
            }
            await gate.waitUntilEntered()
            let cancelled = Task { try await first.createAnnotation(candidate) }
            while first.pendingOperationCount == 0 { await Task.yield() }
            cancelled.cancel()
            gate.release()
            _ = try await holder.value
            await #expect(throws: CancellationError.self) { try await cancelled.value }
            #expect(try await first.annotations(pageNumber: nil).isEmpty)

            let drainingGate = EpubAnnotationTestGate()
            let document = second.info
            let blocking = Task.detached {
                try await DocumentDataStore.withEpubAnnotations(document: document, coordinator: nil) { _ in
                    drainingGate.block()
                    return (nil, true)
                }
            }
            await drainingGate.waitUntilEntered()
            var accepted = candidate
            accepted.id = "drained"
            let write = Task { try await second.createAnnotation(accepted) }
            while second.pendingOperationCount == 0 { await Task.yield() }
            var didClose = false
            let close = Task { try await second.close(); didClose = true }
            while (try? await second.ensureDocumentId()) != nil { await Task.yield() }
            #expect(!didClose)
            drainingGate.release()
            _ = try await blocking.value
            _ = try await write.value
            try await close.value
            #expect(second.pendingOperationCount == 0)
            #expect(try await first.annotations(pageNumber: nil).map(\.id) == ["drained"])
            await #expect(throws: SessionServiceError.self) { try await second.createAnnotation(accepted) }
        }
    }

    @Test("Injected coordinator resolves the existing custom-mode document layout")
    func coordinatorRouting() async throws {
        try await environment { first, _, root in
            let oldRoot = DocumentDataStore.rootDirectoryOverride
            let oldCustom = WebStorageSettings.customRootOverride
            DocumentDataStore.rootDirectoryOverride = nil
            WebStorageSettings.customRootOverride = root
            defer {
                DocumentDataStore.rootDirectoryOverride = oldRoot
                WebStorageSettings.customRootOverride = oldCustom
            }
            let store = root.appendingPathComponent("selected/web")
            let coordinator = StorageCoordinator(
                storeDir: store, modeProvider: { .custom }, effectiveModeProvider: { .custom },
                containerFactory: { nil })
            await coordinator.start()
            let backend = EpubSessionBackend(coordinator: coordinator)
            let session = try await backend.open(path: first.book.path, sessionId: "coordinated")
            do {
                _ = try await session.createAnnotation(input(session))
                let directory = root.appendingPathComponent("selected/documents/\(session.book.docId)")
                #expect(FileManager.default.fileExists(atPath: directory
                    .appendingPathComponent(DocumentDataStore.epubAnnotationsFilename).path))
                #expect(try await DocumentDataStore.listDocumentMetas(coordinator: coordinator).first?.hasUserData == true)
                #expect(await DocumentDataStore.listDocuments(coordinator: coordinator).first?.notesBytes ?? 0 > 0)
                try await session.close()
            } catch { try? await session.close(); await coordinator.stop(); throw error }
            await coordinator.stop()
        }
    }
}

private final class EpubAnnotationTestGate: @unchecked Sendable {
    private let condition = NSCondition()
    private var entered = false
    private var released = false

    func block() {
        condition.lock()
        entered = true
        condition.broadcast()
        while !released { condition.wait() }
        condition.unlock()
    }

    func release() {
        condition.lock()
        released = true
        condition.broadcast()
        condition.unlock()
    }

    private func hasEntered() -> Bool {
        condition.lock()
        defer { condition.unlock() }
        return entered
    }

    func waitUntilEntered() async {
        while !hasEntered() { await Task.yield() }
    }
}
