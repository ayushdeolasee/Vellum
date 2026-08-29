#if os(iOS)
import Foundation
import UIKit

/// Where the phone shell currently is. Home is a ROUTE, not a tab (#153 D1):
/// going Home leaves the current tab active in `AppStore`, so its residency pin
/// survives and coming back is a re-parent rather than a reopen. The pane tree
/// therefore never grows a leaf for Home, and the phone never calls
/// `AppStore.newStartTab()`.
enum PhoneRoute: Sendable, Hashable {
    case home
    case reader
}

/// The phone shell's own state: which route is on screen, whether the tab
/// switcher is up, whether the reader chrome is showing — plus the two
/// phone-specific rules that sit on top of the window-global inspector state.
///
/// Deliberately no `import SwiftUI`. Everything here is decidable without a
/// view, which is what makes the sheet-dismissal trap below testable at all;
/// the shell view binds to it and adds no rules of its own.
///
/// ## Why the inspector state is NOT held here (D2)
///
/// The phone's inspector sheet binds to `WorkspaceStore.sidebarOpen` /
/// `sidebarTab`, the same window-global state the iPad sidebar uses. That is
/// what makes "quote this in AI", ⌥⌘1/2/3 and the ink reveal light up the phone
/// sheet with zero new plumbing (`AiStore`, `AppStore`, `InkController_iOS` and
/// `ShortcutRouter_iOS` all already write it), and it is what preserves the
/// user's chosen panel across a trip through Home.
@MainActor
@Observable
final class PhoneShellStore {
    /// The window the shell is driving. Single-pane by construction on this
    /// idiom (`ShellIdiom_iOS.phone.paneLayout == .singlePane`), so
    /// `focusedPane` is simply "the pane".
    private let workspace: WorkspaceStore

    private(set) var route: PhoneRoute = .home

    /// The full-screen tab switcher (P7). Held here rather than as view state
    /// so route changes can close it — SwiftUI presentations that outlive the
    /// screen underneath them are how a phone shell ends up with two things on
    /// screen claiming to be "current".
    private(set) var switcherPresented = false

    /// Whether the reader chrome (top/bottom capsules) is showing. Immersive
    /// reading is the absence of chrome, not a separate route, so this is plain
    /// shell state rather than a third `PhoneRoute` case.
    private(set) var chromeVisible = true

    /// About one thumb-width of deliberate page travel. The native adapters
    /// send points, so PDF and web readers share the exact same threshold.
    static let chromeTravelThreshold: CGFloat = 28
    private static let chromeJitterTolerance: CGFloat = 3

    private enum ScrollDirection {
        case later
        case earlier
    }

    private var scrollDirection: ScrollDirection?
    private var accumulatedScrollTravel: CGFloat = 0
    private var pendingReverseTravel: CGFloat = 0
    private var scrollGestureFrozen = false
    private var alwaysShowReaderControls = false

    /// D3 — the compact default for `sidebarOpen` is `false`.
    ///
    /// `WorkspaceStore.sidebarOpen` defaults to `true`, which is right for an
    /// iPad sidebar (a column beside the document) and wrong for a phone sheet
    /// (a panel *over* it). Left alone, restoring a session at launch would put
    /// a half-height sheet over the document before the user asked for one.
    /// Written once, here: it is not persisted and has no side effects, so this
    /// costs nothing on any later launch.
    init(workspace: WorkspaceStore) {
        self.workspace = workspace
        workspace.sidebarOpen = false
    }

    private var app: AppStore { workspace.focusedPane.app }

    // MARK: - Inspector (D2)

    /// Whether the inspector sheet should be on screen.
    ///
    /// Three terms. `workspace.inspectorPresented` is the shared rule — a
    /// document must be open and the user must want the panel — and
    /// `route == .reader` is the phone's: the sheet belongs over the document,
    /// and Home has its own full-screen surface underneath it.
    ///
    /// Capture also hides the sheet: its controls live directly over the
    /// reader, where sheet sizing cannot block or distort them.
    ///
    /// The final term is the tab switcher (P7), and it is a mechanical necessity as
    /// much as a design one. UIKit presents one thing at a time from a given
    /// host: a `.fullScreenCover` asked to present while this sheet is up
    /// either fails or stacks over a panel that has no business being under it.
    /// Standing the sheet down while the switcher is up also happens to be the
    /// right picture — the switcher replaces the document, and an inspector
    /// over a grid of cards inspects nothing. The preference itself is
    /// untouched, so closing the switcher brings the panel back.
    var inspectorPresented: Bool {
        workspace.inspectorPresented
            && route == .reader
            && !switcherPresented
            && app.mode != .snapshotRegion
    }

    /// Snapshot capture owns the full reader surface. Keep the user's normal
    /// chrome preference intact so the bars return when capture ends, but do
    /// not present either bar while the marquee is active.
    var readerChromePresented: Bool {
        chromeVisible && app.mode != .snapshotRegion
    }

    /// Applies a presentation change originating from SwiftUI's sheet.
    ///
    /// THE DISMISSAL TRAP. When the route flips to Home, `inspectorPresented`
    /// above goes false, SwiftUI dismisses the sheet — and writes `false` back
    /// through the binding. `WorkspaceStore.setInspectorPresented`'s own guard
    /// does not save us here the way it does on iPad: that guard only ignores
    /// writes made while there is no document, and on Home the document is
    /// still open (D1). So the write would land, flipping the user's
    /// window-level preference off, and returning to the reader would show no
    /// panel — the exact state loss D2 exists to prevent.
    ///
    /// Hence: presentation changes are only accepted while the reader is the
    /// route that owns the sheet. Anything arriving from any other route is
    /// SwiftUI reporting a consequence, not a user asking for one.
    ///
    /// The switcher is the same trap wearing different clothes: raising it also
    /// takes `inspectorPresented` false, and SwiftUI writes that false back the
    /// same way. Hence the guard names both routes-away-from-the-sheet.
    func setInspectorPresented(_ isPresented: Bool) {
        guard route == .reader,
              !switcherPresented,
              app.mode != .snapshotRegion else { return }
        workspace.setInspectorPresented(isPresented)
    }

    /// The panel the sheet shows. Window-global, so it survives Home visits and
    /// stays in step with whatever the iPad last selected in this session.
    var inspectorTab: WorkspaceStore.SidebarTab {
        workspace.sidebarTab
    }

    /// Changes the visible panel without changing whether the sheet is open.
    ///
    /// The switcher lives inside an already-presented sheet, so its buttons mean
    /// only "show this panel". Keeping this separate from `revealInspector`
    /// prevents a tab choice from being coupled to presentation geometry or a
    /// detent transition.
    func selectInspectorTab(_ tab: WorkspaceStore.SidebarTab) {
        guard app.document != nil else { return }
        workspace.sidebarTab = tab
    }

    /// The ink controller the inspector's Handwriting section reads — the live
    /// tab's own, taken straight off its runtime.
    ///
    /// NOT via `InkRegistry_iOS`. That registry exists to retarget the sidebar's
    /// ink as *pane focus* moves between split panes, and this idiom is
    /// `.singlePane` by construction (D4): there is one pane, it can never lose
    /// focus, and routing through the registry would add an indirection whose
    /// only job is to answer a question the phone shell cannot ask. Asking the
    /// runtime directly also means the section follows the *active tab*, which
    /// is the thing that actually changes here.
    ///
    /// `liveTabRuntime(for:)` mints a runtime if there isn't one, which is
    /// harmless at this call site and only at this one: it is asked for the
    /// active tab, and the reader has already mounted that tab's runtime. (The
    /// tab switcher must never ask it — see `WorkspaceStore.liveTabRuntime`.)
    ///
    /// Read-only by design. `InkPagesSection_iOS` is jump-to-page navigation so
    /// that iPad-made ink stays navigable here, but no ink *tools* are exposed
    /// anywhere in the phone chrome — nothing sets `isActive`, so the tool
    /// palette never appears.
    var inspectorInk: InkController_iOS? {
        guard let tabId = app.activeTabId else { return nil }
        return workspace.liveTabRuntime(for: tabId).ink
    }

    /// Selects a panel and makes sure it is actually on screen — the phone's
    /// entry point for every existing reveal path ("quote in AI", ⌥⌘1/2/3, the
    /// ink reveal, `AppStore`'s note flow).
    ///
    /// It routes to the reader as well as opening the panel. Those callers all
    /// mean "show me this panel *for the document*", and a reveal that quietly
    /// did nothing because the shell happened to be on Home (a hardware ⌥⌘2 is
    /// reachable from there) would read as a dead shortcut.
    func revealInspector(_ tab: WorkspaceStore.SidebarTab) {
        // The store's own guard: no document, no panel, and no silent flip of
        // the user's preference for whenever they next open one.
        guard app.document != nil else { return }
        workspace.revealSidebarTab(tab)
        showReader()
    }

    // MARK: - Routing

    func presentSwitcher() {
        switcherPresented = true
    }

    /// Handles interactive/system dismissal as well as the switcher's Done
    /// button. Returning to an already-mounted reader is still a navigation
    /// arrival, so it restores controls and discards pre-switcher travel.
    func setSwitcherPresented(_ isPresented: Bool) {
        guard switcherPresented != isPresented else { return }
        switcherPresented = isPresented
        if !isPresented, route == .reader {
            resetChromeScrollGesture()
            chromeVisible = true
        }
    }

    func showHome() {
        // The switcher is a full-screen cover over the reader; leaving the
        // reader with it still presented would stack it over Home.
        switcherPresented = false
        resetChromeScrollGesture()
        route = .home
    }

    /// Every navigation arrival starts with stable, visible controls. Automatic
    /// hiding only begins after a fresh direct document scroll on this visit.
    func showReader() {
        switcherPresented = false
        resetChromeScrollGesture()
        chromeVisible = true
        route = .reader
    }

    /// A document was opened (Home, the importer, a Files-app hand-off, the
    /// switcher's "+"). Distinct from `showReader()` only in intent — both end
    /// at the reader with chrome up and the switcher closed — so the call sites
    /// read as what happened rather than as what to draw.
    func didOpenDocument() {
        showReader()
    }

    /// A tab was closed. With no tabs left there is nothing for the reader to
    /// render (the phone never mints a start tab, D1), so the shell falls back
    /// to Home rather than to an empty document surface.
    func didCloseTab() {
        guard app.tabs.isEmpty else { return }
        showHome()
    }

    // MARK: - Document-driven chrome

    /// Find is rendered inside the chrome. A hardware shortcut can open it
    /// while bars are hidden, so presentation must reveal the field before it
    /// takes keyboard focus (which then freezes automatic changes).
    func findPresentationChanged(isVisible: Bool) {
        guard isVisible else { return }
        resetChromeScrollGesture()
        chromeVisible = true
    }

    /// Applies the persisted Settings → Reader preference live. Enabling it
    /// while controls are hidden reveals them immediately.
    func updateAlwaysShowReaderControls(_ enabled: Bool) {
        alwaysShowReaderControls = enabled
        resetChromeScrollGesture()
        if enabled { chromeVisible = true }
    }

    /// Called for VoiceOver/Switch Control status changes. Stable-control
    /// navigation is behaviorally equivalent to the preference while active.
    func accessibilityRequirementDidChange() {
        resetChromeScrollGesture()
        if Self.assistiveNavigationRequiresStableControls {
            chromeVisible = true
        }
    }

    /// Consumes normalized, direct vertical travel from PDFKit or WebKit. A
    /// blocked source freezes the WHOLE pan, so a selection that is cleared by
    /// the first few points cannot cause the tail of that same gesture to hide
    /// controls unexpectedly.
    func handleReaderScroll(_ event: ReaderChromeScrollEvent) {
        switch event {
        case .tapped(let sourceInteractionBlocked):
            resetChromeScrollGesture()
            guard !sourceInteractionBlocked, !automaticChromeChangesBlocked else { return }
            chromeVisible.toggle()

        case .began(let sourceInteractionBlocked):
            scrollGestureFrozen = sourceInteractionBlocked || automaticChromeChangesBlocked
            if scrollGestureFrozen { resetChromeScrollProgress() }

        case .changed(let deltaY, let sourceInteractionBlocked):
            if sourceInteractionBlocked || automaticChromeChangesBlocked {
                scrollGestureFrozen = true
                resetChromeScrollProgress()
            }
            guard !scrollGestureFrozen else { return }
            accumulateReaderTravel(deltaY)

        case .ended:
            // Keep valid partial travel across finger lifts: "accumulated"
            // scrolling can be two short direct pans. Only the per-pan freeze
            // latch ends here.
            scrollGestureFrozen = false

        case .reset:
            resetChromeScrollGesture()
        }
    }

    /// Kept for the DEBUG launch-state screenshot hook and direct state tests.
    /// Runtime reader UI has no explicit hide/reveal action.
    func setChrome(_ visible: Bool) {
        guard visible || !automaticChromeChangesBlocked else {
            chromeVisible = true
            return
        }
        chromeVisible = visible
        resetChromeScrollGesture()
    }

    private var automaticChromeChangesBlocked: Bool {
        alwaysShowReaderControls
            || Self.assistiveNavigationRequiresStableControls
            || route != .reader
            || switcherPresented
            || inspectorPresented
            || app.findVisible
            || app.mode != .view
            || textInputFocusRequiresStableChrome
    }

    /// PDFKit's private `PDFDocumentView` conforms to `UITextInput` so it can
    /// host native selection, even when nobody is typing. Treating that as a
    /// keyboard field freezes every PDF pan. Real editors (Find, note text,
    /// webpage inputs) are outside `VellumPDFView` and remain blocked.
    private var textInputFocusRequiresStableChrome: Bool {
        guard VellumKeyboardFocus.isTextInputFirstResponder else { return false }
        return !Self.isPDFDocumentSurfaceResponder(UIResponder.vellumCurrentFirstResponder)
    }

    /// Testable ancestry check for PDFKit's private text-input responder.
    static func isPDFDocumentSurfaceResponder(_ responder: UIResponder?) -> Bool {
        guard let view = responder as? UIView else { return false }
        var ancestor: UIView? = view
        while let current = ancestor {
            if current is VellumPDFView { return true }
            ancestor = current.superview
        }
        return false
    }

    private static var assistiveNavigationRequiresStableControls: Bool {
        UIAccessibility.isVoiceOverRunning || UIAccessibility.isSwitchControlRunning
    }

    private func accumulateReaderTravel(_ deltaY: CGFloat) {
        guard abs(deltaY) > 0.01 else { return }
        let nextDirection: ScrollDirection = deltaY > 0 ? .later : .earlier
        let travel = abs(deltaY)

        if let scrollDirection, scrollDirection != nextDirection {
            // Accumulate the deadband, not just each sample: repeated 1-point
            // samples eventually become a deliberate reversal rather than
            // being ignored forever.
            pendingReverseTravel += travel
            guard pendingReverseTravel > Self.chromeJitterTolerance else { return }
            self.scrollDirection = nextDirection
            accumulatedScrollTravel = pendingReverseTravel
            pendingReverseTravel = 0
        } else {
            scrollDirection = nextDirection
            pendingReverseTravel = 0
            accumulatedScrollTravel += travel
        }

        guard accumulatedScrollTravel >= Self.chromeTravelThreshold else { return }
        switch nextDirection {
        case .later where chromeVisible:
            chromeVisible = false
        case .earlier where !chromeVisible:
            chromeVisible = true
        default:
            break
        }
        resetChromeScrollProgress()
    }

    private func resetChromeScrollProgress() {
        scrollDirection = nil
        accumulatedScrollTravel = 0
        pendingReverseTravel = 0
    }

    private func resetChromeScrollGesture() {
        resetChromeScrollProgress()
        scrollGestureFrozen = false
    }
}
#endif
