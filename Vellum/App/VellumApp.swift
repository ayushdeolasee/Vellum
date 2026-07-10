import AppKit
import SwiftUI

/// Persists reading positions before quit — the Tauri app wrote last_page on
/// tab close/switch only; a native app must also survive ⌘Q with open tabs.
final class VellumAppDelegate: NSObject, NSApplicationDelegate {
    @MainActor static weak var appStore: AppStore?

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        MainActor.assumeIsolated {
            guard let appStore = Self.appStore, !appStore.tabs.isEmpty else {
                return .terminateNow
            }
            Task { @MainActor in
                for tab in appStore.tabs {
                    try? await appStore.sessions.setDocumentMetadata(
                        sessionId: tab.id, key: "last_page", value: String(tab.currentPage))
                    try? await appStore.sessions.closeFile(sessionId: tab.id)
                }
                // Persist the active document's in-flight page text after the
                // last_page writes (each refreshed the cache's validation hash),
                // so a reopen still hits (issue #37 PR B). Then drain detached
                // flushes from persisters dropped by a recent tab switch, whose
                // controller no longer exists to be flushed via the handler.
                await appStore.flushPageTextCacheHandler?()
                await PageTextPersister.awaitInFlightFlushes()
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
    @State private var openRouterCatalog: OpenRouterCatalog
    @State private var chatgptAuth: ChatGPTAuth

    init() {
        let theme = ThemeStore()
        let sessions = DocumentSessionManager()
        let app = AppStore(sessions: sessions)
        let annotations = AnnotationStore(app: app)
        let ai = AiStore()
        let openRouter = OpenRouterCatalog()
        let chatgpt = ChatGPTAuth()
        ai.app = app
        ai.annotationStore = annotations
        ai.openRouterCatalog = openRouter
        ai.chatgptAuth = chatgpt
        _themeStore = State(initialValue: theme)
        _appStore = State(initialValue: app)
        _annotationStore = State(initialValue: annotations)
        _aiStore = State(initialValue: ai)
        _openRouterCatalog = State(initialValue: openRouter)
        _chatgptAuth = State(initialValue: chatgpt)
        VellumAppDelegate.appStore = app
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
                        appStore.tabs.compactMap(\.document)
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
                .environment(openRouterCatalog)
                .environment(chatgptAuth)
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
                .environment(appStore)
                .environment(aiStore)
                .environment(openRouterCatalog)
                .environment(chatgptAuth)
                .environment(\.palette, themeStore.palette)
                .preferredColorScheme(themeStore.colorScheme)
                .tint(themeStore.palette.primary)
        }
    }
}
