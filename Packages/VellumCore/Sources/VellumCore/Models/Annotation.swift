public enum AnnotationType: String, Codable, Sendable {
    case highlight
    case note
    case bookmark
}

public struct AnnotationRect: Codable, Equatable, Sendable {
    public var unknownFields: [String: JSONValue] = [:]

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
    public var unknownFields: [String: JSONValue] = [:]

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
    public var unknownFields: [String: JSONValue] = [:]

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

extension AnnotationRect {
    private enum CodingKeys: String, CodingKey {
        case x, y, width, height
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        x = try container.decode(Double.self, forKey: .x)
        y = try container.decode(Double.self, forKey: .y)
        width = try container.decode(Double.self, forKey: .width)
        height = try container.decode(Double.self, forKey: .height)
        unknownFields = try JSONValue.unknownFields(in: decoder, excluding: CodingKeys.self)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(x, forKey: .x)
        try container.encode(y, forKey: .y)
        try container.encode(width, forKey: .width)
        try container.encode(height, forKey: .height)
        try JSONValue.encode(unknownFields, to: encoder, excluding: CodingKeys.self)
    }
}

extension PositionData {
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        rects = try container.decode([AnnotationRect].self, forKey: .rects)
        pageWidth = try container.decode(Double.self, forKey: .pageWidth)
        pageHeight = try container.decode(Double.self, forKey: .pageHeight)
        selectedText = try container.decodeIfPresent(String.self, forKey: .selectedText)
        startOffset = try container.decodeIfPresent(Int.self, forKey: .startOffset)
        endOffset = try container.decodeIfPresent(Int.self, forKey: .endOffset)
        prefix = try container.decodeIfPresent(String.self, forKey: .prefix)
        suffix = try container.decodeIfPresent(String.self, forKey: .suffix)
        viewportOffset = try container.decodeIfPresent(Double.self, forKey: .viewportOffset)
        unknownFields = try JSONValue.unknownFields(in: decoder, excluding: CodingKeys.self)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(rects, forKey: .rects)
        try container.encode(pageWidth, forKey: .pageWidth)
        try container.encode(pageHeight, forKey: .pageHeight)
        try container.encodeIfPresent(selectedText, forKey: .selectedText)
        try container.encodeIfPresent(startOffset, forKey: .startOffset)
        try container.encodeIfPresent(endOffset, forKey: .endOffset)
        try container.encodeIfPresent(prefix, forKey: .prefix)
        try container.encodeIfPresent(suffix, forKey: .suffix)
        try container.encodeIfPresent(viewportOffset, forKey: .viewportOffset)
        try JSONValue.encode(unknownFields, to: encoder, excluding: CodingKeys.self)
    }
}

extension Annotation {
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        type = try container.decode(AnnotationType.self, forKey: .type)
        pageNumber = try container.decode(Int.self, forKey: .pageNumber)
        color = try container.decodeIfPresent(String.self, forKey: .color)
        content = try container.decodeIfPresent(String.self, forKey: .content)
        positionData = try container.decodeIfPresent(PositionData.self, forKey: .positionData)
        createdAt = try container.decode(String.self, forKey: .createdAt)
        updatedAt = try container.decode(String.self, forKey: .updatedAt)
        isPinned = try container.decodeIfPresent(Bool.self, forKey: .isPinned)
        unknownFields = try JSONValue.unknownFields(in: decoder, excluding: CodingKeys.self)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(type, forKey: .type)
        try container.encode(pageNumber, forKey: .pageNumber)
        try container.encodeIfPresent(color, forKey: .color)
        try container.encodeIfPresent(content, forKey: .content)
        try container.encodeIfPresent(positionData, forKey: .positionData)
        try container.encode(createdAt, forKey: .createdAt)
        try container.encode(updatedAt, forKey: .updatedAt)
        try container.encodeIfPresent(isPinned, forKey: .isPinned)
        try JSONValue.encode(unknownFields, to: encoder, excluding: CodingKeys.self)
    }
}

extension PositionData {
    /// Rectangles have no stored identity. Their array order follows the
    /// selection's text, including when resizing changes the geometry.
    public mutating func inheritUnknownFields(from previous: PositionData) {
        unknownFields.fillMissing(from: previous.unknownFields)
        for index in rects.indices.prefix(previous.rects.count) {
            rects[index].unknownFields.fillMissing(from: previous.rects[index].unknownFields)
        }
    }
}
