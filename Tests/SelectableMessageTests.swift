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
        let attributed = AiAttributedRenderer.attributedString(
            for: "The quick brown fox jumps over the lazy dog, again and again and again.",
            color: .labelColor, secondary: .secondaryLabelColor)
        container.setAttributed(attributed, color: .labelColor, secondary: .secondaryLabelColor)
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
            color: .labelColor, secondary: .secondaryLabelColor)
        let height = container.height(forWidth: 248)
        XCTAssertTrue(height.isFinite)
        container.updateQuoteButton()
    }
}
