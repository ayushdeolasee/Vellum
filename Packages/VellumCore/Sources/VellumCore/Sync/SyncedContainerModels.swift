import Foundation

public enum Materialization: Hashable, Sendable {
    /// Default. Anything but `.current` is refused rather than served stale.
    case requireCurrent
    case downloadIfNeeded(timeout: TimeInterval)
}

public struct SyncedItem: Hashable, Sendable {
    public let url: URL
    public let name: String
    public let readiness: ItemReadiness
    public let byteSize: Int64?
    public let contentModifiedAt: Date?
    public let hasUnresolvedConflicts: Bool
    public let uploadedToCloud: Bool

    public init(
        url: URL,
        name: String,
        readiness: ItemReadiness,
        byteSize: Int64? = nil,
        contentModifiedAt: Date? = nil,
        hasUnresolvedConflicts: Bool = false,
        uploadedToCloud: Bool = false
    ) {
        self.url = url
        self.name = name
        self.readiness = readiness
        self.byteSize = byteSize
        self.contentModifiedAt = contentModifiedAt
        self.hasUnresolvedConflicts = hasUnresolvedConflicts
        self.uploadedToCloud = uploadedToCloud
    }
}

public struct SyncedItemFilter: Hashable, Sendable {
    public var fileExtension: String?
    public var namePrefix: String?
    public var readyOnly: Bool

    public init(fileExtension: String? = nil, namePrefix: String? = nil, readyOnly: Bool = false) {
        self.fileExtension = fileExtension
        self.namePrefix = namePrefix
        self.readyOnly = readyOnly
    }

    public static let all = SyncedItemFilter()

    public func matches(_ item: SyncedItem) -> Bool {
        if let fileExtension, item.url.pathExtension != fileExtension { return false }
        if let namePrefix, !item.name.hasPrefix(namePrefix) { return false }
        if readyOnly, !item.readiness.isReady { return false }
        return true
    }
}

// MARK: - Conflicts

public struct ConflictVersion: Hashable, Sendable {
    /// `NSFileVersion.persistentIdentifier`, stringified.
    public let id: String
    public let modifiedAt: Date?
    public let originatingDeviceName: String?
    public let isCurrent: Bool

    public init(id: String, modifiedAt: Date? = nil, originatingDeviceName: String? = nil, isCurrent: Bool = false) {
        self.id = id
        self.modifiedAt = modifiedAt
        self.originatingDeviceName = originatingDeviceName
        self.isCurrent = isCurrent
    }
}

public struct ConflictEvent: Hashable, Sendable {
    public let url: URL
    public let detectedAt: Date
    /// Includes the current version; count >= 2.
    public let versions: [ConflictVersion]

    public init(url: URL, detectedAt: Date, versions: [ConflictVersion]) {
        self.url = url
        self.detectedAt = detectedAt
        self.versions = versions
    }

    public var currentVersion: ConflictVersion? { versions.first(where: \.isCurrent) }
    public var losingVersions: [ConflictVersion] { versions.filter { !$0.isCurrent } }
}

public enum ConflictResolution: Sendable, Equatable {
    /// TN2336's minimum bar: observe and preserve. The losers' bytes are copied
    /// aside, never dropped.
    case keptCurrent(archivedLosers: [URL])
    /// A real content merge. Supplied later; the seam does not implement one.
    case merged(URL)
    /// Still unresolved — it will be reported again on the next scan.
    case deferred
}

public enum SyncedContainerError: Error, Sendable, Equatable {
    /// No entitlement, or the user is signed out of iCloud.
    case unavailable
    case notReady(URL, ItemReadiness)
    /// Coordinating inside a coordinated accessor deadlocks; we throw instead.
    case nestedCoordination(URL)
    /// `NSUserCancelledError`. A normal, retryable outcome — not a failure.
    case cancelled
    case timedOut(URL)
    case io(String)
}
