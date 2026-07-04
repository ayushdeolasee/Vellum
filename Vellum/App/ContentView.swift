import AppKit
import SwiftUI

struct ContentView: View {
    @Environment(AppStore.self) private var appStore
    @Environment(AnnotationStore.self) private var annotationStore
    @Environment(AiStore.self) private var aiStore
    @Environment(\.palette) private var palette

    @State private var keyMonitor: Any?
    @State private var sidebarHovering = false

    var body: some View {
        VStack(spacing: 0) {
            if !appStore.tabs.isEmpty {
                TabBarView()
            }

            if appStore.document == nil {
                WelcomeScreen()
            } else {
                documentViewer
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .clipped()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(palette.background)
        .toolbar {
            VellumToolbar()
        }
        .inspector(isPresented: inspectorPresented) {
            sidebar
                .inspectorColumnWidth(min: 240, ideal: 340, max: 700)
                .toolbar {
                    // Declared inside the inspector so the switcher lands in
                    // the inspector's own toolbar section, Xcode-style. The
                    // explicit condition matters: inspector toolbar items stay
                    // visible even while the inspector itself is closed.
                    if inspectorPresented.wrappedValue {
                        // Flexible spacers on both sides center the switcher
                        // over the inspector instead of pinning it leading.
                        ToolbarSpacer(.flexible)
                        ToolbarItem {
                            GlassSegmentedPicker(
                                options: [
                                    (AppStore.SidebarTab.annotations, "Annotations"),
                                    (AppStore.SidebarTab.ai, "AI"),
                                ],
                                selection: sidebarTabBinding
                            )
                        }
                        ToolbarSpacer(.flexible)
                    }
                }
        }
        .task(id: documentIdentity) {
            annotationStore.clearAnnotations()
            aiStore.clearDocumentContext()
            guard appStore.document?.pdfPath != nil else { return }
            await annotationStore.loadAnnotations()
            guard !Task.isCancelled else { return }
            aiStore.loadConversationForDocument(appStore.document)
        }
        .task(id: autosaveIdentity) {
            guard let identity = autosaveIdentity else { return }
            while !Task.isCancelled {
                do {
                    try await Task.sleep(for: .seconds(30))
                } catch {
                    return
                }
                guard !Task.isCancelled,
                      appStore.activeTabId == identity.tabId,
                      appStore.document != nil else { return }
                try? await appStore.sessions.saveFile(sessionId: identity.tabId)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .vellumAnnotationsUpdated)) { _ in
            guard appStore.document != nil else { return }
            Task { await annotationStore.loadAnnotations() }
        }
        // Publish the stores as a focused value so the app-level menu commands
        // (VellumCommands) route here and disable themselves when the Settings
        // window — which does not publish this value — is key.
        .focusedValue(\.vellumFocus, VellumFocus(appStore: appStore, annotationStore: annotationStore))
        .onAppear(perform: installKeyMonitor)
        .onDisappear(perform: removeKeyMonitor)
    }

    @ViewBuilder
    private var documentViewer: some View {
        if appStore.document?.kind == .web {
            WebViewerView()
                .id(appStore.activeTabId)
        } else {
            PdfViewerView()
                .id(appStore.activeTabId)
        }
    }

    /// Inspector only makes sense with a document; opening state still lives
    /// in AppStore so the toolbar toggle and restores keep working.
    private var inspectorPresented: Binding<Bool> {
        Binding(
            get: { appStore.document != nil && appStore.sidebarOpen },
            set: { appStore.sidebarOpen = $0 }
        )
    }

    private var sidebarTabBinding: Binding<AppStore.SidebarTab> {
        Binding(
            get: { appStore.sidebarTab },
            set: { appStore.sidebarTab = $0 }
        )
    }

    private var sidebar: some View {
        Group {
            if appStore.sidebarTab == .annotations {
                AnnotationSidebar()
            } else {
                AiPanel()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .clipped()
        .onHover { sidebarHovering = $0 }
    }

    private var documentIdentity: DocumentIdentity {
        DocumentIdentity(tabId: appStore.activeTabId, path: appStore.document?.pdfPath)
    }

    private var autosaveIdentity: AutosaveIdentity? {
        guard let tabId = appStore.activeTabId, appStore.document != nil else { return nil }
        return AutosaveIdentity(tabId: tabId, path: appStore.document?.pdfPath)
    }

    private func installKeyMonitor() {
        guard keyMonitor == nil else { return }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            handleKeyDown(event) ? nil : event
        }
    }

    private func removeKeyMonitor() {
        if let keyMonitor {
            NSEvent.removeMonitor(keyMonitor)
            self.keyMonitor = nil
        }
    }

    /// Returns true when the event matches a Vellum shortcut and must not be
    /// passed on to AppKit.
    ///
    /// The bulk of the keyboard surface now lives in native menu commands
    /// (`VellumCommands`). This monitor is deliberately reduced to only the
    /// interactions SwiftUI's `.commands` cannot express:
    ///   • bare `N` to toggle sticky-note mode,
    ///   • `Escape` to leave note mode / deselect,
    ///   • the pointer-contextual `⌘+ / ⌘− / ⌘=`, which resize the side panel's
    ///     text (instead of zooming the document) only while the pointer hovers
    ///     the open panel — a hover condition a menu shortcut can't carry.
    private func handleKeyDown(_ event: NSEvent) -> Bool {
        // Local monitors see every window's events; these shortcuts must never
        // act on the document while the Settings window is key.
        if let identifier = event.window?.identifier?.rawValue,
           identifier.localizedCaseInsensitiveContains("settings") {
            return false
        }
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let command = modifiers.contains(.command)
        let key = event.charactersIgnoringModifiers ?? ""

        // Sidebar text sizing: only intercept ⌘+/⌘− while hovering the open
        // side panel. Otherwise fall through so the View-menu zoom command
        // handles the document zoom.
        if command && !modifiers.contains(.option) && (key == "=" || key == "+") {
            guard sidebarHovering && appStore.sidebarOpen else { return false }
            appStore.increaseSidebarFont()
            return true
        }
        if command && !modifiers.contains(.option) && key == "-" {
            guard sidebarHovering && appStore.sidebarOpen else { return false }
            appStore.decreaseSidebarFont()
            return true
        }
        if key == "\u{1b}" || event.keyCode == 53 {
            guard !isTextInputFirstResponder else { return false }
            annotationStore.selectAnnotation(nil)
            appStore.setMode(.view)
            return false
        }
        if !command && !modifiers.contains(.control) && key == "n" {
            guard !isTextInputFirstResponder, appStore.document != nil else { return false }
            appStore.setMode(appStore.mode == .note ? .view : .note)
            return true
        }
        return false
    }

    private var isTextInputFirstResponder: Bool {
        guard let responder = NSApp.keyWindow?.firstResponder else { return false }
        return responder is NSTextView || responder is NSTextField || responder is NSSearchField
    }
}

private struct DocumentIdentity: Hashable {
    var tabId: String?
    var path: String?
}

private struct AutosaveIdentity: Hashable {
    var tabId: String
    var path: String?
}

