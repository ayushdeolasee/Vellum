import AppKit
import SwiftUI

/// Persists reading positions before quit — the Tauri app wrote last_page on
/// tab close/switch only; a native app must also survive ⌘Q with open tabs.
final class VellumAppDelegate: NSObject, NSApplicationDelegate {
    @MainActor static weak var appStore: AppStore?
    @MainActor static weak var scratchpadStore: ScratchpadStore?

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        MainActor.assumeIsolated {
            // Persist any pending scratchpad edit before we tear down.
            Self.scratchpadStore?.flush()
            guard let appStore = Self.appStore, !appStore.tabs.isEmpty else {
                return .terminateNow
            }
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
    @State private var appStore: AppStore
    @State private var annotationStore: AnnotationStore
    @State private var aiStore: AiStore
    @State private var scratchpadStore: ScratchpadStore

    init() {
        let theme = ThemeStore()
        let sessions = DocumentSessionManager()
        let app = AppStore(sessions: sessions)
        let annotations = AnnotationStore(app: app)
        let ai = AiStore()
        ai.app = app
        ai.annotationStore = annotations
        let scratchpad = ScratchpadStore()
        _themeStore = State(initialValue: theme)
        _appStore = State(initialValue: app)
        _annotationStore = State(initialValue: annotations)
        _aiStore = State(initialValue: ai)
        _scratchpadStore = State(initialValue: scratchpad)
        VellumAppDelegate.appStore = app
        VellumAppDelegate.scratchpadStore = scratchpad
    }

    var body: some Scene {
        // Single window like the Tauri app — stores are app-wide singletons,
        // so multiple windows would fight over the same active-tab state.
        Window("Vellum", id: "main") {
            ContentView()
                .frame(minWidth: 800, minHeight: 600)
                .task {
                    // Launch-time TTL eviction of the extracted-text cache
                    // (issue #37 PR B). Time-based only — never because a source
                    // file is missing. The open-paths snapshot excludes restored
                    // tabs; a document opened AFTER it is still safe because the
                    // cache actor serializes: its lookup either stamps lastOpened
                    // first (excluding it by age) or re-extracts once after the
                    // eviction — never corruption. Evict off-main at low priority.
                    let openPaths = Set(
                        workspace.root.allLeaves().flatMap { $0.app.tabs }.compactMap(\.document)
                            .filter { $0.kind == .pdf }
                            .map(\.pdfPath))
                    let cutoff = Calendar.current.date(byAdding: .month, value: -6, to: .now) ?? .now
                    Task.detached(priority: .background) {
                        await PageTextCache.shared.evictStale(olderThan: cutoff, excludingPaths: openPaths)
                    }
                }
                .environment(themeStore)
                .environment(appStore)
                .environment(annotationStore)
                .environment(aiStore)
                .environment(scratchpadStore)
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
