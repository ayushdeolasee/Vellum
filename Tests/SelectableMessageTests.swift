import SwiftUI
import UIKit
import XCTest
@testable import Vellum

// iOS-native rebuild of macOS's SelectableMessageText tests (#129 packet 5 §I.3,
// applied by packet 9 §3.4). Exercises the same layer most likely to fault: the
// attributed-markdown renderer shared by the selectable assistant bubble, plus
// the read-only UITextView's self-sizing — and, since #51/#64, the hugging
// bubble's width behaviour across the panel's whole width range.
//
// Two structural swaps run through the whole file:
//   * `MessageContainerView` (an AppKit wrapper around an NSTextView) has no
//     iPad counterpart: `SelectableTextView` IS the UITextView, and carries the
//     `attributed` / `appliedContent` / `appliedMathWidth` state main keeps on
//     the wrapper. Assertions move onto it unchanged.
//   * `NSHostingView` + `NSWindow` + `layoutSubtreeIfNeeded()` becomes
//     `UIHostingController` + `sizeThatFits(in:)` / `layoutIfNeeded()`
//     (packet 9 §4.1: off-screen is fine, no window is needed on iOS). That also
//     removes main's `onGeometryChange` + `RunLoop.run(until:)` measurement,
//     which only existed because AppKit reports geometry after the layout pass
//     commits; `sizeThatFits(in:)` answers synchronously with the size SwiftUI
//     settled on for that proposal.
//
// Main's reentrancy tests (`testHostedInWindowLaysOutWithoutReentrancyCrash`,
// `testRerenderWithDifferentMathContentUpdatesAppliedContent` mounted in an
// NSWindow) are deliberately absent: they pin AppKit's
// "-ensureLayoutForTextContainer while already performing layout" crash, which
// has no iOS analogue. The invariant they protect — that a re-render with
// different math replaces the typeset attachment — is kept below as
// `testDifferentMathContentRendersDistinctAttachments`, and the measurement is
// non-reentrant by construction here (`SelectableTextView.size(forWidth:)`
// measures on a throwaway layout manager, never the live view).
@MainActor
final class SelectableMessageTests: XCTestCase {
    private let richContent = """
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

    func testRendererProducesAttributedString() {
        let attributed = AiAttributedRenderer.attributedString(
            for: richContent, color: .label, secondary: .secondaryLabel)
        XCTAssertGreaterThan(attributed.length, 0)
    }

    func testSizeThatFitsIsFiniteForVariousWidths() {
        let view = SelectableTextView()
        view.isScrollEnabled = false
        view.textContainerInset = .zero
        view.textContainer.lineFragmentPadding = 0
        let content = "The quick brown fox jumps over the lazy dog, again and again and again."
        let attributed = AiAttributedRenderer.attributedString(
            for: content, color: .label, secondary: .secondaryLabel)
        view.setAttributed(attributed, content: content, color: .label, secondary: .secondaryLabel)
        for width in [1.0, 40.0, 80.0, 200.0, 300.0] as [CGFloat] {
            let height = view.sizeThatFits(CGSize(width: width, height: CGFloat.greatestFiniteMagnitude)).height
            XCTAssertTrue(height.isFinite, "height was not finite at width \(width): \(height)")
            XCTAssertGreaterThanOrEqual(height, 0)
        }
    }

    func testEmptyContentDoesNotCrash() {
        let view = SelectableTextView()
        view.setAttributed(
            AiAttributedRenderer.attributedString(for: "", color: .label, secondary: .secondaryLabel),
            content: "", color: .label, secondary: .secondaryLabel)
        let height = view.sizeThatFits(CGSize(width: 300, height: CGFloat.greatestFiniteMagnitude)).height
        XCTAssertTrue(height.isFinite)
        XCTAssertEqual(view.appliedContent, "")
    }

    func testSetAttributedTracksAppliedContent() {
        let view = SelectableTextView()
        let attributed = AiAttributedRenderer.attributedString(
            for: richContent, color: .label, secondary: .secondaryLabel)
        view.setAttributed(attributed, content: richContent, color: .label, secondary: .secondaryLabel)
        XCTAssertEqual(view.appliedContent, richContent)
        XCTAssertEqual(view.appliedColor, UIColor.label)
    }

    /// A change in math content must produce a distinct attributed string even
    /// though both typeset to the same U+FFFC attachment placeholder — the panel
    /// compares raw `content` (not the rendered string) to decide when to
    /// repaint, so the renderer output must actually differ (invariant #7).
    func testDifferentMathContentRendersDistinctAttachments() {
        let a = AiAttributedRenderer.attributedString(for: "$a$", color: .label, secondary: .secondaryLabel)
        let b = AiAttributedRenderer.attributedString(for: "$b$", color: .label, secondary: .secondaryLabel)
        XCTAssertGreaterThan(a.length, 0)
        XCTAssertGreaterThan(b.length, 0)
        XCTAssertFalse(
            a.isEqual(to: b),
            "re-render with a different equation must replace the typeset attachment")
    }

    // MARK: - The hugging bubble (#51 / #64)

    /// `sizeThatFits` used to clamp the bubble to a hard cap, so widening the
    /// panel — a split-view drag or a rotation on iPad — only grew the empty
    /// gutter beside a reply (#51). The ceiling now comes from `maxWidth`, which
    /// the panel derives from the live transcript width, so a wider bubble must
    /// actually be laid out wider and the same text must wrap onto fewer lines.
    func testBubbleGrowsPastTheOldFixedCapWhenGivenAWiderMaxWidth() {
        let content = String(repeating: "The quick brown fox jumps over the lazy dog. ", count: 6)
        let narrow = measureBubble(content: content, width: 248)
        let wide = measureBubble(content: content, width: 520)

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

    /// The point of hugging (#51 review): at a wide panel the cap is ~650pt, and
    /// returning the cap regardless of content painted "Yes." across the whole
    /// of it. Same cap, two lengths, wildly different bubbles.
    func testShortReplyHugsWhileALongOneStillFillsTheColumn() {
        let cap: CGFloat = 520
        let short = measureBubble(content: "Yes.", width: cap)
        let long = measureBubble(
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
            let bubble = measureBubble(content: latex, width: cap)
            let attributed = AiAttributedRenderer.attributedString(
                for: latex, color: .label, secondary: .secondaryLabel,
                mathMaxWidth: max(cap, 80))
            let equation = try XCTUnwrap(Self.firstAttachmentWidth(in: attributed))
            XCTAssertGreaterThanOrEqual(bubble.width + 1, equation, "equation clipped at cap \(cap)")
            XCTAssertLessThanOrEqual(bubble.width, cap + 1, "bubble exceeded its cap at \(cap)")
        }
    }

    /// Display math is rasterized into the attributed string against the
    /// bubble's width, so the renderer has to be told that width up front —
    /// otherwise equations stay pinned to the old 240pt cap in a wide panel.
    func testDisplayMathScalesWithTheBubbleWidth() throws {
        let latex = "$$\\int_0^\\infty e^{-x^2}\\,dx = \\frac{\\sqrt{\\pi}}{2}$$"
        let narrow = AiAttributedRenderer.attributedString(
            for: latex, color: .label, secondary: .secondaryLabel, mathMaxWidth: 40)
        let wide = AiAttributedRenderer.attributedString(
            for: latex, color: .label, secondary: .secondaryLabel, mathMaxWidth: 480)

        let narrowWidth = try XCTUnwrap(Self.firstAttachmentWidth(in: narrow), "expected typeset math")
        let wideWidth = try XCTUnwrap(Self.firstAttachmentWidth(in: wide), "expected typeset math")
        XCTAssertEqual(narrowWidth, 40, accuracy: 1, "narrow bubble must scale the equation down")
        XCTAssertGreaterThan(wideWidth, narrowWidth)
    }

    /// The width only feeds the math rasterizer, so a reply with no equations
    /// renders byte-identically at every width. A split-view drag or a rotation
    /// changes `maxWidth` on every frame for every bubble in the transcript, so
    /// if the early return in `updateUIView` doesn't hold here the drag
    /// re-parses the whole transcript's markdown once per frame. Object identity
    /// is the check: a re-render always installs a fresh NSAttributedString.
    func testWidthOnlyUpdateSkipsRerenderForAReplyWithNoMath() throws {
        let content = "A plain reply with **bold** and `code` but no equations at all."
        let host = mountedBubble(content: content, maxWidth: 248, frameWidth: 520)
        let view = try XCTUnwrap(Self.firstSubview(of: SelectableTextView.self, in: host.view))
        let before = view.attributed

        host.rootView = SelectableMessageText(
            content: content, color: .primary, secondary: .secondary,
            maxWidth: 520, onQuote: { _ in })
        Self.relayout(host)

        XCTAssertTrue(
            before === view.attributed,
            "a width-only change must not re-render a reply that has no math to rescale")
    }

    /// The counterpart: the skip above must not swallow the case it exists for.
    /// A reply that DID typeset an equation has to be re-rendered when the
    /// width changes, or the panel is left showing a stale, undersized image.
    func testWidthOnlyUpdateRerendersAReplyThatContainsMath() throws {
        let content = "The Gaussian integral: $$\\int_0^\\infty e^{-x^2}\\,dx = \\frac{\\sqrt{\\pi}}{2}$$"
        let host = mountedBubble(content: content, maxWidth: 100, frameWidth: 520)
        let view = try XCTUnwrap(Self.firstSubview(of: SelectableTextView.self, in: host.view))
        let before = view.attributed
        XCTAssertEqual(view.appliedMathWidth, 100)

        host.rootView = SelectableMessageText(
            content: content, color: .primary, secondary: .secondary,
            maxWidth: 520, onQuote: { _ in })
        Self.relayout(host)

        XCTAssertFalse(before === view.attributed, "a wider bubble must re-typeset the equation")
        XCTAssertEqual(view.appliedMathWidth, 520)
    }

    // MARK: - Helpers

    /// The size SwiftUI settles on for a bubble capped at `width`. Main reads
    /// the mounted `MessageContainerView`'s bounds after an AppKit layout pass;
    /// `sizeThatFits(in:)` is the same question asked directly, and it runs the
    /// representable's own `sizeThatFits(_:uiView:context:)` — the code under
    /// test — rather than whatever the parent stretched the view to afterwards.
    private func measureBubble(content: String, width: CGFloat) -> CGSize {
        let host = UIHostingController(rootView: SelectableMessageText(
            content: content, color: .primary, secondary: .secondary,
            maxWidth: width, onQuote: { _ in }))
        return host.sizeThatFits(in: CGSize(width: width, height: .greatestFiniteMagnitude))
    }

    /// Mount the representable and force a layout pass, so `updateUIView` runs
    /// on subsequent `rootView` swaps against the same live text view.
    ///
    /// Unlike the pure measurements above, this one needs a real (off-screen,
    /// scene-less, never-shown) `UIWindow`: SwiftUI only instantiates a
    /// `UIViewRepresentable`'s UIView once the hosting controller's view is in a
    /// window, and these two tests assert on that live view's identity.
    private func mountedBubble(
        content: String, maxWidth: CGFloat, frameWidth: CGFloat
    ) -> UIHostingController<SelectableMessageText> {
        let host = UIHostingController(rootView: SelectableMessageText(
            content: content, color: .primary, secondary: .secondary,
            maxWidth: maxWidth, onQuote: { _ in }))
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: frameWidth, height: 600))
        window.rootViewController = host
        window.isHidden = false
        windows.append(window)
        Self.relayout(host)
        return host
    }

    /// Windows created by `mountedBubble`, kept alive for the length of the test
    /// and torn down after it.
    private var windows: [UIWindow] = []

    override func tearDown() async throws {
        for window in windows {
            window.isHidden = true
            window.rootViewController = nil
        }
        windows = []
    }

    private static func relayout(_ host: UIViewController) {
        host.view.setNeedsLayout()
        host.view.layoutIfNeeded()
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

    fileprivate static func firstSubview<T: UIView>(of type: T.Type, in root: UIView) -> T? {
        if let match = root as? T { return match }
        for subview in root.subviews {
            if let match = firstSubview(of: type, in: subview) { return match }
        }
        return nil
    }
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
    /// instead of painting a tinted bar across the panel.
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
    /// its column at 160pt, so while the panel is collapsing — or any other
    /// moment SwiftUI proposes less than the last measured transcript width —
    /// the derived cap is larger than the room actually on offer. If the cap
    /// passed its own `maxWidth` down regardless, the bubble would be laid out
    /// wider than the panel and clip against the trailing edge.
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
    /// `width` points. Hosted off-screen: nothing is launched, shown or focused.
    private func measure(offered width: CGFloat, @ViewBuilder _ content: () -> some View) -> CGSize {
        UIHostingController(rootView: content())
            .sizeThatFits(in: CGSize(width: width, height: .greatestFiniteMagnitude))
    }
}

// The width the whole feature hangs off: `AiPanel_iOS` measures the transcript
// with `onGeometryChange` and derives each bubble's cap from it (#51). That
// measurement is a raw SwiftUI geometry value, so it has to survive the sizes
// SwiftUI hands back before/around a real layout pass as well as the two ends of
// the panel's 240…700pt range.
//
// `AiPanel.` → `AiPanel_iOS.` throughout: the iPad's panel is an iOS-native
// rebuild and owns these statics (packet 5 §F.4), the same rename
// `AiTranscriptFollowTests` carries.
@MainActor
final class AiPanelBubbleWidthTests: XCTestCase {
    /// No geometry pass yet (0), and the values a collapsing/animating panel can
    /// produce, all fall back to the pre-resize 272pt rather than laying a
    /// bubble out at zero — or, for an infinite column, silently switching off
    /// the equation downscaling that `mathMaxWidth` drives.
    func testDegenerateMeasurementsFallBackToTheFixedWidth() {
        for contentWidth in [0, -1, -600, .nan, .infinity, -.infinity] as [CGFloat] {
            XCTAssertEqual(
                AiPanel_iOS.bubbleMaxWidth(for: .assistant, contentWidth: contentWidth), 272,
                "degenerate content width \(contentWidth) should fall back")
        }
    }

    /// The two ends of the panel's width range, minus the transcript's 12pt
    /// insets. The narrow end is the case the feature must not make worse: a
    /// 240pt panel has to stay at least as usable as the old fixed layout.
    func testBubbleWidthsAtTheSidebarExtremes() {
        XCTAssertEqual(AiPanel_iOS.bubbleMaxWidth(for: .assistant, contentWidth: 216), 216)
        XCTAssertEqual(AiPanel_iOS.bubbleMaxWidth(for: .user, contentWidth: 216), 200)
        XCTAssertEqual(AiPanel_iOS.bubbleMaxWidth(for: .assistant, contentWidth: 676), 676)
        XCTAssertEqual(AiPanel_iOS.bubbleMaxWidth(for: .user, contentWidth: 676), 676 * 0.82, accuracy: 0.01)
    }

    /// Sweep the whole range: a bubble may never exceed the column it sits in
    /// (that would clip against the trailing edge) and the "You" column may
    /// never overtake the assistant's.
    func testBubbleNeverExceedsItsColumnAcrossTheSidebarRange() {
        for sidebar in stride(from: CGFloat(240), through: CGFloat(700), by: CGFloat(10)) {
            let column = sidebar - 24
            let assistant = AiPanel_iOS.bubbleMaxWidth(for: .assistant, contentWidth: column)
            let user = AiPanel_iOS.bubbleMaxWidth(for: .user, contentWidth: column)
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
// the panel. These pin the two together.
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

    /// The regression the merge of #64 would otherwise have shipped: offered far
    /// more room than the cap, the chips must wrap at the cap rather than
    /// running out to the full transcript width.
    func testChipsWrapAtTheCapNotTheOfferedWidth() {
        let size = measureChips(offered: 600, cap: 200)
        XCTAssertLessThanOrEqual(size.width, 201, "chips overflowed the bubble's cap")
        XCTAssertGreaterThan(
            size.height, 20, "four chips capped at 200pt should have wrapped onto several lines")
    }

    /// A chips row may never be wider than the user bubble it labels, anywhere
    /// in the panel's 240…700pt range — including the narrow end, where the old
    /// 272pt literal was WIDER than the whole user column (200pt).
    func testChipsNeverExceedTheUserBubbleAcrossTheSidebarRange() {
        for sidebar in stride(from: CGFloat(240), through: CGFloat(700), by: CGFloat(100)) {
            let cap = AiPanel_iOS.bubbleMaxWidth(for: .user, contentWidth: sidebar - 24)
            let size = measureChips(offered: sidebar, cap: cap)
            XCTAssertLessThanOrEqual(
                size.width, cap + 1,
                "chips exceeded the \(cap)pt user bubble at a \(sidebar)pt panel")
        }
    }

    private func measureChips(offered width: CGFloat, cap: CGFloat) -> CGSize {
        UIHostingController(rootView: chips(maxWidth: cap))
            .sizeThatFits(in: CGSize(width: width, height: .greatestFiniteMagnitude))
    }
}
