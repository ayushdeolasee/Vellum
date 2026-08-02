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
    @State private var inkRegistry: InkRegistry_iOS
    @State private var showStorageChoice = false
    @Environment(\.scenePhase) private var scenePhase

    init() {
        let theme = ThemeStore()
        let sessions = DocumentSessionManager()
        let workspace = WorkspaceStore(sessions: sessions)
        _themeStore = State(initialValue: theme)
        _workspace = State(initialValue: workspace)
        _inkRegistry = State(initialValue: InkRegistry_iOS())
    }

    var body: some Scene {
        WindowGroup {
            ContentView_iOS()
                .task { await launchMaintenance() }
                .onOpenURL { url in handleIncomingFile(url) }
                .sheet(isPresented: $showStorageChoice) {
                    StorageLocationChoiceSheet()
                        .environment(\.palette, themeStore.palette)
                        .preferredColorScheme(themeStore.colorScheme)
                        .tint(themeStore.palette.primary)
                }
                .environment(themeStore)
                .environment(workspace)
                .environment(inkRegistry)
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

    /// Files-app open / share-sheet "Open in Vellum" for a registered type
    /// (.pdf, .vellumweb, .vellum). The iOS analogue of macOS's
    /// `NSApplicationDelegate.application(_:open:)`: it copies the
    /// security-scoped file into the writable library (or stages a bundle in
    /// tmp/) off the main actor, then hands the local paths to the shell
    /// through the SAME `vellumOpenFile` channel ⌘O uses — a payload means
    /// "open these", no payload still means "show the picker".
    @MainActor
    private func handleIncomingFile(_ url: URL) {
        Task {
            let paths = await Task.detached(priority: .userInitiated) {
                DocumentImport.importPicked([url])
            }.value
            guard !paths.isEmpty else { return }
            NotificationCenter.default.post(
                name: .vellumOpenFile, object: nil, userInfo: ["paths": paths])
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
        // The text cache excludes open documents by STORAGE KEY now (docId when
        // stamped, else path hash) — the same key their lookup/persister used.
        let openKeys = Set(
            openDocuments.filter { $0.kind == .pdf }
                .map { DocumentIdentity.storageKey(for: $0) })
        let openWebUrls = Set(openDocuments.filter { $0.kind == .web }.map(\.pdfPath))

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
            // TTL eviction of derived data, using the user's chosen retention
            // window (Settings ▸ Storage ▸ Housekeeping; "Never" skips it).
            await StorageHousekeeping.runCleanup(
                openPdfKeys: openKeys, openWebUrls: openWebUrls)
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
            // Tabs closed moments ago finish their metadata write and session
            // close behind the UI (AppStore.closeTab) and are no longer in
            // `tabs`, so the per-tab loop below would miss them. Drained via the
            // workspace registry, not per pane: a close that collapsed its pane
            // left no leaf to ask. First, because their last_page writes must
            // land before the loop rewrites the same files.
            await workspace.tabTeardowns.awaitAll()
            // Every OPEN tab's ink, not just the focused pane's. The registry
            // now holds one controller per pane (the active tab's projection
            // the inspector reads), while ink itself is per-tab state on the
            // runtime — so iterating the registry would silently skip the
            // debounced strokes of every background tab.
            for pane in workspace.root.allLeaves() {
                for tab in pane.app.tabs {
                    await workspace.liveTabRuntime(for: tab.id).ink.flushPendingInkAndWait()
                }
            }
            for pane in workspace.root.allLeaves() {
                // Commit the pane's latest debounced edit to the scratchpad cache.
                pane.scratchpad.flush()
                for tab in pane.app.tabs {
                    try? await workspace.sessions.setDocumentMetadata(
                        sessionId: tab.id, key: "last_page", value: String(tab.currentPage))
                    try? await workspace.sessions.saveFile(sessionId: tab.id)
                }
            }
            // Every runtime, not just the focused pane's handler: the metadata
            // writes above changed each PDF's validation hash, and with live
            // tabs there is one extractor per TAB rather than one per pane. The
            // old `pane.app.flushPageTextCacheHandler?()` covered only whichever
            // viewer last claimed that slot (issue #37 PR B).
            await workspace.flushLivePageTextCaches()
            // Drain the coalesced background flushes so a page-text cache write
            // (issue #37) or an in-flight conversation blob (do-not-reintroduce
            // #8) still lands if the app is suspended right after backgrounding.
            await PageTextPersister.awaitInFlightFlushes()
            await ScratchpadPersistence.awaitPendingFlush()
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
