import Foundation
import VellumCore

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

    /// The active build profile owns the fixed container identifier. This must
    /// not derive directly from the test host bundle identifier.
    static var vellum: SyncedContainerIdentifier {
        SyncedContainerIdentifier(rawValue: RuntimeProfile.current.cloudContainerIdentifier)
    }
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

typealias ItemReadiness = VellumCore.ItemReadiness
typealias Materialization = VellumCore.Materialization
typealias SyncedItem = VellumCore.SyncedItem
typealias SyncedItemFilter = VellumCore.SyncedItemFilter
typealias ConflictVersion = VellumCore.ConflictVersion
typealias ConflictEvent = VellumCore.ConflictEvent
typealias ConflictResolution = VellumCore.ConflictResolution
typealias SyncedContainerError = VellumCore.SyncedContainerError
