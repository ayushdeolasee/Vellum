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

    init() {
        let theme = ThemeStore()
        let sessions = DocumentSessionManager()
        let app = AppStore(sessions: sessions)
        let annotations = AnnotationStore(app: app)
        let ai = AiStore()
        ai.app = app
        ai.annotationStore = annotations
        _themeStore = State(initialValue: theme)
        _appStore = State(initialValue: app)
        _annotationStore = State(initialValue: annotations)
        _aiStore = State(initialValue: ai)
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
                .environment(\.palette, themeStore.palette)
                .preferredColorScheme(themeStore.colorScheme)
                .tint(themeStore.palette.primary)
        }
    }
}
