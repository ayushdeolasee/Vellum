#if os(iOS)
import SwiftUI

/// The phone's inspector: the iPad's inspector column, presented as a detented
/// sheet over the reader (#153 P6).
///
/// The content is `SidebarContent_iOS` **unchanged** — the same switcher, the
/// same three panels, the same lazy AI/scratchpad latches. That is the whole
/// design: the phone has no second copy of the annotation list or the AI panel
/// to keep in step, and every existing reveal path (`AiStore`'s "quote in AI",
/// `AppStore`'s note flow, ⌥⌘1/2/3, the ink reveal) already writes the
/// window-global `sidebarTab`/`sidebarOpen` this sheet is bound to (D2), so
/// they light it up here with no new plumbing.
///
/// ## Why every dependency is passed in and re-injected
///
/// A `.sheet` is a separate presentation host. Content presented from one only
/// reliably sees environment written *above* the presentation modifier, and
/// `@Environment(SomeStore.self)` for a store that did not make it across is a
/// `fatalError`, not a `nil` — the crash `ContentView_iOS:57-63` documents from
/// main PR #116. `SettingsSheet_iOS:35-39` is the precedent this follows: name
/// every store the subtree reads and inject it explicitly at the sheet's root.
///
/// This goes one step further than `SettingsSheet_iOS` and takes them as `let`
/// parameters rather than reading them from `@Environment` here, so the sheet's
/// own root performs no environment lookup at all and the modifier that
/// presents it is free to sit anywhere in the shell.
///
/// The list is not decoration; it is exactly what the subtree reads:
/// `WorkspaceStore` (the switcher's selection, and `AnnotationSidebar`),
/// `AppStore`/`AnnotationStore`/`AiStore`/`ScratchpadStore` (the pane triple
/// plus its app), `OpenRouterCatalog` (the AI panel's model picker), and the
/// palette/scheme/tint trio that every
/// other presentation in this app re-states.
struct PhoneInspectorSheet_iOS: View {
    /// The shell, for the one piece of state the sheet's *content* needs that
    /// the environment does not carry: which tab's ink the Handwriting section
    /// is showing. Reading it through the store (rather than recomputing it
    /// here) keeps the "no `InkRegistry_iOS` retarget" rule in the one place
    /// that can be tested without mounting a view.
    let shell: PhoneShellStore

    /// The window. Same object the shell holds; passed rather than looked up so
    /// this view has no environment dependency of its own.
    let workspace: WorkspaceStore

    /// The one pane (the phone is `.singlePane` by construction, D4). Held as
    /// the `PaneModel` rather than as four separate stores so that the sheet
    /// cannot end up injecting a triple from one pane and an `AppStore` from
    /// another.
    let pane: PaneModel

    /// Theme, for the palette/scheme/tint re-injection. Read as a store rather
    /// than as a frozen `Palette` value so switching themes in Settings repaints
    /// the sheet while it is up.
    let themeStore: ThemeStore

    /// Which detent the sheet is sitting at.
    ///
    /// A `selection:` binding exists for exactly one reason: the AI composer
    /// gaining focus while the sheet is at `.medium`. The keyboard then covers
    /// most of a half-height sheet and the transcript the user is typing about
    /// disappears behind it. Promoting to `.large` on that event keeps the
    /// conversation visible.
    ///
    /// Deliberately view `@State`, not shell state: a detent is transient
    /// presentation geometry, and re-presenting the sheet should start at
    /// `.medium` again (the half-height sheet is the one that leaves the
    /// document readable underneath it).
    @State private var detent: PresentationDetent = .medium

    var body: some View {
        SidebarContent_iOS(
            ink: ink,
            presentation: .phoneSheet,
            onTabSelected: shell.selectInspectorTab)
            .environment(workspace)
            .environment(pane.app)
            .environment(pane.annotations)
            .environment(pane.ai)
            .environment(pane.scratchpad)
            .environment(workspace.openRouterCatalog)
            .environment(\.palette, themeStore.palette)
            .preferredColorScheme(themeStore.colorScheme)
            .tint(themeStore.palette.primary)
            .accessibilityIdentifier("phone.inspector.sheet")
            .presentationDetents(Self.detents, selection: $detent)
            // The half-height sheet must not lock the document out. Reading is
            // the point of the screen underneath, and an annotation list you
            // cannot scroll the page beside is a modal dialog wearing a sheet's
            // clothes. `upThrough: .medium` keeps the reader live at half
            // height and hands interaction back to the sheet at `.large`,
            // where the document is not visible anyway.
            .presentationBackgroundInteraction(.enabled(upThrough: Self.interactiveDetent))
            // With the background interactive there is no dimmed backdrop to
            // tap away, so the grabber is the only visible affordance saying
            // "this drags and dismisses".
            .presentationDragIndicator(.visible)
            // Every panel in here scrolls (annotation rows, the AI transcript,
            // the scratchpad editor). Without this the first drag inside them
            // resizes the sheet instead of scrolling the content.
            .presentationContentInteraction(.scrolls)
            // `AiStore.composerFocusRequest` is the app-wide "the user is about
            // to type into the AI composer" signal — `AiPanel_iOS` already
            // observes the same token to take focus, and `AiStore.addReference`
            // raises it for every "Add to AI Chat" action. Promoting here (and
            // not, say, on a keyboard-height notification) means the sheet grows
            // in the same transaction the keyboard is requested rather than
            // after it, so there is one animation instead of two.
            .onChange(of: pane.ai.composerFocusRequest) { _, request in
                guard request != nil else { return }
                withAnimation(.snappy) { detent = .large }
            }
    }

    /// The ink controller the Handwriting section reads, taken straight from the
    /// live tab's runtime rather than from `InkRegistry_iOS`.
    ///
    /// The registry exists to retarget the sidebar's ink as *pane focus* moves,
    /// and the phone has one pane that can never lose focus — so going through
    /// it would add an indirection whose only job is to answer a question this
    /// shell cannot ask.
    ///
    /// `InkPagesSection_iOS` is read-only jump-to-page navigation, which is why
    /// this is here at all: iPad-made ink still has to be navigable on the
    /// phone. No ink *tools* are exposed anywhere in the phone chrome, so
    /// `isActive` is never set and `InkToolPalette_iOS` never appears.
    private var ink: InkController_iOS? { shell.inspectorInk }

    // MARK: - Geometry

    /// The detents the sheet offers. `.medium` first because it is where the
    /// sheet opens: half the screen is enough for the annotation list while
    /// leaving the page it annotates on screen.
    static let detents: Set<PresentationDetent> = [.medium, .large]

    /// The tallest detent at which the document underneath stays interactive.
    /// Named so the modifier above and any test agree on one value.
    static let interactiveDetent: PresentationDetent = .medium

    /// The width `InspectorTabSwitcher` is actually handed when this sheet is up
    /// on a screen `screenWidth` points wide.
    ///
    /// A sheet is full-width on a compact screen, and `SidebarContent_iOS` insets
    /// the switcher by `InspectorLayout.switcherHorizontalPadding` on each side.
    /// So the number the switcher's `GeometryReader` reports — the one
    /// `InspectorLayout.presentation(for:)` branches on — is the screen minus
    /// that inset, and nothing else.
    ///
    /// This exists so `PhoneInspectorTests` can assert the shared switcher
    /// resolves to `.fullLabels` here rather than silently degrading to the
    /// `.menu` fallback, which was written for a column squeezed past its own
    /// stated minimum and would read as a bug on a phone.
    static func contentWidth(at screenWidth: CGFloat) -> CGFloat {
        screenWidth - InspectorLayout.switcherHorizontalPadding * 2
    }
}
#endif
