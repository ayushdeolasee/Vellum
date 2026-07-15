#if os(iOS)
import Observation
import PDFKit
import PencilKit
import SwiftUI
import UIKit

/// The Pencil ink tool. Highlighter is a translucent marker; pen is opaque.
enum InkTool: String, CaseIterable, Sendable {
    case pen, highlighter, eraser
}

/// Ink colors (Scriptorium-aligned). Pen inks are saturated; highlighter reuses
/// the highlight palette.
enum InkPalette {
    static let penColors: [Color] = [
        Color(hex: "#000000"), // true black (matches Notes)
        Color(hex: "#45418f"), // indigo (brand)
        Color(hex: "#b23a30"), // red
        Color(hex: "#1f6f43"), // green
        Color(hex: "#1f5fa8"), // blue
    ]
    static let highlighterColors: [Color] = HIGHLIGHT_COLORS.map { Color(hex: $0.value) }
}

/// What a double-tap on the Apple Pencil does. The user picks this in Settings
/// (it overrides the system-wide Pencil preference, which iPadOS otherwise
/// reserves for its own tools). Persisted as a raw string in UserDefaults.
enum PencilDoubleTapAction: String, CaseIterable, Sendable {
    /// Toggle the eraser: switch to it, or back to the previous tool if already erasing.
    case eraser
    /// Switch to the previously used tool (e.g. flip between pen and highlighter).
    case lastTool

    static let defaultsKey = "pencilDoubleTapAction"

    static func current() -> PencilDoubleTapAction {
        UserDefaults.standard.string(forKey: defaultsKey)
            .flatMap(PencilDoubleTapAction.init(rawValue:)) ?? .eraser
    }

    var label: String {
        switch self {
        case .eraser: "Switch to eraser"
        case .lastTool: "Switch to last tool"
        }
    }
}

/// Eraser behavior: `.pixel` (bitmap) erases only the ink under the pixels the
/// eraser passes over; `.object` (vector) erases an entire stroke as soon as
/// the eraser touches any point on it — GoodNotes calls these "Pixel" and
/// "Object" erasers.
enum EraserMode: String, Codable, Sendable {
    case pixel, object
}

/// GoodNotes-style per-tool width presets: three slots per tool, one selected
/// slot, plus the eraser mode — persisted together as a single JSON blob so a
/// relaunch restores the exact palette state.
struct InkWidthSettings: Codable, Equatable {
    var penWidths: [CGFloat] = [2, 4, 8]
    var highlighterWidths: [CGFloat] = [12, 20, 30]
    var eraserWidths: [CGFloat] = [12, 24, 40]
    var penSlot: Int = 0
    var highlighterSlot: Int = 0
    var eraserSlot: Int = 0
    var eraserMode: EraserMode = .pixel

    static let defaultsKey = "ink.widthSettings.v1"

    static func loadFromDefaults() -> InkWidthSettings {
        guard let data = UserDefaults.standard.data(forKey: defaultsKey),
              let decoded = try? JSONDecoder().decode(InkWidthSettings.self, from: data)
        else { return InkWidthSettings() }
        return decoded
    }

    func saveToDefaults() {
        guard let data = try? JSONEncoder().encode(self) else { return }
        UserDefaults.standard.set(data, forKey: Self.defaultsKey)
    }
}

/// Owns Pencil ink state and coordinates the live canvas with the display
/// document (native `/Ink` rendering) and the on-disk PDF (durable persistence).
@MainActor
@Observable
final class InkController_iOS {
    var isActive = false {
        didSet {
            guard oldValue != isActive else { return }
            #if DEBUG
            NSLog("[ink-debug] isActive -> %d (currentPage=%d)",
                  isActive ? 1 : 0, app?.currentPage ?? -1)
            #endif
            if isActive {
                // Focused inking: collapse the inspector sidebar so the full
                // tool palette fits the document column (it overflows the
                // narrowed column otherwise). Restore the prior state on Done.
                // Opt-out via the "auto-hide sidebar while inking" setting.
                if Self.autoHideSidebarWhileInking {
                    sidebarWasOpen = app?.workspace?.sidebarOpen ?? false
                    app?.workspace?.sidebarOpen = false
                }
            } else {
                // Turning ink off can't lose the last stroke: write any pending
                // debounced ink right now (the canvas keeps rendering regardless).
                flushPendingInk()
                if sidebarWasOpen {
                    sidebarWasOpen = false
                    app?.workspace?.sidebarOpen = true
                }
            }
            inkProvider.refreshPolicies()
        }
    }
    /// Whether the inspector sidebar was open when inking began, so Done can
    /// restore it (inking auto-collapses it for a full-width palette).
    @ObservationIgnored private var sidebarWasOpen = false

    /// User preference: whether entering Pencil ink mode auto-collapses the
    /// inspector sidebar to give the tool palette the full document width.
    /// Defaults to on. Persisted under `autoHideSidebarKey`.
    static let autoHideSidebarKey = "autoHideSidebarWhileInking"
    static var autoHideSidebarWhileInking: Bool {
        UserDefaults.standard.object(forKey: autoHideSidebarKey) as? Bool ?? true
    }
    var tool: InkTool = .pen {
        didSet {
            guard oldValue != tool else { return }
            previousTool = oldValue
            bumpTool()
        }
    }
    var penColor: Color = InkPalette.penColors[0]
    var highlighterColor: Color = InkPalette.highlighterColors[0]
    /// Per-tool width slots, selected slot, and eraser mode — persisted as one
    /// JSON blob (see `InkWidthSettings`).
    var widthSettings: InkWidthSettings = InkWidthSettings.loadFromDefaults() {
        didSet {
            guard oldValue != widthSettings else { return }
            widthSettings.saveToDefaults()
        }
    }
    /// When false (default) only the Pencil draws; a finger scrolls/zooms.
    var allowFingerDrawing = false {
        didSet {
            guard oldValue != allowFingerDrawing else { return }
            inkProvider.refreshPolicies()
            bumpTool()
        }
    }

    /// The PDFKit overlay provider: one live `PKCanvasView` per page.
    @ObservationIgnored let inkProvider = InkOverlayProvider_iOS()

    init() {
        inkProvider.ink = self
    }

    /// Bumped when tool/color/width change so the canvas re-reads the PKTool.
    private(set) var toolVersion = 0
    /// Bumped on every drawing mutation so undo/redo button state re-renders
    /// (UndoManager itself is not observable).
    private(set) var drawingVersion = 0
    /// The tool in use before the last switch — the Pencil double-tap target.
    @ObservationIgnored private var previousTool: InkTool = .eraser

    @ObservationIgnored weak var pdfController: PdfViewerControlleriOS?
    @ObservationIgnored weak var app: AppStore?

    /// The cached canvas for a given 1-based page (via the overlay provider).
    func canvas(forPage n: Int) -> PKCanvasView? { inkProvider.canvas(forPage: n) }
    /// The canvas for the current page — undo/redo/clear target it.
    var currentCanvas: PKCanvasView? { canvas(forPage: app?.currentPage ?? 0) }

    func undo() { currentCanvas?.undoManager?.undo() }
    func redo() { currentCanvas?.undoManager?.redo() }
    var canUndo: Bool {
        _ = drawingVersion
        return currentCanvas?.undoManager?.canUndo ?? false
    }
    var canRedo: Bool {
        _ = drawingVersion
        return currentCanvas?.undoManager?.canRedo ?? false
    }

    /// Apple Pencil double-tap: follow the user's in-app choice (Settings ▸
    /// Pencil), which overrides the system-wide preference iPadOS reports.
    func pencilDoubleTap(preferredAction: UIPencilPreferredAction) {
        switch PencilDoubleTapAction.current() {
        case .eraser:
            tool = tool == .eraser ? previousTool : .eraser
        case .lastTool:
            tool = previousTool
        }
    }

    /// Clear the current page's ink (undoable).
    func clearCurrentPage() {
        guard let canvas = currentCanvas, let page = app?.currentPage, page >= 1 else { return }
        canvas.drawing = PKDrawing()
        drawingChanged(PKDrawing(), page: page)
    }

    /// Debounce state per page — each page's canvas persists independently, so
    /// inking two pages inside one debounce window must not drop either write.
    @ObservationIgnored private var persistTasks: [Int: Task<Void, Never>] = [:]
    @ObservationIgnored private var pendingWrites: [Int: (data: Data, path: String)] = [:]
    /// Retains the active immediate flush. Backgrounding joins this exact task
    /// instead of seeing emptied dictionaries and ending its assertion while a
    /// previously launched PDF rewrite is still running.
    @ObservationIgnored private var flushTask: Task<Void, Never>?

    var activeColor: Color {
        get { tool == .highlighter ? highlighterColor : penColor }
        set { if tool == .highlighter { highlighterColor = newValue } else { penColor = newValue } }
    }
    /// The three width presets for the active tool.
    var activeWidths: [CGFloat] {
        get {
            switch tool {
            case .pen: widthSettings.penWidths
            case .highlighter: widthSettings.highlighterWidths
            case .eraser: widthSettings.eraserWidths
            }
        }
        set {
            switch tool {
            case .pen: widthSettings.penWidths = newValue
            case .highlighter: widthSettings.highlighterWidths = newValue
            case .eraser: widthSettings.eraserWidths = newValue
            }
        }
    }
    /// The selected slot (0...2) for the active tool.
    var activeSlot: Int {
        get {
            switch tool {
            case .pen: widthSettings.penSlot
            case .highlighter: widthSettings.highlighterSlot
            case .eraser: widthSettings.eraserSlot
            }
        }
        set {
            switch tool {
            case .pen: widthSettings.penSlot = newValue
            case .highlighter: widthSettings.highlighterSlot = newValue
            case .eraser: widthSettings.eraserSlot = newValue
            }
        }
    }
    /// The current width for the active tool (its selected slot's value).
    var activeWidth: CGFloat {
        get {
            let widths = activeWidths
            let slot = activeSlot
            guard widths.indices.contains(slot) else { return widths.first ?? 4 }
            return widths[slot]
        }
        set {
            var widths = activeWidths
            let slot = activeSlot
            guard widths.indices.contains(slot) else { return }
            widths[slot] = newValue
            activeWidths = widths
        }
    }
    /// Set a specific slot's width for the active tool (used by the size
    /// popover, which edits a slot without necessarily selecting it first).
    func setWidth(_ width: CGFloat, forSlot slot: Int) {
        var widths = activeWidths
        guard widths.indices.contains(slot) else { return }
        widths[slot] = width
        activeWidths = widths
        bumpTool()
    }
    /// Select a width slot for the active tool (GoodNotes-style: tapping an
    /// unselected dot switches to it).
    func selectWidthSlot(_ slot: Int) {
        guard activeWidths.indices.contains(slot) else { return }
        activeSlot = slot
        bumpTool()
    }
    /// Cycle to the next width slot for the active tool (compact palette).
    func cycleWidthSlot() {
        let count = activeWidths.count
        guard count > 0 else { return }
        activeSlot = (activeSlot + 1) % count
        bumpTool()
    }
    /// The eraser's pixel-vs-object mode.
    var eraserMode: EraserMode {
        get { widthSettings.eraserMode }
        set { widthSettings.eraserMode = newValue }
    }

    func bumpTool() {
        toolVersion &+= 1
        inkProvider.applyTool()
    }

    /// A page canvas was seeded with existing ink — nudge observers (the
    /// sidebar's Handwriting chips) that consult the canvas cache.
    func noteSeededDrawing() {
        drawingVersion &+= 1
    }

    var pkTool: PKTool { pkTool(widthScale: 1) }

    /// The active PencilKit tool, with its width multiplied by `widthScale`. The
    /// ink canvases draw in a super-sampled space (see `InkOverlayProvider_iOS`),
    /// so each passes its own `K` here to keep the on-page stroke width equal to
    /// what the user selected regardless of the backing-store density.
    func pkTool(widthScale: CGFloat) -> PKTool {
        switch tool {
        case .pen:
            return PKInkingTool(.pen, color: UIColor(penColor), width: activeWidth * widthScale)
        case .highlighter:
            return PKInkingTool(.marker, color: UIColor(highlighterColor), width: activeWidth * widthScale)
        case .eraser:
            // Explicit width — the default reports 0 ("system default"), which
            // leaves the erase radius an unknown.
            switch eraserMode {
            case .pixel:
                return PKEraserTool(.bitmap, width: activeWidth * widthScale)
            case .object:
                return PKEraserTool(.vector, width: activeWidth * widthScale)
            }
        }
    }

    // MARK: - Editing lifecycle

    /// Live change on a page's canvas: bump undo/redo observability and debounce
    /// a durable write to disk. The canvas is the on-screen renderer, so there is
    /// no display-document mutation here.
    func drawingChanged(_ drawing: PKDrawing, page: Int) {
        drawingVersion &+= 1
        persist(drawing: drawing, page: page, debounce: true)
    }

    // MARK: - Persistence to the on-disk PDF

    /// Write all pending debounced ink immediately (no 700ms wait). Called when
    /// ink mode turns off so a fast app-kill can't drop the last strokes.
    func flushPendingInk() {
        _ = ensureFlushTask()
    }

    /// Cancel the debounce and wait until every pending page rewrite is durable.
    /// The scene-background task uses this before iPadOS is allowed to suspend
    /// the app, so a stroke made immediately before pressing Home cannot vanish.
    func flushPendingInkAndWait() async {
        // A stroke can arrive while an earlier flush is suspended in PDFKit.
        // Keep joining/draining until there is neither an active flush nor new
        // pending state.
        while let task = ensureFlushTask() {
            await task.value
        }
    }

    private func ensureFlushTask() -> Task<Void, Never>? {
        if let flushTask { return flushTask }
        guard !pendingWrites.isEmpty || !persistTasks.isEmpty else { return nil }
        let task = Task { [weak self] in
            guard let self else { return }
            await self.drainPendingInk()
            self.flushTask = nil
        }
        flushTask = task
        return task
    }

    private func drainPendingInk() async {
        while !pendingWrites.isEmpty || !persistTasks.isEmpty {
            let pending = pendingWrites
            let scheduled = Array(persistTasks.values)
            for task in scheduled { task.cancel() }
            persistTasks.removeAll()
            pendingWrites.removeAll()

            // Cancellation does not interrupt a writer that already passed its
            // debounce. Join those tasks before the background assertion ends;
            // writing the captured latest page state again is intentional and
            // leaves the newest drawing authoritative.
            for task in scheduled { await task.value }
            for (page, write) in pending {
                await Self.writer.write(data: write.data, page: page, path: write.path)
            }
        }
    }

    private func persist(drawing: PKDrawing, page: Int, debounce: Bool = false) {
        guard let path = app?.document?.pdfPath else { return }
        persistTasks[page]?.cancel()
        let data = drawing.dataRepresentation()
        pendingWrites[page] = (data, path)
        persistTasks[page] = Task { [weak self] in
            if debounce {
                try? await Task.sleep(for: .milliseconds(700))
                if Task.isCancelled { return }
            }
            await Self.writer.write(data: data, page: page, path: path)
            if Task.isCancelled { return }
            self?.pendingWrites.removeValue(forKey: page)
            self?.persistTasks.removeValue(forKey: page)
        }
    }

    /// Serializes every ink disk write: each write is a full read-modify-write
    /// of the PDF, so two pages persisting concurrently would clobber each
    /// other's strokes if they interleaved.
    private static let writer = InkDiskWriter()
}

/// Loads a FRESH copy of the on-disk PDF (so the highlight/note annotations
/// written by the atomic writer are preserved), replaces one page's ink, and
/// atomically writes it back. Every ink write is routed through the shared
/// `PdfFileGate` so it can never interleave with an annotation/metadata rewrite
/// of the same file (both are full read-modify-writes; interleaving would lose
/// one side's changes). The gate also runs the PDFKit mutation + write off the
/// main thread.
struct InkDiskWriter {
    func write(data: Data, page: Int, path: String) async {
        await PdfFileGate.shared.perform {
            Self.writeSync(data: data, page: page, path: path)
        }
    }

    private static func writeSync(data: Data, page: Int, path: String) {
        let url = URL(fileURLWithPath: path)
        guard let originalData = try? Data(contentsOf: url),
              let document = PDFDocument(data: originalData),
              page >= 1, page <= document.pageCount,
              let pdfPage = document.page(at: page - 1) else { return }
        let drawing = (try? PKDrawing(data: data)) ?? PKDrawing()
        PdfInk.apply(drawing, to: pdfPage)
        guard let rewritten = document.dataRepresentation() else { return }
        try? PdfDocumentSession.persistPdfKitRewrite(
            rewritten,
            preservingMetadataFrom: originalData,
            path: path)
    }
}
#endif
