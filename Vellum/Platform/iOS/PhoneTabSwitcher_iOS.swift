#if os(iOS)
import PDFKit
import QuickLookThumbnailing
import SwiftUI
import UIKit
import WebKit

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

    /// Width ÷ height of a card's preview. Portrait, close to a page's 1 / √2,
    /// so PDF thumbnails and webpage snapshots share one stable card shape.
    static let previewAspect: CGFloat = 0.72
    /// Accessibility layouts prioritize the readable card identity below the
    /// image. A bounded crop survives both portrait and short landscape screens.
    static let accessibilityPreviewHeight: CGFloat = 160

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

    /// Minimum height of the opaque bottom bar, excluding the home indicator's
    /// inset. It grows when Dynamic Type needs a second row.
    static let minimumBarHeight: CGFloat = 52

    static func columnCount(for dynamicTypeSize: DynamicTypeSize) -> Int {
        dynamicTypeSize.isAccessibilitySize ? 1 : 2
    }
}

/// The Safari-style tab switcher (#153 P7).
///
/// A full-screen grid of every open document, mounted as a `.fullScreenCover`
/// over the reader. Cards are values (`PhoneTabCard`), so what the grid shows is
/// decided in `PhoneTabCardBuilder` and testable without a view.
///
/// ## Two rules this screen exists to honour
///
/// **It must not allocate reader state.** With a phone-sized residency budget
/// (hot 2, resident 3) the switcher is the one surface that sees every tab at
/// once, and asking `WorkspaceStore.liveTabRuntime(for:)` per card would mint a
/// runtime for each of them. Residency is asked through
/// `existingLiveTabRuntime(for:)` plus `residency.isResident(tabId:)` — both
/// pure reads. Only visible cards allocate their bounded thumbnail bitmap.
///
/// **The bar is opaque, not glass.** Every other floating surface on the phone
/// is a glass capsule over a document, because there is a document under it
/// worth seeing. Here the thing underneath is a scrolling grid of cards, and
/// glass over it would blur the cards into the control that acts on them. So:
/// `palette.surface`, a hairline divider, and the bottom safe area filled.
struct PhoneTabSwitcher_iOS: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

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
            LazyVGrid(columns: columns, spacing: PhoneTabSwitcherLayout.rowGap) {
                ForEach(cards) { card in
                    PhoneTabCardView(
                        card: card,
                        palette: palette,
                        thumbnailRevision: thumbnailRevision(for: card),
                        loadThumbnail: { await thumbnail(for: card) },
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

    /// Two page-like cards at normal sizes; one readable card when accessibility
    /// text would otherwise crush the title and close control into half a phone.
    private var columns: [GridItem] {
        return Array(
            repeating: GridItem(.flexible(), spacing: PhoneTabSwitcherLayout.columnGap),
            count: PhoneTabSwitcherLayout.columnCount(for: dynamicTypeSize))
    }

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
                countText
                Spacer(minLength: 8)
                doneButton
            }

            // Keep the compact system-style plus at every text size. Its
            // VoiceOver label carries the full action without turning the
            // bottom bar into a multi-line panel that covers the cards.
            newDocumentButton
        }
        .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
        .padding(.horizontal, PhoneTabSwitcherLayout.gutter)
        .padding(.vertical, 4)
        .frame(minHeight: PhoneTabSwitcherLayout.minimumBarHeight)
        .background(alignment: .top) {
            Rectangle()
                .fill(palette.border)
                .frame(height: 0.5)
        }
        .background(palette.surface.ignoresSafeArea(edges: .bottom))
    }

    private var countText: some View {
        Text(countLabel)
            .font(.subheadline)
            .monospacedDigit()
            .foregroundStyle(palette.mutedForeground)
            .accessibilityIdentifier("phone.tabs.count")
    }

    private var doneButton: some View {
        Button("Done") { shell.setSwitcherPresented(false) }
            .font(.body.bold())
            .foregroundStyle(palette.primary)
            .frame(
                minWidth: PhoneChromeLayout.buttonSide,
                minHeight: PhoneChromeLayout.buttonSide)
            .contentShape(Rectangle())
            .accessibilityIdentifier("phone.tabs.done")
    }

    private var newDocumentButton: some View {
        Button {
            // Home, never `newStartTab()` (D1). A start tab would grow a
            // leaf in the pane tree and a fourth card here that opens
            // nothing; Home is the phone's new-document surface.
            shell.showHome()
        } label: {
            Image(systemName: "plus")
                .font(.title3.weight(.medium))
                .frame(
                    width: PhoneChromeLayout.buttonSide,
                    height: PhoneChromeLayout.buttonSide)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(palette.primary)
        .accessibilityLabel("Open another document")
        .accessibilityIdentifier("phone.tabs.new")
    }

    private var countLabel: String {
        let count = app.tabs.count
        return count == 1 ? "1 tab" : "\(count) tabs"
    }

    // MARK: - Thumbnails

    /// Changes when a resident reader finishes loading or a webpage navigates,
    /// causing a visible card's thumbnail task to retry with fresh content.
    private func thumbnailRevision(for card: PhoneTabCard) -> Int {
        guard let runtime = workspace.existingLiveTabRuntime(for: card.id),
              !runtime.isEvicted else { return 0 }
        switch card.kind {
        case .pdf:
            if case .loaded = runtime.pdfLoadState { return 1 }
            return 0
        case .web:
            return runtime.webController.hasWebView ? runtime.webController.initCount : 0
        case nil:
            return 0
        }
    }

    /// Prefer the exact page/view already held by a resident runtime. The
    /// side-effect-free guards are important: `existingLiveTabRuntime` never
    /// creates a runtime, and `hasWebView` is checked before touching the lazy
    /// `webView` property. A cold PDF asks Quick Look for a file thumbnail; a
    /// cold webpage keeps the lightweight URL preview because rendering it
    /// would require allocating a WKWebView and loading the page.
    private func thumbnail(for card: PhoneTabCard) async -> UIImage? {
        if let runtime = workspace.existingLiveTabRuntime(for: card.id),
           !runtime.isEvicted {
            switch card.kind {
            case .pdf:
                if case .loaded(let document) = runtime.pdfLoadState,
                   document.pageCount > 0,
                   let page = document.page(
                    at: min(max((card.previewPageNumber ?? 1) - 1, 0), document.pageCount - 1)) {
                    return page.thumbnail(
                        of: CGSize(width: 360, height: 500), for: .cropBox)
                }
            case .web:
                guard runtime.webController.hasWebView else { break }
                let webView = runtime.webController.webView
                guard webView.bounds.width >= 4, webView.bounds.height >= 4 else { break }
                let configuration = WKSnapshotConfiguration()
                configuration.rect = webView.bounds
                return try? await webView.takeSnapshot(configuration: configuration)
            case nil:
                break
            }
        }

        guard let path = card.thumbnailPath else { return nil }
        let request = QLThumbnailGenerator.Request(
            fileAt: URL(fileURLWithPath: path),
            size: CGSize(width: 360, height: 500),
            scale: 1,
            representationTypes: .thumbnail)
        return try? await QLThumbnailGenerator.shared
            .generateBestRepresentation(for: request)
            .uiImage
    }

    /// Only reachable for a beat: `didCloseTab()` routes Home the moment the
    /// last tab goes. It exists so that beat is not a blank screen.
    private var emptyState: some View {
        Text("No open documents")
            .font(.body)
            .foregroundStyle(palette.mutedForeground)
    }
}

/// One card: a lazy document thumbnail when one can be produced without
/// creating native reader state, the ring when it is current, a close
/// affordance, and an adaptive label beneath.
struct PhoneTabCardView: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    let card: PhoneTabCard
    let palette: ThemePalette
    let thumbnailRevision: Int
    let loadThumbnail: () async -> UIImage?
    let open: () -> Void
    let close: () -> Void

    @State private var thumbnail: UIImage?

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

    private var thumbnailIdentity: String {
        "\(card.id):\(card.thumbnailPath ?? card.subtitle):\(card.previewPageNumber ?? 0):\(card.isResident):\(thumbnailRevision)"
    }

    private var accessibilityTitle: String {
        [card.title, card.duplicateLabel ?? ""]
            .filter { !$0.isEmpty }
            .joined(separator: ", ")
    }

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Button(action: open) {
                VStack(alignment: .leading, spacing: 8) {
                    preview
                    label
                }
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("phone.tabs.card")
            .accessibilityLabel(accessibilityTitle)
            .accessibilityValue(
                [card.subtitle, card.isCurrent ? "Current document" : "",
                 showsReloadNote ? "Reloads on open" : ""]
                    .filter { !$0.isEmpty }
                    .joined(separator: ", "))

            // A sibling, not a Button overlay. SwiftUI folds controls inside a
            // Button's overlay into the parent's accessibility element even
            // though touch still works; sibling placement keeps Close exposed.
            closeButton
        }
        .task(id: thumbnailIdentity) {
            thumbnail = nil
            let loaded = await loadThumbnail()
            guard !Task.isCancelled else { return }
            thumbnail = loaded
        }
    }

    @ViewBuilder
    private var preview: some View {
        if dynamicTypeSize.isAccessibilitySize {
            previewSurface
                .frame(height: PhoneTabSwitcherLayout.accessibilityPreviewHeight)
        } else {
            previewSurface
                .aspectRatio(PhoneTabSwitcherLayout.previewAspect, contentMode: .fit)
        }
    }

    private var previewSurface: some View {
        RoundedRectangle(cornerRadius: PhoneTabSwitcherLayout.cardCorner)
            .fill(palette.surface)
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
            .contentShape(RoundedRectangle(cornerRadius: PhoneTabSwitcherLayout.cardCorner))
    }

    private var previewContent: some View {
        ZStack(alignment: .bottomLeading) {
            if let thumbnail {
                Image(uiImage: thumbnail)
                    .resizable()
                    .scaledToFill()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .clipped()
            } else {
                fallbackPreview
            }

            if let pageLabel = card.pageLabel {
                Text(pageLabel)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(palette.foreground)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(.regularMaterial, in: Capsule())
                    .padding(8)
            }
        }
        .accessibilityHidden(true)
    }

    /// Cold webpages intentionally stop here: creating a WKWebView to render a
    /// card would defeat tab residency. The source-shaped browser tile is still
    /// more useful than repeating the title because it foregrounds the host and
    /// path that distinguish one article from another.
    private var fallbackPreview: some View {
        VStack(spacing: 12) {
            Image(systemName: symbol)
                .font(.largeTitle.weight(.light))
                .foregroundStyle(palette.mutedForeground)

            Text(card.subtitle)
                .font(.subheadline)
                .foregroundStyle(palette.mutedForeground)
                .multilineTextAlignment(.center)
                .lineLimit(dynamicTypeSize.isAccessibilitySize ? 3 : 2)
                .truncationMode(.middle)
        }
        .padding()
    }

    private var label: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(card.title)
                .font(card.isCurrent ? .headline.bold() : .headline)
                .foregroundStyle(palette.foreground)
                .lineLimit(dynamicTypeSize.isAccessibilitySize ? 3 : 2)
                .truncationMode(.middle)
            Text(card.subtitle)
                .font(.subheadline)
                .foregroundStyle(palette.mutedForeground)
                .lineLimit(dynamicTypeSize.isAccessibilitySize ? 2 : 1)
                .truncationMode(.middle)

            if let duplicateLabel = card.duplicateLabel {
                Label(duplicateLabel, systemImage: "square.on.square")
                    .font(.caption)
                    .foregroundStyle(palette.mutedForeground)
            }

            if showsReloadNote {
                // An honest placeholder rather than a hidden cost: this tab's
                // native state has been released, so opening it parses the
                // document again. `LiveTabHost_iOS` shows "Restoring tab…" for
                // the moment that takes.
                Label("Reloads on open", systemImage: "arrow.clockwise")
                    .font(.caption)
                    .foregroundStyle(palette.mutedForeground)
            }
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
                    .font(.caption.bold())
                    .foregroundStyle(palette.mutedForeground)
            }
            .frame(
                width: PhoneChromeLayout.buttonSide, height: PhoneChromeLayout.buttonSide)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        // Keep the full 44pt target inside this card so it cannot overlap the
        // adjacent card or extend beyond the screen gutter.
        .accessibilityLabel("Close \(accessibilityTitle)")
        .accessibilityIdentifier("phone.tabs.close")
    }
}
#endif
