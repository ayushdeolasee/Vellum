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

    /// User preference: whether scribbling over existing ink with the pen erases
    /// what the scribble covers, instead of leaving the scribble as ink (see
    /// `ScratchOutRecognizer`). Defaults to on — it matches Notes/GoodNotes and
    /// the recognizer is tuned to be conservative — but it is a *destructive*
    /// gesture, so anyone whose drawing style trips it (heavy hatching over an
    /// existing sketch is the plausible case) needs a way out. Persisted under
    /// `scratchOutToEraseKey`.
    static let scratchOutToEraseKey = "ink.scratchOutToErase"
    static var scratchOutToErase: Bool {
        UserDefaults.standard.object(forKey: scratchOutToEraseKey) as? Bool ?? true
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
    /// One cached summary for the sidebar. It is populated while the PDF is
    /// already being parsed off-main, so opening or interacting with the
    /// sidebar never has to walk every PDF page from SwiftUI's `body`.
    private(set) var handwritingPages: [Int] = []
    @ObservationIgnored private var handwritingDocumentID: ObjectIdentifier?
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

    /// How long the canvas must stay quiet before ink is written to disk.
    ///
    /// Every write is a full read-modify-write of the PDF (see `InkDiskWriter`),
    /// so on a large document each one costs tens of MB of I/O plus two complete
    /// parses. At the previous 700ms the natural pauses between words triggered
    /// a rewrite more or less continuously while taking notes, which was a
    /// significant battery cost. Durability does not rest on this value: ink is
    /// flushed unconditionally when ink mode turns off (`flushPendingInk`) and
    /// before the scene suspends (`flushPendingInkAndWait`), so it bounds only
    /// the window a hard crash could lose.
    @ObservationIgnored private static let persistDebounce = Duration.milliseconds(2500)

    /// Ceiling on how long a page may stay dirty. Uninterrupted drawing keeps
    /// resetting the debounce, so without this a long unbroken passage would
    /// never reach disk at all — an unbounded window the previous per-page
    /// debounce had too. This makes the crash window strictly bounded.
    @ObservationIgnored private static let maxDirtyAge = Duration.seconds(15)

    /// How many times `flushPendingInkAndWait` re-drains before giving up. A
    /// failed write returns its pages to `pendingDrawings`, so this is what
    /// stops a file that cannot be written at all from spinning the flush.
    @ObservationIgnored private static let maxDrainAttempts = 3

    /// Pages whose canvas has changed but whose ink is not yet on disk, grouped
    /// by the file they belong to (switching tabs mid-debounce can leave two
    /// documents dirty at once).
    ///
    /// This holds the `PKDrawing` itself — a `Sendable` value type — rather than
    /// its encoded bytes, which keeps `dataRepresentation()` off the per-stroke
    /// path. That call serializes *every* stroke on the page, and PencilKit
    /// invokes `canvasViewDrawingDidChange` repeatedly *during* a stroke, so
    /// encoding inline cost O(strokes already on the page) of main-actor work at
    /// Pencil input rate — up to 120Hz on a ProMotion display.
    @ObservationIgnored private var pendingDrawings: [String: [Int: PKDrawing]] = [:]

    /// When the oldest currently-unwritten change arrived, for `maxDirtyAge`.
    @ObservationIgnored private var oldestDirtyAt: ContinuousClock.Instant?

    /// The pending debounce timer. Cancelled and restarted on every change.
    @ObservationIgnored private var debounceTask: Task<Void, Never>?

    /// Retains the active drain. Backgrounding joins this exact task instead of
    /// seeing emptied dictionaries and ending its assertion while a previously
    /// launched PDF rewrite is still running.
    @ObservationIgnored private var drainTask: Task<Void, Never>?

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
    func noteSeededDrawing(page: Int, hasVisibleInk: Bool) {
        drawingVersion &+= 1
        updateHandwritingPage(page, hasInk: hasVisibleInk)
    }

    /// Adopts the summary gathered during the viewer's existing detached PDF
    /// preparation pass. The display document is stripped of native
    /// annotations before PDFKit mounts it, so this is also the authoritative
    /// record for pages that have not created a PencilKit canvas yet.
    func adoptHandwritingPages(_ pages: [Int], for document: PDFDocument) {
        handwritingDocumentID = ObjectIdentifier(document)
        if handwritingPages != pages {
            handwritingPages = pages
        }
    }

    /// The active PencilKit tool. The width is exactly the one the user picked:
    /// ink canvases super-sample by raising their `zoomScale`, which is purely a
    /// rasterization concern and leaves stroke geometry in page space, so the
    /// width must NOT be scaled to compensate. (It used to be, and because
    /// PencilKit clamps `PKInkingTool.width` — pen 0.88…25.66, marker 7.5…60 —
    /// and doesn't map it linearly onto rendered geometry, strokes drawn while
    /// zoomed in came out about half as thick as strokes drawn at 100%.)
    var pkTool: PKTool {
        switch tool {
        case .pen:
            return PKInkingTool(.pen, color: UIColor(penColor), width: activeWidth)
        case .highlighter:
            return PKInkingTool(.marker, color: UIColor(highlighterColor), width: activeWidth)
        case .eraser:
            // Explicit width — the default reports 0 ("system default"), which
            // leaves the erase radius an unknown.
            switch eraserMode {
            case .pixel:
                return PKEraserTool(.bitmap, width: activeWidth)
            case .object:
                return PKEraserTool(.vector, width: activeWidth)
            }
        }
    }

    // MARK: - Editing lifecycle

    /// Live change on a page's canvas: bump undo/redo observability and debounce
    /// a durable write to disk. The canvas is the on-screen renderer, so there is
    /// no display-document mutation here.
    func drawingChanged(_ drawing: PKDrawing, page: Int) {
        drawingVersion &+= 1
        updateHandwritingPage(
            page,
            hasInk: drawing.strokes.contains(where: PdfInk.strokeHasVisibleInk))
        persist(drawing: drawing, page: page)
    }

    private func updateHandwritingPage(_ page: Int, hasInk: Bool) {
        guard page >= 1,
              let document = pdfController?.document,
              handwritingDocumentID == ObjectIdentifier(document)
        else { return }

        var pages = Set(handwritingPages)
        if hasInk {
            pages.insert(page)
        } else {
            pages.remove(page)
        }
        let updated = pages.sorted()
        if updated != handwritingPages {
            handwritingPages = updated
        }
    }

    // MARK: - Persistence to the on-disk PDF

    /// Write all pending debounced ink immediately (no debounce wait). Called
    /// when ink mode turns off so a fast app-kill can't drop the last strokes.
    func flushPendingInk() {
        _ = ensureDrainTask()
    }

    /// Cancel the debounce and wait until every pending page rewrite is durable.
    /// The scene-background task uses this before iPadOS is allowed to suspend
    /// the app, so a stroke made immediately before pressing Home cannot vanish.
    func flushPendingInkAndWait() async {
        // A stroke can arrive while an earlier flush is suspended in PDFKit, so
        // join/drain repeatedly. Bounded, not `while`: a drain that fails puts
        // its batch back, and an unwritable file would otherwise spin here
        // forever while the scene-suspend assertion is running.
        for _ in 0..<Self.maxDrainAttempts {
            guard let task = ensureDrainTask() else { return }
            await task.value
        }
    }

    private func ensureDrainTask() -> Task<Void, Never>? {
        // The debounce has been superseded: whatever it was waiting to write is
        // still in `pendingDrawings` and the drain below picks it up.
        debounceTask?.cancel()
        debounceTask = nil
        if let drainTask { return drainTask }
        guard !pendingDrawings.isEmpty else { return nil }
        // Strong `self` for the same reason as the debounce task: the batch this
        // is about to write lives on this object, and the task body doesn't
        // start until the next main-actor turn. The retain ends with the drain.
        let task = Task {
            await self.drainPendingInk()
            self.drainTask = nil
        }
        drainTask = task
        return task
    }

    private func drainPendingInk() async {
        // A stroke can land while an earlier batch is inside PDFKit, so keep
        // draining until nothing new has arrived.
        while !pendingDrawings.isEmpty {
            let batch = pendingDrawings
            pendingDrawings.removeAll()
            oldestDirtyAt = nil
            var failed = false
            for (path, pages) in batch where await !Self.writer.write(drawings: pages, path: path) {
                // The file was unreadable, or PDFKit refused to serialize it.
                // The batch has already been taken out of `pendingDrawings`, so
                // without this the user's strokes would be gone for good on a
                // failure as transient as an iCloud eviction mid-write.
                requeue(pages, path: path)
                failed = true
            }
            // Leave a failing file to the next stroke or flush rather than
            // retrying in a tight loop against the disk.
            if failed { return }
        }
    }

    /// Put a failed batch back, without burying a newer drawing that landed
    /// while the write was in flight — newest-wins still holds.
    private func requeue(_ pages: [Int: PKDrawing], path: String) {
        var current = pendingDrawings[path] ?? [:]
        for (page, drawing) in pages where current[page] == nil {
            current[page] = drawing
        }
        pendingDrawings[path] = current
        if oldestDirtyAt == nil { oldestDirtyAt = ContinuousClock.now }
    }

    private func persist(drawing: PKDrawing, page: Int) {
        guard let path = app?.document?.pdfPath, page >= 1 else { return }
        // O(1): just retain the drawing. Encoding happens once per write, off
        // the main actor — see `pendingDrawings`.
        pendingDrawings[path, default: [:]][page] = drawing
        let now = ContinuousClock.now
        let dirtiedAt = oldestDirtyAt ?? now
        oldestDirtyAt = dirtiedAt
        // Continuous drawing keeps resetting the debounce below, so stop
        // deferring once the batch has been dirty for `maxDirtyAge`.
        guard now - dirtiedAt < Self.maxDirtyAge else {
            flushPendingInk()
            return
        }
        debounceTask?.cancel()
        // Strong `self` on purpose. The pending drawings live on this object, so
        // a weak capture would silently drop them if the controller went away
        // during the debounce window — closing a tab mid-stroke would lose ink.
        // The retain is bounded: the task ends after `persistDebounce` (or is
        // cancelled by the next stroke), and releasing it breaks the cycle.
        debounceTask = Task {
            try? await Task.sleep(for: Self.persistDebounce)
            guard !Task.isCancelled else { return }
            self.debounceTask = nil
            self.flushPendingInk()
        }
    }

    /// Serializes every ink disk write: each write is a full read-modify-write
    /// of the PDF, so two pages persisting concurrently would clobber each
    /// other's strokes if they interleaved.
    private static let writer = InkDiskWriter()
}

/// Loads a FRESH copy of the on-disk PDF (so the highlight/note annotations
/// written by the atomic writer are preserved), replaces the ink on every dirty
/// page, and atomically writes it back. Every ink write is routed through the
/// shared `PdfFileGate` so it can never interleave with an annotation/metadata
/// rewrite of the same file (both are full read-modify-writes; interleaving
/// would lose one side's changes). The gate also runs the PDFKit mutation +
/// write off the main thread.
struct InkDiskWriter {
    /// Apply every dirty page's ink in ONE read-modify-write cycle.
    ///
    /// A rewrite re-reads the whole file, re-parses it, re-serializes it, and —
    /// on iPadOS 26, where PDFKit drops Vellum's custom annotation keys — parses
    /// it a second time to rehydrate them. Writing pages one at a time paid all
    /// of that per page, so inking across a spread cost two full rewrites of a
    /// document that might be tens of MB.
    /// - Returns: whether the pages are durable. `false` means the caller must
    ///   keep them pending — every failure mode here (unreadable file, PDFKit
    ///   declining to serialize, a throwing rewrite) used to be swallowed, which
    ///   with batching would discard a whole window of strokes at once.
    @discardableResult
    func write(drawings: [Int: PKDrawing], path: String) async -> Bool {
        guard !drawings.isEmpty else { return true }
        return await PdfFileGate.shared.perform {
            Self.writeSync(drawings: drawings, path: path)
        }
    }

    private static func writeSync(drawings: [Int: PKDrawing], path: String) -> Bool {
        let url = URL(fileURLWithPath: path)
        guard let originalData = try? Data(contentsOf: url),
              let document = PDFDocument(data: originalData) else { return false }
        var didApply = false
        for (page, drawing) in drawings {
            guard page >= 1, page <= document.pageCount,
                  let pdfPage = document.page(at: page - 1) else { continue }
            PdfInk.apply(drawing, to: pdfPage)
            didApply = true
        }
        // Every page was out of range: nothing to write, and nothing to retry
        // either — retrying would fail identically.
        guard didApply else { return true }
        guard let rewritten = document.dataRepresentation() else { return false }
        do {
            try PdfDocumentSession.persistPdfKitRewrite(
                rewritten,
                preservingMetadataFrom: originalData,
                path: path)
            return true
        } catch {
            return false
        }
    }
}
#endif
