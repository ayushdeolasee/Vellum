import Foundation

/// Offsets refer to the normalized chapter text, in end-exclusive UTF-16 units.
struct EpubTextAnchor: Codable, Hashable, Sendable {
    var chapterHref: String
    var quote: String
    var prefix: String
    var suffix: String
    var startUTF16: Int? = nil
    var endUTF16: Int? = nil

    enum CodingKeys: String, CodingKey {
        case chapterHref = "chapter_href"
        case quote, prefix, suffix
        case startUTF16 = "start_utf16"
        case endUTF16 = "end_utf16"
    }
}

/// `chapterHref` is the resolved archive path (not a URL or a publisher-relative href).
struct EpubLocation: Codable, Hashable, Sendable {
    var chapterHref: String
    var textAnchor: EpubTextAnchor? = nil
    var progression: Double? = nil

    enum CodingKeys: String, CodingKey {
        case chapterHref = "chapter_href"
        case textAnchor = "text_anchor"
        case progression
    }
}
