public enum AnnotationType: String, Codable, Sendable {
    case highlight
    case note
    case bookmark
}

public struct AnnotationRect: Codable, Equatable, Sendable {
    public var x: Double
    public var y: Double
    public var width: Double
    public var height: Double

    public init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }
}

public struct PositionData: Codable, Equatable, Sendable {
    public var rects: [AnnotationRect]
    public var pageWidth: Double
    public var pageHeight: Double
    public var selectedText: String?
    public var startOffset: Int?
    public var endOffset: Int?
    /// Text-quote anchor context for webpage annotations (normalized text,
    /// ~32 chars each side). Absent for PDF annotations.
    public var prefix: String?
    public var suffix: String?
    /// How far below the viewport top (CSS px) the anchor text sat when a
    /// webpage point bookmark was captured. Absent for PDFs and selections.
    public var viewportOffset: Double?

    public init(
        rects: [AnnotationRect], pageWidth: Double, pageHeight: Double,
        selectedText: String? = nil, startOffset: Int? = nil, endOffset: Int? = nil,
        prefix: String? = nil, suffix: String? = nil, viewportOffset: Double? = nil
    ) {
        self.rects = rects
        self.pageWidth = pageWidth
        self.pageHeight = pageHeight
        self.selectedText = selectedText
        self.startOffset = startOffset
        self.endOffset = endOffset
        self.prefix = prefix
        self.suffix = suffix
        self.viewportOffset = viewportOffset
    }

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

public struct Annotation: Codable, Equatable, Identifiable, Sendable {
    public var id: String
    public var type: AnnotationType
    public var pageNumber: Int
    public var color: String?
    public var content: String?
    public var positionData: PositionData?
    public var createdAt: String
    public var updatedAt: String
    /// Pinned annotations float to the top of the sidebar list. Optional so
    /// records written before pinning existed decode cleanly (missing → false).
    public var isPinned: Bool? = nil

    public init(
        id: String, type: AnnotationType, pageNumber: Int, color: String? = nil,
        content: String? = nil, positionData: PositionData? = nil, createdAt: String,
        updatedAt: String, isPinned: Bool? = nil
    ) {
        self.id = id
        self.type = type
        self.pageNumber = pageNumber
        self.color = color
        self.content = content
        self.positionData = positionData
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.isPinned = isPinned
    }

    enum CodingKeys: String, CodingKey {
        case id
        case type
        case pageNumber = "page_number"
        case color
        case content
        case positionData = "position_data"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
        case isPinned = "is_pinned"
    }

    /// True when the user has pinned this annotation.
    public var pinned: Bool { isPinned == true }

    /// Sidebar / backend list order: pinned first, then page, then created_at.
    /// `enumerated` keeps relative order stable when the sort keys tie.
    public static func sortedForDisplay(_ annotations: [Annotation]) -> [Annotation] {
        annotations.enumerated()
            .sorted { left, right in
                if left.element.pinned != right.element.pinned {
                    return left.element.pinned && !right.element.pinned
                }
                if left.element.pageNumber != right.element.pageNumber {
                    return left.element.pageNumber < right.element.pageNumber
                }
                if left.element.createdAt != right.element.createdAt {
                    return left.element.createdAt < right.element.createdAt
                }
                return left.offset < right.offset
            }
            .map(\.element)
    }
}

public struct CreateAnnotationInput: Sendable {
    public var type: AnnotationType
    public var pageNumber: Int
    public var color: String?
    public var content: String?
    public var positionData: PositionData?
    /// Optional caller-supplied identity so the UI can render an annotation
    /// optimistically (before the disk write finishes) and the persisted record
    /// carries the same id/timestamp. Nil lets the backend generate them.
    public var id: String?
    public var createdAt: String?

    public init(
        type: AnnotationType, pageNumber: Int, color: String? = nil, content: String? = nil,
        positionData: PositionData? = nil, id: String? = nil, createdAt: String? = nil
    ) {
        self.type = type
        self.pageNumber = pageNumber
        self.color = color
        self.content = content
        self.positionData = positionData
        self.id = id
        self.createdAt = createdAt
    }
}

public struct UpdateAnnotationInput: Sendable {
    public var id: String
    public var color: String?
    public var content: String?
    public var positionData: PositionData?
    /// Web highlight resizes can cross a virtual page break; PDF annotations
    /// never move pages, so the PDF backend ignores this.
    public var pageNumber: Int? = nil
    /// When set, pin or unpin the annotation in the sidebar list.
    public var isPinned: Bool? = nil

    public init(
        id: String, color: String? = nil, content: String? = nil,
        positionData: PositionData? = nil, pageNumber: Int? = nil, isPinned: Bool? = nil
    ) {
        self.id = id
        self.color = color
        self.content = content
        self.positionData = positionData
        self.pageNumber = pageNumber
        self.isPinned = isPinned
    }
}
