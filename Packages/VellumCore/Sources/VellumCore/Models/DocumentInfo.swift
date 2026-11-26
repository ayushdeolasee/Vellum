import Foundation

public enum DocumentKind: String, Codable, Sendable {
    case pdf
    case web
}

public struct DocumentInfo: Codable, Equatable, Sendable {
    /// "pdf" for files on disk, "web" for proxied webpages.
    public var kind: DocumentKind
    /// Generic document URI: a filesystem path for PDFs, a normalized URL for
    /// webpages. The name is kept for compatibility with stored data keyed on it.
    public var pdfPath: String
    public var title: String?
    public var pageCount: Int?
    public var lastPage: Int?
    /// Stable cross-session document identity. PDFs: the /VellumDocId UUID
    /// stamped into the Info dictionary, nil until a mutation (or
    /// ensureDocumentId) lazily stamps it. Web docs: the sha256 URL hash, set at
    /// open. Class-B/C stores resolve their storage key from this via
    /// DocumentIdentity.
    public var docId: String? = nil
    /// Security-scoped bookmark for `pdfPath` (PDFs only), minted the moment the
    /// document is opened while read access is guaranteed. On iOS this is
    /// MANDATORY, not defense-in-depth: the app is sandboxed, a
    /// UIDocumentPicker URL's access does not survive relaunch, and the app
    /// container's UUID changes across reinstalls — so a saved raw path can stop
    /// resolving even for a file that is still there. Optional so data written
    /// before this field existed (and web docs, which never carry one) decodes
    /// cleanly; readers must fall back to `pdfPath` when nil.
    public var bookmarkData: Data? = nil
    /// Web titles chosen by the user take precedence over later DOM titles.
    /// Carried with the document when its tab moves between panes.
    public var titleIsUserDefined: Bool? = nil

    public init(
        kind: DocumentKind, pdfPath: String, title: String? = nil, pageCount: Int? = nil,
        lastPage: Int? = nil, docId: String? = nil, bookmarkData: Data? = nil,
        titleIsUserDefined: Bool? = nil
    ) {
        self.kind = kind
        self.pdfPath = pdfPath
        self.title = title
        self.pageCount = pageCount
        self.lastPage = lastPage
        self.docId = docId
        self.bookmarkData = bookmarkData
        self.titleIsUserDefined = titleIsUserDefined
    }

    enum CodingKeys: String, CodingKey {
        case kind
        case pdfPath = "pdf_path"
        case title
        case pageCount = "page_count"
        case lastPage = "last_page"
        case docId = "doc_id"
        case bookmarkData = "bookmark_data"
        case titleIsUserDefined = "title_is_user_defined"
    }
}

public struct RecentDocument: Codable, Equatable, Sendable {
    /// File path for PDFs, normalized URL for webpages.
    public var pdfPath: String
    public var kind: DocumentKind
    public var title: String?
    public var pageCount: Int?
    public var openedAt: String
    /// Stable document identity (DocumentInfo.docId): the /VellumDocId for
    /// stamped PDFs, the sha256 URL hash for web docs, nil otherwise. Used to
    /// re-resolve a moved PDF via its meta.json last_known_path when its
    /// recorded path no longer exists.
    public var docId: String?

    enum CodingKeys: String, CodingKey {
        case pdfPath = "pdf_path"
        case kind
        case title
        case pageCount = "page_count"
        case openedAt = "opened_at"
        case docId = "doc_id"
    }

    public init(
        pdfPath: String, kind: DocumentKind, title: String?, pageCount: Int?,
        openedAt: String, docId: String? = nil
    ) {
        self.pdfPath = pdfPath
        self.kind = kind
        self.title = title
        self.pageCount = pageCount
        self.openedAt = openedAt
        self.docId = docId
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        pdfPath = try container.decode(String.self, forKey: .pdfPath)
        // Entries written before webpage support have no kind; treat them as PDFs.
        kind = try container.decodeIfPresent(DocumentKind.self, forKey: .kind) ?? .pdf
        title = try container.decodeIfPresent(String.self, forKey: .title)
        pageCount = try container.decodeIfPresent(Int.self, forKey: .pageCount)
        openedAt = try container.decode(String.self, forKey: .openedAt)
        docId = try container.decodeIfPresent(String.self, forKey: .docId)
    }
}
