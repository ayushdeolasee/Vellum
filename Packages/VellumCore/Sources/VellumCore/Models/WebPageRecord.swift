/// Sidecar record persisted per webpage (`<appData>/web/<key>.json`).
/// All fields default on decode except `url` (mirrors `#[serde(default)]`).
public struct WebPageRecord: Codable, Equatable, Sendable {
    public var url: String
    public var title: String?
    public var titleIsUserDefined: Bool
    public var pageCount: Int?
    public var lastPage: Int?
    public var saved: Bool
    public var savedAt: String?
    public var openedAt: String?
    /// "live-first" (default when nil) or "snapshot-only" (pinned snapshot,
    /// set when importing a .vellumweb archive that requests it).
    public var loadingPolicy: String?
    public var annotations: [Annotation]

    enum CodingKeys: String, CodingKey {
        case url
        case title
        case titleIsUserDefined = "title_is_user_defined"
        case pageCount = "page_count"
        case lastPage = "last_page"
        case saved
        case savedAt = "saved_at"
        case openedAt = "opened_at"
        case loadingPolicy = "loading_policy"
        case annotations
    }

    public init(url: String) {
        self.url = url
        title = nil
        titleIsUserDefined = false
        pageCount = nil
        lastPage = nil
        saved = false
        savedAt = nil
        openedAt = nil
        loadingPolicy = nil
        annotations = []
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        url = try container.decode(String.self, forKey: .url)
        title = try container.decodeIfPresent(String.self, forKey: .title)
        // Older records stored manual and automatic titles in the same field.
        // Preserve an existing name until the user explicitly clears it.
        titleIsUserDefined = try container.decodeIfPresent(Bool.self, forKey: .titleIsUserDefined)
            ?? (title != nil)
        pageCount = try container.decodeIfPresent(Int.self, forKey: .pageCount)
        lastPage = try container.decodeIfPresent(Int.self, forKey: .lastPage)
        saved = try container.decodeIfPresent(Bool.self, forKey: .saved) ?? false
        savedAt = try container.decodeIfPresent(String.self, forKey: .savedAt)
        openedAt = try container.decodeIfPresent(String.self, forKey: .openedAt)
        loadingPolicy = try container.decodeIfPresent(String.self, forKey: .loadingPolicy)
        annotations = try container.decodeIfPresent([Annotation].self, forKey: .annotations) ?? []
    }
}
