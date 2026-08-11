#if os(iOS)
import Foundation
import Observation

/// The one runtime seam for system entry points. Both a validated URL and an
/// App Intent enqueue the same small route; the app scene consumes it once.
@MainActor
@Observable
final class VellumSystemRouteHandoff {
    struct Request: Equatable, Identifiable, Sendable {
        let id = UUID()
        let route: VellumSystemRoute
    }

    static let shared = VellumSystemRouteHandoff()

    private(set) var pendingRequest: Request?

    private init() {}

    func submit(_ route: VellumSystemRoute) {
        pendingRequest = Request(route: route)
    }

    func consume(_ id: Request.ID) -> VellumSystemRoute? {
        guard pendingRequest?.id == id else { return nil }
        defer { pendingRequest = nil }
        return pendingRequest?.route
    }
}

/// Resolves the opaque route against the app-authored snapshot, then hands the
/// concrete target to the same openers used by Home and the read-later list.
@MainActor
enum VellumSystemRouteOpener {
    @discardableResult
    static func open(
        _ route: VellumSystemRoute,
        workspace: WorkspaceStore,
        snapshotStore: VellumWidgetSnapshotStore? = .resolve()
    ) async -> Bool {
        guard let snapshot = snapshotStore?.load(),
              let item = snapshot.item(for: route),
              item.shelf == route.shelf
        else { return false }

        let app = workspace.focusedPane.app
        guard !app.isLoading else { return false }

        switch item.target {
        case .file(let path, let recordedPath):
            let intent = HomeOpenResolver.intent(
                for: .file(path: path, recordedPath: recordedPath),
                resolveExisting: DocumentImport.resolveExistingPath)
            guard case .file(let resolvedPath, let staleRecentPath) = intent else { return false }
            if let staleRecentPath { _ = RecentFilesService.remove(path: staleRecentPath) }
            await app.openFiles(paths: [resolvedPath])
        case .url(let url):
            let intent = HomeOpenResolver.intent(
                for: .url(url),
                resolveExisting: DocumentImport.resolveExistingPath)
            guard case .url(let address) = intent else { return false }
            await app.openUrl(address)
        case .readLater(let itemID):
            await workspace.integrations.start()
            guard let readLater = workspace.integrations.searchableItems.first(where: {
                $0.id == itemID
            }) else { return false }
            guard let destination = try? await workspace.integrations.route(for: readLater)
            else { return false }
            switch destination {
            case .web(let url): await app.openUrl(url.absoluteString)
            case .file(let url): await app.openFiles(paths: [url.path])
            }
        }
        guard app.error == nil else { return false }
        // `activeTabId` does not change when the route resolves to the tab that
        // is already active. Tell the compact shell explicitly so a widget tap
        // from Home still returns to the reader in that case.
        NotificationCenter.default.post(
            name: .vellumSystemRouteDidOpenDocument,
            object: nil)
        return true
    }
}

extension Notification.Name {
    static let vellumSystemRouteDidOpenDocument = Notification.Name(
        "vellum.system-route-did-open-document")
}
#endif
