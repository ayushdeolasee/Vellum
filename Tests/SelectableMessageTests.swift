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

        XCTAssertEqual(narrow.width, 248, accuracy: 1)
        XCTAssertEqual(wide.width, 520, accuracy: 1)
        XCTAssertLessThan(wide.height, narrow.height, "wider column should wrap onto fewer lines")
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
