#if os(iOS)
import SwiftUI
import UIKit

/// iOS app entry (iPhone + iPad). Mirrors the macOS `VellumApp` wiring — one window-global
/// `WorkspaceStore` owning the split-screen pane tree, each pane its own
/// store-triple — but hosts a touch-first `WindowGroup` shell. macOS persists
/// reading positions via an NSApplication terminate hook; iOS has no terminate
/// callback, so the flush hangs off scene-phase `.background` instead, wrapped
/// in a `beginBackgroundTask` so the system grants time for the writes.
@main
struct VellumApp_iOS: App {
    @UIApplicationDelegateAdaptor(CaptureAppDelegate.self) private var captureAppDelegate
    @State private var themeStore: ThemeStore
    @State private var workspace: WorkspaceStore
    @State private var inkRegistry: InkRegistry_iOS
    @State private var showStorageChoice = false
    @State private var showWalkthrough = false
    @State private var showHelp = false
    @State private var backgroundFlushController: BackgroundFlushController
    @State private var systemRouteHandoff: VellumSystemRouteHandoff
    private let captureIngestion: CaptureIngestion?
    private let widgetSnapshotPublisher: VellumWidgetSnapshotPublisher
    @Environment(\.scenePhase) private var scenePhase

    init() {
        // Moves the first vault read off the main thread before anything asks
        // for a token.
        KeychainStore.prewarm()
        let theme = ThemeStore()
        let sessions = DocumentSessionManager()
        let storageCoordinator = StorageCoordinator()
        let webLibraryStorage = WebLibraryStorage(coordinator: storageCoordinator)
        let captureIngestion = CaptureInboxLayout.resolve().map {
            CaptureIngestion(layout: $0, storage: webLibraryStorage)
        }
        let integrations = IntegrationsStore(
            engine: IntegrationsSyncEngine(),
            webLibraryStorage: webLibraryStorage)
        // One read of the idiom for the whole process (#153 D6): the shell
        // `RootShell_iOS` renders, the memory the residency policy may hold, and
        // whether the workspace may split are three consequences of the same
        // fact and must not be allowed to disagree.
        let idiom = ShellIdiom_iOS.current
        // Position records are shared across platforms and their device label
        // is user-facing on Continue Reading. Install the main-actor UIKit
        // values before WorkspaceStore constructs its position service; the
        // cross-platform model cannot safely reach into UIDevice itself.
        DeviceIdentity.nameOverride = UIDevice.current.name
        DeviceIdentity.platformOverride = idiom.positionPlatform
        let workspace = WorkspaceStore(
            sessions: sessions,
            integrations: integrations,
            residency: TabResidencyManager(budget: idiom.residencyBudget),
            layout: idiom.paneLayout,
            storageCoordinator: storageCoordinator,
            webLibraryStorage: webLibraryStorage)
        _themeStore = State(initialValue: theme)
        _workspace = State(initialValue: workspace)
        _inkRegistry = State(initialValue: InkRegistry_iOS())
        _backgroundFlushController = State(initialValue: BackgroundFlushController())
        _systemRouteHandoff = State(initialValue: .shared)
        self.captureIngestion = captureIngestion
        widgetSnapshotPublisher = VellumWidgetSnapshotPublisher()

        // Background URLSession completion is delivered through UIApplicationDelegate,
        // while every foreground/launch trigger below calls the same actor-owned,
        // idempotent drain. The delegate is deliberately only a wake-up bridge.
        CaptureAppDelegate.drainInbox = { [captureIngestion, storageCoordinator] in
            // A background-session launch can arrive before any SwiftUI `.task`
            // has started storage. Join the same idempotent lifecycle gate the
            // foreground uses before asking the web-library adapter to write.
            await storageCoordinator.start()
            _ = await captureIngestion?.drain()
        }

        // Read-later autopull's background trigger (#157). Registration has to
        // happen before the app finishes launching — BGTaskScheduler treats a
        // late `register` as a programmer error — so it lives here rather than
        // in a `.task`. The handler asks the integrations store for the same
        // refresh + prefetch + retention-sweep pass the foreground runs, minus
        // the documents that are currently open in a tab.
        ReadLaterBackgroundRefresh.register { [integrations, workspace] in
            let openPaths = Set(
                workspace.root.allLeaves()
                    .flatMap { $0.app.tabs }.compactMap(\.document).map(\.pdfPath))
            await integrations.backgroundRefresh(openDocumentPaths: openPaths)
        }
    }

    var body: some Scene {
        WindowGroup {
            // `RootShell_iOS`, not `ContentView_iOS` directly: the target now
            // builds for iPhone as well (#151), and the shell that gets picked
            // depends on the scene's size class. Every modifier below stays at
            // the ROOT so it applies to whichever shell is on screen.
            RootShell_iOS()
                // Startup sync. Deliberately BEFORE the detached maintenance
                // work: start() loads the cached snapshots, so the providers'
                // items are on screen before the TTL sweep starts churning.
                .task {
                    await workspace.integrations.start()
                    await publishWidgetSnapshot()
                }
                // Publishing follows item revisions, but must not own startup.
                // Cached snapshots bump this value while `start()` is still
                // restoring providers; tying both jobs to one task would cancel
                // startup before its refresh timer and stale-provider pass land.
                .task(id: workspace.integrations.searchRevision) {
                    await publishWidgetSnapshot()
                }
                .task { await launchMaintenance() }
                .task {
                    await workspace.startStorageCoordinator()
                    _ = await captureIngestion?.drain()
                }
                .task(id: workspace.focusedPane.app.document?.pdfPath) {
                    guard workspace.focusedPane.app.document != nil else { return }
                    try? await Task.sleep(for: .milliseconds(300))
                    guard !Task.isCancelled else { return }
                    ScratchpadEditorPrewarmer.prepare()
                }
                .onOpenURL { url in handleIncomingURL(url) }
                .onChange(of: workspace.focusedPane.app.document?.pdfPath) { _, _ in
                    Task { await publishWidgetSnapshot() }
                }
                .onChange(of: systemRouteHandoff.pendingRequest, initial: true) { _, request in
                    guard let request,
                          let route = systemRouteHandoff.consume(request.id)
                    else { return }
                    Task {
                        await workspace.restoreFromDisk()
                        _ = await VellumSystemRouteOpener.open(route, workspace: workspace)
                    }
                }
                // The storage choice hands off to the walkthrough when it
                // closes — see `launchMaintenance` for why it goes first.
                .sheet(
                    isPresented: $showStorageChoice,
                    onDismiss: { showWalkthrough = WalkthroughSettings.needsFirstRun }
                ) {
                    StorageLocationChoiceSheet()
                        .environment(\.palette, themeStore.palette)
                        .preferredColorScheme(themeStore.colorScheme)
                        .tint(themeStore.palette.primary)
                }
                // Presented at the ROOT, not on the Home screen: the
                // walkthrough stays reachable with a document open, and it
                // outlives the screen that offers it.
                //
                // iOS silently drops a second simultaneous presentation, so
                // each handler guards on the other two flags. Together with the
                // `if !showStorageChoice` gate in `launchMaintenance`, that is
                // the "one sheet at a time" rule.
                .onReceive(
                    NotificationCenter.default.publisher(for: .vellumShowWalkthrough)
                ) { _ in
                    guard !showStorageChoice, !showHelp else { return }
                    showWalkthrough = true
                }
                .sheet(isPresented: $showWalkthrough) {
                    WalkthroughSheet_iOS()
                        .environment(\.palette, themeStore.palette)
                        .preferredColorScheme(themeStore.colorScheme)
                        .tint(themeStore.palette.primary)
                }
                .onReceive(NotificationCenter.default.publisher(for: .vellumShowHelp)) { _ in
                    guard !showStorageChoice, !showWalkthrough else { return }
                    showHelp = true
                }
                .onReceive(NotificationCenter.default.publisher(for: .vellumStorageModeChanged)) { _ in
                    Task { @MainActor in
                        await workspace.reconfigureStorageCoordinator()
                    }
                }
                .sheet(isPresented: $showHelp) {
                    HelpCenterView_iOS()
                        .environment(\.palette, themeStore.palette)
                        .preferredColorScheme(themeStore.colorScheme)
                        .tint(themeStore.palette.primary)
                }
                .environment(themeStore)
                .environment(workspace)
                .environment(workspace.integrations)
                .environment(inkRegistry)
                .environment(workspace.openRouterCatalog)
                .environment(\.palette, themeStore.palette)
                .preferredColorScheme(themeStore.colorScheme)
                .tint(themeStore.palette.primary)
                .overlay(alignment: .topTrailing) {
                    if RuntimeProfile.current.isDevelopment {
                        DevelopmentBadge()
                            .padding(12)
                            .allowsHitTesting(false)
                    }
                }
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
                // Ask for the next background wake-up on the way out: a request
                // submitted while in the foreground would be the one the system
                // schedules against, and leaving is when the queue starts going
                // stale (#157).
                ReadLaterBackgroundRefresh.schedule()
            }
            // iOS suspends the process, so the store's 30-minute auto-refresh
            // Task.sleep does not fire in the background and an iPad that has
            // been away for a day would show stale items until someone tapped
            // Sync Now. Returning to the foreground is the moment to re-check.
            if phase == .active {
                backgroundFlushController.invalidate()
                Task { @MainActor in
                    await workspace.foregroundStorageCoordinator()
                    _ = await captureIngestion?.drain()
                    workspace.integrations.run { await workspace.integrations.foregroundRefresh() }
                }
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
    ///
    /// Universal target caveat (#151): the phone is an "Open in" target too, and
    /// the shell that receives this there cannot open anything yet. Both shells
    /// therefore listen — `ContentView_iOS` opens the files, `PhoneShell_iOS`
    /// says where they went — so the channel is never posted into a void.
    @MainActor
    private func handleIncomingURL(_ url: URL) {
        if url.scheme?.lowercased() == VellumDeepLink.scheme {
            guard let route = VellumDeepLink.parse(url) else { return }
            systemRouteHandoff.submit(route)
            return
        }

        Task {
            let paths = await Task.detached(priority: .userInitiated) {
                DocumentImport.importPicked([url])
            }.value
            guard !paths.isEmpty else { return }
            NotificationCenter.default.post(
                name: .vellumOpenFile, object: nil, userInfo: ["paths": paths])
        }
    }

    @MainActor
    private func publishWidgetSnapshot() async {
        await widgetSnapshotPublisher.publish(
            readLaterItems: workspace.integrations.searchableItems)
    }

    /// Launch-time TTL eviction of derived data (issue #37 PR B / issue #29):
    /// the extracted-text cache, plus web-snapshot artifacts for pages the user
    /// never saved or annotated. Time-based only — never because a source file
    /// is missing. Then finish any interrupted storage-location move and present
    /// the first-launch storage choice if the user hasn't made one yet.
    @MainActor
    private func launchMaintenance() async {
        // The root also starts integrations in its own task for fast UI data,
        // but maintenance must join that same startup before it snapshots the
        // queue. Otherwise a cold launch can prefetch an empty initial store.
        await workspace.integrations.start()
        await workspace.startStorageCoordinator()

        let openDocuments = workspace.root.allLeaves()
            .flatMap { $0.app.tabs }.compactMap(\.document)
        // The text cache excludes open documents by STORAGE KEY now (docId when
        // stamped, else path hash) — the same key their lookup/persister used.
        let openKeys = Set(
            openDocuments.filter { $0.kind == .pdf }
                .map { DocumentIdentity.storageKey(for: $0) })
        let openWebUrls = Set(openDocuments.filter { $0.kind == .web }.map(\.pdfPath))
        // Every open document's path, web or PDF: the read-later sweep refuses
        // to delete an offline copy that is on screen right now.
        let openPaths = Set(openDocuments.map(\.pdfPath))
        let integrations = workspace.integrations
        let positions = workspace.positions

        // Resolve the iCloud ubiquity container off-main FIRST: it can block,
        // and both the launch sweep (to name the iCloud layout) and the
        // first-launch sheet (to offer/disable the iCloud option) need it
        // resolved. Awaited so the sheet below reflects real availability.
        await Task.detached(priority: .utility) {
            WebStorageSettings.resolveICloudRoot()
        }.value

        Task.detached(priority: .background) {
            // Startup autopull runs before retention. The app's other sync
            // triggers join the same store-owned prefetch task, and the
            // prefetcher serializes a sweep that arrives during I/O.
            await integrations.prefetchOfflineCopies()
            // Finish any interrupted storage-location move and fold legacy-local
            // strays into the active layout before the evictors walk the store.
            // Routed through the relocator so it can't run concurrently with a
            // location change the user makes in the first-launch sheet below
            // (single relocation runner — parity plan do-not-reintroduce #9).
            await WebStorageRelocator.sweepAtLaunch(
                coordinator: workspace.storageCoordinator)
            // TTL eviction of derived data, using the user's chosen retention
            // window (Settings ▸ Storage ▸ Housekeeping; "Never" skips it).
            // The read-later retention sweep rides the same pass (#157): one
            // eviction pass at launch, one policy per data class inside it.
            await StorageHousekeeping.runCleanup(
                openPdfKeys: openKeys,
                openWebUrls: openWebUrls,
                openDocumentPaths: openPaths,
                readLater: integrations,
                webLastOpened: { await positions.lastOpenedForWebURL($0) },
                webStorage: workspace.webLibraryStorage)
        }

        showStorageChoice = WebStorageSettings.needsFirstLaunchChoice
        // Only one sheet at a time. On a true first launch the storage choice
        // goes first — it decides where everything the walkthrough describes
        // gets written — and hands off to the walkthrough when it closes (see
        // the sheet's `onDismiss`). This ordering is already safe here because
        // `launchMaintenance` awaits `WebStorageSettings.resolveICloudRoot()`
        // before reaching this line.
        if !showStorageChoice {
            showWalkthrough = WalkthroughSettings.needsFirstRun
        }
    }

    /// Scene-background flush. macOS drains these on `applicationShouldTerminate`;
    /// iOS gets a `beginBackgroundTask` window instead so the last_page /
    /// saveFile writes and the coalesced cache / conversation flushes complete
    /// before the app is suspended.
    @MainActor
    private func flushOnBackground() {
        let workspace = self.workspace
        let flushController = backgroundFlushController
        let generation = flushController.begin()

        let token = BackgroundFlushToken(name: "VellumBackgroundFlush") {
            flushController.expire(generation: generation)
        }

        let task = Task { @MainActor in
            defer { flushController.finish(generation: generation) }
            await workspace.saveNowAfterPendingPositionRecords()
            // Tabs closed moments ago finish their metadata write and session
            // close behind the UI (AppStore.closeTab) and are no longer in
            // `tabs`, so the per-tab loop below would miss them. Drained via the
            // workspace registry, not per pane: a close that collapsed its pane
            // left no leaf to ask. First, because their last_page writes must
            // land before the loop rewrites the same files.
            await workspace.tabTeardowns.awaitAll()
            await workspace.flushOpenTabPositions()
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
                await pane.scratchpad.flush().value
                for tab in pane.app.tabs {
                    if tab.document?.kind == .pdf {
                        try? await workspace.sessions.setDocumentMetadata(
                            sessionId: tab.id, key: "last_page", value: String(tab.currentPage))
                    }
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
            // The iOS analogue of the Mac's applicationShouldTerminate barrier:
            // cancel in-flight read-later syncs and wait for the store-owned
            // writes (preference flips, optimistic moves, disconnects,
            // thumbnail cleanup), then suspend coordinated storage.
            await workspace.integrations.awaitQuiescence()
            guard flushController.isCurrent(generation), !Task.isCancelled else { return }
            _ = await workspace.backgroundStorageCoordinator(timeout: 20) {
                await MainActor.run { flushController.isCurrent(generation) }
            }
        }
        flushController.install(task: task, token: token, generation: generation)
    }
}

/// Main-actor controller for the iOS scene-background flush. The generation is
/// the authority: expiration and foreground invalidate the generation, cancel the
/// task, and end the UIKit background token exactly once. The storage coordinator
/// checks this generation again inside its final suspend path.
@MainActor
final class BackgroundFlushController {
    private struct Active {
        var generation: Int
        var task: Task<Void, Never>
        var token: any BackgroundFlushHandle
    }

    private var generation = 0
    private var active: Active?

    func begin() -> Int {
        invalidate()
        generation += 1
        return generation
    }

    func install(task: Task<Void, Never>, token: any BackgroundFlushHandle, generation: Int) {
        guard self.generation == generation, active == nil else {
            task.cancel()
            token.end()
            return
        }
        active = Active(generation: generation, task: task, token: token)
    }

    func isCurrent(_ generation: Int) -> Bool {
        self.generation == generation && active?.generation == generation
    }

    func finish(generation: Int) {
        guard active?.generation == generation else { return }
        active?.token.end()
        active = nil
    }

    func expire(generation: Int) {
        guard active?.generation == generation else { return }
        let expired = active
        active = nil
        self.generation += 1
        expired?.task.cancel()
        expired?.token.end()
    }

    func invalidate() {
        generation += 1
        let stale = active
        active = nil
        stale?.task.cancel()
        stale?.token.end()
    }
}

/// Holds the `beginBackgroundTask` identifier so all owners can end it exactly
/// once, on the main actor.
@MainActor
protocol BackgroundFlushHandle: AnyObject {
    func end()
}

@MainActor
final class BackgroundFlushToken: BackgroundFlushHandle {
    private var id: UIBackgroundTaskIdentifier = .invalid

    init(name: String, expiration: @escaping @MainActor @Sendable () -> Void) {
        id = UIApplication.shared.beginBackgroundTask(withName: name) {
            Task { @MainActor in expiration() }
        }
    }

    func end() {
        guard id != .invalid else { return }
        UIApplication.shared.endBackgroundTask(id)
        id = .invalid
    }
}
#endif
