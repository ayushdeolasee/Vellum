import Foundation

enum IntegrationProvider: String, CaseIterable, Codable, Hashable, Identifiable, Sendable {
    case readwise
    case raindrop

    var id: String { rawValue }

    var name: String {
        switch self {
        case .readwise: "Readwise Reader"
        case .raindrop: "Raindrop.io"
        }
    }

    var symbol: String {
        switch self {
        case .readwise: "books.vertical"
        case .raindrop: "bookmark"
        }
    }
}

enum ReadLaterKind: String, Codable, CaseIterable, Hashable, Sendable {
    case article
    case pdf
    case epub
    case video
    case other
}

enum PDFRetrievalStrategy: Codable, Hashable, Sendable {
    case readwiseItem(id: String)
    case raindropURL(URL)
}

struct ReadLaterCollection: Codable, Hashable, Identifiable, Sendable {
    let id: String
    let provider: IntegrationProvider
    let vendorID: String
    let title: String
    let parentID: String?
    let depth: Int
    let sortIndex: Int

    /// Canonical collection identifier — the single place the
    /// "provider:collection:vendorID" format is defined.
    static func id(provider: IntegrationProvider, vendorID: String) -> String {
        "\(provider.rawValue):collection:\(vendorID)"
    }

    init(provider: IntegrationProvider, vendorID: String, title: String, parentID: String? = nil, depth: Int = 0, sortIndex: Int = 0) {
        self.id = Self.id(provider: provider, vendorID: vendorID)
        self.provider = provider
        self.vendorID = vendorID
        self.title = title.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty ?? "Untitled collection"
        self.parentID = parentID
        self.depth = max(0, depth)
        self.sortIndex = sortIndex
    }
}

struct ReadLaterItem: Codable, Hashable, Identifiable, Sendable {
    let id: String
    let provider: IntegrationProvider
    let vendorID: String
    let sourceURL: URL
    let title: String
    let author: String?
    let excerpt: String?
    let kind: ReadLaterKind
    let tags: [String]
    let collectionIDs: [String]
    let thumbnailURL: URL?
    let savedAt: Date
    let updatedAt: Date
    let pdfRetrieval: PDFRetrievalStrategy?

    init?(provider: IntegrationProvider, vendorID: String, sourceURL: URL?, title: String?, author: String? = nil, excerpt: String? = nil, kind: ReadLaterKind = .article, tags: [String] = [], collectionIDs: [String] = [], thumbnailURL: URL? = nil, savedAt: Date?, updatedAt: Date?, pdfRetrieval: PDFRetrievalStrategy? = nil) {
        let vendorID = vendorID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !vendorID.isEmpty, let sourceURL = sourceURL.flatMap(Self.validHTTPURL) else { return nil }
        let fallback = Date(timeIntervalSince1970: 0)
        self.id = "\(provider.rawValue):\(vendorID)"
        self.provider = provider
        self.vendorID = vendorID
        self.sourceURL = sourceURL
        self.title = title?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty ?? sourceURL.host() ?? sourceURL.absoluteString
        self.author = author?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        self.excerpt = excerpt?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        self.kind = kind
        self.tags = Array(Set(tags.compactMap { $0.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty })).sorted()
        self.collectionIDs = Array(Set(collectionIDs)).sorted()
        self.thumbnailURL = thumbnailURL.flatMap(Self.validHTTPURL)
        self.savedAt = savedAt ?? updatedAt ?? fallback
        self.updatedAt = updatedAt ?? savedAt ?? fallback
        self.pdfRetrieval = pdfRetrieval
    }

    static func validHTTPURL(_ url: URL) -> URL? {
        guard let scheme = url.scheme?.lowercased(), ["http", "https"].contains(scheme), url.host()?.isEmpty == false else { return nil }
        return url
    }

    /// Copy of this item filed under a single new collection, with `updatedAt`
    /// bumped so the moved item wins the newest-revision merge against stale
    /// cached copies until the provider reports its own update timestamp.
    func movingToCollection(_ collectionID: String, updatedAt: Date) -> ReadLaterItem {
        ReadLaterItem(provider: provider, vendorID: vendorID, sourceURL: sourceURL, title: title, author: author, excerpt: excerpt, kind: kind, tags: tags, collectionIDs: [collectionID], thumbnailURL: thumbnailURL, savedAt: savedAt, updatedAt: updatedAt, pdfRetrieval: pdfRetrieval) ?? self
    }
}

extension ReadLaterCollection {
    /// Raindrop's built-in inbox. It never appears in the collections API, but
    /// items outside every collection live under vendor id -1.
    static let raindropUnsorted = ReadLaterCollection(provider: .raindrop, vendorID: "-1", title: "Unsorted")
}

struct IntegrationPage: Sendable {
    let items: [ReadLaterItem]
    let nextCursor: String?
    let hasMore: Bool
    let skippedRecordCount: Int
    /// The response carried no records at all, as opposed to records this walk
    /// dropped as malformed. Paired with `hasMore` it identifies a service that
    /// is promising a next page it will never deliver.
    let responseWasEmpty: Bool
}

struct IntegrationQueryDescriptor: Codable, Hashable, Sendable {
    let provider: IntegrationProvider
    let pageSize: Int
    let sort: String?
    let updatedAfter: Date?
}

enum IntegrationSyncMode: String, Codable, Hashable, Sendable { case incremental, full }

/// A page walk that is still in progress, persisted so an interrupted sync
/// resumes where it stopped instead of re-fetching the whole library.
///
/// `walkOwnerID` is the engine instance that started the walk and `startedAt`
/// is when. Both exist for one decision: a walk picked up by a *different*
/// engine (so, after a relaunch) or long after it began can no longer assume
/// the service's page boundaries still line up with the ones it already walked
/// — offset pagination over a list that shifted in the meantime silently skips
/// items — so it sets `mergeOnly` and forfeits the authoritative-replace path
/// that would otherwise read those absences as deletions.
struct TentativePagination: Codable, Hashable, Sendable {
    let walkOwnerID: UUID
    let startedAt: Date
    let connectionGeneration: Int
    let accountFingerprint: String
    let query: IntegrationQueryDescriptor
    let startingBoundary: Date?
    let mode: IntegrationSyncMode
    var cursor: String?
    var fetchedItems: [ReadLaterItem]
    /// Every item id this walk has already taken, so a page that carries only
    /// records it has seen can be recognised as a loop rather than progress.
    var seenIDs: Set<String>
    var skippedRecordCount: Int
    var mergeOnly: Bool
}

struct ProviderSnapshot: Codable, Hashable, Sendable {
    var provider: IntegrationProvider
    var accountFingerprint: String
    var connectionGeneration: Int
    var items: [ReadLaterItem]
    var collections: [ReadLaterCollection]
    var committedBoundary: Date?
    var tentativePagination: TentativePagination?
    var lastSuccessfulSync: Date?
    var lastFullSweep: Date?
    var skippedRecordCount: Int

    static func empty(provider: IntegrationProvider, fingerprint: String, generation: Int) -> ProviderSnapshot {
        ProviderSnapshot(provider: provider, accountFingerprint: fingerprint, connectionGeneration: generation, items: [], collections: provider == .readwise ? ReadwiseClient.locationCollections : [], committedBoundary: nil, tentativePagination: nil, lastSuccessfulSync: nil, lastFullSweep: nil, skippedRecordCount: 0)
    }
}

enum ExternalOpenRoute: Hashable, Sendable { case web(URL), file(URL) }

enum IntegrationConnectionState: Hashable, Sendable {
    case disconnected, connecting, connected, syncing, tokenRejected, offlineCache
    case failed(String)
}

struct IntegrationProviderViewState: Identifiable, Hashable, Sendable {
    let provider: IntegrationProvider
    var connection: IntegrationConnectionState
    var items: [ReadLaterItem]
    var collections: [ReadLaterCollection]
    var lastSuccessfulSync: Date?
    var lastFullSweep: Date?
    var skippedRecordCount: Int
    var statusMessage: String?
    var id: IntegrationProvider { provider }
    var isConnected: Bool {
        switch connection {
        case .connected, .syncing, .tokenRejected, .offlineCache, .failed: true
        case .disconnected, .connecting: false
        }
    }
    var canAutoRefresh: Bool {
        switch connection {
        case .connected, .offlineCache, .failed: true
        case .disconnected, .connecting, .syncing, .tokenRejected: false
        }
    }
}

struct IntegrationDownloadState: Hashable, Sendable {
    var progress: Double?
    var message: String
    var isActive: Bool
    var isSuccess: Bool = false
    /// Monotonic ordering across download and move notices, so overlays can
    /// deterministically show the newest one instead of a dictionary-order pick.
    var sequence: Int = 0
}

enum IntegrationError: LocalizedError, Equatable, Sendable {
    case invalidCredential, tokenRejected, rateLimited, invalidResponse, malformedData
    case credentialPersistenceFailed, disconnected, staleGeneration, downloadTooLarge, notPDF, existingDownload, downloadsAreOpen
    case unsupportedDestination, paginationDidNotAdvance
    case server(status: Int)

    var errorDescription: String? {
        switch self {
        case .invalidCredential: "Enter a valid access token."
        case .tokenRejected: "The service rejected this token. Check it and try again."
        case .rateLimited: "The service is temporarily rate limiting requests."
        case .server(let status): "The service returned HTTP \(status)."
        case .invalidResponse: "The service returned an invalid response."
        case .malformedData: "The service returned data Vellum could not read."
        case .credentialPersistenceFailed: "The token was valid, but Vellum could not save it in Keychain."
        case .disconnected: "This service is not connected."
        case .staleGeneration: "A newer connection replaced this request."
        case .downloadTooLarge: "This PDF exceeds Vellum’s download size limit."
        case .notPDF: "The linked file is not a valid PDF."
        case .existingDownload: "A downloaded copy already exists."
        case .downloadsAreOpen: "Close downloaded PDFs from this service before deleting them."
        case .unsupportedDestination: "This item can't be moved to that location."
        case .paginationDidNotAdvance: "The service kept returning the same results instead of the next page."
        }
    }
}

extension String { fileprivate var nilIfEmpty: String? { isEmpty ? nil : self } }
