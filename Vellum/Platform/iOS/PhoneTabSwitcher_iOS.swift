#if os(iOS)
import SwiftUI

/// Geometry for the tab switcher, in one place so the grid, the cards and the
/// bar cannot drift apart (and so a later thumbnail pass — P9 — has one aspect
/// ratio to fill rather than three opinions about it).
enum PhoneTabSwitcherLayout {
    /// Page gutter. Wider than Home's because these are objects on a shelf, not
    /// rows in a list: the whitespace is what makes two columns read as cards.
    static let gutter: CGFloat = 16

    /// Gap between the two columns, and between rows.
    static let columnGap: CGFloat = 14
    static let rowGap: CGFloat = 18

    /// Width ÷ height of a card's preview. Portrait, close to a page's 1 / √2 —
    /// the placeholder is typographic today and a page thumbnail tomorrow, and
    /// the shape should not change when that lands.
    static let previewAspect: CGFloat = 0.72

    /// Corner radius of a preview. The largest token in the scale: at 180pt
    /// wide a card wants to read as a sheet of paper, not as a table row.
    static let cardCorner: CGFloat = Radius.xxl

    /// The current card's ring, and every other card's hairline.
    static let ringWidth: CGFloat = 2.5
    static let edgeWidth: CGFloat = 1

    /// Diameter of the close affordance's visible disc. Its touch target is
    /// `PhoneChromeLayout.buttonSide` (44pt), which is deliberately larger —
    /// a 24pt disc is what looks right on a card and 44pt is what the thumb
    /// actually needs.
    static let closeDisc: CGFloat = 24

    /// Height of the opaque bottom bar, excluding the home indicator's inset.
    static let barHeight: CGFloat = 52
}

/// The Safari-style tab switcher (#153 P7).
///
/// A full-screen grid of every open document, mounted as a `.fullScreenCover`
/// over the reader. Cards are values (`PhoneTabCard`), so what the grid shows is
/// decided in `PhoneTabCardBuilder` and testable without a view.
///
/// ## Two rules this screen exists to honour
///
/// **It must not allocate.** With a phone-sized residency budget (hot 2,
/// resident 3) the switcher is the one surface that sees every tab at once, and
/// asking `WorkspaceStore.liveTabRuntime(for:)` per card would mint a runtime
/// for each of them. Residency is asked through `existingLiveTabRuntime(for:)`
/// plus `residency.isResident(tabId:)` — both pure reads.
///
/// **The bar is opaque, not glass.** Every other floating surface on the phone
/// is a glass capsule over a document, because there is a document under it
/// worth seeing. Here the thing underneath is a scrolling grid of cards, and
/// glass over it would blur the cards into the control that acts on them. So:
/// `palette.surface`, a hairline divider, and the bottom safe area filled.
struct PhoneTabSwitcher_iOS: View {
    /// The shell, for the three transitions this screen can cause: open a tab,
    /// go Home, dismiss. It owns `switcherPresented`, so the screen never
    /// dismisses itself by any other route.
    let shell: PhoneShellStore

    /// The window. Read-only here — the residency questions and nothing else.
    let workspace: WorkspaceStore

    /// The one pane's tabs (`.singlePane` by construction, D4).
    let app: AppStore

    /// Theme, re-injected below: a `.fullScreenCover` is a separate presentation
    /// host and only reliably sees environment written above the modifier that
    /// presents it. Same discipline as `PhoneInspectorSheet_iOS`.
    let themeStore: ThemeStore

    private var palette: ThemePalette { themeStore.palette }

    /// Rebuilt on every body pass, which is what keeps titles and page numbers
    /// truthful while the switcher is up (a background tab finishing its open
    /// changes its own card and nothing else — `PhoneTabCard` is `Equatable`).
    private var cards: [PhoneTabCard] {
        PhoneTabCardBuilder.cards(
            tabs: app.tabs, activeTabId: app.activeTabId, isResident: isResident)
    }

    /// Is this tab still backed by live native state?
    ///
    /// Both halves are pure reads. `existingLiveTabRuntime` never creates —
    /// that is the whole point (see `PhoneTabCardBuilder`) — and
    /// `isResident(tabId:)` is a dictionary lookup in the residency policy. A
    /// tab restored from disk but never opened in this session answers `false`
    /// here, correctly: opening it will parse a PDF.
    private func isResident(_ tabId: String) -> Bool {
        guard let runtime = workspace.existingLiveTabRuntime(for: tabId),
              !runtime.isEvicted else { return false }
        return workspace.residency.isResident(tabId: tabId)
    }

    var body: some View {
        ScrollView {
            LazyVGrid(columns: Self.columns, spacing: PhoneTabSwitcherLayout.rowGap) {
                ForEach(cards) { card in
                    PhoneTabCardView(
                        card: card,
                        palette: palette,
                        open: { open(card) },
                        close: { close(card) })
                }
            }
            .padding(.horizontal, PhoneTabSwitcherLayout.gutter)
            .padding(.top, PhoneTabSwitcherLayout.gutter)
            .padding(.bottom, PhoneTabSwitcherLayout.rowGap)
        }
        .scrollBounceBehavior(.basedOnSize)
        .overlay { if cards.isEmpty { emptyState } }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(palette.well.ignoresSafeArea())
        // The bar is an inset rather than an overlay so the last row of cards
        // can be scrolled clear of it. With an overlay, the bottom two cards
        // would sit under an opaque bar with no way to reach their close
        // buttons.
        .safeAreaInset(edge: .bottom, spacing: 0) { bottomBar }
        .environment(\.palette, palette)
        .preferredColorScheme(themeStore.colorScheme)
        .tint(palette.primary)
        .accessibilityIdentifier("phone.tabs")
    }

    private static let columns = [
        GridItem(.flexible(), spacing: PhoneTabSwitcherLayout.columnGap),
        GridItem(.flexible(), spacing: PhoneTabSwitcherLayout.columnGap),
    ]

    // MARK: - Actions

    /// Activating is synchronous and cheap for a resident tab (`applyActiveState`
    /// swaps the pane's view of the document; `LiveTabStack_iOS` re-parents the
    /// retained `PDFView`), so the dismissal can follow it in the same
    /// transaction — the reader is already showing the right document by the
    /// time the cover finishes animating away.
    private func open(_ card: PhoneTabCard) {
        app.activateTab(card.id)
        shell.showReader()
    }

    /// Closing is the async half: `AppStore.closeTab` removes the tab from the
    /// list immediately and finishes the backend teardown afterwards, so the
    /// card disappears on the tap. `didCloseTab()` is what routes Home when the
    /// last one goes — the phone has no start tab to fall back to (D1), and
    /// `showHome()` takes this cover down with it.
    private func close(_ card: PhoneTabCard) {
        Task {
            await app.closeTab(card.id)
            shell.didCloseTab()
        }
    }

    // MARK: - Chrome

    /// Count, new, done. No glass (see the type comment): `palette.surface`, a
    /// hairline top divider, and the fill carried down through the home
    /// indicator so the grid does not show through beneath the bar.
    private var bottomBar: some View {
        ZStack {
            HStack(spacing: 12) {
                Text(countLabel)
                    .font(.system(size: 13))
                    .monospacedDigit()
                    .foregroundStyle(palette.mutedForeground)
                    .accessibilityIdentifier("phone.tabs.count")
                Spacer(minLength: 8)
                Button("Done") { shell.switcherPresented = false }
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(palette.primary)
                    .frame(minWidth: PhoneChromeLayout.buttonSide,
                           minHeight: PhoneChromeLayout.buttonSide)
                    .contentShape(Rectangle())
                    .accessibilityIdentifier("phone.tabs.done")
            }

            // Centred independently of the two labels beside it, so a
            // three-digit count cannot nudge it off centre.
            Button {
                // Home, never `newStartTab()` (D1). A start tab would grow a
                // leaf in the pane tree and a fourth card here that opens
                // nothing; Home is the phone's new-document surface.
                shell.showHome()
            } label: {
                Image(systemName: "plus")
                    .font(.system(size: 20, weight: .medium))
                    .foregroundStyle(palette.primary)
                    .frame(width: PhoneChromeLayout.buttonSide,
                           height: PhoneChromeLayout.buttonSide)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Open another document")
            .accessibilityIdentifier("phone.tabs.new")
        }
        .padding(.horizontal, PhoneTabSwitcherLayout.gutter)
        .frame(height: PhoneTabSwitcherLayout.barHeight)
        .background(alignment: .top) {
            Rectangle()
                .fill(palette.border)
                .frame(height: 0.5)
        }
        .background(palette.surface.ignoresSafeArea(edges: .bottom))
    }

    private var countLabel: String {
        let count = app.tabs.count
        return count == 1 ? "1 tab" : "\(count) tabs"
    }

    /// Only reachable for a beat: `didCloseTab()` routes Home the moment the
    /// last tab goes. It exists so that beat is not a blank screen.
    private var emptyState: some View {
        Text("No open documents")
            .font(.system(size: 15))
            .foregroundStyle(palette.mutedForeground)
    }
}

/// One card: a typographic preview, the ring when it is current, a close
/// affordance, and two lines of label beneath.
///
/// The preview is deliberately text, not a screenshot. P9 may put a real
/// thumbnail behind it; until then a title set large on paper-coloured stock
/// identifies a document better than a grey rectangle would, and it costs
/// nothing for an evicted tab — which is precisely the tab a screenshot cannot
/// be produced for.
private struct PhoneTabCardView: View {
    let card: PhoneTabCard
    let palette: ThemePalette
    let open: () -> Void
    let close: () -> Void

    /// The current tab is never drawn as needing a reload. It is the document
    /// the reader is showing; `LiveTabStack_iOS.shouldRender` guarantees it is
    /// rendered whatever the policy currently thinks, and a "reloads on open"
    /// note on the tab you are looking at would simply be false.
    private var showsReloadNote: Bool { !card.isResident && !card.isCurrent }

    private var symbol: String {
        switch card.kind {
        case .web: "globe"
        case .pdf: "doc.text"
        case nil: "square.dashed"
        }
    }

    var body: some View {
        Button(action: open) {
            VStack(alignment: .leading, spacing: 8) {
                preview
                label
            }
        }
        .buttonStyle(.plain)
        // Outside the button rather than inside its label: a button nested in
        // another button's label is not reliably tappable on iOS, and this way
        // the close target sits above the card's own hit area.
        .overlay(alignment: .topTrailing) { closeButton }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("phone.tabs.card")
        .accessibilityLabel(card.title)
        .accessibilityValue(
            [card.subtitle, card.isCurrent ? "Current document" : "",
             showsReloadNote ? "Reloads on open" : ""]
                .filter { !$0.isEmpty }
                .joined(separator: ", "))
    }

    private var preview: some View {
        RoundedRectangle(cornerRadius: PhoneTabSwitcherLayout.cardCorner)
            .fill(palette.surface)
            .aspectRatio(PhoneTabSwitcherLayout.previewAspect, contentMode: .fit)
            .overlay { previewContent }
            .clipShape(RoundedRectangle(cornerRadius: PhoneTabSwitcherLayout.cardCorner))
            .overlay {
                RoundedRectangle(cornerRadius: PhoneTabSwitcherLayout.cardCorner)
                    .strokeBorder(
                        card.isCurrent ? palette.primary : palette.border,
                        lineWidth: card.isCurrent
                            ? PhoneTabSwitcherLayout.ringWidth
                            : PhoneTabSwitcherLayout.edgeWidth)
            }
            // The whole preview is tappable, including the gaps between its
            // glyph and its text.
            .contentShape(RoundedRectangle(cornerRadius: PhoneTabSwitcherLayout.cardCorner))
    }

    private var previewContent: some View {
        VStack(spacing: 10) {
            Image(systemName: symbol)
                .font(.system(size: 24, weight: .light))
                .foregroundStyle(palette.mutedForeground)

            Text(card.title)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(palette.foreground)
                .multilineTextAlignment(.center)
                .lineLimit(3)
                .truncationMode(.middle)

            if let pageLabel = card.pageLabel {
                Text(pageLabel)
                    .font(.system(size: 11))
                    .monospacedDigit()
                    .foregroundStyle(palette.mutedForeground)
            }

            if showsReloadNote {
                // An honest placeholder rather than a hidden cost: this tab's
                // native state has been released, so opening it parses the
                // document again. `LiveTabHost_iOS` shows "Restoring tab…" for
                // the moment that takes.
                Label("Reloads on open", systemImage: "arrow.clockwise")
                    .font(.system(size: 10))
                    .foregroundStyle(palette.mutedForeground)
                    .labelStyle(.titleAndIcon)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 14)
        // Dimmed as a whole, so "this one is not loaded" reads before any of
        // the text does.
        .opacity(showsReloadNote ? 0.55 : 1)
    }

    private var label: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(card.title)
                .font(.system(size: 12, weight: card.isCurrent ? .semibold : .medium))
                .foregroundStyle(palette.foreground)
                .lineLimit(1)
                .truncationMode(.middle)
            Text(card.subtitle)
                .font(.system(size: 10))
                .foregroundStyle(palette.mutedForeground)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 2)
        .accessibilityHidden(true)
    }

    /// A 24pt disc in a 44pt target. The disc is what the card's composition
    /// wants; the target is what a thumb needs, and the two are allowed to
    /// differ as long as it is the larger one that receives the touch.
    private var closeButton: some View {
        Button(action: close) {
            ZStack {
                Circle()
                    .fill(palette.surface)
                    .overlay { Circle().strokeBorder(palette.border, lineWidth: 1) }
                    .frame(
                        width: PhoneTabSwitcherLayout.closeDisc,
                        height: PhoneTabSwitcherLayout.closeDisc)
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(palette.mutedForeground)
            }
            .frame(
                width: PhoneChromeLayout.buttonSide, height: PhoneChromeLayout.buttonSide)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        // Pulled up and out so the disc straddles the card's corner rather than
        // covering the first line of its title.
        .offset(x: 10, y: -10)
        .accessibilityLabel("Close \(card.title)")
        .accessibilityIdentifier("phone.tabs.close")
    }
}
#endif
