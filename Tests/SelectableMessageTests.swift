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

    private static func firstSubview<T: NSView>(of type: T.Type, in root: NSView) -> T? {
        if let match = root as? T { return match }
        for subview in root.subviews {
            if let match = firstSubview(of: type, in: subview) { return match }
        }
        return nil
    }
}
