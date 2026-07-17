import AppKit
import SwiftUI

/// Persists reading positions before quit — the Tauri app wrote last_page on
/// tab close/switch only; a native app must also survive ⌘Q with open tabs.
final class VellumAppDelegate: NSObject, NSApplicationDelegate {
    @MainActor static weak var workspace: WorkspaceStore?

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        MainActor.assumeIsolated {
            guard let workspace = Self.workspace else { return .terminateNow }
            let leaves = workspace.root.allLeaves()
            let hasTabs = leaves.contains { !$0.app.tabs.isEmpty }
            // Persist the split layout, and every pane's pending scratchpad
            // edit (each pane owns its own note), before tearing down sessions.
            workspace.saveNow()
            for leaf in leaves { leaf.scratchpad.flush() }
            guard hasTabs else { return .terminateNow }
            Task { @MainActor in
                for leaf in leaves {
                    for tab in leaf.app.tabs {
                        try? await workspace.sessions.setDocumentMetadata(
                            sessionId: tab.id, key: "last_page", value: String(tab.currentPage))
                        try? await workspace.sessions.closeFile(sessionId: tab.id)
                    }
                }
                // Persist the active document's in-flight page text after the
                // last_page writes (each refreshed the cache's validation hash),
                // so a reopen still hits (issue #37 PR B). Then drain detached
                // flushes from persisters dropped by a recent tab switch, whose
                // controller no longer exists to be flushed via the handler.
                for leaf in leaves {
                    await leaf.app.flushPageTextCacheHandler?()
                }
                await PageTextPersister.awaitInFlightFlushes()
                await AiPersistence.awaitPendingFlush()
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

    init() {
        let theme = ThemeStore()
        let sessions = DocumentSessionManager()
        let workspace = WorkspaceStore(sessions: sessions)
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
                    let cutoff = Calendar.current.date(byAdding: .month, value: -6, to: .now) ?? .now
                    Task.detached(priority: .background) {
                        // Finish any interrupted storage-location move and fold
                        // legacy-local strays into the active layout before the
                        // evictors walk the store. Routed through the relocator
                        // so it can't run concurrently with a location change
                        // the user makes in the first-launch sheet below.
                        await WebStorageRelocator.sweepAtLaunch()
                        await PageTextCache.shared.evictStale(olderThan: cutoff, excludingKeys: openKeys)
                        WebLibrary.evictStaleUnsavedSnapshots(olderThan: cutoff, excludingUrls: openWebUrls)
                    }
                    showStorageChoice = WebStorageSettings.needsFirstLaunchChoice
                }
                .sheet(isPresented: $showStorageChoice) {
                    StorageLocationChoiceSheet()
                        .environment(\.palette, themeStore.palette)
                }
                .environment(themeStore)
                .environment(workspace)
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
            VellumCommands()
        }

        // Adds "Settings…" (⌘,) to the app menu automatically.
        Settings {
            SettingsView()
                .environment(themeStore)
                .environment(workspace)
                .environment(workspace.settingsAi)
                .environment(workspace.openRouterCatalog)
                .environment(workspace.chatgptAuth)
                .environment(\.palette, themeStore.palette)
                .preferredColorScheme(themeStore.colorScheme)
                .tint(themeStore.palette.primary)
        }
    }
}
