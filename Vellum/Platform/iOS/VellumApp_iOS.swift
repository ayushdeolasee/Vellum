#if os(iOS)
import SwiftUI

/// iPad app entry. Mirrors the macOS `VellumApp` wiring — one window-global
/// `WorkspaceStore` owning the split-screen pane tree, each pane its own
/// store-triple — but hosts a touch-first `WindowGroup` shell and persists
/// reading positions on scene backgrounding instead of via an NSApplication
/// terminate hook.
@main
struct VellumApp_iOS: App {
    @State private var themeStore: ThemeStore
    @State private var workspace: WorkspaceStore
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
                .environment(themeStore)
                .environment(workspace)
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
                let workspace = self.workspace
                workspace.saveNow()
                Task { @MainActor in
                    for pane in workspace.root.allLeaves() {
                        for tab in pane.app.tabs {
                            try? await workspace.sessions.setDocumentMetadata(
                                sessionId: tab.id, key: "last_page", value: String(tab.currentPage))
                            try? await workspace.sessions.saveFile(sessionId: tab.id)
                        }
                    }
                }
            }
        }
    }
}
#endif
