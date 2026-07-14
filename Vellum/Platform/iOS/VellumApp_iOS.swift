#if os(iOS)
import SwiftUI
import UIKit

/// iPad app entry. Mirrors the macOS `VellumApp` wiring — one window-global
/// `WorkspaceStore` owning the split-screen pane tree, each pane its own
/// store-triple — but hosts a touch-first `WindowGroup` shell. macOS persists
/// reading positions via an NSApplication terminate hook; iOS has no terminate
/// callback, so the flush hangs off scene-phase `.background` instead, wrapped
/// in a `beginBackgroundTask` so the system grants time for the writes.
@main
struct VellumApp_iOS: App {
    @State private var themeStore: ThemeStore
    @State private var workspace: WorkspaceStore
    @State private var showStorageChoice = false
    @Environment(\.scenePhase) private var scenePhase

    init() {
        let theme = ThemeStore()
        let sessions = DocumentSessionManager()
        let workspace = WorkspaceStore(sessions: sessions)
        _themeStore = State(initialValue: theme)
        _workspace = State(initialValue: workspace)
    }

    var body: some Scene {
        WindowGroup {
            ContentView_iOS()
                .task { await launchMaintenance() }
                .sheet(isPresented: $showStorageChoice) {
                    StorageLocationChoiceSheet()
                        .environment(\.palette, themeStore.palette)
                        .preferredColorScheme(themeStore.colorScheme)
                        .tint(themeStore.palette.primary)
                }
                .environment(themeStore)
                .environment(workspace)
                .environment(workspace.openRouterCatalog)
                .environment(workspace.chatgptAuth)
                .environment(\.palette, themeStore.palette)
                .preferredColorScheme(themeStore.colorScheme)
                .tint(themeStore.palette.primary)
        }
        .commands {
            VellumCommands_iOS(workspace: workspace)
        }
        .onChange(of: scenePhase) { _, phase in
            // Persist the split layout and last_page for every open tab in
            // every pane when leaving the foreground — the iOS analogue of the
            // macOS terminate hook.
            if phase == .background {
                flushOnBackground()
            }
        }
    }

    /// Launch-time TTL eviction of derived data (issue #37 PR B / issue #29):
    /// the extracted-text cache, plus web-snapshot artifacts for pages the user
    /// never saved or annotated. Time-based only — never because a source file
    /// is missing. Then finish any interrupted storage-location move and present
    /// the first-launch storage choice if the user hasn't made one yet.
    @MainActor
    private func launchMaintenance() async {
        let openDocuments = workspace.root.allLeaves()
            .flatMap { $0.app.tabs }.compactMap(\.document)
        let openPaths = Set(openDocuments.filter { $0.kind == .pdf }.map(\.pdfPath))
        let openWebUrls = Set(openDocuments.filter { $0.kind == .web }.map(\.pdfPath))
        let cutoff = Calendar.current.date(byAdding: .month, value: -6, to: .now) ?? .now

        // Resolve the iCloud ubiquity container off-main FIRST: it can block,
        // and both the launch sweep (to name the iCloud layout) and the
        // first-launch sheet (to offer/disable the iCloud option) need it
        // resolved. Awaited so the sheet below reflects real availability.
        await Task.detached(priority: .utility) {
            WebStorageSettings.resolveICloudRoot()
        }.value

        Task.detached(priority: .background) {
            // Finish any interrupted storage-location move and fold legacy-local
            // strays into the active layout before the evictors walk the store.
            // Routed through the relocator so it can't run concurrently with a
            // location change the user makes in the first-launch sheet below
            // (single relocation runner — parity plan do-not-reintroduce #9).
            await WebStorageRelocator.sweepAtLaunch()
            await PageTextCache.shared.evictStale(olderThan: cutoff, excludingPaths: openPaths)
            WebLibrary.evictStaleUnsavedSnapshots(olderThan: cutoff, excludingUrls: openWebUrls)
        }

        showStorageChoice = WebStorageSettings.needsFirstLaunchChoice
    }

    /// Scene-background flush. macOS drains these on `applicationShouldTerminate`;
    /// iOS gets a `beginBackgroundTask` window instead so the last_page /
    /// saveFile writes and the coalesced cache / conversation flushes complete
    /// before the app is suspended.
    @MainActor
    private func flushOnBackground() {
        let workspace = self.workspace
        workspace.saveNow()

        let token = BackgroundFlushToken()
        token.id = UIApplication.shared.beginBackgroundTask(withName: "VellumBackgroundFlush") {
            Task { @MainActor in token.end() }
        }

        Task { @MainActor in
            defer { token.end() }
            for pane in workspace.root.allLeaves() {
                for tab in pane.app.tabs {
                    try? await workspace.sessions.setDocumentMetadata(
                        sessionId: tab.id, key: "last_page", value: String(tab.currentPage))
                    try? await workspace.sessions.saveFile(sessionId: tab.id)
                }
            }
            // Drain the coalesced background flushes so a page-text cache write
            // (issue #37) or an in-flight conversation blob (do-not-reintroduce
            // #8) still lands if the app is suspended right after backgrounding.
            // (Per-pane scratchpad flush joins here once Phase 5 lands.)
            await PageTextPersister.awaitInFlightFlushes()
            await AiPersistence.awaitPendingFlush()
        }
    }
}

/// Holds the `beginBackgroundTask` identifier so the expiration handler and the
/// flush task can each end it exactly once, on the main actor.
@MainActor
private final class BackgroundFlushToken {
    var id: UIBackgroundTaskIdentifier = .invalid

    func end() {
        guard id != .invalid else { return }
        UIApplication.shared.endBackgroundTask(id)
        id = .invalid
    }
}
#endif
