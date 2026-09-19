#if os(iOS)
import Observation
import PencilKit
import SwiftUI
import UIKit

/// The Pencil ink tool. Highlighter is a translucent marker; pen is opaque.
enum InkTool: String, CaseIterable, Sendable {
    case pen, highlighter, textHighlight, eraser
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
        AppDefaults.current.string(forKey: defaultsKey)
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
        guard let data = AppDefaults.current.data(forKey: defaultsKey),
              let decoded = try? JSONDecoder().decode(InkWidthSettings.self, from: data)
        else { return InkWidthSettings() }
        return decoded
    }

    func saveToDefaults() {
        guard let data = try? JSONEncoder().encode(self) else { return }
        AppDefaults.current.set(data, forKey: Self.defaultsKey)
    }
}

/// Shared Pencil-tool state — tool/color/width-slot selection, the persisted
/// `InkWidthSettings` blob, eraser mode, the finger-drawing toggle, the Pencil
/// double-tap behavior, and `PKTool` construction. Extracted from
/// `InkController_iOS` so the PDF ink controller and the (future) web ink
/// controller share one palette state instead of duplicating it.
///
/// The controller that owns this instance wires the two callbacks below to its
/// own renderer: `onToolChanged` re-applies the tool to the live canvases and
/// `onPolicyChanged` refreshes the drawing/interaction policy. The state object
/// itself knows nothing about PDFKit or the web overlay.
@MainActor
@Observable
final class InkToolState {
    var tool: InkTool = .pen {
        didSet {
            guard oldValue != tool else { return }
            previousTool = oldValue
            bumpTool()
        }
    }
    var penColor: Color = InkPalette.penColors[0]
    var textHighlightColor: Color = Color(hex: WorkspaceStore.storedDefaultHighlightColor())
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
            onPolicyChanged?()
            bumpTool()
        }
    }

    /// Bumped when tool/color/width change so the canvas re-reads the PKTool.
    private(set) var toolVersion = 0
    /// The tool in use before the last switch — the Pencil double-tap target.
    @ObservationIgnored private var previousTool: InkTool = .eraser

    /// Called after any tool/color/width change so the owning controller can
    /// re-apply the active `PKTool` to its live canvases.
    @ObservationIgnored var onToolChanged: (() -> Void)?
    /// Called when the finger-drawing toggle flips so the owning controller can
    /// refresh its canvases' drawing/interaction policy.
    @ObservationIgnored var onPolicyChanged: (() -> Void)?

    var activeColor: Color {
        get {
            switch tool {
            case .highlighter: highlighterColor
            case .textHighlight: textHighlightColor
            case .pen, .eraser: penColor
            }
        }
        set {
            switch tool {
            case .highlighter: highlighterColor = newValue
            case .textHighlight: textHighlightColor = newValue
            case .pen, .eraser: penColor = newValue
            }
        }
    }

    /// Persisted annotation color for the Pencil text-highlighter. Its palette
    /// is deliberately the same five colors as ordinary Vellum highlights.
    var textHighlightColorHex: String {
        let selected = UIColor(textHighlightColor).cgColor
        return HIGHLIGHT_COLORS.first {
            UIColor(Color(hex: $0.value)).cgColor == selected
        }?.value ?? WorkspaceStore.storedDefaultHighlightColor()
    }
    /// The three width presets for the active tool.
    var activeWidths: [CGFloat] {
        get {
            switch tool {
            case .pen: widthSettings.penWidths
            case .highlighter: widthSettings.highlighterWidths
            case .textHighlight: []
            case .eraser: widthSettings.eraserWidths
            }
        }
        set {
            switch tool {
            case .pen: widthSettings.penWidths = newValue
            case .highlighter: widthSettings.highlighterWidths = newValue
            case .textHighlight: break
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
            case .textHighlight: 0
            case .eraser: widthSettings.eraserSlot
            }
        }
        set {
            switch tool {
            case .pen: widthSettings.penSlot = newValue
            case .highlighter: widthSettings.highlighterSlot = newValue
            case .textHighlight: break
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
        onToolChanged?()
        onPolicyChanged?()
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
        case .textHighlight:
            return PKInkingTool(.marker, color: UIColor(textHighlightColor), width: 12)
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
}

/// The controller surface the shared `InkToolPalette_iOS` renders against. Both
/// the PDF ink controller and the web ink controller adopt it, so the
/// palette drives either without knowing which document kind it is annotating.
/// Tool/color/width state comes from `toolState`; the undo/redo/clear/done
/// actions are controller-specific (they target different canvases and
/// persistence paths).
@MainActor
protocol InkPaletteHost: AnyObject, Observable {
    /// Shared tool/color/width state the palette binds its controls to.
    var toolState: InkToolState { get }
    /// Whether ink mode is currently active — the palette's Done button clears it.
    var isActive: Bool { get set }
    var canUndo: Bool { get }
    var canRedo: Bool { get }
    func undo()
    func redo()
    /// Clear the ink on the current page/view (undoable).
    func clearCurrentPage()
    /// Exit ink mode (the palette's Done button).
    func done()
    /// Write any pending debounced ink now and wait until it is durable — the
    /// scene-background flush (`VellumApp_iOS.flushOnBackground`) drains every
    /// registered controller, PDF and web alike, before iPadOS may suspend.
    func flushPendingInkAndWait() async
}

extension InkPaletteHost {
    func done() { isActive = false }
}
#endif
