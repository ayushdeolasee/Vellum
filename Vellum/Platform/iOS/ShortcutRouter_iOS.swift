#if os(iOS)
import SwiftUI
import UIKit

// The execution half of the keyboard-shortcut system (issue #40). The table in
// `KeyboardShortcuts_iOS.swift` says *what* the chords are; this file is the one
// place that says what they *do*, plus the plumbing that lets a UIKit document
// surface run them.
//
// Both dispatch surfaces funnel through `VellumShortcutRouter.perform`:
//   • `VellumCommands_iOS` — the SwiftUI menu, i.e. the ⌘-hold HUD / menu bar.
//   • `VellumShortcutResponder` — `UIKeyCommand`s on `VellumPDFView` /
//     `VellumWebView`, for when PDFKit or WebKit holds first responder.
// One implementation means the two can never disagree about what ⌘G does.

/// Callback shape a document surface uses to hand a decoded shortcut back to
/// SwiftUI. `@MainActor` because everything it touches (the stores, the router)
/// is main-actor isolated, and UIKit delivers key commands on the main thread
/// anyway — spelling it out lets the compiler check it instead of us.
typealias VellumShortcutHandler = @MainActor (VellumShortcutAction) -> Void

// MARK: - Router

@MainActor
enum VellumShortcutRouter {
    /// Runs `action` against the workspace's focused pane.
    ///
    /// Unlike macOS — which routes through `@FocusedValue` and gets menu
    /// validation (and therefore `.disabled` state) for free — the iPad app is a
    /// single window whose menu is rebuilt only when SwiftUI re-evaluates
    /// `Commands`. Relying on `.disabled` would leave stale menu state, so every
    /// precondition is re-checked *here*, at invocation time, and an
    /// inapplicable shortcut is a silent no-op rather than a wrong action.
    ///
    /// Note the target is always `workspace.focusedPane`, even when the chord
    /// arrived from a document surface's `UIKeyCommand`. Pane focus is driven by
    /// the tap catcher (`PaneFocusCatcher_iOS`), not by UIKit first-responder
    /// status, so in a split it is conceivable for a pane to take first
    /// responder without having taken pane focus (a long-press text selection,
    /// say). Routing to the focused pane regardless is the deliberate choice:
    /// it matches what the toolbar, inspector and find bar all act on, so the
    /// keyboard never disagrees with the rest of the chrome.
    static func perform(_ action: VellumShortcutAction, workspace: WorkspaceStore) {
        // A modal is up: every document command below acts on something the user
        // cannot see, and on macOS the equivalent menu items are disabled — a
        // disabled item does not claim its key equivalent, which is the whole of
        // issue #98 (⌘W pressed to dismiss a sheet closed the tab underneath).
        //
        // `.dismiss` is the one exception and is HANDLED rather than suppressed,
        // because a matching `UIKeyCommand` is consumed unconditionally on iOS:
        // if Escape no-oped here, the sheet the user is trying to close would
        // simply stop responding to it.
        //
        // Anything reachable from a Help/Settings scene (macOS keeps Help ▸
        // Vellum Walkthrough always enabled) must bypass this gate. The iPad
        // catalog has no such entry today; if packet 3 adds one, hoist it above
        // this check.
        if SheetPresence_iOS.isPresenting {
            if case .dismiss = action { SheetPresence_iOS.topPresented?.dismiss(animated: true) }
            return
        }

        // Pane management is gated on the workspace's own capability rather than
        // on a size class (#153 D4/D6). `VellumCommands_iOS` already omits these
        // items on a single-pane workspace, but the menu is not the only way in:
        // a `UIKeyCommand` installed on a document surface never consulted a
        // menu, and an iPad's persisted layout can hand a phone a workspace that
        // still remembers being split. `WorkspaceStore` no-ops the split calls
        // anyway; refusing here means the chord reads as unbound rather than as
        // broken.
        guard VellumShortcutCatalog.isAvailable(action, in: workspace.layout) else { return }

        let pane = workspace.focusedPane
        let app = pane.app

        switch action {
        // MARK: File
        case .newTab:
            // On the phone a "new tab" is a trip to Home, never a start tab
            // (#153 D1). Home is a ROUTE there: the current tab stays active, so
            // its residency pin survives and coming back is instant — whereas
            // `newStartTab()` would push an empty document leaf into a pane tree
            // whose shell has no tab strip to escape it with.
            //
            // A notification rather than a call because the route lives in
            // `PhoneShellStore`, which the router has no handle on — same
            // channel discipline as `.vellumOpenFile` below.
            guard workspace.layout == .splitScreen else {
                NotificationCenter.default.post(name: .vellumShowHome, object: nil)
                return
            }
            app.newStartTab()

        case .openFile:
            // The document picker is presented by the shell (`ContentView_iOS`),
            // which owns the presentation state; panes and `Commands` structs
            // cannot drive it directly, so both go through this notification.
            NotificationCenter.default.post(name: .vellumOpenFile, object: nil)

        case .addWebpage:
            NotificationCenter.default.post(name: .vellumAddWebpage, object: nil)

        case .closeTab:
            // Works on a lone document-less start tab too, matching macOS.
            guard !app.tabs.isEmpty else { return }
            Task { await app.closeFile() }

        case .printDocument:
            guard app.document != nil else { return }
            app.printDocument()

        case .save:
            // Save writes annotations back into the PDF; web tabs persist via
            // export, not Save, so the command is PDF-only.
            guard app.document?.kind == .pdf, let sessionId = app.activeTabId else { return }
            Task { try? await app.sessions.saveFile(sessionId: sessionId) }

        // MARK: Find
        case .find:
            guard app.document != nil else {
                // Home is on screen, so "Find…" has nothing to find and ⌘F is
                // free to mean "search my library". Extending the router is
                // what keeps ONE claimant on the chord — a competing SwiftUI
                // `.keyboardShortcut("f")` in the Home view would race this one
                // and SwiftUI picks between duplicates arbitrarily.
                NotificationCenter.default.post(name: .vellumFocusHomeSearch, object: nil)
                return
            }
            app.showFind()

        case .findNext:
            guard app.findVisible else { return }
            app.findNext()

        case .findPrevious:
            guard app.findVisible else { return }
            app.findPrev()

        case .dismiss:
            // Order matters and mirrors the macOS key monitor: closing the find
            // bar comes first and is NOT gated on the text-input check, because
            // the find field is itself a text input holding first responder —
            // gating it would make Escape unable to close the very bar it opened.
            if app.findVisible {
                app.hideFind()
                return
            }
            guard !VellumKeyboardFocus.isTextInputFirstResponder else { return }
            pane.annotations.selectAnnotation(nil)
            app.setMode(.view)

        // MARK: View
        case .zoomIn:
            guard app.document != nil else { return }
            app.zoomIn()

        case .zoomOut:
            guard app.document != nil else { return }
            app.zoomOut()

        case .actualSize:
            guard app.document != nil else { return }
            app.resetZoom()

        case .toggleInspector:
            // The inspector only exists alongside a document, but its open state
            // is window-global so it survives focus changes.
            guard app.document != nil else { return }
            workspace.sidebarOpen.toggle()

        case .showSidebarTab(let tab):
            // Reveal, never toggle: ⌥⌘S is the toggle, and a panel command that
            // sometimes HID the panel would be a trap. `revealSidebarTab` also
            // declines without a document, so this cannot silently flip the
            // user's preference for the next document they open.
            workspace.revealSidebarTab(tab)

        case .splitRight:
            workspace.splitFocused(.horizontal)

        case .splitDown:
            workspace.splitFocused(.vertical)

        case .mergePanes:
            guard workspace.isSplit else { return }
            workspace.mergeAll()

        case .closePane:
            guard workspace.isSplit else { return }
            workspace.closePane(workspace.focusedPaneId)

        // MARK: Navigate
        case .previousPage:
            goToPage(app, delta: -1)

        case .nextPage:
            goToPage(app, delta: 1)

        case .firstPage:
            guard isPdf(app) else { return }
            app.goToPage(1)

        case .lastPage:
            guard isPdf(app) else { return }
            app.goToPage(app.numPages)

        case .webBack:
            webHistory(app, delta: -1)

        case .webForward:
            webHistory(app, delta: 1)

        case .previousTab:
            guard app.tabs.count >= 2 else { return }
            app.cycleTab(-1)

        case .nextTab:
            guard app.tabs.count >= 2 else { return }
            app.cycleTab(1)

        case .showTab(let number):
            // The table is 1-based (⌘1 is the first tab); `tabs` is 0-based.
            let index = number - 1
            guard app.tabs.indices.contains(index) else { return }
            app.activateTab(app.tabs[index].id)

        // MARK: Annotations
        case .bookmarkPage:
            guard app.document != nil else { return }
            let annotations = pane.annotations
            Task { await annotations.toggleBookmark() }

        case .toggleNoteMode:
            // Bare `N` with no modifier: it must never steal a keystroke that
            // belongs to a text field, the scratchpad's CodeMirror editor, or
            // the AI composer. This is the iOS analogue of the macOS
            // `ContentView.isTextInputFirstResponder` responder walk.
            guard app.document != nil, !VellumKeyboardFocus.isTextInputFirstResponder else { return }
            app.setMode(app.mode == .note ? .view : .note)

        // MARK: Help
        //
        // Deliberately NOT gated on `app.document != nil`: someone who just
        // closed their last tab is exactly who reaches for these. Both sheets
        // are presented at the app root, so they travel as notifications.
        case .showHelp:
            NotificationCenter.default.post(name: .vellumShowHelp, object: nil)

        case .showWalkthrough:
            NotificationCenter.default.post(name: .vellumShowWalkthrough, object: nil)
        }
    }

    // MARK: - Helpers

    private static func isPdf(_ app: AppStore) -> Bool { app.document?.kind == .pdf }

    private static func goToPage(_ app: AppStore, delta: Int) {
        guard isPdf(app) else { return }
        app.goToPage(app.currentPage + delta)
    }

    private static func webHistory(_ app: AppStore, delta: Int) {
        // The web viewer owns its WKWebView's history so it can rebind the
        // session; the shortcut only asks it to move.
        //
        // Inherited quirk, not a regression: this notification is pane-blind, so
        // in a split with two web tabs both move. macOS behaves identically (the
        // toolbar buttons post the same broadcast) — fixing it means making the
        // notification pane-scoped on both platforms, which is out of scope here.
        guard app.document?.kind == .web else { return }
        NotificationCenter.default.post(
            name: .vellumWebHistory, object: nil, userInfo: ["delta": delta])
    }
}

// MARK: - Keyboard focus

/// First-responder questions the shortcut system needs to answer before firing
/// a chord that a text surface might legitimately want.
@MainActor
enum VellumKeyboardFocus {
    /// True when the user is typing somewhere: a UIKit text control, anything
    /// conforming to `UITextInput`, or the scratchpad's WebView-hosted editor.
    ///
    /// Mirrors the macOS `ContentView.isTextInputFirstResponder`. The scratchpad
    /// needs the ancestry walk because CodeMirror edits inside a WKWebView, so
    /// the first responder is a private WebKit content view rather than a
    /// `UITextView` — hence the marker subclass `ScratchpadWebView`.
    static var isTextInputFirstResponder: Bool {
        guard let responder = UIResponder.vellumCurrentFirstResponder else { return false }
        if responder is UITextField || responder is UITextView || responder is UISearchBar {
            return true
        }
        guard let view = responder as? UIView else {
            // Non-view responders can still be text inputs (e.g. a custom
            // `UIKeyInput`), so fall back to the protocol test.
            return responder is any UITextInput
        }
        var ancestor: UIView? = view
        while let current = ancestor {
            if current is ScratchpadWebView { return true }
            ancestor = current.superview
        }
        return view is any UITextInput
    }
}

/// Resolves the current first responder without holding a reference to it, by
/// bouncing a captured selector through the responder chain — the standard UIKit
/// idiom, since `UIWindow` exposes no `firstResponder` property.
extension UIResponder {
    @MainActor private static weak var _vellumFirstResponder: UIResponder?

    @MainActor
    static var vellumCurrentFirstResponder: UIResponder? {
        _vellumFirstResponder = nil
        UIApplication.shared.sendAction(
            #selector(UIResponder._vellumCaptureFirstResponder(_:)), to: nil, from: nil, for: nil)
        return _vellumFirstResponder
    }

    @MainActor
    @objc private func _vellumCaptureFirstResponder(_ sender: Any?) {
        UIResponder._vellumFirstResponder = self
    }
}

// MARK: - Document-surface responder

/// Adopted by the Vellum-owned views that wrap a UIKit document surface
/// (`VellumPDFView` around PDFKit, `VellumWebView` around WebKit).
///
/// Why this exists at all: SwiftUI's `.keyboardShortcut` commands live at the
/// end of the responder chain, so whenever PDFKit or WebKit is first responder
/// it sees the key press first and can consume chords it has its own bindings
/// for (⌘F, ⌘G, ⌘↑/⌘↓ scrolling, ⌘[ / ⌘] history). macOS neutralises that with
/// a local `NSEvent` monitor; iPadOS offers no such pre-dispatch hook, so we put
/// the competing chords on the nearest Vellum-owned ancestor of the first
/// responder instead. UIKit stops at the first responder that handles a chord,
/// so this wins the race *and* keeps the menu copy from double-firing.
@MainActor
protocol VellumShortcutResponder: UIView {
    /// Set by the `UIViewRepresentable` that vends the view; forwards to
    /// `VellumShortcutRouter.perform`.
    var onShortcut: VellumShortcutHandler? { get set }
}

extension VellumShortcutResponder {
    /// The catalog's document-surface commands, bound to `selector`. Conformers
    /// pass their own `#selector(...)` because an `@objc` entry point cannot be
    /// synthesised in a protocol extension.
    func vellumKeyCommands(action selector: Selector) -> [UIKeyCommand] {
        VellumShortcutCatalog.documentSurfaceKeyCommands(action: selector)
    }

    /// Decodes the shortcut a `UIKeyCommand` carried and forwards it.
    func vellumPerform(_ command: UIKeyCommand) {
        guard let identifier = command.propertyList as? String,
              let action = VellumShortcutCatalog.action(forIdentifier: identifier)
        else { return }
        onShortcut?(action)
    }
}
#endif  // os(iOS)
