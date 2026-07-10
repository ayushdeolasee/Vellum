#if os(iOS)
import SwiftUI

/// Hardware-keyboard shortcuts for the iPad app, mirroring the macOS
/// `VellumCommands` menu surface (see `App/VellumCommands.swift`). When a Magic
/// Keyboard or any Bluetooth keyboard is attached, these appear in the ⌘-hold
/// discoverability HUD and fire the same actions as the Mac app.
///
/// Unlike macOS — which routes through `@FocusedValue` for free menu validation
/// — the iPad app is a single window with singleton stores, so we capture the
/// stores directly and guard inside each action. That keeps every guard fresh at
/// invocation time (no reliance on `Commands` re-evaluation to update
/// `.disabled` state), so a shortcut never silently no-ops because a menu item
/// was left stale.
struct VellumCommands_iOS: Commands {
    let appStore: AppStore
    let annotationStore: AnnotationStore

    var body: some Commands {
        // MARK: File
        CommandGroup(replacing: .newItem) {
            Button("New Tab") { appStore.newStartTab() }
                .keyboardShortcut("t", modifiers: .command)

            Button("Open…") {
                NotificationCenter.default.post(name: .vellumOpenFile, object: nil)
            }
            .keyboardShortcut("o", modifiers: .command)

            Button("Add Webpage…") {
                NotificationCenter.default.post(name: .vellumAddWebpage, object: nil)
            }
            .keyboardShortcut("l", modifiers: .command)

            Divider()

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
        CommandGroup(after: .textEditing) {
            Button("Find…") {
                guard appStore.document != nil else { return }
                appStore.showFind()
            }
            .keyboardShortcut("f", modifiers: .command)

            Button("Find Next") {
                guard appStore.findVisible else { return }
                appStore.findNext()
            }
            .keyboardShortcut("g", modifiers: .command)

            Button("Find Previous") {
                guard appStore.findVisible else { return }
                appStore.findPrev()
            }
            .keyboardShortcut("g", modifiers: [.command, .shift])
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
                appStore.sidebarOpen.toggle()
            }
            .keyboardShortcut("s", modifiers: [.command, .option])
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
                guard appStore.document != nil else { return }
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
#endif  // os(iOS)
