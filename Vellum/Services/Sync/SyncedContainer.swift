import Foundation
import VellumCore

typealias SyncedContainer = VellumCore.SyncedContainer
typealias SyncedContainerAccessor = VellumCore.SyncedContainerAccessor

// MARK: - Routing

/// Which storage discipline a location gets. Local and custom-folder layouts
/// keep the existing uncoordinated tmp+rename path exactly as it is and never
/// construct a container. Both synced backends use a container lease;
/// only the iCloud implementation uses Apple file coordination.
enum StorageAccess: Sendable {
    case direct(root: URL)
    case coordinated(any SyncedContainer, root: URL)
    /// The selected synced backend could not be opened.
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
            guard let root = icloudRoot, let container = container() else { return .unavailable }
            return .coordinated(container, root: WebStorageLayout.iCloud(root: root).recordsDir)
        case .syncedFolder:
            return .unavailable
        }
    }

    /// S5b injects its folder container here. A missing adapter must never
    /// lend a direct store pointed at the shared folder.
    typealias FolderContainerFactory = @Sendable (WebStorageLayout) async -> (any SyncedContainer)?

    static func resolveSyncedFolder(
        layout: WebStorageLayout, factory: FolderContainerFactory
    ) async -> StorageAccess {
        guard layout.backend == .syncedFolder,
              let container = await factory(layout) else { return .unavailable }
        return .coordinated(container, root: layout.recordsDir)
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
            guard RuntimeProfile.current.syncEnabled else { return .unavailable }
            let (root, container) = await Task.detached(priority: .utility) {
                WebStorageSettings.resolveICloudRoot()
                let root = WebStorageSettings.icloudVellumRoot
                return (root, root == nil ? nil : ICloudSyncedContainer())
            }.value
            return resolve(mode: .icloud, storeDir: storeDir, icloudRoot: root) { container }
        case .syncedFolder:
            return .unavailable
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

/// Open the root selected and scoped by WebStorageSettings.
enum SharedFolderContainerFactory {
    static func make(root: URL) async -> (any SyncedContainer)? {
        await Task.detached(priority: .utility) {
            guard let values = try? root.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]),
                  values.isDirectory == true, values.isSymbolicLink != true else { return nil }
            let container = FolderSyncedContainer(root: root, store: LocalFolderFileStore(root: root),
                                                 watcher: FolderDirectoryWatcher(), merge: ConflictMerge.decide)
            await container.resume()
            return container
        }.value
    }
}
