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
            // Persist the split layout before tearing down sessions.
            workspace.saveNow()
            guard hasTabs else { return .terminateNow }
            Task { @MainActor in
                for leaf in leaves {
                    for tab in leaf.app.tabs {
                        try? await workspace.sessions.setDocumentMetadata(
                            sessionId: tab.id, key: "last_page", value: String(tab.currentPage))
                        try? await workspace.sessions.closeFile(sessionId: tab.id)
                    }
                }
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
