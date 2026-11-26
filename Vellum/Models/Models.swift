import Foundation
import VellumCore

typealias PdfZoomMode = VellumCore.PdfZoomMode
typealias PdfZoomPolicy = VellumCore.PdfZoomPolicy

typealias AnnotationType = VellumCore.AnnotationType
typealias AnnotationRect = VellumCore.AnnotationRect
typealias PositionData = VellumCore.PositionData
typealias Annotation = VellumCore.Annotation
typealias CreateAnnotationInput = VellumCore.CreateAnnotationInput
typealias UpdateAnnotationInput = VellumCore.UpdateAnnotationInput
typealias DocumentKind = VellumCore.DocumentKind
typealias DocumentInfo = VellumCore.DocumentInfo
typealias RecentDocument = VellumCore.RecentDocument

struct VellumwebExportSummary: Codable, Equatable, Sendable {
    var path: String
    var bytes: Int
    var assetCount: Int
    var assetsSkipped: Int

    enum CodingKeys: String, CodingKey {
        case path
        case bytes
        case assetCount = "asset_count"
        case assetsSkipped = "assets_skipped"
    }
}

struct WebLibraryEntry: Codable, Equatable, Sendable {
    var url: String
    var title: String?
    var pageCount: Int?
    var savedAt: String?
    var hasSnapshot: Bool

    enum CodingKeys: String, CodingKey {
        case url
        case title
        case pageCount = "page_count"
        case savedAt = "saved_at"
        case hasSnapshot = "has_snapshot"
    }
}

/// One page of extracted text handed to web archive export.
struct WebPageText: Sendable {
    var number: Int
    var text: String
}

enum InteractionMode: String, Codable, Sendable {
    case view
    case note
    /// Drag a rectangle over the page to snapshot that region into the
    /// scratchpad. Transient (never persisted to a tab); returns to `.view`.
    case snapshotRegion
}

/// Which side panel receives a pending drag-to-crop capture. This is kept on
/// the live tab rather than the pane-wide active state so changing tabs cannot
/// silently lose, or misroute, an armed capture.
enum RegionCaptureTarget: Sendable, Equatable {
    case ai
    case scratchpad
}

struct WebVisibleRange: Equatable, Sendable {
    var start: Int
    var end: Int
}

struct PdfTab: Identifiable, Equatable, Sendable {
    var id: String
    /// The tab's document, or `nil` for a lightweight "start tab" — the
    /// new-tab page offering Recent, Open PDF…, and Open Webpage…. A start tab
    /// is replaced in place the moment a document is opened from it.
    var document: DocumentInfo? {
        didSet {
            let oldKey = oldValue.map { DocumentIdentity.storageKey(for: $0) }
            let newKey = document.map { DocumentIdentity.storageKey(for: $0) }
            if oldKey != newKey || oldValue?.kind != document?.kind {
                documentBindingGeneration = UUID()
            }
        }
    }
    /// Live only: restoration makes a new binding, while a pane move keeps it.
    var documentBindingGeneration = UUID()
    var currentPage: Int
    var numPages: Int
    var zoom: Double
    var visiblePages: [Int]
    /// Raw text-offset span currently on screen (web documents only).
    var webVisibleRange: WebVisibleRange?
    /// Ids of point bookmarks whose re-anchored position is on screen right
    /// now (web documents only; reported by the content script).
    var webVisibleBookmarks: [String]
    var mode: InteractionMode
    /// AI text queued for the next placed note. It deliberately remains live
    /// only: relaunching restores the note tool, never a stale AI reply.
    var pendingNoteContent: String? = nil
    /// An in-progress region capture is also live-only, but belongs to its tab
    /// while the user moves around the workspace.
    var regionCaptureTarget: RegionCaptureTarget? = nil
    /// Find is document work, not window chrome. Keep it with the tab so
    /// switching away does not silently dismiss the query and highlights.
    var findVisible: Bool = false
    var findQuery: String = ""
    var findMatchCount: Int = 0
    var findCurrentMatch: Int = 0
}

struct HighlightColor: Identifiable, Sendable {
    var name: String
    /// Light-theme hex value, e.g. "#fef08a" — this is what gets persisted.
    var value: String
    /// Dark-theme render value (with alpha), e.g. "#854d0e80".
    var dark: String

    var id: String { value }
}

let HIGHLIGHT_COLORS: [HighlightColor] = [
    HighlightColor(name: "Yellow", value: "#fef08a", dark: "#854d0e80"),
    HighlightColor(name: "Green", value: "#bbf7d0", dark: "#16653480"),
    HighlightColor(name: "Blue", value: "#bfdbfe", dark: "#1e40af80"),
    HighlightColor(name: "Pink", value: "#fbcfe8", dark: "#9d174d80"),
    HighlightColor(name: "Purple", value: "#ddd6fe", dark: "#5b21b680"),
]
