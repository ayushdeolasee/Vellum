import XCTest
import AppKit
import SwiftUI
@testable import Vellum

// Reproduces the "reference text → send → crash" path at the layer most likely
// to fault: the AppKit selectable-message renderer + its self-sizing.
@MainActor
final class SelectableMessageTests: XCTestCase {
    func testRendererProducesAttributedString() {
        let content = """
        # Heading

        Here is a paragraph with **bold**, *italic*, `code`, and math $d\\sin\\theta = 2\\lambda$.

        - item one
        - item two

        1. first
        2. second

        > a quote

        ```
        let x = 1
        ```
        """
        let attributed = AiAttributedRenderer.attributedString(
            for: content, color: .labelColor, secondary: .secondaryLabelColor)
        XCTAssertGreaterThan(attributed.length, 0)
    }

    func testContainerHeightIsFiniteForVariousWidths() {
        let container = MessageContainerView(frame: NSRect(x: 0, y: 0, width: 248, height: 10))
        let content = "The quick brown fox jumps over the lazy dog, again and again and again."
        let attributed = AiAttributedRenderer.attributedString(
            for: content,
            color: .labelColor, secondary: .secondaryLabelColor)
        container.setAttributed(attributed, content: content, color: .labelColor, secondary: .secondaryLabelColor)
        for width in [1.0, 40.0, 80.0, 200.0, 248.0] as [CGFloat] {
            let height = container.height(forWidth: width)
            XCTAssertTrue(height.isFinite, "height was not finite at width \(width): \(height)")
            XCTAssertGreaterThanOrEqual(height, 0)
        }
    }

    /// Mounts the representable in a real NSHostingView and forces an AppKit
    /// layout pass. This drives SwiftUI's `sizeThatFits(_:nsView:context:)` from
    /// INSIDE AppKit layout — the condition under which measuring on the live
    /// text view crashed ("-ensureLayoutForTextContainer while already
    /// performing layout"). Must not crash.
    func testHostedInWindowLaysOutWithoutReentrancyCrash() {
        let view = SelectableMessageText(
            content: "# Reply\n\nThe path difference equals **two wavelengths**: $d\\sin\\theta = 2\\lambda$.\n\n- one\n- two",
            color: .primary,
            secondary: .secondary,
            onQuote: { _ in }
        )
        let hosting = NSHostingView(rootView: view)
        hosting.frame = NSRect(x: 0, y: 0, width: 248, height: 400)

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 300, height: 500),
            styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView?.addSubview(hosting)
        hosting.layoutSubtreeIfNeeded()
        window.contentView?.layoutSubtreeIfNeeded()
        // Second pass with a different width to exercise re-measurement.
        hosting.frame = NSRect(x: 0, y: 0, width: 200, height: 400)
        hosting.layoutSubtreeIfNeeded()
        XCTAssertTrue(hosting.fittingSize.height.isFinite)
    }

    func testEmptyContentDoesNotCrash() {
        let container = MessageContainerView(frame: NSRect(x: 0, y: 0, width: 248, height: 10))
        container.setAttributed(AiAttributedRenderer.attributedString(
            for: "", color: .labelColor, secondary: .secondaryLabelColor),
            content: "", color: .labelColor, secondary: .secondaryLabelColor)
        let height = container.height(forWidth: 248)
        XCTAssertTrue(height.isFinite)
        container.updateQuoteButton()
    }

    /// The early-return in `updateNSView` compares the raw `content` input
    /// rather than the rendered output string. That distinction matters
    /// because math spans typeset to a single NSTextAttachment whose
    /// contribution to `textStorage.string` is one U+FFFC placeholder no
    /// matter what the LaTeX inside says — an output-string comparison would
    /// have called "$a$" → "$b$" a no-op and left the stale equation on
    /// screen. Drives the real SwiftUI update path (not a direct
    /// `setAttributed` call) so it exercises `updateNSView` itself.
    func testRerenderWithDifferentMathContentUpdatesAppliedContent() {
        let hosting = NSHostingView(rootView: SelectableMessageText(
            content: "$a$", color: .primary, secondary: .secondary, onQuote: { _ in }
        ))
        hosting.frame = NSRect(x: 0, y: 0, width: 248, height: 200)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 300, height: 300),
            styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView?.addSubview(hosting)
        hosting.layoutSubtreeIfNeeded()

        guard let container = Self.firstSubview(of: MessageContainerView.self, in: hosting) else {
            return XCTFail("could not locate MessageContainerView in the hosted hierarchy")
        }
        XCTAssertEqual(container.appliedContent, "$a$")
        let firstAttributed = container.attributed

        hosting.rootView = SelectableMessageText(
            content: "$b$", color: .primary, secondary: .secondary, onQuote: { _ in }
        )
        hosting.layoutSubtreeIfNeeded()

        XCTAssertEqual(container.appliedContent, "$b$")
        XCTAssertFalse(
            firstAttributed.isEqual(to: container.attributed),
            "re-render with a different equation must replace the typeset attachment"
        )
    }

    /// `sizeThatFits` used to clamp the bubble to a hard 248pt, so dragging the
    /// resizable sidebar wider only grew the empty gutter beside a reply (#51).
    /// The ceiling now comes from `maxWidth`, which the panel derives from the
    /// live transcript width — a wider bubble must actually be laid out wider,
    /// and the same text must therefore wrap onto fewer lines.
    func testBubbleGrowsPastTheOldFixedCapWhenGivenAWiderMaxWidth() throws {
        let content = String(repeating: "The quick brown fox jumps over the lazy dog. ", count: 6)
        let narrow = try measureBubble(content: content, width: 248)
        let wide = try measureBubble(content: content, width: 520)

        // Not equality with the cap: the bubble hugs, so a wrapped paragraph
        // stops at the last word that fit rather than at the cap exactly.
        XCTAssertGreaterThan(narrow.width, 248 - Self.wordBreakSlack)
        XCTAssertLessThanOrEqual(narrow.width, 248)
        XCTAssertGreaterThan(wide.width, 520 - Self.wordBreakSlack)
        XCTAssertLessThanOrEqual(wide.width, 520)
        XCTAssertLessThan(wide.height, narrow.height, "wider column should wrap onto fewer lines")
    }

    /// A hugging bubble ends at the last word that fit, so "filled the column"
    /// means "within about one word of the cap", never the cap to the point.
    private static let wordBreakSlack: CGFloat = 60

    /// The point of hugging (#51 review): at a 700pt sidebar the cap is ~650pt,
    /// and returning the cap regardless of content painted "Yes." across the
    /// whole of it. Same cap, two lengths, wildly different bubbles.
    func testShortReplyHugsWhileALongOneStillFillsTheColumn() throws {
        let cap: CGFloat = 520
        let short = try measureBubble(content: "Yes.", width: cap)
        let long = try measureBubble(
            content: String(repeating: "The quick brown fox jumps over the lazy dog. ", count: 6),
            width: cap)

        XCTAssertLessThan(short.width, 150, "a four-character reply must not span the column")
        XCTAssertGreaterThan(long.width, cap - Self.wordBreakSlack, "a long reply should still fill it")
        XCTAssertLessThanOrEqual(long.width, cap, "and must never exceed it")
    }

    /// Hugging measures the laid-out glyphs, and a typeset equation is laid out
    /// like any other glyph — so the bubble has to stay wide enough to hold it
    /// at every cap, including one narrow enough to have scaled it down.
    func testHuggingNeverClipsTypesetMath() throws {
        let latex = "$$\\int_0^\\infty e^{-x^2}\\,dx = \\frac{\\sqrt{\\pi}}{2}$$"
        for cap in [120, 520] as [CGFloat] {
            let bubble = try measureBubble(content: latex, width: cap)
            let attributed = AiAttributedRenderer.attributedString(
                for: latex, color: .labelColor, secondary: .secondaryLabelColor,
                mathMaxWidth: max(cap, 80))
            let equation = try XCTUnwrap(Self.firstAttachmentWidth(in: attributed))
            XCTAssertGreaterThanOrEqual(bubble.width + 1, equation, "equation clipped at cap \(cap)")
            XCTAssertLessThanOrEqual(bubble.width, cap + 1, "bubble exceeded its cap at \(cap)")
        }
    }

    /// Display math is rasterized into the attributed string against the
    /// bubble's width, so the renderer has to be told that width up front —
    /// otherwise equations stay pinned to the old 240pt cap in a wide sidebar.
    func testDisplayMathScalesWithTheBubbleWidth() throws {
        let latex = "$$\\int_0^\\infty e^{-x^2}\\,dx = \\frac{\\sqrt{\\pi}}{2}$$"
        let narrow = AiAttributedRenderer.attributedString(
            for: latex, color: .labelColor, secondary: .secondaryLabelColor, mathMaxWidth: 40)
        let wide = AiAttributedRenderer.attributedString(
            for: latex, color: .labelColor, secondary: .secondaryLabelColor, mathMaxWidth: 480)

        let narrowWidth = try XCTUnwrap(Self.firstAttachmentWidth(in: narrow), "expected typeset math")
        let wideWidth = try XCTUnwrap(Self.firstAttachmentWidth(in: wide), "expected typeset math")
        XCTAssertEqual(narrowWidth, 40, accuracy: 1, "narrow bubble must scale the equation down")
        XCTAssertGreaterThan(wideWidth, narrowWidth)
    }

    /// The width only feeds the math rasterizer, so a reply with no equations
    /// renders byte-identically at every width. Dragging the sidebar changes
    /// `maxWidth` on every frame for every bubble in the transcript, so if the
    /// early return in `updateNSView` doesn't hold here the drag re-parses the
    /// whole transcript's markdown once per frame. Object identity is the
    /// check: a re-render always installs a fresh NSAttributedString.
    func testWidthOnlyUpdateSkipsRerenderForAReplyWithNoMath() throws {
        let content = "A plain reply with **bold** and `code` but no equations at all."
        let hosting = try mountedBubble(content: content, maxWidth: 248, frameWidth: 520)
        let container = try XCTUnwrap(Self.firstSubview(of: MessageContainerView.self, in: hosting))
        let before = container.attributed

        hosting.rootView = SelectableMessageText(
            content: content, color: .primary, secondary: .secondary,
            maxWidth: 520, onQuote: { _ in }
        )
        hosting.layoutSubtreeIfNeeded()

        XCTAssertTrue(
            before === container.attributed,
            "a width-only change must not re-render a reply that has no math to rescale"
        )
    }

    /// The counterpart: the skip above must not swallow the case it exists for.
    /// A reply that DID typeset an equation has to be re-rendered when the
    /// width changes, or the sidebar is left showing a stale, undersized image.
    func testWidthOnlyUpdateRerendersAReplyThatContainsMath() throws {
        let content = "The Gaussian integral: $$\\int_0^\\infty e^{-x^2}\\,dx = \\frac{\\sqrt{\\pi}}{2}$$"
        let hosting = try mountedBubble(content: content, maxWidth: 100, frameWidth: 520)
        let container = try XCTUnwrap(Self.firstSubview(of: MessageContainerView.self, in: hosting))
        let before = container.attributed
        XCTAssertEqual(container.appliedMathWidth, 100)

        hosting.rootView = SelectableMessageText(
            content: content, color: .primary, secondary: .secondary,
            maxWidth: 520, onQuote: { _ in }
        )
        hosting.layoutSubtreeIfNeeded()

        XCTAssertFalse(before === container.attributed, "a wider bubble must re-typeset the equation")
        XCTAssertEqual(container.appliedMathWidth, 520)
    }

    /// Mount the representable and force a layout pass, leaving it hosted in a
    /// window so `updateNSView` runs on subsequent `rootView` swaps.
    private func mountedBubble(
        content: String, maxWidth: CGFloat, frameWidth: CGFloat
    ) throws -> NSHostingView<SelectableMessageText> {
        let hosting = NSHostingView(rootView: SelectableMessageText(
            content: content, color: .primary, secondary: .secondary,
            maxWidth: maxWidth, onQuote: { _ in }
        ))
        hosting.frame = NSRect(x: 0, y: 0, width: frameWidth, height: 600)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: frameWidth + 40, height: 700),
            styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView?.addSubview(hosting)
        hosting.layoutSubtreeIfNeeded()
        return hosting
    }

    /// Mount the representable at `width` and report the size AppKit actually
    /// gave the text container.
    private func measureBubble(content: String, width: CGFloat) throws -> CGSize {
        let hosting = NSHostingView(rootView: SelectableMessageText(
            content: content, color: .primary, secondary: .secondary,
            maxWidth: width, onQuote: { _ in }
        ))
        hosting.frame = NSRect(x: 0, y: 0, width: width, height: 600)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: width + 40, height: 700),
            styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView?.addSubview(hosting)
        hosting.layoutSubtreeIfNeeded()
        let container = try XCTUnwrap(
            Self.firstSubview(of: MessageContainerView.self, in: hosting),
            "could not locate MessageContainerView in the hosted hierarchy")
        return container.bounds.size
    }

    private static func firstAttachmentWidth(in attributed: NSAttributedString) -> CGFloat? {
        var found: CGFloat?
        attributed.enumerateAttribute(
            .attachment, in: NSRange(location: 0, length: attributed.length)
        ) { value, _, stop in
            if let attachment = value as? NSTextAttachment {
                found = attachment.bounds.width
                stop.pointee = true
            }
        }
        return found
    }

    private static func firstSubview<T: NSView>(of type: T.Type, in root: NSView) -> T? {
        if let match = root as? T { return match }
        for subview in root.subviews {
            if let match = firstSubview(of: type, in: subview) { return match }
        }
        return nil
    }
}

/// Captures a size out of a SwiftUI geometry callback.
private final class SizeBox {
    var size: CGSize = .zero
}

// The SwiftUI half of the hugging bubble. `MarkdownMessage` renders user
// messages in the AI panel AND the three fixed-width surfaces (sticky notes,
// the annotation sidebar, web note popovers), so its filling behaviour had to
// become opt-out rather than change for everyone — these pin both sides of that.
@MainActor
final class MarkdownMessageWidthTests: XCTestCase {
    /// None of the three fixed-width hosts passes `fillsAvailableWidth`, and
    /// all three left-align text inside a card that decides its own width. The
    /// default therefore has to keep stretching exactly as it did before.
    func testDefaultStillFillsTheOfferedWidth() {
        let size = measure(offered: 400) {
            MarkdownMessage(content: "Hi", textColor: .primary)
        }
        XCTAssertEqual(size.width, 400, accuracy: 1, "the fixed-width callers depend on this")
    }

    /// The AI panel's user bubbles opt out, so a short message stops at its text
    /// instead of painting a tinted bar across the sidebar.
    func testOptingOutHugsTheContent() {
        let size = measure(offered: 400) {
            MarkdownMessage(content: "Hi", textColor: .primary, fillsAvailableWidth: false)
        }
        XCTAssertGreaterThan(size.width, 0)
        XCTAssertLessThan(size.width, 100, "a two-letter message must not span the bubble")
    }

    /// Hugging must not turn into "never wrap": long content still has to break
    /// at the width it was offered.
    func testOptingOutStillWrapsAtTheOfferedWidth() {
        let size = measure(offered: 400) {
            MarkdownMessage(
                content: String(repeating: "wrap me please ", count: 20),
                textColor: .primary, fillsAvailableWidth: false)
        }
        XCTAssertGreaterThan(size.width, 300, "long content should reach the offered width")
        XCTAssertLessThanOrEqual(size.width, 401, "and must not overflow it")
    }

    /// `BubbleWidthCap` exists because `.frame(maxWidth:)` is greedy — a
    /// flexible frame reports the whole clamped proposal, which is what made
    /// every bubble a full-column slab. The cap must bound long content without
    /// stretching short content.
    func testBubbleWidthCapLimitsWithoutStretching() {
        let long = measure(offered: 600) {
            BubbleWidthCap(maxWidth: 300) {
                MarkdownMessage(
                    content: String(repeating: "wrap me please ", count: 20),
                    textColor: .primary, fillsAvailableWidth: false)
            }
        }
        XCTAssertLessThanOrEqual(long.width, 301, "cap not honoured")
        XCTAssertGreaterThan(long.width, 200, "long content should reach the cap")

        let short = measure(offered: 600) {
            BubbleWidthCap(maxWidth: 300) {
                MarkdownMessage(content: "Hi", textColor: .primary, fillsAvailableWidth: false)
            }
        }
        XCTAssertLessThan(short.width, 100, "the cap must not stretch short content")
    }

    /// The other half of the cap, which the test above cannot reach because it
    /// only ever offers MORE room than the cap: when the proposal is NARROWER
    /// than `maxWidth`, the proposal has to win.
    ///
    /// This is reachable in the panel, not theoretical. `bubbleMaxWidth` floors
    /// its column at 160pt, so while the inspector is collapsing — or any other
    /// moment SwiftUI proposes less than the last measured transcript width —
    /// the derived cap is larger than the room actually on offer. If the cap
    /// passed its own `maxWidth` down regardless, the bubble would be laid out
    /// wider than the sidebar and clip against the trailing edge.
    ///
    /// Verified to bite: with `cap(for:)` mutated to `return maxWidth`, this
    /// fails (measures ~300 against a 200pt offer) and every other layout test
    /// still passes.
    func testBubbleWidthCapNeverExceedsANarrowerProposal() {
        let narrow = measure(offered: 200) {
            BubbleWidthCap(maxWidth: 300) {
                MarkdownMessage(
                    content: String(repeating: "wrap me please ", count: 20),
                    textColor: .primary, fillsAvailableWidth: false)
            }
        }
        XCTAssertLessThanOrEqual(
            narrow.width, 201,
            "a cap wider than the offered room must not widen the bubble past it")
        XCTAssertGreaterThan(narrow.width, 100, "long content should still reach the offer")
    }

    /// Size SwiftUI actually settles on for `content` when it is offered
    /// `width` points. Hosted in an off-screen window that is never ordered on
    /// screen, so nothing is launched, shown or focused.
    private func measure(offered width: CGFloat, @ViewBuilder _ content: () -> some View) -> CGSize {
        let box = SizeBox()
        let hosting = NSHostingView(
            rootView: content()
                .onGeometryChange(for: CGSize.self) { $0.size } action: { box.size = $0 }
        )
        hosting.frame = NSRect(x: 0, y: 0, width: width, height: 400)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: width + 40, height: 500),
            styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView?.addSubview(hosting)
        hosting.layoutSubtreeIfNeeded()
        // The geometry callback lands after the layout pass commits.
        RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        return box.size
    }
}

// The width the whole feature hangs off: `AiPanel` measures the transcript with
// `onGeometryChange` and derives each bubble's cap from it (#51). That
// measurement is a raw SwiftUI geometry value, so it has to survive the sizes
// SwiftUI hands back before/around a real layout pass as well as the two ends
// of the sidebar's 240…700pt range.
@MainActor
final class AiPanelBubbleWidthTests: XCTestCase {
    /// No geometry pass yet (0), and the values a collapsing/animating
    /// inspector can produce, all fall back to the pre-resize 272pt rather than
    /// laying a bubble out at zero — or, for an infinite column, silently
    /// switching off the equation downscaling that `mathMaxWidth` drives.
    func testDegenerateMeasurementsFallBackToTheFixedWidth() {
        for contentWidth in [0, -1, -600, .nan, .infinity, -.infinity] as [CGFloat] {
            XCTAssertEqual(
                AiPanel.bubbleMaxWidth(for: .assistant, contentWidth: contentWidth), 272,
                "degenerate content width \(contentWidth) should fall back"
            )
        }
    }

    /// The two ends of the resizable inspector, minus the transcript's 12pt
    /// insets. The narrow end is the case the feature must not make worse: a
    /// 240pt sidebar has to stay at least as usable as the old fixed layout.
    func testBubbleWidthsAtTheSidebarExtremes() {
        XCTAssertEqual(AiPanel.bubbleMaxWidth(for: .assistant, contentWidth: 216), 216)
        XCTAssertEqual(AiPanel.bubbleMaxWidth(for: .user, contentWidth: 216), 200)
        XCTAssertEqual(AiPanel.bubbleMaxWidth(for: .assistant, contentWidth: 676), 676)
        XCTAssertEqual(AiPanel.bubbleMaxWidth(for: .user, contentWidth: 676), 676 * 0.82, accuracy: 0.01)
    }

    /// Sweep the whole range: a bubble may never exceed the column it sits in
    /// (that would clip against the trailing edge) and the "You" column may
    /// never overtake the assistant's.
    func testBubbleNeverExceedsItsColumnAcrossTheSidebarRange() {
        for sidebar in stride(from: CGFloat(240), through: CGFloat(700), by: CGFloat(10)) {
            let column = sidebar - 24
            let assistant = AiPanel.bubbleMaxWidth(for: .assistant, contentWidth: column)
            let user = AiPanel.bubbleMaxWidth(for: .user, contentWidth: column)
            XCTAssertEqual(assistant, column, "assistant should take the full column at \(sidebar)pt")
            XCTAssertGreaterThan(user, 0, "user bubble collapsed at \(sidebar)pt")
            XCTAssertLessThanOrEqual(user, assistant, "user bubble overflowed the column at \(sidebar)pt")
        }
    }
}

// The sent-reference chips (#58) render as a sibling ABOVE the user bubble in
// `messageRow`, so nothing about the bubble's own layout constrains them. They
// used to carry a hardcoded `.frame(maxWidth: 272)` — correct while the bubble
// was a fixed 272pt, silently wrong once #64 made `bubbleMaxWidth` scale with
// the resizable sidebar. These pin the two together.
@MainActor
final class SentReferenceChipsWidthTests: XCTestCase {
    /// Four mixed-width chips, enough to force a wrap at any realistic cap.
    private var references: [AiReference] {
        let snapshot = AiPageImageSnapshot(
            pageNumber: 2, base64Data: "", mediaType: "image/jpeg", width: 1280, height: 1656)
        return [
            AiReference(kind: .selection(
                text: "Chlorophyll a absorbs light most strongly in the blue and red bands "
                    + "of the visible spectrum.", page: 2)),
            AiReference(kind: .highlight(text: "Calvin cycle", page: 3)),
            AiReference(kind: .pageSnapshot(image: snapshot, page: 2)),
            AiReference(kind: .image(image: snapshot, name: "absorption-spectrum.png")),
        ]
    }

    private func chips(maxWidth: CGFloat) -> some View {
        SentReferenceChips(
            references: references,
            onGoToPage: { _ in },
            previewData: { _ in nil },
            maxWidth: maxWidth
        )
        .environment(\.palette, .dark)
    }

    /// The regression the merge of #64 into this branch would otherwise have
    /// shipped: offered far more room than the cap, the chips must wrap at the
    /// cap rather than running out to the full transcript width.
    ///
    /// Verified to bite: restoring the old hardcoded `.frame(maxWidth: 272)`
    /// fails this (measures ~272 against a 200pt cap).
    func testChipsWrapAtTheCapNotTheOfferedWidth() {
        let size = measureChips(offered: 600, cap: 200)
        XCTAssertLessThanOrEqual(
            size.width, 201, "chips overflowed the bubble's cap")
        XCTAssertGreaterThan(
            size.height, 20, "four chips capped at 200pt should have wrapped onto several lines")
    }

    /// A chips row may never be wider than the user bubble it labels, anywhere
    /// in the sidebar's 240…700pt range — including the narrow end, where the
    /// old 272pt literal was WIDER than the whole user column (200pt).
    func testChipsNeverExceedTheUserBubbleAcrossTheSidebarRange() {
        for sidebar in stride(from: CGFloat(240), through: CGFloat(700), by: CGFloat(100)) {
            let cap = AiPanel.bubbleMaxWidth(for: .user, contentWidth: sidebar - 24)
            let size = measureChips(offered: sidebar, cap: cap)
            XCTAssertLessThanOrEqual(
                size.width, cap + 1,
                "chips exceeded the \(cap)pt user bubble at a \(sidebar)pt sidebar")
        }
    }

    private func measureChips(offered width: CGFloat, cap: CGFloat) -> CGSize {
        let box = SizeBox()
        let hosting = NSHostingView(
            rootView: chips(maxWidth: cap)
                .onGeometryChange(for: CGSize.self) { $0.size } action: { box.size = $0 }
        )
        hosting.frame = NSRect(x: 0, y: 0, width: width, height: 400)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: width + 40, height: 500),
            styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView?.addSubview(hosting)
        hosting.layoutSubtreeIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        return box.size
    }
}
