import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @Environment(AppStore.self) private var appStore
    @Environment(AnnotationStore.self) private var annotationStore
    @Environment(AiStore.self) private var aiStore
    @Environment(\.palette) private var palette

    @State private var keyMonitor: Any?
    @State private var sidebarHovering = false
    @State private var addWebpagePresented = false
    @State private var hostWindow: NSWindow?

    var body: some View {
        VStack(spacing: 0) {
            if !appStore.tabs.isEmpty {
                TabBarView()
            }

            if appStore.findVisible && appStore.document != nil {
                FindBar()
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
                                selection: sidebarTabBinding,
                                accessibilityIdentifierPrefix: "sidebarTab"
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
        .onReceive(NotificationCenter.default.publisher(for: .vellumAddWebpage)) { _ in
            addWebpagePresented = true
        }
        .sheet(isPresented: $addWebpagePresented) {
            AddWebpageSheet()
        }
        // Publish the stores as a focused value so the app-level menu commands
        // (VellumCommands) route here and disable themselves when the Settings
        // window — which does not publish this value — is key.
        .focusedValue(\.vellumFocus, VellumFocus(appStore: appStore, annotationStore: annotationStore))
        .background(WindowAccessor { hostWindow = $0 })
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
        // Keep both panels mounted and toggle visibility rather than swapping via
        // if/else: tearing AiPanel down on every tab switch loses its scroll
        // position (returning would land mid-list) and any half-typed draft.
        // Staying mounted preserves both exactly.
        ZStack {
            let showingAnnotations = appStore.sidebarTab == .annotations
            AnnotationSidebar()
                .opacity(showingAnnotations ? 1 : 0)
                .allowsHitTesting(showingAnnotations)
                .accessibilityHidden(!showingAnnotations)
            AiPanel()
                .opacity(showingAnnotations ? 0 : 1)
                .allowsHitTesting(!showingAnnotations)
                .accessibilityHidden(showingAnnotations)
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
    /// interactions SwiftUI's `.commands` cannot express, plus two shortcuts
    /// that must be intercepted here defensively:
    ///   • bare `N` to toggle sticky-note mode,
    ///   • `Escape` to leave note mode / deselect,
    ///   • the pointer-contextual `⌘+ / ⌘− / ⌘=`, which resize the side panel's
    ///     text (instead of zooming the document) only while the pointer hovers
    ///     the open panel — a hover condition a menu shortcut can't carry.
    ///   • `⌘L` (Add Webpage) and `⌘O` (Open…) — `PDFView` and `WKWebView` both
    ///     override `performKeyEquivalent(with:)` and can swallow command-key
    ///     events before `NSWindow` ever offers them to the main menu, so once
    ///     one of those views becomes first responder (any open PDF or web
    ///     tab) the equivalent `VellumCommands` menu items silently stop
    ///     firing from the keyboard even though they still work from a click.
    ///     A local monitor runs before that responder-chain dispatch, so
    ///     handling the two shortcuts here guarantees they always reach us
    ///     regardless of which document view currently holds first responder.
    private func handleKeyDown(_ event: NSEvent) -> Bool {
        // Local monitors see every window's events; only act on events aimed
        // at the window hosting this view. A positive identity check (rather
        // than filtering out windows whose identifier "looks like Settings")
        // also excludes sheets, panels, and any future auxiliary windows.
        guard let window = event.window, window === hostWindow else { return false }
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let command = modifiers.contains(.command)
        let key = event.charactersIgnoringModifiers ?? ""
        let lowerKey = key.lowercased()

        // Escape dismisses the find bar first — this must run before the
        // text-field guard below, since the find field is itself a text field.
        if (key == "\u{1b}" || event.keyCode == 53), appStore.findVisible {
            appStore.hideFind()
            return true
        }

        // ⌘F / ⌘G / ⌘⇧G / ⌘P: PDFView and WKWebView can swallow these via
        // performKeyEquivalent before the menu sees them (same reasoning as
        // ⌘L/⌘O below), so intercept them here. Guards mirror the menu
        // validation; when a guard fails the event falls through untouched.
        if modifiers == .command && lowerKey == "f" {
            guard appStore.document != nil else { return false }
            appStore.showFind()
            return true
        }
        if modifiers == [.command, .shift] && lowerKey == "g" {
            guard appStore.findVisible else { return false }
            appStore.findPrev()
            return true
        }
        if modifiers == .command && lowerKey == "g" {
            guard appStore.findVisible else { return false }
            appStore.findNext()
            return true
        }
        if modifiers == .command && lowerKey == "p" {
            guard appStore.document != nil else { return false }
            appStore.printDocument()
            return true
        }

        // ⌘L / ⌘O: see the doc comment above — PDFView/WKWebView can eat these
        // via performKeyEquivalent before the menu ever sees them, so handle
        // them unconditionally here rather than relying on the menu shortcut.
        if modifiers == .command && key == "l" {
            NotificationCenter.default.post(name: .vellumAddWebpage, object: nil)
            return true
        }
        if modifiers == .command && key == "o" {
            openFilePanel()
            return true
        }

        // ⌘⇧[ / ⌘⇧] previous/next tab. Handled here for the same reason as
        // ⌘L/⌘O: an open PDF/web view can consume the command-key event via
        // performKeyEquivalent before the Navigate-menu shortcut is offered.
        // With Shift held, charactersIgnoringModifiers yields "{" / "}", so
        // accept both the shifted and unshifted glyphs.
        if modifiers == [.command, .shift] {
            if key == "[" || key == "{" {
                appStore.cycleTab(-1)
                return true
            }
            if key == "]" || key == "}" {
                appStore.cycleTab(1)
                return true
            }
        }

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

    /// Mirrors `VellumCommands.openPanel()`. Duplicated (rather than shared)
    /// because the menu command and this defensive key-monitor path have no
    /// common owner to hang a shared helper off without new plumbing; both
    /// are small and intentionally identical.
    private func openFilePanel() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        var types: [UTType] = [.pdf]
        if let archive = UTType(filenameExtension: "vellumweb") { types.append(archive) }
        panel.allowedContentTypes = types
        guard panel.runModal() == .OK else { return }
        let paths = panel.urls.map(\.path)
        Task { await appStore.openFiles(paths: paths) }
    }
}

private struct DocumentIdentity: Hashable {
    var tabId: String?
    var path: String?
}

/// Reports the NSWindow hosting this view so the key monitor can positively
/// identify events belonging to the main content window.
private struct WindowAccessor: NSViewRepresentable {
    let onWindow: (NSWindow?) -> Void

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async { [weak view] in onWindow(view?.window) }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async { [weak nsView] in onWindow(nsView?.window) }
    }
}

private struct AutosaveIdentity: Hashable {
    var tabId: String
    var path: String?
}

