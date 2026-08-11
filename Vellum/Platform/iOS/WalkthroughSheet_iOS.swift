#if os(iOS)
import SwiftUI

/// The guided walkthrough (issue #49) — shown once on first launch, and on
/// demand from the Help menu, Home's "How Vellum works" link, or the Help
/// centre's Walkthrough button.
///
/// A paged sheet rather than a scrolling document: the point is to be finished
/// in under a minute, and a page break per topic makes the length honest and
/// visible instead of hiding it behind a scrollbar.
///
/// iPad deltas from main's `Views/Help/WalkthroughSheet.swift`:
///   * no `.focusable()` / `.focusEffectDisabled()` / `@FocusState` dance. That
///     exists on macOS only because Full Keyboard Access is off by default and
///     a sheet of plain Buttons has no focusable view, so `onKeyPress` would
///     never fire. iOS has no such problem, and `.focusable()` here would just
///     make the container a Full Keyboard Access stop for no benefit.
///   * `onKeyPress(.escape)` is dropped — the close button and the sheet's own
///     swipe-down dismissal cover it. Left/right arrows stay: they are the
///     Magic Keyboard path and work on iOS 17+.
///   * a horizontal drag pages the sheet, because a paged sheet on iPad that
///     cannot be swiped is simply wrong. Kept as ZStack + gesture rather than
///     `TabView(.page)` so the "size to the tallest page" trick — and the
///     layout test that depends on it — survives.
///   * the chrome bars are taller and the footer buttons a size up, because
///     44/50pt bars hold controls that must be real touch targets.
struct WalkthroughSheet_iOS: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.palette) private var palette
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.verticalSizeClass) private var verticalSizeClass

    @State private var index = 0
    /// Direction of the last page change, so the outgoing and incoming pages
    /// slide the way the user just moved. Without it, Back animates like Next.
    @State private var movingForward = true

    private let pages = WalkthroughPage.all

    // MARK: - Metrics
    //
    // The sheet's bounds and minimum chrome geometry, named once here so
    // `WalkthroughLayoutTests` can measure the real views rather than re-typing
    // layout constants. The bars have minimums, not fixed heights: accessibility
    // text is allowed to reflow and the page area scrolls in the remaining room.

    /// Maximum content width. iPad gets the intended reading column; compact
    /// phones accept their sheet's narrower proposal instead of forcing a
    /// 640-point view off both screen edges.
    static let sheetWidth: CGFloat = 640
    /// Backstop on the sheet's height. Past this the page area scrolls rather
    /// than growing — see `pageContent`.
    static let maxSheetHeight: CGFloat = 720
    /// Minimum chrome heights. Both regions may grow when Dynamic Type or a
    /// narrow phone makes their content reflow.
    static let minimumTitleBarHeight: CGFloat = 52
    static let minimumFooterHeight: CGFloat = 60
    static let controlSide: CGFloat = 44
    /// Height of each of the two rules between the chrome and the page.
    ///
    /// Pinned rather than left to `Divider()`'s intrinsic size, and this is not
    /// pedantry: on iOS a Divider is a **hairline** — 1/displayScale, so 0.5pt
    /// on a 2x iPad and 0.33pt on a 3x phone — where macOS gives a flat 1pt. A
    /// `+ 2` allowance therefore overstated the real chrome by a point, and the
    /// page area came out one point short of the tallest page. That is exactly
    /// the failure mode the explicit bar heights above exist to prevent, so the
    /// dividers get the same treatment: pinned, named, and scale-independent.
    static let dividerHeight: CGFloat = 1
    private var page: WalkthroughPage { pages[index] }
    private var isFirst: Bool { index == 0 }
    private var isLast: Bool { index == pages.count - 1 }

    var body: some View {
        VStack(spacing: 0) {
            titleBar
            Divider().frame(height: Self.dividerHeight)
            pageContent
            Divider().frame(height: Self.dividerHeight)
            footer
        }
        .frame(maxWidth: Self.sheetWidth)
        .frame(maxHeight: Self.maxSheetHeight)
        // No explicit background: take the system sheet material, like
        // StorageLocationChoiceSheet does. Painting palette.surface here made
        // this the only sheet in the app opting out of it, and in light mode it
        // read as a flat white slab pasted onto the warm parchment chrome.
        .onAppear {
            // Presented, therefore seen — see WalkthroughSettings.markSeen for
            // why this is not tied to the Done button.
            WalkthroughSettings.markSeen()
        }
        // Arrow keys page the sheet with a keyboard attached. The buttons and
        // the swipe stay the primary affordances.
        .onKeyPress(.leftArrow) {
            guard !isFirst else { return .ignored }
            go(to: index - 1)
            return .handled
        }
        .onKeyPress(.rightArrow) {
            guard !isLast else { return .ignored }
            go(to: index + 1)
            return .handled
        }
        // Horizontal swipe pages. The dominant-axis guard keeps it from
        // stealing the sheet's own vertical swipe-to-dismiss.
        .gesture(
            DragGesture(minimumDistance: 30)
                .onEnded { value in
                    guard abs(value.translation.width) > abs(value.translation.height) else {
                        return
                    }
                    if value.translation.width < 0, !isLast { go(to: index + 1) }
                    if value.translation.width > 0, !isFirst { go(to: index - 1) }
                })
        // .contain keeps each control its own AX element with its own
        // identifier — without it the container id shadows the children.
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("walkthrough.sheet")
    }

    // MARK: - Chrome

    /// Persistent identity + orientation strip. Naming the step count up front
    /// answers "how long is this?" before the user has to guess from the dots.
    private var titleBar: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 8) {
                walkthroughIdentity
                Spacer(minLength: 12)
                stepCount
                closeButton
            }

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 8) {
                    wordmark
                    Spacer(minLength: 12)
                    closeButton
                }
                HStack(spacing: 8) {
                    Text("Walkthrough")
                        .font(.subheadline)
                        .foregroundStyle(palette.mutedForeground)
                    Spacer(minLength: 12)
                    stepCount
                }
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 4)
        .frame(minHeight: Self.minimumTitleBarHeight)
        .fixedSize(horizontal: false, vertical: true)
    }

    private var walkthroughIdentity: some View {
        HStack(spacing: 8) {
            wordmark
            Text("Walkthrough")
                .font(.subheadline)
                .foregroundStyle(palette.mutedForeground)
        }
    }

    private var wordmark: some View {
        HStack(spacing: 0) {
            Text("Vellum").foregroundStyle(palette.foreground)
            Text(".").foregroundStyle(palette.primary)
        }
        .font(.headline.bold())
        .fontDesign(.serif)
        .lineLimit(1)
        .accessibilityHidden(true)
    }

    private var stepCount: some View {
        Text("\(index + 1) of \(pages.count)")
            .font(.subheadline.monospacedDigit())
            .foregroundStyle(palette.mutedForeground)
            .lineLimit(1)
    }

    /// The only dismiss affordance present on every page. Its visible glyph can
    /// scale while the interactive frame remains at least 44×44pt.
    private var closeButton: some View {
        Button("Close the walkthrough", systemImage: "xmark") { dismiss() }
            .labelStyle(.iconOnly)
            .font(.body.weight(.medium))
            .frame(minWidth: Self.controlSide, minHeight: Self.controlSide)
            .contentShape(Rectangle())
            .buttonStyle(.plain)
            .keyboardShortcut(.cancelAction)
            .accessibilityIdentifier("walkthrough.close")
    }

    @ViewBuilder
    private var pageContent: some View {
        // At normal sizes the scroll view adopts the tallest page so the sheet
        // opens at its natural compact height. Accessibility text must instead
        // accept the height offered by the phone; its content then scrolls
        // inside that bound rather than making the sheet taller than the screen.
        if dynamicTypeSize.isAccessibilitySize || verticalSizeClass == .compact {
            // Accessibility text and short landscape screens must accept the
            // offered height so the persistent title/footer remain reachable.
            walkthroughPages
        } else {
            walkthroughPages
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var walkthroughPages: some View {
        ScrollView(.vertical) {
            ZStack(alignment: .topLeading) {
                // Every page is laid out here, but only the current one is
                // drawn. The hidden copies keep the footer stable at the height
                // of the tallest page.
                ForEach(pages) { item in
                    WalkthroughPageBody(page: item)
                        .hidden()
                        .accessibilityHidden(true)
                }

                WalkthroughPageBody(page: page)
                    .id(page.id)
                    .transition(
                        .asymmetric(
                            insertion: .move(edge: movingForward ? .trailing : .leading)
                                .combined(with: .opacity),
                            removal: .move(edge: movingForward ? .leading : .trailing)
                                .combined(with: .opacity)))
            }
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .scrollBounceBehavior(.basedOnSize)
    }

    private var footer: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 12) {
                if !isLast {
                    skipButton
                }

                Spacer(minLength: 12)

                pageIndicator

                Spacer(minLength: 12)

                backButton
                nextButton
            }

            VStack(spacing: 4) {
                pageIndicator
                HStack(spacing: 12) {
                    if !isLast {
                        skipButton
                    }
                    Spacer(minLength: 12)
                    backButton
                    nextButton
                }
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 4)
        .frame(minHeight: Self.minimumFooterHeight)
        .fixedSize(horizontal: false, vertical: true)
    }

    private var skipButton: some View {
        Button("Skip") { dismiss() }
            .font(.body)
            .frame(minWidth: Self.controlSide, minHeight: Self.controlSide)
            .contentShape(Rectangle())
            .buttonStyle(.plain)
            .accessibilityIdentifier("walkthrough.skip")
    }

    private var backButton: some View {
        Button("Back") { go(to: index - 1) }
            .font(.body)
            .frame(minWidth: Self.controlSide, minHeight: Self.controlSide)
            .buttonStyle(.glass)
            .disabled(isFirst)
            .accessibilityIdentifier("walkthrough.back")
    }

    private var nextButton: some View {
        Button(isLast ? "Done" : "Next") {
            if isLast { dismiss() } else { go(to: index + 1) }
        }
        .font(.body.bold())
        .frame(minWidth: Self.controlSide, minHeight: Self.controlSide)
        .buttonStyle(.glassProminent)
        // Return advances, and finishes on the last page — the whole
        // walkthrough is reachable from a keyboard.
        .keyboardShortcut(.defaultAction)
        .accessibilityIdentifier("walkthrough.next")
    }

    /// Dots double as direct navigation — someone reopening this from the Help
    /// menu usually wants one specific page, not five presses of Next.
    private var pageIndicator: some View {
        HStack(spacing: 6) {
            ForEach(Array(pages.enumerated()), id: \.element.id) { offset, item in
                let isCurrent = offset == index
                Button { go(to: offset) } label: {
                    Capsule()
                        // Inactive dots are palette.borderStrong, not
                        // `.quaternary`. SwiftUI's quaternary fill resolves
                        // from the color scheme, not from our palette, and on
                        // the light parchment chrome it came out so faint the
                        // dots were invisible. borderStrong is defined for both
                        // schemes (#d6cdbb / #45413a), so it reads in each.
                        .fill(isCurrent ? palette.primary : palette.borderStrong)
                        .frame(width: isCurrent ? 18 : 6, height: 6)
                        .frame(width: Self.controlSide, height: Self.controlSide)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(item.title)
                .accessibilityAddTraits(isCurrent ? [.isButton, .isSelected] : .isButton)
                .accessibilityIdentifier("walkthrough.dot.\(item.id)")
            }
        }
        .animation(.spring(response: 0.3, dampingFraction: 0.8), value: index)
    }

    // MARK: - Navigation

    private func go(to target: Int) {
        guard pages.indices.contains(target), target != index else { return }
        movingForward = target > index
        withAnimation(.easeOut(duration: 0.22)) {
            index = target
        }
    }
}

/// One page's content, extracted from the sheet as a view of its own.
///
/// Not just tidiness: `WalkthroughLayoutTests` hosts this directly off-screen
/// to measure how tall a page really is. It used to re-derive that number from
/// a dozen padding/spacing/font constants copied into the test file, which
/// meant the test drifted the moment anyone touched the layout — and a
/// mirrored constant that is quietly two points wrong produces a test that
/// fails for a reason nobody can find. Measuring the real view removes the
/// mirror entirely.
struct WalkthroughPageBody: View {
    let page: WalkthroughPage

    @Environment(\.palette) private var palette

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .center, spacing: 14) {
                // Same glass tile as the home screen's hero, one size down —
                // the walkthrough should read as the same room as the app.
                Image(systemName: page.symbol)
                    .font(.title3)
                    .foregroundStyle(.tint)
                    .padding(10)
                    .frame(minWidth: 44, minHeight: 44)
                    .glassEffect(.regular, in: .rect(cornerRadius: Radius.xl))
                    .accessibilityHidden(true)

                Text(page.title)
                    .font(.title2.bold())
                    .foregroundStyle(palette.foreground)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityAddTraits(.isHeader)
            }

            Text(page.summary)
                .font(.body)
                .foregroundStyle(palette.mutedForeground)
                .fixedSize(horizontal: false, vertical: true)

            VStack(alignment: .leading, spacing: 12) {
                ForEach(page.points) { point in
                    bullet(point)
                }
            }

            if let footnote = page.footnote {
                Text(footnote)
                    .font(.footnote)
                    .foregroundStyle(palette.mutedForeground)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.horizontal, 24)
        .padding(.top, 22)
        .padding(.bottom, 20)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func bullet(_ point: WalkthroughPoint) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: point.symbol)
                .font(.body)
                .foregroundStyle(.tint)
                // Fixed gutter so every line of body text starts on the same
                // vertical, whatever each symbol's intrinsic width happens to be.
                .frame(minWidth: 24, alignment: .center)
                .accessibilityHidden(true)

            ViewThatFits(in: .horizontal) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    pointText(point)
                    if let shortcut = point.shortcut {
                        WalkthroughKeycap(keys: shortcut)
                    }
                    Spacer(minLength: 0)
                }

                VStack(alignment: .leading, spacing: 6) {
                    pointText(point)
                    if let shortcut = point.shortcut {
                        WalkthroughKeycap(keys: shortcut)
                    }
                }
            }
        }
    }

    private func pointText(_ point: WalkthroughPoint) -> some View {
        Text(point.text)
            .font(.body)
            .foregroundStyle(palette.foreground)
            .fixedSize(horizontal: false, vertical: true)
    }
}

private struct WalkthroughKeycap: View {
    let keys: String

    @Environment(\.palette) private var palette

    var body: some View {
        Text(keys)
            .font(.caption.monospaced())
            .foregroundStyle(palette.foreground)
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background(palette.muted, in: RoundedRectangle(cornerRadius: Radius.sm))
            .overlay {
                RoundedRectangle(cornerRadius: Radius.sm)
                    .strokeBorder(palette.borderStrong)
            }
            .accessibilityElement()
            .accessibilityLabel("Keyboard shortcut \(keys)")
    }
}
#endif
