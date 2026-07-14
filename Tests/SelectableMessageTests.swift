import UIKit
import XCTest
@testable import Vellum

// iOS-native rebuild of macOS's SelectableMessageText tests. Exercises the same
// layer most likely to fault: the attributed-markdown renderer shared by the
// selectable assistant bubble, plus the read-only UITextView's self-sizing.
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
}
