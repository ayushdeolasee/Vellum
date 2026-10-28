import Foundation
import Testing
@testable import Vellum
#if os(iOS)
import PencilKit
import UIKit
import WebKit
#endif

@Suite("EPUB passage handwriting", .serialized, .isolatedStorage, .scratchDefaults)
@MainActor
struct EpubHandwritingTests {
    private func environment(
        _ body: (EpubDocumentSession, EpubDocumentSession, URL) async throws -> Void
    ) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("epub-ink-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let oldRoot = DocumentDataStore.rootDirectoryOverride
        let oldBooks = EpubLibrary.directoryOverride
        let oldWeb = WebLibrary.storeDirOverride
        DocumentDataStore.rootDirectoryOverride = root.appendingPathComponent("documents")
        EpubLibrary.directoryOverride = root.appendingPathComponent("Books")
        WebLibrary.storeDirOverride = root.appendingPathComponent("web")
        defer {
            DocumentDataStore.rootDirectoryOverride = oldRoot
            EpubLibrary.directoryOverride = oldBooks
            WebLibrary.storeDirOverride = oldWeb
            try? FileManager.default.removeItem(at: root)
        }
        let url = try EpubFixture.epub2().write(to: root.appendingPathComponent("book.epub"))
        let backend = EpubSessionBackend()
        let first = try await backend.open(path: url.path, sessionId: "first")
        let second = try await backend.open(path: url.path, sessionId: "second")
        do {
            try await body(first, second, root)
            try await first.close(); try await second.close()
        } catch {
            try? await first.close(); try? await second.close()
            throw error
        }
    }

    private func passage(_ session: EpubDocumentSession, chapter: Int = 0) async throws -> EpubTextAnchor {
        let text = try await session.chapterText(spineIndex: chapter)
        return try #require(text.anchor(in: NSRange(location: 0, length: min(4, text.utf16Count))))
    }

    @Test("Drawing and fixed sheet survive a moved original without changing archive bytes")
    func roundTripAndIdentity() async throws {
        try await environment { first, second, root in
            let source = URL(fileURLWithPath: first.book.path)
            let original = try Data(contentsOf: source)
            let note = EpubHandwritingNote(anchor: try await passage(first), drawing: Data([1, 2, 3]))
            try await first.saveHandwriting(note)
            #expect(try await second.handwritingNotes() == [note])
            let moved = root.appendingPathComponent("renamed.epub")
            try FileManager.default.copyItem(at: source, to: moved)
            let reopened = try await EpubSessionBackend().open(path: moved.path, sessionId: "moved")
            #expect(reopened.info.docId == first.info.docId)
            #expect(try await reopened.handwritingNotes() == [note])
            #expect(try Data(contentsOf: source) == original)
            #expect(note.canvasWidth == 900 && note.canvasHeight == 1200)
            #expect(DocumentDataStore.notesBytes(forKey: first.book.docId) > 0)
            #expect(DocumentDataStore.listDocumentMetas().first?.hasUserData == true)
            try await reopened.close()
        }
    }

    @Test("Concurrent book sessions merge distinct notes and preserve drawings on reattachment")
    func concurrentMerge() async throws {
        try await environment { first, second, _ in
            let anchor = try await passage(first)
            let a = EpubHandwritingNote(anchor: anchor, drawing: Data([1]))
            let b = EpubHandwritingNote(anchor: anchor, drawing: Data([2]))
            async let one: Void = first.saveHandwriting(a)
            async let two: Void = second.saveHandwriting(b)
            _ = try await (one, two)
            #expect(Set(try await first.handwritingNotes().map(\.id)) == [a.id, b.id])
            var reattached = a
            reattached.anchor = try await passage(first, chapter: 1)
            try await first.saveHandwriting(reattached)
            #expect(try await second.handwritingNotes().first { $0.id == a.id }?.drawing == a.drawing)
            #expect(try await second.handwritingNotes().first { $0.id == a.id }?.anchor == reattached.anchor)
            try await second.deleteHandwriting(id: a.id)
            #expect(try await first.handwritingNotes() == [b])
        }
    }

    @Test("Unresolved imported anchors remain readable and editable until explicitly reattached")
    func unresolvedRecovery() async throws {
        try await environment { first, _, _ in
            let storage = EpubHandwritingStorage(document: first.info, coordinator: nil)
            var anchor = try await passage(first)
            anchor.quote = "This passage is no longer resolvable"
            anchor.startUTF16 = nil; anchor.endUTF16 = nil
            var note = EpubHandwritingNote(anchor: anchor, drawing: Data([9]))
            try await storage.save(note)
            #expect(try await first.resolveAnchor(anchor) == nil)
            #expect(try await first.handwritingNotes() == [note])
            note.drawing = Data([8, 7])
            try await first.saveHandwriting(note)
            #expect(try await first.handwritingNotes().first?.drawing == note.drawing)
            note.anchor = try await passage(first)
            try await first.saveHandwriting(note)
            #expect(try await first.resolveAnchor(note.anchor) != nil)
            #expect(try await first.handwritingNotes().first?.id == note.id)
        }
    }

    @Test("Malformed, unsupported and duplicate sidecars are preserved, not overwritten")
    func corruptSidecars() async throws {
        try await environment { first, _, _ in
            let note = EpubHandwritingNote(anchor: try await passage(first))
            let object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(note))
            let invalid = [
                Data("not json".utf8),
                try JSONSerialization.data(withJSONObject: ["version": 9, "docId": first.book.docId, "notes": []]),
                try JSONSerialization.data(withJSONObject: ["version": 1, "docId": "wrong", "notes": []]),
                try JSONSerialization.data(withJSONObject: ["version": 1, "docId": first.book.docId, "notes": [object, object]]),
            ]
            for bytes in invalid {
                try await DocumentDataStore.withEpubHandwriting(document: first.info, coordinator: nil) { _ in (bytes, ()) }
                await #expect(throws: (any Error).self) { try await first.saveHandwriting(note) }
                let retained = try await DocumentDataStore.withEpubHandwriting(document: first.info, coordinator: nil) { data in (nil, data) }
                #expect(retained == bytes)
            }
        }
    }

    @Test("New invalid anchors and out-of-bounds drawings cannot enter storage")
    func validation() async throws {
        try await environment { first, _, _ in
            var note = EpubHandwritingNote(anchor: try await passage(first))
            note.canvasWidth = .infinity
            await #expect(throws: (any Error).self) { try await first.saveHandwriting(note) }
            note.canvasWidth = 900
            note.drawing = Data(count: 4 * 1024 * 1024 + 1)
            await #expect(throws: (any Error).self) { try await first.saveHandwriting(note) }
            note.drawing = Data()
            note.anchor.quote = "not in the book"
            await #expect(throws: EpubAnnotationError.invalidAnchor) { try await first.saveHandwriting(note) }
            #expect(try await first.handwritingNotes().isEmpty)
        }
    }

    @Test("Note-count and sidecar-byte limits reject writes without truncation")
    func storageLimits() async throws {
        try await environment { first, _, _ in
            let anchor = try await passage(first)
            let notes = (0..<500).map { _ in EpubHandwritingNote(anchor: anchor) }
            let noteObjects = try JSONSerialization.jsonObject(with: JSONEncoder().encode(notes))
            let full = try JSONSerialization.data(withJSONObject: [
                "version": 1, "docId": first.book.docId, "notes": noteObjects,
            ])
            try await DocumentDataStore.withEpubHandwriting(document: first.info, coordinator: nil) { _ in (full, ()) }
            let extra = EpubHandwritingNote(anchor: anchor)
            await #expect(throws: EpubAnnotationError.limitExceeded) { try await first.saveHandwriting(extra) }
            #expect(try await first.handwritingNotes().count == 500)
            let oversized = Data(count: 32 * 1024 * 1024 + 1)
            try await DocumentDataStore.withEpubHandwriting(document: first.info, coordinator: nil) { _ in (oversized, ()) }
            await #expect(throws: EpubAnnotationError.limitExceeded) { try await first.saveHandwriting(extra) }
            let preserved = try await DocumentDataStore.withEpubHandwriting(document: first.info, coordinator: nil) { data in (nil, data?.count) }
            #expect(preserved == oversized.count)
        }
    }

    #if os(iOS)
    private func drawing() -> PKDrawing {
        var points: [PKStrokePoint] = []
        for index in 0...8 {
            let location = CGPoint(x: CGFloat(50 + index * 10), y: CGFloat(70 + index * 4))
            points.append(PKStrokePoint(location: location,
                timeOffset: Double(index) / 60, size: CGSize(width: 3, height: 3),
                opacity: 1, force: 1, azimuth: 0, altitude: .pi / 2))
        }
        return PKDrawing(strokes: [PKStroke(ink: PKInk(.pen, color: .black),
            path: PKStrokePath(controlPoints: points, creationDate: Date(timeIntervalSince1970: 0)))])
    }

    @Test("iPad intake is enabled explicitly; phone intake rejects EPUB without copying")
    func iPadIntake() async throws {
        try await environment { first, _, _ in
            #expect(DocumentImport.openableTypes(includeEpub: true).contains(.epub))
            #expect(!DocumentImport.openableTypes(includeEpub: false).contains(.epub))
            let url = URL(fileURLWithPath: first.book.path)
            let phone = DocumentImport.importPickedResult([url])
            #expect(phone.paths.isEmpty && !phone.errors.isEmpty)
            let iPad = DocumentImport.importPickedResult([url], supportsEpub: true)
            #expect(iPad.paths.count == 1 && iPad.errors.isEmpty)
            let repeated = DocumentImport.importPickedResult([url], supportsEpub: true)
            #expect(iPad.paths == repeated.paths)
            let importedId = try EpubIdentity.contentDocId(fileAt: URL(fileURLWithPath: iPad.paths[0]))
            #expect(importedId == first.book.docId)
        }
    }

    @Test("Pencil-only canvas, tools, fixed-coordinate reflow and drainable autosave")
    func pencilCanvas() async throws {
        try await environment { first, second, _ in
            let ink = EpubHandwritingController_iOS()
            ink.bind(session: first)
            #expect(await ink.flushPendingInkAndWait())
            await ink.create(anchor: try await passage(first))
            #expect(ink.isPresented && ink.activeNote != nil)
            #expect(ink.canvas.drawingPolicy == .pencilOnly)
            #expect(ink.canvas.panGestureRecognizer.allowedTouchTypes == [NSNumber(value: UITouch.TouchType.direct.rawValue)])
            ink.toolState.tool = .eraser
            #expect(ink.canvas.tool is PKEraserTool)
            ink.toolState.tool = .pen
            #expect(ink.canvas.tool is PKInkingTool)
            ink.canvas.drawing = drawing()
            ink.canvasViewDrawingDidChange(ink.canvas)
            #expect(await ink.flushPendingInkAndWait())
            let stored = try #require(try await second.handwritingNotes().first)
            #expect(try PKDrawing(data: stored.drawing).strokes.count == 1)
            let undo = try #require(ink.canvas.undoManager)
            undo.removeAllActions()
            undo.beginUndoGrouping()
            ink.clearCurrentPage()
            undo.endUndoGrouping()
            #expect(ink.canvas.drawing.strokes.isEmpty && ink.canUndo)
            ink.undo()
            #expect(ink.canvas.drawing.strokes.count == 1 && ink.canRedo)
            ink.redo()
            #expect(ink.canvas.drawing.strokes.isEmpty)
            ink.undo()
            for width: CGFloat in [900, 400, 700] {
                ink.canvas.frame = CGRect(x: 0, y: 0, width: width, height: 500)
                ink.canvas.setNeedsLayout(); ink.canvas.layoutIfNeeded()
                #expect(ink.canvas.drawing.strokes.count == 1)
                #expect(ink.canvas.drawing.bounds == drawing().bounds)
            }
            ink.readerActive = false
            await ink.open(stored)
            #expect(!ink.isPresented)
            #expect(ink.canvas.drawing.bounds == drawing().bounds)
            #expect(await ink.flushPendingInkAndWait())
        }
    }

    @Test("Reopening the same note drains edits before decoding its latest drawing")
    func reopenDirtyNote() async throws {
        try await environment { first, _, _ in
            let ink = EpubHandwritingController_iOS()
            ink.bind(session: first)
            #expect(await ink.flushPendingInkAndWait())
            await ink.create(anchor: try await passage(first))
            let oldSnapshot = try #require(ink.activeNote)
            ink.canvas.drawing = drawing()
            ink.canvasViewDrawingDidChange(ink.canvas)
            await ink.open(oldSnapshot)
            #expect(ink.canvas.drawing.strokes.count == 1)
            #expect(await ink.flushPendingInkAndWait())
        }
    }

    @Test("Failed autosave keeps live strokes for a later successful barrier")
    func failedSaveRetainsDraft() async throws {
        try await environment { first, second, _ in
            let ink = EpubHandwritingController_iOS()
            ink.bind(session: first)
            #expect(await ink.flushPendingInkAndWait())
            await ink.create(anchor: try await passage(first))
            ink.canvas.drawing = drawing()
            ink.canvasViewDrawingDidChange(ink.canvas)
            let original = try await DocumentDataStore.withEpubHandwriting(document: first.info, coordinator: nil) { data in (nil, data) }
            try await DocumentDataStore.withEpubHandwriting(document: first.info, coordinator: nil) { _ in (Data("corrupt".utf8), ()) }
            #expect(!(await ink.flushPendingInkAndWait()))
            #expect(ink.canvas.drawing.strokes.count == 1 && ink.notice != nil)
            try await DocumentDataStore.withEpubHandwriting(document: first.info, coordinator: nil) { _ in (original, ()) }
            #expect(await ink.flushPendingInkAndWait())
            let saved = try #require(try await second.handwritingNotes().first)
            #expect(try PKDrawing(data: saved.drawing).strokes.count == 1)
        }
    }

    @Test("Background and tab-close barriers drain drawings; failed close retains the reader for retry")
    func readerLifecycle() async throws {
        try await environment { first, _, _ in
            let manager = DocumentSessionManager()
            let workspace = WorkspaceStore(sessions: manager,
                positions: DocumentPositionService(storage: InMemoryPositionStorage()))
            let pane = workspace.focusedPane
            await pane.app.openFile(path: first.book.path)
            let binding = try #require(pane.app.activeDocumentBinding)
            let session = try #require(manager.documentSession(sessionId: binding.tabId) as? EpubDocumentSession)
            let reader = EpubReaderController()
            reader.bind(app: pane.app, ai: pane.ai, annotations: pane.annotations,
                scratchpad: pane.scratchpad, session: session, tabId: binding.tabId)
            reader.activate(true)
            #expect(await reader.drain())
            await reader.handwriting.create(anchor: try await passage(session))
            reader.handwriting.canvas.drawing = drawing()
            reader.handwriting.canvasViewDrawingDidChange(reader.handwriting.canvas)
            #expect(await workspace.flushLiveInk())
            let firstSave = try #require(try await first.handwritingNotes().first)
            #expect(try PKDrawing(data: firstSave.drawing).strokes.count == 1)
            reader.handwriting.canvas.drawing = PKDrawing(strokes: drawing().strokes + drawing().strokes)
            reader.handwriting.canvasViewDrawingDidChange(reader.handwriting.canvas)
            let original = try await DocumentDataStore.withEpubHandwriting(document: session.info, coordinator: nil) { data in (nil, data) }
            try await DocumentDataStore.withEpubHandwriting(document: session.info, coordinator: nil) { _ in (Data("corrupt".utf8), ()) }
            _ = workspace.liveTabRuntime(for: binding.tabId)
            await pane.app.closeFile()
            #expect(!(await workspace.tabTeardowns.awaitAll()))
            #expect(!reader.isCurrent && manager.documentSession(sessionId: binding.tabId) != nil)
            #expect(reader.handwriting.canvas.drawing.strokes.count == 2)
            try await DocumentDataStore.withEpubHandwriting(document: session.info, coordinator: nil) { _ in (original, ()) }
            #expect(await workspace.tabTeardowns.awaitAll())
            #expect(manager.documentSession(sessionId: binding.tabId) == nil)
            let closed = try #require(try await first.handwritingNotes().first)
            #expect(try PKDrawing(data: closed.drawing).strokes.count == 2)
            await workspace.awaitMaintenance()
            await AiPersistence.awaitPendingFlush(); await ScratchpadPersistence.awaitPendingFlush()
        }
    }
    #endif
}
