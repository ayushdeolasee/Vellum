import Foundation

// Core data models — mirror src/types/index.ts and the Rust models exactly.
// JSON field names stay snake_case for compatibility with data written by the
// Tauri app (embedded PDF annotations, .vellumweb archives, recent-files JSON).

enum AnnotationType: String, Codable, Sendable {
    case highlight
    case note
    case bookmark
}

struct AnnotationRect: Codable, Equatable, Sendable {
    var x: Double
    var y: Double
    var width: Double
    var height: Double
}

struct PositionData: Codable, Equatable, Sendable {
    var rects: [AnnotationRect]
    var pageWidth: Double
    var pageHeight: Double
    var selectedText: String?
    var startOffset: Int?
    var endOffset: Int?
    /// Text-quote anchor context for webpage annotations (normalized text,
    /// ~32 chars each side). Absent for PDF annotations.
    var prefix: String?
    var suffix: String?
    /// How far below the viewport top (CSS px) the anchor text sat when a
    /// webpage point bookmark was captured. Absent for PDFs and selections.
    var viewportOffset: Double?

    enum CodingKeys: String, CodingKey {
        case rects
        case pageWidth = "page_width"
        case pageHeight = "page_height"
        case selectedText = "selected_text"
        case startOffset = "start_offset"
        case endOffset = "end_offset"
        case prefix
        case suffix
        case viewportOffset = "viewport_offset"
    }
}

struct Annotation: Codable, Equatable, Identifiable, Sendable {
    var id: String
    var type: AnnotationType
    var pageNumber: Int
    var color: String?
    var content: String?
    var positionData: PositionData?
    var createdAt: String
    var updatedAt: String

    enum CodingKeys: String, CodingKey {
        case id
        case type
        case pageNumber = "page_number"
        case color
        case content
        case positionData = "position_data"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
    }
}

struct CreateAnnotationInput: Sendable {
    var type: AnnotationType
    var pageNumber: Int
    var color: String?
    var content: String?
    var positionData: PositionData?
    /// Optional caller-supplied identity so the UI can render an annotation
    /// optimistically (before the disk write finishes) and the persisted record
    /// carries the same id/timestamp. Nil lets the backend generate them.
    var id: String?
    var createdAt: String?
}

struct UpdateAnnotationInput: Sendable {
    var id: String
    var color: String?
    var content: String?
    var positionData: PositionData?
    /// Web highlight resizes can cross a virtual page break; PDF annotations
    /// never move pages, so the PDF backend ignores this.
    var pageNumber: Int? = nil
}

enum DocumentKind: String, Codable, Sendable {
    case pdf
    case web
}

struct DocumentInfo: Codable, Equatable, Sendable {
    /// "pdf" for files on disk, "web" for proxied webpages.
    var kind: DocumentKind
    /// Generic document URI: a filesystem path for PDFs, a normalized URL for
    /// webpages. The name is kept for compatibility with stored data keyed on it.
    var pdfPath: String
    var title: String?
    var pageCount: Int?
    var lastPage: Int?

    enum CodingKeys: String, CodingKey {
        case kind
        case pdfPath = "pdf_path"
        case title
        case pageCount = "page_count"
        case lastPage = "last_page"
    }
}

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
    var document: DocumentInfo?
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

struct RecentDocument: Codable, Equatable, Sendable {
    /// File path for PDFs, normalized URL for webpages.
    var pdfPath: String
    var kind: DocumentKind
    var title: String?
    var pageCount: Int?
    var openedAt: String

    enum CodingKeys: String, CodingKey {
        case pdfPath = "pdf_path"
        case kind
        case title
        case pageCount = "page_count"
        case openedAt = "opened_at"
    }

    init(pdfPath: String, kind: DocumentKind, title: String?, pageCount: Int?, openedAt: String) {
        self.pdfPath = pdfPath
        self.kind = kind
        self.title = title
        self.pageCount = pageCount
        self.openedAt = openedAt
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        pdfPath = try container.decode(String.self, forKey: .pdfPath)
        // Entries written before webpage support have no kind; treat them as PDFs.
        kind = try container.decodeIfPresent(DocumentKind.self, forKey: .kind) ?? .pdf
        title = try container.decodeIfPresent(String.self, forKey: .title)
        pageCount = try container.decodeIfPresent(Int.self, forKey: .pageCount)
        openedAt = try container.decode(String.self, forKey: .openedAt)
    }
}
