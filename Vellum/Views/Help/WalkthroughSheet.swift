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
        // Fixed WIDTH, and a height that resolves once to fit the tallest page
        // (see pageContent) rather than to a constant. The sheet still does not
        // resize as you page through — that was the original reason for pinning
        // it, and the ZStack in pageContent preserves it — but it is no longer
        // possible for copy to outgrow the number someone typed here. Shorter
        // pages carry the difference as trailing whitespace, as before.
        //
        // maxHeight is a backstop, not the layout: at very large system font
        // sizes the tallest page can exceed what a sheet should occupy, and
        // past this point pageContent scrolls instead of growing further.
        .frame(width: 620)
        .frame(maxHeight: 620)
        // No explicit background. This used to paint `palette.surface`, which
        // in the light palette is a flat #ffffff slab — the only sheet in the
        // app that opted out of the system sheet material, and it read as a
        // white rectangle pasted onto the warm parchment chrome (reported on
        // review as "the light mode is just not as pretty"). The app's other
        // sheet, StorageLocationChoiceSheet, sets no background at all and
        // takes the system material; matching it is what makes this one look
        // like it belongs, and it lets the glass tiles read against something
        // other than pure white.
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
        // Secondary Escape path, behind the title bar's `.cancelAction` close
        // button. It only fires when the container above actually holds focus,
        // which is the thing we cannot confirm without running the app — so the
        // close button is the guarantee and this is the belt. `dismiss()` twice
        // is a no-op, so the overlap is harmless.
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

            // The only dismiss affordance present on EVERY page, and the one
            // that carries Escape.
            //
            // `.cancelAction` is routed by AppKit to the sheet's cancel button
            // through the responder chain, so unlike the `.onKeyPress(.escape)`
            // below it does not depend on any view having claimed keyboard
            // focus — which matters because with Full Keyboard Access off (the
            // macOS default) a sheet of plain Buttons has no focusable view.
            // The footer's Skip button cannot own this: it is hidden on the
            // last page, which is exactly where a reader who wants out has no
            // other keyboard exit.
            IconButton(help: "Close the walkthrough", action: { dismiss() }) {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .medium))
            }
            .keyboardShortcut(.cancelAction)
            .accessibilityIdentifier("walkthrough.close")
        }
        .padding(.horizontal, 20)
        // 8pt, not 12: the 28pt icon button is now the tallest thing in the
        // row, and this keeps the bar at the same 44pt the layout test's
        // chrome constant is measured against.
        .padding(.vertical, 8)
    }

    private var pageContent: some View {
        // Scrolls, but only when the content genuinely does not fit. This area
        // used to be a fixed box with `.clipped()`, which meant a page one line
        // too tall silently lost that line — no scrollbar, no warning, nothing
        // to tell the reader there was more. A longer translation, a larger
        // system font, or one extra bullet was enough to trigger it, and the
        // Storage page was already within a few points of the edge.
        //
        // The ScrollView also does the clipping the old `.clipped()` did, so
        // the sliding page still can't paint over the chrome.
        ScrollView(.vertical) {
            ZStack(alignment: .topLeading) {
                // Every page is laid out here, but only the current one is
                // drawn. The hidden copies still take part in sizing, so this
                // ZStack adopts the height of the TALLEST page and holds it —
                // which is what keeps the footer buttons from jumping as you
                // page through, the reason the height was pinned to a constant
                // originally. Sizing to the real content instead means copy
                // edits and font changes can't outgrow the sheet.
                ForEach(pages) { item in
                    pageBody(item)
                        .hidden()
                        .accessibilityHidden(true)
                }

                pageBody(page)
                    // Re-identify on the page slug so SwiftUI treats each page
                    // as a new view and actually runs the transition, rather
                    // than cross-fading text in place.
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
        // No rubber-banding on pages that already fit, so the scroll only shows
        // itself when it is actually doing something.
        .scrollBounceBehavior(.basedOnSize)
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
                        // Inactive dots are palette.borderStrong, not
                        // `.quaternary`. SwiftUI's quaternary fill resolves
                        // from the color scheme, not from our palette, and on
                        // the light parchment chrome it came out so faint the
                        // dots were invisible — reported on review with a
                        // screenshot showing only the active pill. borderStrong
                        // is the same hairline value the rest of the app uses
                        // for "present but quiet", and it is defined for both
                        // schemes (#d6cdbb / #45413a), so it reads in each.
                        .fill(isCurrent ? palette.primary : palette.borderStrong)
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
