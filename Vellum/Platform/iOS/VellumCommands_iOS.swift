#if os(iOS)
import SwiftUI
import UIKit

/// Hardware-keyboard shortcuts for the iPad app, mirroring the macOS
/// `VellumCommands` menu surface (see `App/VellumCommands.swift`). When a Magic
/// Keyboard or any Bluetooth keyboard is attached, these appear in the ⌘-hold
/// discoverability HUD and fire the same actions as the Mac app.
///
/// Unlike macOS — which routes through `@FocusedValue` for free menu validation
/// — the iPad app is a single window, so we capture the WorkspaceStore directly,
/// resolve the focused pane's stores at invocation time, and guard inside each
/// action. That keeps every guard fresh (no reliance on `Commands` re-evaluation
/// to update `.disabled` state), so a shortcut never silently no-ops because a
/// menu item was left stale — and every document command targets the pane the
/// user is actually working in.
struct VellumCommands_iOS: Commands {
    let workspace: WorkspaceStore

    private var appStore: AppStore { workspace.focusedPane.app }
    private var annotationStore: AnnotationStore { workspace.focusedPane.annotations }

    var body: some Commands {
        // MARK: File
        CommandGroup(replacing: .newItem) {
            Button("New Tab") { appStore.newStartTab() }
                .keyboardShortcut("t", modifiers: .command)
        }

        // Replace UIKit's document-import command so ⌘O has exactly one owner
        // and routes through Vellum's pane-aware importer.
        CommandGroup(replacing: .importExport) {
            Button("Open…") {
                NotificationCenter.default.post(name: .vellumOpenFile, object: nil)
            }
            // UIKit owns the standard hardware ⌘O key command on iPad. Adding
            // a SwiftUI duplicate produces undefined dispatch; keep this menu
            // action while leaving the standard key equivalent to UIKit.

            Button("Add Webpage…") {
                NotificationCenter.default.post(name: .vellumAddWebpage, object: nil)
            }
            .keyboardShortcut("l", modifiers: .command)
        }

        CommandGroup(after: .newItem) {
            Button("Close Tab") {
                guard !appStore.tabs.isEmpty else { return }
                Task { await appStore.closeFile() }
            }
            .keyboardShortcut("w", modifiers: .command)
        }

        CommandGroup(replacing: .printItem) {
            Button("Print…") {
                guard appStore.document != nil else { return }
                appStore.printDocument()
            }
            .keyboardShortcut("p", modifiers: .command)
        }

        // MARK: Find
        // UIKit already owns the responder-chain ⌘A/⌘F/⌘G commands on iPad.
        // These menu actions expose Vellum's document-aware find UI without
        // registering duplicate key equivalents with undefined dispatch.
        CommandGroup(after: .textEditing) {
            Button("Find…") {
                guard appStore.document != nil else { return }
                appStore.showFind()
            }

            Button("Find Next") {
                guard appStore.findVisible else { return }
                appStore.findNext()
            }

            Button("Find Previous") {
                guard appStore.findVisible else { return }
                appStore.findPrev()
            }
        }

        CommandGroup(replacing: .saveItem) {
            Button("Save") {
                // Save writes annotations back into the PDF; web tabs persist via
                // export, not Save, so the command is PDF-only.
                guard appStore.document?.kind == .pdf,
                      let sessionId = appStore.activeTabId else { return }
                Task { try? await appStore.sessions.saveFile(sessionId: sessionId) }
            }
            .keyboardShortcut("s", modifiers: .command)
        }

        // MARK: View
        CommandGroup(after: .sidebar) {
            Button("Zoom In") {
                guard appStore.document != nil else { return }
                appStore.zoomIn()
            }
            .keyboardShortcut("+", modifiers: .command)

            // ⌘= as an unshifted alias for Zoom In: on hardware keyboards the
            // "+" glyph needs Shift, so ⌘= is the ergonomic combo most reach for.
            Button("Zoom In") {
                guard appStore.document != nil else { return }
                appStore.zoomIn()
            }
            .keyboardShortcut("=", modifiers: .command)

            Button("Zoom Out") {
                guard appStore.document != nil else { return }
                appStore.zoomOut()
            }
            .keyboardShortcut("-", modifiers: .command)

            Button("Actual Size") {
                guard appStore.document != nil else { return }
                appStore.resetZoom()
            }
            .keyboardShortcut("0", modifiers: .command)

            Divider()

            Button("Toggle Inspector") {
                guard appStore.document != nil else { return }
                workspace.sidebarOpen.toggle()
            }
            .keyboardShortcut("s", modifiers: [.command, .option])

            Divider()

            // Split shortcuts mirror macOS: they avoid the arrow keys, which
            // ⌘⌥↑/↓ already use for First/Last Page. ⌘\ matches VS Code.
            Button("Split Right") { workspace.splitFocused(.horizontal) }
                .keyboardShortcut("\\", modifiers: .command)

            Button("Split Down") { workspace.splitFocused(.vertical) }
                .keyboardShortcut("\\", modifiers: [.command, .option])

            Button("Merge Panes") {
                guard workspace.isSplit else { return }
                workspace.mergeAll()
            }
            .keyboardShortcut("j", modifiers: [.command, .option])

            Button("Close Pane") {
                guard workspace.isSplit else { return }
                workspace.closePane(workspace.focusedPaneId)
            }
            .keyboardShortcut("\\", modifiers: [.command, .shift])
        }

        // MARK: Navigate
        CommandMenu("Navigate") {
            Button("Previous Page") { goToPage(-1) }
                .keyboardShortcut(.upArrow, modifiers: .command)

            Button("Next Page") { goToPage(1) }
                .keyboardShortcut(.downArrow, modifiers: .command)

            Button("First Page") {
                guard isPdf else { return }
                appStore.goToPage(1)
            }
            .keyboardShortcut(.upArrow, modifiers: [.command, .option])

            Button("Last Page") {
                guard isPdf else { return }
                appStore.goToPage(appStore.numPages)
            }
            .keyboardShortcut(.downArrow, modifiers: [.command, .option])

            Divider()

            // Web in-page history.
            Button("Back") { webHistory(-1) }
                .keyboardShortcut("[", modifiers: .command)

            Button("Forward") { webHistory(1) }
                .keyboardShortcut("]", modifiers: .command)

            Divider()

            // Tab cycling, wrapping at the ends across any mix of tabs.
            Button("Show Previous Tab") {
                guard appStore.tabs.count >= 2 else { return }
                appStore.cycleTab(-1)
            }
            .keyboardShortcut("[", modifiers: [.command, .shift])

            Button("Show Next Tab") {
                guard appStore.tabs.count >= 2 else { return }
                appStore.cycleTab(1)
            }
            .keyboardShortcut("]", modifiers: [.command, .shift])

            Divider()

            // Tab switching ⌘1…⌘9.
            ForEach(1...9, id: \.self) { number in
                Button("Show Tab \(number)") { activateTab(index: number - 1) }
                    .keyboardShortcut(
                        KeyEquivalent(Character("\(number)")), modifiers: .command)
            }
        }

        // MARK: Annotations
        CommandMenu("Annotations") {
            Button("Bookmark Page") {
                guard appStore.document != nil else { return }
                Task { await annotationStore.toggleBookmark() }
            }
            .keyboardShortcut("d", modifiers: .command)

            Button("Toggle Note Mode") {
                // Bare `N` has no modifier, so it can collide with typing in the
                // scratchpad editor's WebView. Suppress it while that editor
                // holds keyboard focus (iOS analogue of macOS
                // `ContentView.isTextInputFirstResponder`'s responder walk).
                guard appStore.document != nil, !scratchpadEditorFocused else { return }
                appStore.setMode(appStore.mode == .note ? .view : .note)
            }
            .keyboardShortcut("n", modifiers: [])
        }
    }

    // MARK: - Derived state / actions

    private var isPdf: Bool {
        guard let doc = appStore.document else { return false }
        return doc.kind == .pdf
    }

    /// True when keyboard focus is inside the scratchpad editor's WKWebView.
    /// Editing happens in a private WebKit content view (no `UITextField` to
    /// detect directly), so we walk the first responder's view ancestry for the
    /// marker `ScratchpadWebView`.
    private var scratchpadEditorFocused: Bool {
        guard let responder = UIResponder.vellumCurrentFirstResponder as? UIView else { return false }
        var view: UIView? = responder
        while let current = view {
            if current is ScratchpadWebView { return true }
            view = current.superview
        }
        return false
    }

    private func goToPage(_ delta: Int) {
        guard isPdf else { return }
        appStore.goToPage(appStore.currentPage + delta)
    }

    private func webHistory(_ delta: Int) {
        guard appStore.document?.kind == .web else { return }
        NotificationCenter.default.post(
            name: .vellumWebHistory, object: nil, userInfo: ["delta": delta])
    }

    private func activateTab(index: Int) {
        guard appStore.tabs.indices.contains(index) else { return }
        appStore.activateTab(appStore.tabs[index].id)
    }
}

/// Resolves the current first responder without a reference to it, by bouncing a
/// captured selector through the responder chain — the standard UIKit idiom.
extension UIResponder {
    private weak static var _vellumFirstResponder: UIResponder?

    static var vellumCurrentFirstResponder: UIResponder? {
        _vellumFirstResponder = nil
        UIApplication.shared.sendAction(
            #selector(UIResponder._vellumCaptureFirstResponder(_:)), to: nil, from: nil, for: nil)
        return _vellumFirstResponder
    }

    @objc private func _vellumCaptureFirstResponder(_ sender: Any?) {
        UIResponder._vellumFirstResponder = self
    }
}
#endif  // os(iOS)
