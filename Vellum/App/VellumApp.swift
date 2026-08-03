#if os(macOS)
import AppKit
import SwiftUI

/// Persists reading positions before quit — the Tauri app wrote last_page on
/// tab close/switch only; a native app must also survive ⌘Q with open tabs.
final class VellumAppDelegate: NSObject, NSApplicationDelegate {
    @MainActor static weak var workspace: WorkspaceStore?

    /// Finder double-click / drag-onto-dock for registered types (.pdf,
    /// .vellumweb, .vellum). Routes into the focused pane's store the same way
    /// ContentView.openFilePanel does — `openFiles` dispatches each extension
    /// (bundle import, archive import, or plain PDF open).
    func application(_ application: NSApplication, open urls: [URL]) {
        let paths = urls.map(\.path)
        guard !paths.isEmpty else { return }
        MainActor.assumeIsolated {
            guard let workspace = Self.workspace else { return }
            let app = workspace.focusedPane.app
            Task { await app.openFiles(paths: paths) }
        }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        MainActor.assumeIsolated {
            guard let workspace = Self.workspace else { return .terminateNow }
            let leaves = workspace.root.allLeaves()
            let hasTabs = leaves.contains { !$0.app.tabs.isEmpty }
            // Persist the split layout, and every pane's pending scratchpad
            // edit (each pane owns its own note), before tearing down sessions.
            workspace.saveNow()
            for leaf in leaves { leaf.scratchpad.flush() }
            guard hasTabs else {
                // No open tabs, but a conversation or page-text write saved just
                // before ⌘Q (the 200ms coalesced AI flush, or a detached
                // page-text flush from the last tab's close) may still be in
                // flight. Drain those on the terminateLater path — there is no
                // per-tab metadata/close loop to run — so the final
                // conversations.json / cache write always lands. Both awaits are
                // no-ops when nothing is pending.
                Task { @MainActor in
                    // A tab closed moments ago finishes its metadata write and
                    // session close behind the UI (AppStore.closeTab); it is no
                    // longer in `tabs`, so nothing else here would await it.
                    // Drained via the workspace registry, not per pane: a close
                    // that collapsed its pane left no leaf to ask.
                    await workspace.tabTeardowns.awaitAll()
                    await PageTextPersister.awaitInFlightFlushes()
                    await AiPersistence.awaitPendingFlush()
                    // Read-later work the user started behind the UI — the
                    // auto-refresh preference, a move-to-collection, a
                    // disconnect, thumbnail cleanup — is store-owned and joinable
                    // for exactly this reason. Cancels in-flight syncs, waits for
                    // the rest.
                    await workspace.integrations.awaitQuiescence()
                    sender.reply(toApplicationShouldTerminate: true)
                }
                return .terminateLater
            }
            Task { @MainActor in
                // Tabs closed moments ago finish their metadata write and
                // session close behind the UI (AppStore.closeTab) and are no
                // longer in `tabs`, so the loop below would miss them. Drained
                // via the workspace registry, not per pane: a close that
                // collapsed its pane left no leaf to ask.
                await workspace.tabTeardowns.awaitAll()
                for leaf in leaves {
                    for tab in leaf.app.tabs {
                        try? await workspace.sessions.setDocumentMetadata(
                            sessionId: tab.id, key: "last_page", value: String(tab.currentPage))
                    }
                }
                // Metadata rewrites PDFs and changes their validation hashes.
                // Flush every runtime after those writes (not only the focused
                // pane's shared handler), then close the backend sessions.
                await workspace.flushLivePageTextCaches()
                for leaf in leaves {
                    for tab in leaf.app.tabs {
                        try? await workspace.sessions.closeFile(sessionId: tab.id)
                    }
                }
                // Also drain detached flushes from controllers dropped by a
                // recent close/eviction, then the coalesced AI conversation write.
                await PageTextPersister.awaitInFlightFlushes()
                await AiPersistence.awaitPendingFlush()
                // Same for the read-later stores' background work (see above).
                await workspace.integrations.awaitQuiescence()
                sender.reply(toApplicationShouldTerminate: true)
            }
            return .terminateLater
        }
    }
}

@main
struct VellumApp: App {
    @NSApplicationDelegateAdaptor(VellumAppDelegate.self) private var appDelegate
    @State private var themeStore: ThemeStore
    @State private var workspace: WorkspaceStore
    @State private var showStorageChoice = false
    @State private var showWalkthrough = false
    @State private var didOpenUITestDocument = false
    private let uiTestDocumentPath: String?

    init() {
        uiTestDocumentPath = UITestLaunchConfiguration.prepare()
        // The first keychain read of a launch is a full vault load plus the
        // legacy migration — hundreds of milliseconds, reachable synchronously
        // from @MainActor callers (AI keys, ChatGPT auth, integration tokens).
        // Warm it on a background queue here, after the UI-test configuration
        // has had its say, so no main-actor read ever pays for it.
        KeychainStore.prewarm()
        let theme = ThemeStore()
        let sessions = DocumentSessionManager()
        let integrations = IntegrationsStore(engine: IntegrationsSyncEngine())
        let workspace = WorkspaceStore(sessions: sessions, integrations: integrations)
        _themeStore = State(initialValue: theme)
        _workspace = State(initialValue: workspace)
        VellumAppDelegate.workspace = workspace
    }

    var body: some Scene {
        // Single window like the Tauri app — stores are app-wide singletons,
        // so multiple windows would fight over the same active-tab state.
        Window("Vellum", id: "main") {
            ContentView()
                .frame(minWidth: 800, minHeight: 600)
                .task {
                    await workspace.integrations.start()
                    await workspace.integrations.prefetchOfflineCopies()
                    // Launch-time TTL eviction of derived data (issue #37 PR B /
                    // issue #29): the extracted-text cache, plus web-snapshot
                    // artifacts for pages the user never saved or annotated.
                    // Time-based only — never because a source file is missing.
                    // The open-documents snapshot excludes restored tabs; a
                    // document opened AFTER it is still safe because the cache
                    // actor serializes (its lookup either stamps lastOpened
                    // first, excluding it by age, or re-extracts once after the
                    // eviction) and the web store re-archives on the open
                    // debounce. Evict off-main at low priority.
                    let openDocuments = workspace.root.allLeaves()
                        .flatMap { $0.app.tabs }.compactMap(\.document)
                    // The text cache excludes open documents by STORAGE KEY now
                    // (docId when stamped, else path hash) — the same key their
                    // lookup/persister used.
                    let openKeys = Set(
                        openDocuments.filter { $0.kind == .pdf }
                            .map { DocumentIdentity.storageKey(for: $0) })
                    let openWebUrls = Set(
                        openDocuments.filter { $0.kind == .web }.map(\.pdfPath))
                    Task.detached(priority: .background) {
                        // Finish any interrupted storage-location move and fold
                        // legacy-local strays into the active layout before the
                        // evictors walk the store. Routed through the relocator
                        // so it can't run concurrently with a location change
                        // the user makes in the first-launch sheet below. The
                        // sweep runs regardless of the retention policy.
                        await WebStorageRelocator.sweepAtLaunch()
                        // TTL eviction of derived data, using the user's chosen
                        // retention window (Settings ▸ Storage ▸ Housekeeping;
                        // "Never" skips it). Excludes currently-open documents.
                        await StorageHousekeeping.runCleanup(
                            openPdfKeys: openKeys, openWebUrls: openWebUrls)
                    }
                    showStorageChoice = WebStorageSettings.needsFirstLaunchChoice
                    // Only one sheet at a time. On a true first launch the
                    // storage choice goes first — it decides where everything
                    // the walkthrough describes gets written — and hands off to
                    // the walkthrough when it closes.
                    if !showStorageChoice {
                        showWalkthrough = WalkthroughSettings.needsFirstRun
                    }
                    // UI tests open their generated fixture through this seam
                    // instead of driving the system open panel. Inert without
                    // `--ui-testing` (the path is nil), and the launch
                    // configuration has already marked both first-run sheets as
                    // handled so neither can cover the document.
                    if !didOpenUITestDocument, let uiTestDocumentPath {
                        didOpenUITestDocument = true
                        await workspace.focusedPane.app.openFile(path: uiTestDocumentPath)
                    }
                }
                .task {
                    // A UI-test launch skips this: it is a real network request
                    // whose outcome adds an "install update" affordance to
                    // Home's chrome, which is the opposite of deterministic
                    // (and rate-limits the release API across a test run).
                    guard !UITestLaunchConfiguration.isEnabled else { return }
                    // The checker belongs to the workspace, not the Home
                    // toolbar, so this continues to represent the same check
                    // while documents are opened or Home is revisited — and it
                    // is the same instance the app menu's update commands use.
                    await workspace.checkForUpdatesAutomatically()
                }
                .sheet(
                    isPresented: $showStorageChoice,
                    onDismiss: { showWalkthrough = WalkthroughSettings.needsFirstRun }
                ) {
                    StorageLocationChoiceSheet()
                        .environment(\.palette, themeStore.palette)
                }
                // Help ▸ Vellum Walkthrough and the welcome screen's help button
                // both route here, since the sheet's presentation state lives
                // with the window rather than with either caller.
                .onReceive(NotificationCenter.default.publisher(for: .vellumShowWalkthrough)) { _ in
                    showWalkthrough = true
                }
                .sheet(isPresented: $showWalkthrough) {
                    WalkthroughSheet()
                        .environment(\.palette, themeStore.palette)
                }
                .environment(themeStore)
                .environment(workspace)
                .environment(workspace.integrations)
                .environment(workspace.openRouterCatalog)
                .environment(workspace.chatgptAuth)
                .environment(\.palette, themeStore.palette)
                .preferredColorScheme(themeStore.colorScheme)
                .background(themeStore.palette.background)
                .tint(themeStore.palette.primary)
        }
        .defaultSize(width: 1280, height: 800)
        .windowResizability(.contentMinSize)
        .windowToolbarStyle(.unified(showsTitle: false))
        .commands {
            VellumCommands(appWorkspace: workspace)
        }

        // Adds "Settings…" (⌘,) to the app menu automatically.
        Settings {
            SettingsView()
                .environment(themeStore)
                .environment(workspace)
                .environment(workspace.integrations)
                .environment(workspace.settingsAi)
                .environment(workspace.openRouterCatalog)
                .environment(workspace.chatgptAuth)
                .environment(\.palette, themeStore.palette)
                .preferredColorScheme(themeStore.colorScheme)
                .tint(themeStore.palette.primary)
        }

        // The searchable Help centre (Help ▸ Vellum Help, ⌘?). A scene rather
        // than a sheet on the main window: a reference is only useful if you
        // can leave it open next to the document it describes, which a modal
        // sheet cannot do. It publishes no `vellumFocus`, so every
        // document-scoped menu command correctly greys out while it is key.
        //
        // It gets the theme environment but deliberately not the workspace —
        // it reads nothing from the app's state, which is what keeps it safe to
        // open with no document at all.
        Window(HelpScene.title, id: HelpScene.windowId) {
            HelpCenterView()
                .environment(themeStore)
                .environment(\.palette, themeStore.palette)
                .preferredColorScheme(themeStore.colorScheme)
                .background(themeStore.palette.background)
                .tint(themeStore.palette.primary)
        }
        .defaultSize(width: 640, height: 660)
    }
}
#endif  // os(macOS) — iPad reference; see Platform/iOS
