#if os(iOS)
import Observation
import PencilKit
import SwiftUI
import UIKit

@MainActor @Observable
final class EpubHandwritingController_iOS: NSObject, InkPaletteHost, PKCanvasViewDelegate {
    let toolState = InkToolState()
    let canvas = EpubNoteCanvas_iOS()
    private(set) var notes: [EpubHandwritingNote] = []
    private(set) var unresolved: Set<String> = []
    private(set) var activeNote: EpubHandwritingNote?
    private(set) var isLoading = false
    var isActive = true
    var isPresented = false
    var listPresented = false
    var readerActive = true
    var notice: String?
    private var session: EpubDocumentSession?
    private var revision = 0
    private var savedRevision = 0
    private var restoring = false
    private var opening = UUID()
    private var loading: Task<Void, Never>?
    private var debounce: Task<Void, Never>?
    private var writing: Task<Bool, Never>?

    var canUndo: Bool { _ = revision; return canvas.undoManager?.canUndo == true }
    var canRedo: Bool { _ = revision; return canvas.undoManager?.canRedo == true }

    override init() {
        super.init()
        canvas.delegate = self
        canvas.drawingPolicy = .pencilOnly
        canvas.backgroundColor = .white
        canvas.overrideUserInterfaceStyle = .light
        canvas.panGestureRecognizer.allowedTouchTypes = [NSNumber(value: UITouch.TouchType.direct.rawValue)]
        canvas.accessibilityIdentifier = "epub.handwriting.canvas"
        canvas.contentSize = CGSize(width: 900, height: 1200)
        canvas.maximumZoomScale = 3
        canvas.tool = toolState.pkTool(widthScale: 1)
        toolState.onToolChanged = { [weak self] in
            guard let self else { return }
            canvas.tool = toolState.pkTool(widthScale: 1)
        }
        toolState.onPolicyChanged = { [weak self] in
            guard let self else { return }
            canvas.drawingPolicy = toolState.allowFingerDrawing ? .anyInput : .pencilOnly
            canvas.panGestureRecognizer.minimumNumberOfTouches = toolState.allowFingerDrawing ? 2 : 1
        }
    }

    func bind(session: EpubDocumentSession) {
        guard self.session == nil else { return }
        self.session = session
        isLoading = true
        loading = Task { [self] in
            defer { isLoading = false; loading = nil }
            do {
                notes = try await session.handwritingNotes()
                for note in notes {
                    if try await session.resolveAnchor(note.anchor) == nil { unresolved.insert(note.id) }
                }
            } catch { notice = error.localizedDescription }
        }
    }

    func create(anchor: EpubTextAnchor) async {
        guard !isLoading, let session, await flushPendingInkAndWait() else { return }
        do {
            guard let canonical = try await session.resolveAnchor(anchor) else { throw EpubAnnotationError.invalidAnchor }
            let note = EpubHandwritingNote(anchor: canonical)
            try await session.saveHandwriting(note)
            notes.insert(note, at: 0)
            await open(note)
        } catch { notice = error.localizedDescription }
    }

    func open(_ note: EpubHandwritingNote) async {
        guard await flushPendingInkAndWait() else { return }
        guard let note = notes.first(where: { $0.id == note.id }) else { return }
        let generation = UUID(); opening = generation
        do {
            let decoding = Task.detached(priority: .userInitiated) {
                note.drawing.isEmpty ? PKDrawing() : try PKDrawing(data: note.drawing)
            }
            let drawing = try await decoding.value
            guard opening == generation else { return }
            restoring = true
            activeNote = note
            canvas.drawing = drawing
            canvas.contentSize = CGSize(width: note.canvasWidth, height: note.canvasHeight)
            canvas.sheetWidth = note.canvasWidth
            canvas.resetFit()
            canvas.undoManager?.removeAllActions()
            revision = 0; savedRevision = 0
            restoring = false
            isActive = true; isPresented = readerActive; notice = nil
        } catch {
            restoring = false
            notice = "This drawing could not be read. Its original bytes have been kept unchanged."
        }
    }

    func reattach(id: String, to anchor: EpubTextAnchor) async {
        guard let session, await flushPendingInkAndWait(),
              var note = notes.first(where: { $0.id == id }) else { return }
        do {
            guard let canonical = try await session.resolveAnchor(anchor) else { throw EpubAnnotationError.invalidAnchor }
            note.anchor = canonical; note.updatedAt = Date()
            try await session.saveHandwriting(note)
            replace(note)
            if activeNote?.id == id { activeNote = note }
            unresolved.remove(id)
        } catch { notice = error.localizedDescription }
    }

    func delete(id: String) async {
        guard let session, await flushPendingInkAndWait() else { return }
        do {
            try await session.deleteHandwriting(id: id)
            notes.removeAll { $0.id == id }; unresolved.remove(id)
            if activeNote?.id == id { activeNote = nil; isPresented = false }
        } catch { notice = error.localizedDescription }
    }

    func canvasViewDrawingDidChange(_ canvasView: PKCanvasView) {
        guard !restoring, activeNote != nil else { return }
        revision += 1
        debounce?.cancel()
        debounce = Task { [self] in
            do { try await Task.sleep(for: .milliseconds(500)) } catch { return }
            _ = await flushPendingInkAndWait()
        }
    }

    func undo() { canvas.undoManager?.undo(); canvasViewDrawingDidChange(canvas) }
    func redo() { canvas.undoManager?.redo(); canvasViewDrawingDidChange(canvas) }

    func clearCurrentPage() {
        restoreDrawing(PKDrawing())
    }

    private func restoreDrawing(_ drawing: PKDrawing) {
        let previous = canvas.drawing
        canvas.undoManager?.registerUndo(withTarget: self) { target in
            MainActor.assumeIsolated { target.restoreDrawing(previous) }
        }
        canvas.drawing = drawing
        canvasViewDrawingDidChange(canvas)
    }

    func done() { isActive = false }

    func flushPendingInkAndWait() async -> Bool {
        debounce?.cancel(); debounce = nil
        await loading?.value
        for _ in 0..<8 {
            if let writing {
                guard await writing.value else { return false }
                continue
            }
            guard savedRevision != revision, var note = activeNote, let session else { return true }
            let savingRevision = revision
            note.updatedAt = Date()
            let metadata = note
            let drawing = canvas.drawing
            writing = Task { [self] in
                defer { writing = nil }
                do {
                    let encoding = Task.detached(priority: .utility) { drawing.dataRepresentation() }
                    var snapshot = metadata
                    snapshot.drawing = await encoding.value
                    try await session.saveHandwriting(snapshot)
                    replace(snapshot)
                    if activeNote?.id == snapshot.id { activeNote = snapshot; savedRevision = savingRevision }
                    notice = nil
                    return true
                } catch { notice = "Handwriting is not saved: \(error.localizedDescription)"; return false }
            }
        }
        notice = "Handwriting is still being saved. Try again before closing this book."
        return false
    }

    private func replace(_ note: EpubHandwritingNote) {
        if let index = notes.firstIndex(where: { $0.id == note.id }) { notes[index] = note }
    }
}

final class EpubNoteCanvas_iOS: PKCanvasView {
    private let noteUndoManager = UndoManager()
    override var undoManager: UndoManager? { noteUndoManager }
    var sheetWidth: Double = 900
    private var fittedWidth: CGFloat = 0

    func resetFit() { fittedWidth = 0; setNeedsLayout() }

    override func layoutSubviews() {
        super.layoutSubviews()
        guard bounds.width > 0, fittedWidth != bounds.width else { return }
        let wasFitted = fittedWidth == 0 || abs(zoomScale - minimumZoomScale) < 0.01
        fittedWidth = bounds.width
        minimumZoomScale = min(1, bounds.width / sheetWidth)
        if wasFitted { zoomScale = minimumZoomScale }
    }
}

private struct EpubNoteCanvasSurface_iOS: UIViewRepresentable {
    let ink: EpubHandwritingController_iOS
    func makeUIView(context: Context) -> EpubNoteCanvas_iOS { ink.canvas }
    func updateUIView(_ view: EpubNoteCanvas_iOS, context: Context) {
        view.tool = ink.toolState.pkTool(widthScale: 1)
    }
}

struct EpubHandwritingSheet_iOS: View {
    let ink: EpubHandwritingController_iOS
    let close: () -> Void

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                if let note = ink.activeNote {
                    Text(note.anchor.quote).font(.callout).lineLimit(3).padding()
                    if ink.unresolved.contains(note.id) {
                        Text("Passage not found. The drawing is safe; reattach it from Handwriting.")
                            .font(.caption).foregroundStyle(.secondary).padding(.horizontal)
                    }
                }
                EpubNoteCanvasSurface_iOS(ink: ink)
                InkToolPalette_iOS(host: ink, onDone: close).padding(8)
                if let notice = ink.notice { Text(notice).font(.caption).padding(8) }
            }
            .navigationTitle("Passage Handwriting")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done", action: close) } }
        }
        .presentationDetents([.large])
    }
}
#endif
