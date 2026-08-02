#if os(iOS)
import SwiftUI
import UIKit

/// Hardware-keyboard shortcuts for the iPad app, mirroring the macOS
/// `VellumCommands` menu surface (see `App/VellumCommands.swift`). When a Magic
/// Keyboard or any Bluetooth keyboard is attached, these appear in the ⌘-hold
/// discoverability HUD — and, on iPadOS 26, in the real menu bar — and fire the
/// same actions as the Mac app.
///
/// This type is only the *presentation* of the shortcut system (issue #40):
///   • the chords themselves live in `KeyboardShortcuts_iOS.swift`, as a plain
///     data table so they can be unit-tested and shared;
///   • the behaviour lives in `VellumShortcutRouter`, which the UIKit
///     document-surface key commands also call.
/// Every item below is therefore a two-liner: title and chord straight out of
/// the catalog, action straight into the router. Adding a shortcut means adding
/// a row to the table and one `item(_:)` call here — the two cannot drift.
///
/// Unlike macOS — which routes through `@FocusedValue` for free menu validation
/// — the iPad app is a single window, so we capture the WorkspaceStore directly
/// and the router re-checks every precondition at invocation time. That keeps
/// each guard fresh (no reliance on `Commands` re-evaluation to refresh
/// `.disabled` state), so a shortcut never fires the wrong thing because a menu
/// item was left stale — and every document command targets the pane the user
/// is actually working in.
struct VellumCommands_iOS: Commands {
    let workspace: WorkspaceStore

    var body: some Commands {
        // MARK: File
        CommandGroup(replacing: .newItem) {
            item(.newTab)
        }

        // Replacing (not adding to) the standard import/export group means the
        // system's own document-import item — and any key equivalent it carries
        // — goes away, leaving Vellum's pane-aware importer as the sole owner of
        // ⌘O.
        CommandGroup(replacing: .importExport) {
            item(.openFile)
            item(.addWebpage)
        }

        CommandGroup(after: .newItem) {
            item(.closeTab)
        }

        CommandGroup(replacing: .printItem) {
            item(.printDocument)
        }

        CommandGroup(replacing: .saveItem) {
            item(.save)
        }

        // MARK: Edit → Find
        // Appended after the standard text-editing group, where the Mac's
        // Edit ▸ Find lives. ⌘C/⌘V/⌘X/⌘A are deliberately absent: UIKit already
        // implements those on every text surface and shadowing them would break
        // editing.
        CommandGroup(after: .textEditing) {
            item(.find)
            item(.findNext)
            item(.findPrevious)
            item(.dismiss)
        }

        // MARK: View (zoom + inspector live alongside the built-in sidebar group)
        CommandGroup(after: .sidebar) {
            item(.zoomIn)
            item(.zoomOut)
            item(.actualSize)

            Divider()

            item(.toggleInspector)

            // Pane management, and only where there is a second pane to manage
            // (#153 D4). On a `.singlePane` workspace these four are omitted
            // outright rather than shown disabled: iPadOS builds this menu once
            // per `Commands` evaluation, so a "disabled" item is really just an
            // item that looks available in the ⌘-hold HUD and does nothing. The
            // divider goes with them — a trailing separator over an empty group
            // is the tell that something was hidden.
            if workspace.layout == .splitScreen {
                Divider()

                item(.splitRight)
                item(.splitDown)
                item(.mergePanes)
                item(.closePane)
            }
        }

        // MARK: Navigate
        CommandMenu("Navigate") {
            item(.previousPage)
            item(.nextPage)
            item(.firstPage)
            item(.lastPage)

            Divider()

            // Web in-page history.
            item(.webBack)
            item(.webForward)

            Divider()

            // Tab cycling, wrapping at the ends across any mix of
            // PDF / web / start tabs.
            item(.previousTab)
            item(.nextTab)

            Divider()

            // Tab switching ⌘1…⌘9.
            ForEach(1...9, id: \.self) { number in
                item(.showTab(number))
            }
        }

        // MARK: Annotations
        CommandMenu("Annotations") {
            item(.bookmarkPage)
            item(.toggleNoteMode)
        }

        // MARK: Help
        // Replacing the standard group, like the Mac's `VellumCommands`, so
        // Vellum's own two entries are the whole Help menu.
        CommandGroup(replacing: .help) {
            item(.showHelp)
            // No catalogue row: `VellumShortcut` requires a chord and the
            // walkthrough is intentionally unbound, on both platforms.
            Button("Vellum Walkthrough") {
                VellumShortcutRouter.perform(.showWalkthrough, workspace: workspace)
            }
        }
    }

    /// One menu item, fully described by the catalog.
    ///
    /// Titles are static rather than state-dependent ("Bookmark Page", not
    /// "Remove Bookmark"): iPadOS builds the menu from a single `Commands`
    /// evaluation and does not re-validate items the way AppKit does before each
    /// menu tracking session, so a live title would read as stale more often
    /// than it read as correct.
    ///
    /// The availability check is the same one the router enforces
    /// (`VellumShortcutCatalog.isAvailable`), applied here so a command that a
    /// single-pane workspace cannot honour never reaches the HUD at all — and so
    /// that a future gated action added to a menu below cannot leak in by
    /// someone forgetting the surrounding `if`.
    @ViewBuilder
    private func item(_ action: VellumShortcutAction) -> some View {
        if VellumShortcutCatalog.isAvailable(action, in: workspace.layout),
           let shortcut = VellumShortcutCatalog[action] {
            Button(shortcut.title) {
                VellumShortcutRouter.perform(action, workspace: workspace)
            }
            .keyboardShortcut(
                shortcut.combo.key.keyEquivalent, modifiers: shortcut.combo.modifiers.eventModifiers)
        }
    }
}
#endif  // os(iOS)
