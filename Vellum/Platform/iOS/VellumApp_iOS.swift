#if os(iOS)
import SwiftUI

/// iPad app entry. Mirrors the macOS `VellumApp` wiring (shared stores as
/// app-wide singletons) but hosts a touch-first `WindowGroup` shell and
/// persists reading positions on scene backgrounding instead of via an
/// NSApplication terminate hook.
@main
struct VellumApp_iOS: App {
    @State private var themeStore: ThemeStore
    @State private var appStore: AppStore
    @State private var annotationStore: AnnotationStore
    @State private var aiStore: AiStore
    @Environment(\.scenePhase) private var scenePhase

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
    }

    var body: some Scene {
        WindowGroup {
            ContentView_iOS()
                .environment(themeStore)
                .environment(appStore)
                .environment(annotationStore)
                .environment(aiStore)
                .environment(\.palette, themeStore.palette)
                .preferredColorScheme(themeStore.colorScheme)
                .tint(themeStore.palette.primary)
        }
        .onChange(of: scenePhase) { _, phase in
            // Persist last_page for every open tab when leaving the foreground,
            // the iOS analogue of the macOS terminate hook.
            if phase == .background {
                let store = appStore
                Task { @MainActor in
                    for tab in store.tabs {
                        try? await store.sessions.setDocumentMetadata(
                            sessionId: tab.id, key: "last_page", value: String(tab.currentPage))
                        try? await store.sessions.saveFile(sessionId: tab.id)
                    }
                }
            }
        }
    }
}
#endif
