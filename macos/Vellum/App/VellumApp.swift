import SwiftUI

@main
struct VellumApp: App {
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
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .frame(minWidth: 800, minHeight: 600)
                .environment(themeStore)
                .environment(appStore)
                .environment(annotationStore)
                .environment(aiStore)
                .environment(\.palette, themeStore.palette)
                .preferredColorScheme(themeStore.colorScheme)
                .background(themeStore.palette.background)
        }
        .defaultSize(width: 1280, height: 800)
        .windowResizability(.contentMinSize)
    }
}
