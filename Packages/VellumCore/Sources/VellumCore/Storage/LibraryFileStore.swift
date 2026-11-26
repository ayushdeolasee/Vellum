import Foundation

/// The file vocabulary used above the local/iCloud routing decision. Callers
/// cannot enumerate, stat, or write a synced URL behind coordination because
/// those operations simply do not exist here.
public protocol LibraryFileStore: Sendable {
    func read(_ url: URL) async throws -> Data?
    func replace(_ url: URL, with data: Data) async throws
    func remove(_ url: URL) async throws
    func list(_ directory: URL, suffix: String?) async throws -> [LibraryFileEntry]
    var isCoordinated: Bool { get }
}

public struct LibraryFileEntry: Sendable, Equatable {
    public var url: URL
    public var name: String
    public var readiness: ItemReadiness
    public var byteSize: Int64?
    public var contentModifiedAt: Date?

    public init(url: URL, name: String, readiness: ItemReadiness, byteSize: Int64?,
                contentModifiedAt: Date?) {
        self.url = url
        self.name = name
        self.readiness = readiness
        self.byteSize = byteSize
        self.contentModifiedAt = contentModifiedAt
    }
}

public enum LibraryFileError: Error, Sendable, Equatable {
    case notDownloaded(URL, ItemReadiness)
    case outsideAllowedRoot(URL)
    case symbolicLink(URL)
    case retryable
    case unavailable
    case nestedCoordination(URL)
    case io(String)
}

/// Mirrors `NSURLUbiquitousItemDownloadingStatusKey` without exposing it.
public enum ItemReadiness: String, Sendable, Codable, CaseIterable {
    case notDownloaded
    case downloaded
    case current

    /// `.downloaded` means A LOCAL COPY EXISTS BUT IS STALE. It is not ready.
    /// Every readiness decision in the app funnels through this one property so
    /// "stale local bytes" can never be mistaken for "the current file".
    public var isReady: Bool { self == .current }
}
