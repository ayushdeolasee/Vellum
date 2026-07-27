import SwiftUI

/// The guided walkthrough (issue #49) — shown once on first launch, and on
/// demand from Help ▸ Vellum Walkthrough or the welcome screen.
///
/// A paged sheet rather than a scrolling document: the point is to be finished
/// in under a minute, and a page break per topic makes the length honest and
/// visible instead of hiding it behind a scrollbar.
struct WalkthroughSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.palette) private var palette

    @State private var index = 0
    /// Direction of the last page change, so the outgoing and incoming pages
    /// slide the way the user just moved. Without it, Back animates like Next.
    @State private var movingForward = true
    /// Parks keyboard focus on the sheet itself. `onKeyPress` only fires for the
    /// focused view or one of its ancestors, and with Full Keyboard Access off
    /// (the macOS default) a sheet of plain Buttons has NO focusable view at
    /// all — the focused element stays the window, so every key press below is
    /// dropped. Making the container focusable and claiming focus on appear is
    /// what actually wires the keyboard up.
    @FocusState private var keyboardFocused: Bool

    private let pages = WalkthroughPage.all

    private var page: WalkthroughPage { pages[index] }
    private var isFirst: Bool { index == 0 }
    private var isLast: Bool { index == pages.count - 1 }

    var body: some View {
        VStack(spacing: 0) {
            titleBar
            Divider()
            pageContent
            Divider()
            footer
        }
        // Fixed size on purpose. A sheet that resizes to each page's content
        // jumps under the cursor every time Next is pressed, which makes the
        // buttons feel like they move away from you. The height is measured
        // against the longest page (Storage — four bullets, two of them
        // wrapping, plus the footnote) with a little slack; shorter pages carry
        // the difference as trailing whitespace, which is the cheaper tradeoff.
        .frame(width: 620, height: 460)
        .background(palette.surface)
        // Focusable, but with no focus ring: the sheet is claiming focus to
        // receive key presses, not to advertise itself as a control.
        .focusable()
        .focusEffectDisabled()
        .focused($keyboardFocused)
        .onAppear {
            // Presented, therefore seen — see WalkthroughSettings.markSeen for
            // why this is not tied to the Done button.
            WalkthroughSettings.markSeen()
            keyboardFocused = true
        }
        // Arrow keys page the sheet. The buttons stay the primary affordance;
        // this just makes the sheet behave the way a paged sheet should.
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
        // Escape closes the sheet. Nothing else provides this: Skip is hidden
        // on the last page, and a SwiftUI sheet with no `.cancelAction` button
        // does not dismiss on Escape by itself — so without this the only way
        // out of the final page is the mouse.
        .onKeyPress(.escape) {
            dismiss()
            return .handled
        }
        // .contain keeps each control its own AX element with its own
        // identifier — without it the container id shadows the children (same
        // gotcha as StorageLocationChoiceSheet's option cards).
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("walkthrough.sheet")
    }

    // MARK: - Chrome

    /// Persistent identity + orientation strip. Naming the step count up front
    /// answers "how long is this?" before the user has to guess from the dots.
    private var titleBar: some View {
        HStack(spacing: 8) {
            Wordmark(size: 14)
            Text("Walkthrough")
                .font(.system(size: 12))
                .foregroundStyle(palette.mutedForeground)

            Spacer(minLength: 12)

            Text("\(index + 1) of \(pages.count)")
                .font(.system(size: 11).monospacedDigit())
                .foregroundStyle(palette.mutedForeground)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
    }

    private var pageContent: some View {
        VStack(alignment: .leading, spacing: 0) {
            pageBody(page)
                // Re-identify on the page slug so SwiftUI treats each page as a
                // new view and actually runs the transition, rather than
                // cross-fading text in place.
                .id(page.id)
                .transition(
                    .asymmetric(
                        insertion: .move(edge: movingForward ? .trailing : .leading)
                            .combined(with: .opacity),
                        removal: .move(edge: movingForward ? .leading : .trailing)
                            .combined(with: .opacity)))

            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        // Clip the slide so the outgoing page doesn't paint over the chrome.
        .clipped()
    }

    private func pageBody(_ page: WalkthroughPage) -> some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .center, spacing: 14) {
                // Same glass tile as the welcome screen's hero, one size down —
                // the walkthrough should read as the same room as the app.
                Image(systemName: page.symbol)
                    .font(.system(size: 20, weight: .regular))
                    .foregroundStyle(.tint)
                    .frame(width: 44, height: 44)
                    .glassEffect(.regular, in: .rect(cornerRadius: Radius.xl))
                    .accessibilityHidden(true)

                Text(page.title)
                    .font(.system(size: 21, weight: .semibold))
                    .foregroundStyle(palette.foreground)
                    .accessibilityAddTraits(.isHeader)
            }

            Text(page.summary)
                .font(.system(size: 13))
                .foregroundStyle(palette.mutedForeground)
                .fixedSize(horizontal: false, vertical: true)
                .lineSpacing(2)

            VStack(alignment: .leading, spacing: 12) {
                ForEach(page.points) { point in
                    bullet(point)
                }
            }

            if let footnote = page.footnote {
                Text(footnote)
                    .font(.system(size: 12))
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
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Image(systemName: point.symbol)
                .font(.system(size: 13))
                .foregroundStyle(.tint)
                // Fixed gutter so every line of body text starts on the same
                // vertical, whatever each symbol's intrinsic width happens to be.
                .frame(width: 18, alignment: .center)
                .accessibilityHidden(true)

            // Text and keycap share a line and wrap together, so a trailing
            // shortcut sits at the end of the sentence rather than pinned to
            // the far right of the sheet where it reads as a separate column.
            Text(point.text)
                .font(.system(size: 13))
                .foregroundStyle(palette.foreground)
                .fixedSize(horizontal: false, vertical: true)
                .lineSpacing(2)

            if let shortcut = point.shortcut {
                Keycap(keys: shortcut)
            }

            Spacer(minLength: 0)
        }
    }

    private var footer: some View {
        HStack(spacing: 12) {
            if !isLast {
                TextButton(variant: .ghost, size: .sm) { dismiss() } label: {
                    Text("Skip")
                }
                .accessibilityIdentifier("walkthrough.skip")
            }

            Spacer(minLength: 12)

            pageIndicator

            Spacer(minLength: 12)

            TextButton(variant: .secondary, size: .sm, disabled: isFirst) {
                go(to: index - 1)
            } label: {
                Text("Back")
            }
            .accessibilityIdentifier("walkthrough.back")

            TextButton(variant: .primary, size: .sm) {
                if isLast { dismiss() } else { go(to: index + 1) }
            } label: {
                Text(isLast ? "Done" : "Next")
            }
            // Return advances, and finishes on the last page — the whole
            // walkthrough is reachable without touching the mouse.
            .keyboardShortcut(.defaultAction)
            .accessibilityIdentifier("walkthrough.next")
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
    }

    /// Dots double as direct navigation — someone reopening this from the Help
    /// menu usually wants one specific page, not five presses of Next.
    private var pageIndicator: some View {
        HStack(spacing: 6) {
            ForEach(Array(pages.enumerated()), id: \.element.id) { offset, item in
                let isCurrent = offset == index
                Button { go(to: offset) } label: {
                    Capsule()
                        .fill(
                            isCurrent
                                ? AnyShapeStyle(palette.primary)
                                : AnyShapeStyle(.quaternary))
                        .frame(width: isCurrent ? 18 : 6, height: 6)
                        .contentShape(Capsule().inset(by: -6))
                }
                .buttonStyle(.plain)
                .help(item.title)
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

#Preview("Walkthrough") {
    WalkthroughSheet()
        .environment(\.palette, .light)
        .tint(ThemePalette.light.primary)
}

#Preview("Walkthrough (dark)") {
    WalkthroughSheet()
        .environment(\.palette, .dark)
        .preferredColorScheme(.dark)
        .tint(ThemePalette.dark.primary)
}
