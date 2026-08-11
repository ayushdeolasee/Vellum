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

/// Single resolver for Vellum's ubiquity container root. Web storage and the
/// file-coordination presenter both derive their roots from this cache, so the
/// app cannot address one iCloud tree for direct web paths and another for
/// coordinated reads/writes.
enum VellumUbiquityContainerRoot {
    static let documentsDirectoryName = "Documents"

    private enum RootState {
        case resolving
        case resolved(URL?)
    }

    #if DEBUG
    static let fakeRootEnvironmentKey = "VELLUM_FAKE_UBIQUITY_ROOT"

    /// Test seam for the blocking Foundation lookup. Production code never sets
    /// this; the DEBUG launch-environment seam below is the sanctioned way to
    /// exercise iCloud layouts before the entitlement cutover.
    nonisolated(unsafe) static var rootLookupOverride: (@Sendable (SyncedContainerIdentifier) -> URL?)? {
        get {
            lock.lock()
            let override = _rootLookupOverride
            lock.unlock()
            return override
        }
        set {
            lock.lock()
            _rootLookupOverride = newValue
            lock.unlock()
        }
    }

    private nonisolated(unsafe) static var _rootLookupOverride:
        (@Sendable (SyncedContainerIdentifier) -> URL?)?
    private nonisolated(unsafe) static var waitForResolvingRootObserver:
        (@Sendable (SyncedContainerIdentifier) -> Void)?

    static func observeWaitForResolvingRootForTests(
        _ observer: (@Sendable (SyncedContainerIdentifier) -> Void)?
    ) {
        lock.lock()
        waitForResolvingRootObserver = observer
        lock.unlock()
    }
    #endif

    private nonisolated(unsafe) static var roots: [String: RootState] = [:]
    private static let lock = NSCondition()

    /// Blocking on first real use. Call from a detached/background context,
    /// then read `cachedDocumentsRoot(for:)` from UI-facing code.
    static func root(
        for identifier: SyncedContainerIdentifier = .vellum,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> URL? {
        lock.lock()
        while true {
            switch roots[identifier.rawValue] {
            case .resolved(let cached):
                lock.unlock()
                return cached
            case .resolving:
                #if DEBUG
                let observer = waitForResolvingRootObserver
                lock.unlock()
                observer?(identifier)
                lock.lock()
                if case .resolving = roots[identifier.rawValue] {
                    lock.wait()
                }
                #else
                lock.wait()
                #endif
            case nil:
                roots[identifier.rawValue] = .resolving
                lock.unlock()
                let resolved: URL?
                #if DEBUG
                resolved = fakeRoot(from: environment) ?? lookupRoot(for: identifier)
                #else
                resolved = lookupRoot(for: identifier)
                #endif
                lock.lock()
                roots[identifier.rawValue] = .resolved(resolved)
                lock.broadcast()
                lock.unlock()
                return resolved
            }
        }
    }

    static func documentsRoot(
        for identifier: SyncedContainerIdentifier = .vellum,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> URL? {
        root(for: identifier, environment: environment)?
            .appendingPathComponent(documentsDirectoryName, isDirectory: true)
    }

    /// Non-blocking read of the cached answer. Nil means either "not resolved
    /// yet" or "resolved unavailable"; callers degrade to local in both cases.
    static func cachedDocumentsRoot(for identifier: SyncedContainerIdentifier = .vellum) -> URL? {
        lock.lock()
        let root: URL?
        if case .resolved(let cached) = roots[identifier.rawValue] {
            root = cached
        } else {
            root = nil
        }
        lock.unlock()
        return root?.appendingPathComponent(documentsDirectoryName, isDirectory: true)
    }

    private static func lookupRoot(for identifier: SyncedContainerIdentifier) -> URL? {
        #if DEBUG
        lock.lock()
        let override = _rootLookupOverride
        lock.unlock()
        if let override { return override(identifier) }
        #endif
        return FileManager.default.url(forUbiquityContainerIdentifier: identifier.rawValue)
    }

    #if DEBUG
    private static func fakeRoot(from environment: [String: String]) -> URL? {
        guard let raw = environment[fakeRootEnvironmentKey]?
            .trimmingCharacters(in: .whitespacesAndNewlines),
            raw.isEmpty == false
        else { return nil }
        let expanded = NSString(string: raw).expandingTildeInPath
        return URL(fileURLWithPath: expanded, isDirectory: true).standardizedFileURL
    }

    static func resetCacheForTests() {
        lock.lock()
        roots.removeAll()
        _rootLookupOverride = nil
        waitForResolvingRootObserver = nil
        lock.broadcast()
        lock.unlock()
    }
    #endif
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
