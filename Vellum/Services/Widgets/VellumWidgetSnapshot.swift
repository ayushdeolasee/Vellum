import CryptoKit
import Foundation

/// The only library data visible to the widget extension. The app builds this
/// small, versioned projection; the extension never walks Vellum's library or
/// talks to a read-later provider.
struct VellumWidgetSnapshot: Codable, Equatable, Sendable {
    static let currentVersion = 1
    static let maximumItemsPerShelf = 8

    var version: Int
    var generatedAt: Date
    var recentDocuments: [VellumWidgetItem]
    var readLaterItems: [VellumWidgetItem]

    init(
        generatedAt: Date,
        recentDocuments: [VellumWidgetItem],
        readLaterItems: [VellumWidgetItem]
    ) {
        version = Self.currentVersion
        self.generatedAt = generatedAt
        self.recentDocuments = Array(recentDocuments.prefix(Self.maximumItemsPerShelf))
        self.readLaterItems = Array(readLaterItems.prefix(Self.maximumItemsPerShelf))
    }

    static func empty(at date: Date = .now) -> Self {
        Self(generatedAt: date, recentDocuments: [], readLaterItems: [])
    }

    var allItems: [VellumWidgetItem] { recentDocuments + readLaterItems }

    func item(for route: VellumSystemRoute) -> VellumWidgetItem? {
        items(for: route.shelf).first { $0.id == route.itemID }
    }

    func items(for shelf: VellumWidgetShelf) -> [VellumWidgetItem] {
        switch shelf {
        case .recent: recentDocuments
        case .readLater: readLaterItems
        }
    }

    /// Treat the App Group file as an input boundary. A newer schema or an
    /// oversized/corrupt projection is ignored instead of being partially used.
    var isValid: Bool {
        guard version == Self.currentVersion,
              recentDocuments.count <= Self.maximumItemsPerShelf,
              readLaterItems.count <= Self.maximumItemsPerShelf
        else { return false }

        let ids = allItems.map(\.id)
        return Set(ids).count == ids.count && allItems.allSatisfy(\.isValid)
    }
}

enum VellumWidgetShelf: String, Codable, CaseIterable, Equatable, Hashable, Sendable {
    case recent
    case readLater = "read-later"

    var title: String {
        switch self {
        case .recent: "Recent Documents"
        case .readLater: "Read Later"
        }
    }
}

struct VellumWidgetItem: Codable, Equatable, Hashable, Identifiable, Sendable {
    let id: String
    let shelf: VellumWidgetShelf
    let title: String
    let subtitle: String
    let systemImage: String
    let date: Date?
    let target: VellumWidgetOpenTarget

    init(
        shelf: VellumWidgetShelf,
        title: String,
        subtitle: String,
        systemImage: String,
        date: Date?,
        target: VellumWidgetOpenTarget
    ) {
        self.shelf = shelf
        self.title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        self.subtitle = subtitle.trimmingCharacters(in: .whitespacesAndNewlines)
        self.systemImage = systemImage
        self.date = date
        self.target = target
        id = Self.routeID(shelf: shelf, target: target)
    }

    var deepLink: URL? {
        VellumDeepLink.url(for: VellumSystemRoute(shelf: shelf, itemID: id))
    }

    var isValid: Bool {
        !title.isEmpty && title.count <= 512
            && subtitle.count <= 1_024
            && systemImage.count <= 128
            && VellumSystemRoute.isValidItemID(id)
            && target.isValid
    }

    private static func routeID(shelf: VellumWidgetShelf, target: VellumWidgetOpenTarget) -> String {
        let digest = SHA256.hash(data: Data("\(shelf.rawValue)|\(target.identity)".utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}

enum VellumWidgetOpenTarget: Codable, Equatable, Hashable, Sendable {
    case file(path: String, recordedPath: String)
    case url(String)
    case readLater(itemID: String)

    fileprivate var identity: String {
        switch self {
        case .file(let path, let recordedPath): "file|\(path)|\(recordedPath)"
        case .url(let url): "url|\(url)"
        case .readLater(let itemID): "read-later|\(itemID)"
        }
    }

    var isValid: Bool {
        switch self {
        case .file(let path, let recordedPath):
            return path.utf8.count <= 8_192 && recordedPath.utf8.count <= 8_192
                && path.hasPrefix("/") && recordedPath.hasPrefix("/")
                && !path.contains("\0") && !recordedPath.contains("\0")
        case .url(let value):
            guard value.utf8.count <= 8_192, let url = URL(string: value) else { return false }
            guard let scheme = url.scheme?.lowercased(), ["http", "https"].contains(scheme)
            else { return false }
            return url.host()?.isEmpty == false
        case .readLater(let itemID):
            return !itemID.isEmpty && itemID.utf8.count <= 1_024 && !itemID.contains("\0")
        }
    }
}

enum VellumWidgetKind {
    static let recentDocuments = "VellumRecentDocuments"
    static let readLater = "VellumReadLater"
}
