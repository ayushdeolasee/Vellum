#if os(iOS)
import SwiftUI
import UIKit

/// The shared inspector panels, docked to the phone reader's bottom and side
/// edges. Only the grabber resizes the panel, leaving each panel's scrolling
/// and the reader above a half-height inspector independent.
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
    /// The expansion state exists for the AI composer
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
    @State private var presenceID = UUID()
    @GestureState private var dragTranslation: CGFloat = 0
    @Environment(\.verticalSizeClass) private var verticalSizeClass

    var body: some View {
        GeometryReader { geometry in
            let expanded = detent != Self.interactiveDetent || verticalSizeClass == .compact
            let restingHeight = expanded
                ? geometry.size.height
                : (geometry.size.height + geometry.safeAreaInsets.bottom) / 2
            let height = min(geometry.size.height, max(120, restingHeight - dragTranslation))
            VStack(spacing: 0) {
                Spacer(minLength: 0)
                VStack(spacing: 0) {
                    grabber(expanded: expanded)
                    panels
                }
                .frame(height: height)
                .clipShape(UnevenRoundedRectangle(topLeadingRadius: 24, topTrailingRadius: 24))
                .background {
                    UnevenRoundedRectangle(topLeadingRadius: 24, topTrailingRadius: 24)
                        .fill(themeStore.palette.surface)
                        .ignoresSafeArea(.container, edges: .bottom)
                }
                .accessibilityIdentifier("phone.inspector.sheet")
                .accessibilityAddTraits(expanded ? .isModal : [])
                .accessibilityAction(.escape) { shell.setInspectorPresented(false) }
            }
            .animation(.snappy, value: detent)
        }
        .preferredColorScheme(themeStore.colorScheme)
        .tint(themeStore.palette.primary)
        .onAppear { SheetPresence_iOS.registerInspector(shell, id: presenceID) }
        .onDisappear { SheetPresence_iOS.unregisterInspector(id: presenceID) }
        .onChange(of: pane.ai.composerFocusRequest) { _, request in
            guard request != nil else { return }
            detent = .large
        }
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillShowNotification)) { _ in
            detent = .large
        }
    }

    private func grabber(expanded: Bool) -> some View {
        Button {
            if expanded { collapse() }
            else { detent = .large }
        } label: {
            Capsule()
                .fill(themeStore.palette.mutedForeground.opacity(0.5))
                .frame(width: 56, height: 4)
                .frame(maxWidth: .infinity, minHeight: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Sheet Grabber")
        .accessibilityValue(expanded ? "Expanded" : "Half screen")
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: detent = .large
            case .decrement:
                if expanded { collapse() }
                else { shell.setInspectorPresented(false) }
            @unknown default: break
            }
        }
        .gesture(
            DragGesture(minimumDistance: 10)
                .updating($dragTranslation) { value, translation, _ in
                    translation = value.translation.height
                }
                .onEnded { value in
                    let distance = value.predictedEndTranslation.height
                    if distance < -60 {
                        detent = .large
                    } else if distance > 60 {
                        if expanded { collapse() }
                        else { shell.setInspectorPresented(false) }
                    }
                })
    }

    private func collapse() {
        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
        detent = .medium
    }

    private var panels: some View {
        SidebarContent_iOS(
            ink: ink,
            presentation: .phoneSheet,
            onTabSelected: shell.selectInspectorTab)
            .environment(workspace)
            .environment(pane.app)
            .environment(pane.annotations)
            .environment(pane.ai)
            .environment(pane.scratchpad)
            .environment(workspace.openAIModelCatalog)
            .environment(workspace.openRouterCatalog)
            .environment(\.palette, themeStore.palette)
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

    /// The half-height state leaves the reader above the panel interactive.
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
