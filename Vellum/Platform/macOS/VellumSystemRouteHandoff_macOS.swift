#if os(macOS)
import Foundation
import Observation

/// Mac system entry points share the widget's opaque route contract. Opening
/// is registered immediately; the observable request only presents the window.
@MainActor
@Observable
final class VellumSystemRouteHandoff {
    struct Request: Equatable, Identifiable, Sendable {
        let id = UUID()
        let route: VellumSystemRoute
    }

    static let shared = VellumSystemRouteHandoff()

    private(set) var pendingRequest: Request?
    @ObservationIgnored private weak var workspace: WorkspaceStore?
    @ObservationIgnored private var launchRoutes: [VellumSystemRoute] = []

    private init() {}

    func attach(to workspace: WorkspaceStore) {
        self.workspace = workspace
        for route in launchRoutes { workspace.openSystemRoute(route) }
        launchRoutes.removeAll()
    }

    @discardableResult
    func submit(_ route: VellumSystemRoute) -> Bool {
        guard VellumSystemRoute.isValidItemID(route.itemID) else { return false }
        if let workspace {
            guard workspace.openSystemRoute(route) else { return false }
        } else {
            // A foreground intent may arrive before App.init finishes. Keep
            // every accepted open, even if window presentation is coalesced.
            launchRoutes.append(route)
        }
        pendingRequest = Request(route: route)
        return true
    }

    func consume(_ id: Request.ID) -> VellumSystemRoute? {
        guard pendingRequest?.id == id else { return nil }
        defer { pendingRequest = nil }
        return pendingRequest?.route
    }
}

/// Resolve private targets only inside the app, using its normal openers and
/// document lifecycle. No path or provider identifier is exposed in a URL.
@MainActor
enum VellumSystemRouteOpener {
    @discardableResult
    static func open(
        _ route: VellumSystemRoute,
        workspace: WorkspaceStore,
        snapshotStore: VellumWidgetSnapshotStore? = nil
    ) async -> Bool {
        let snapshot = await Task.detached(priority: .userInitiated) {
            (snapshotStore ?? VellumWidgetSnapshotStore.resolve())?.load()
        }.value
        guard !Task.isCancelled else { return false }
        guard let item = snapshot?.item(for: route), item.shelf == route.shelf else {
            return unavailable(in: workspace)
        }

        switch item.target {
        case .file(let path, let recordedPath):
            let resolved = await Task.detached(priority: .userInitiated) {
                let recent = RecentFilesService.getRecent().first {
                    $0.kind == .pdf && ($0.pdfPath == recordedPath || $0.pdfPath == path)
                }
                let currentPath = recent.map { RecentFilesService.resolvedPath(for: $0) } ?? path
                let canonical = (try? PdfDocumentLoader.canonicalize(currentPath)) ?? currentPath
                return (path: canonical, recent: recent)
            }.value
            guard !Task.isCancelled else { return false }
            if activateFile(
                paths: [resolved.path, path, recordedPath],
                docId: resolved.recent?.docId,
                workspace: workspace
            ) { return true }
            guard let app = availableApp(in: workspace) else { return false }
            await app.openFiles(paths: [resolved.path])
            guard !Task.isCancelled, app.error == nil else { return false }
            if let recent = resolved.recent, recent.pdfPath != resolved.path {
                // Never delete a newer visit if the recents row changed while
                // opening. The AppStore has already recorded the resolved path.
                await Task.detached(priority: .utility) {
                    _ = RecentFilesService.removeIfUnchanged(recent)
                }.value
            }
            return true

        case .url(let address):
            return await openWeb(address, workspace: workspace)

        case .readLater(let itemID):
            await workspace.integrations.start()
            guard !Task.isCancelled else { return false }
            guard let readLater = workspace.integrations.searchableItems.first(where: {
                $0.id == itemID
            }) else { return unavailable(in: workspace) }
            let destination: ExternalOpenRoute
            do {
                destination = try await workspace.integrations.route(for: readLater)
            } catch {
                guard !Task.isCancelled else { return false }
                workspace.focusedPane.app.error = error.localizedDescription
                return false
            }
            guard !Task.isCancelled else { return false }
            // Disconnect/removal can happen while resolving an offline copy.
            guard workspace.integrations.searchableItems.contains(where: { $0.id == itemID })
            else { return unavailable(in: workspace) }
            switch destination {
            case .web(let url):
                return await openWeb(url.absoluteString, workspace: workspace)
            case .file(let url):
                let path = await Task.detached(priority: .userInitiated) {
                    (try? PdfDocumentLoader.canonicalize(url.path)) ?? url.path
                }.value
                guard !Task.isCancelled else { return false }
                guard workspace.integrations.searchableItems.contains(where: { $0.id == itemID })
                else { return unavailable(in: workspace) }
                if activateFile(paths: [path, url.path], docId: nil, workspace: workspace) {
                    return true
                }
                guard let app = availableApp(in: workspace) else { return false }
                await app.openFiles(paths: [path])
                return !Task.isCancelled && app.error == nil
            }
        }
    }

    private static func openWeb(_ address: String, workspace: WorkspaceStore) async -> Bool {
        guard !Task.isCancelled else { return false }
        guard let normalized = try? WebUrl.normalize(address) else {
            return unavailable(in: workspace)
        }
        if let existing = workspace.allTabs.first(where: {
            $0.tab.document?.kind == .web && $0.tab.document?.pdfPath == normalized
        }) {
            workspace.activateWorkspaceTab(paneId: existing.paneId, tabId: existing.tab.id)
            return true
        }
        guard let app = availableApp(in: workspace) else { return false }
        await app.openUrl(normalized)
        return !Task.isCancelled && app.error == nil
    }

    private static func activateFile(
        paths: [String], docId: String?, workspace: WorkspaceStore
    ) -> Bool {
        guard let existing = workspace.allTabs.first(where: { entry in
            guard let document = entry.tab.document, document.kind == .pdf else { return false }
            if let docId, !docId.isEmpty, let existingID = document.docId, !existingID.isEmpty {
                return docId == existingID
            }
            return paths.contains(document.pdfPath)
        }) else { return false }
        workspace.activateWorkspaceTab(paneId: existing.paneId, tabId: existing.tab.id)
        return true
    }

    private static func availableApp(in workspace: WorkspaceStore) -> AppStore? {
        let app = workspace.focusedPane.app
        guard !app.hasPendingDocumentAdmission else {
            app.error = "Vellum is opening another document. Try again when it finishes."
            return nil
        }
        return app
    }

    @discardableResult
    private static func unavailable(in workspace: WorkspaceStore) -> Bool {
        workspace.focusedPane.app.error = "That document is no longer available in your Vellum shortcuts. Open it in Vellum and choose it again."
        return false
    }
}
#endif
