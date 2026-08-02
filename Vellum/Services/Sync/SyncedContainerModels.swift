import Foundation

// The vocabulary of the coordination seam. Nothing in here knows that
// `NSFileCoordinator`, `NSFilePresenter`, `NSMetadataQuery` or `NSFileVersion`
// exist — that is the point. Callers hold `any SyncedContainer` and speak in
// these types, so the day the real adapter lands (and the day it is replaced)
// nothing above the seam moves.

/// The iCloud container the app syncs through.
struct SyncedContainerIdentifier: Hashable, Sendable {
    let rawValue: String

    init(rawValue: String) {
        self.rawValue = rawValue
    }

    /// The ONE place the container id is written. Deliberately a literal rather
    /// than `"iCloud." + Bundle.main.bundleIdentifier!`: inside the test host
    /// that derivation yields `iCloud.com.ayushdeolasee.vellum.tests`, which
    /// names a container that does not exist.
    static let vellum = SyncedContainerIdentifier(rawValue: "iCloud.com.ayushdeolasee.vellum")
}

/// Mirrors `NSURLUbiquitousItemDownloadingStatusKey` without exposing it.
enum ItemReadiness: String, Sendable, Codable, CaseIterable {
    case notDownloaded
    case downloaded
    case current

    /// `.downloaded` means A LOCAL COPY EXISTS BUT IS STALE. It is not ready.
    /// Every readiness decision in the app funnels through this one property so
    /// "stale local bytes" can never be mistaken for "the current file".
    var isReady: Bool { self == .current }
}

enum Materialization: Hashable, Sendable {
    /// Default. Anything but `.current` is refused rather than served stale.
    case requireCurrent
    case downloadIfNeeded(timeout: TimeInterval)
}

struct SyncedItem: Hashable, Sendable {
    let url: URL
    let name: String
    let readiness: ItemReadiness
    let byteSize: Int64?
    let contentModifiedAt: Date?
    let hasUnresolvedConflicts: Bool
    let uploadedToCloud: Bool

    init(
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

struct SyncedItemFilter: Hashable, Sendable {
    var fileExtension: String?
    var namePrefix: String?
    var readyOnly: Bool

    init(fileExtension: String? = nil, namePrefix: String? = nil, readyOnly: Bool = false) {
        self.fileExtension = fileExtension
        self.namePrefix = namePrefix
        self.readyOnly = readyOnly
    }

    static let all = SyncedItemFilter()

    func matches(_ item: SyncedItem) -> Bool {
        if let fileExtension, item.url.pathExtension != fileExtension { return false }
        if let namePrefix, !item.name.hasPrefix(namePrefix) { return false }
        if readyOnly, !item.readiness.isReady { return false }
        return true
    }
}

// MARK: - Conflicts

struct ConflictVersion: Hashable, Sendable {
    /// `NSFileVersion.persistentIdentifier`, stringified.
    let id: String
    let modifiedAt: Date?
    let originatingDeviceName: String?
    let isCurrent: Bool

    init(id: String, modifiedAt: Date? = nil, originatingDeviceName: String? = nil, isCurrent: Bool = false) {
        self.id = id
        self.modifiedAt = modifiedAt
        self.originatingDeviceName = originatingDeviceName
        self.isCurrent = isCurrent
    }
}

struct ConflictEvent: Hashable, Sendable {
    let url: URL
    let detectedAt: Date
    /// Includes the current version; count >= 2.
    let versions: [ConflictVersion]

    init(url: URL, detectedAt: Date, versions: [ConflictVersion]) {
        self.url = url
        self.detectedAt = detectedAt
        self.versions = versions
    }

    var currentVersion: ConflictVersion? { versions.first(where: \.isCurrent) }
    var losingVersions: [ConflictVersion] { versions.filter { !$0.isCurrent } }
}

enum ConflictResolution: Sendable, Equatable {
    /// TN2336's minimum bar: observe and preserve. The losers' bytes are copied
    /// aside, never dropped.
    case keptCurrent(archivedLosers: [URL])
    /// A real content merge. Supplied later; the seam does not implement one.
    case merged(URL)
    /// Still unresolved — it will be reported again on the next scan.
    case deferred
}

enum SyncedContainerError: Error, Sendable, Equatable {
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
