import Foundation

// The file-coordination seam. Eight members, each one traceable to a rule the
// coordination APIs impose and that a call site would otherwise have to
// remember: coordinate every access, always replace atomically, never stat a
// ubiquitous file, never treat a stale local copy as ready, never leave a
// presenter registered into the background, never drop a conflicting version.
//
// The omissions are as load-bearing as the members:
//   * no `exists(_:)` — `fileExists(atPath:)` materializes a ubiquitous file,
//     so existence is `list(...)` returning the item and nothing else.
//   * no writing-options parameter — `.forReplacing` is the only correct option
//     for Vellum's tmp+rename pattern, so there is no way to pick wrong.
//   * no `isReady(_:)` — readiness is a property of `SyncedItem` and a
//     precondition of `read`, so "downloaded but stale" can't be read as ready.
//   * no presenter-registration API — registration happens on construction and
//     `suspend()`/`resume()` are the only lifecycle verbs.
protocol SyncedContainer: Sendable {
    /// Coordinated read, off the caller's actor. `body` runs inside the
    /// accessor scope, so a nested coordinated access from within it throws
    /// `.nestedCoordination` instead of deadlocking.
    func read<T: Sendable>(
        _ url: URL,
        materializing: Materialization,
        _ body: @Sendable (Data) throws -> T
    ) async throws -> T

    /// The ONLY sanctioned write: always a `.forReplacing` coordinated atomic
    /// replace.
    func replace(_ url: URL, with data: Data) async throws

    func remove(_ url: URL) async throws

    /// The ONLY discovery API. Backed by a metadata query, never by directory
    /// enumeration or an existence check.
    func list(_ directory: URL, matching filter: SyncedItemFilter) async throws -> [SyncedItem]

    /// Typed detection surface. Carries no merge policy of its own.
    var conflicts: AsyncStream<ConflictEvent> { get }

    func resolveConflict(_ event: ConflictEvent) async throws -> ConflictResolution

    /// Remove the presenter and stop the query. Driven by the app layer's
    /// scene-phase handling; the module observes no UIKit notification itself.
    func suspend() async
    /// Re-register, restart, and rescan for conflicts that appeared meanwhile.
    func resume() async
}

extension SyncedContainer {
    func read<T: Sendable>(_ url: URL, _ body: @Sendable (Data) throws -> T) async throws -> T {
        try await read(url, materializing: .requireCurrent, body)
    }

    func data(at url: URL, materializing: Materialization = .requireCurrent) async throws -> Data {
        try await read(url, materializing: materializing) { $0 }
    }

    func list(_ directory: URL) async throws -> [SyncedItem] {
        try await list(directory, matching: .all)
    }
}

/// The nesting guard, shared by every adapter so the fake and the real
/// container fail the same way. Apple's coordination APIs deadlock when a
/// coordinated access is opened inside another one; this turns that into a
/// thrown error that a test can assert on.
enum SyncedContainerAccessor {
    @TaskLocal static var isInside = false

    static func guarded<T>(
        _ url: URL,
        isolation: isolated (any Actor)? = #isolation,
        _ body: () async throws -> T
    ) async throws -> T {
        guard !isInside else { throw SyncedContainerError.nestedCoordination(url) }
        return try await $isInside.withValue(
            true, operation: { try await body() }, isolation: isolation)
    }
}

// MARK: - Routing

/// Which storage discipline a location gets. Local and custom-folder layouts
/// keep the existing uncoordinated tmp+rename path exactly as it is and never
/// construct a container at all; only iCloud is coordinated.
enum StorageAccess: Sendable {
    case direct(root: URL)
    case coordinated(any SyncedContainer, root: URL)
    /// iCloud was chosen but the container could not be opened (no entitlement,
    /// signed out). Represented explicitly so a caller degrades knowingly
    /// instead of silently addressing a container with a nil identifier.
    case unavailable

    /// Synchronous routing with an injected container factory. There is
    /// deliberately NO default factory here: the default would be
    /// `ICloudSyncedContainer()`, whose init performs the potentially lengthy
    /// `url(forUbiquityContainerIdentifier:)` lookup on whatever thread asks —
    /// and the natural mirror of `WebStorageLayout.resolve` is a main-actor
    /// call site. Callers that want the real container use the async form
    /// below, which does that lookup off the caller's thread.
    static func resolve(
        mode: WebStorageMode,
        storeDir: URL,
        icloudRoot: URL?,
        container: @Sendable () -> (any SyncedContainer)?
    ) -> StorageAccess {
        switch mode {
        case .local, .custom:
            let root = WebStorageLayout.resolve(mode: mode, storeDir: storeDir).recordsDir
            return .direct(root: root)
        case .icloud:
            guard let root = icloudRoot else { return .unavailable }
            guard let container = container() else { return .unavailable }
            let layout = WebStorageLayout.pretty(
                root: root, recordsInRoot: true, localStoreDir: storeDir)
            return .coordinated(container, root: layout.recordsDir)
        }
    }

    /// The default path. Safe to call from the main actor: the ubiquity lookup
    /// runs on a detached background task, and the local and custom-folder
    /// modes never reach it at all.
    static func resolve(mode: WebStorageMode, storeDir: URL) async -> StorageAccess {
        switch mode {
        case .local, .custom:
            let root = WebStorageLayout.resolve(mode: mode, storeDir: storeDir).recordsDir
            return .direct(root: root)
        case .icloud:
            let (root, container) = await Task.detached(priority: .utility) {
                WebStorageSettings.resolveICloudRoot()
                let root = WebStorageSettings.icloudVellumRoot
                return (root, root == nil ? nil : ICloudSyncedContainer())
            }.value
            guard let root else { return .unavailable }
            guard let container else { return .unavailable }
            let layout = WebStorageLayout.pretty(
                root: root, recordsInRoot: true, localStoreDir: storeDir)
            return .coordinated(container, root: layout.recordsDir)
        }
    }

    var root: URL? {
        switch self {
        case .direct(let root): return root
        case .coordinated(_, let root): return root
        case .unavailable: return nil
        }
    }

    var container: (any SyncedContainer)? {
        switch self {
        case .coordinated(let container, _): return container
        case .direct, .unavailable: return nil
        }
    }

    var isCoordinated: Bool { container != nil }
}
