import XCTest
import AppKit
import SwiftUI
@testable import Vellum

/// Regression coverage for the AI-reply rendering defects in issue #57:
/// literal `**` and `---` leaking into rendered replies, and the large dead
/// space under long assistant bubbles.
///
/// `Self.sample` is the reply pasted into the issue, verbatim. It is the
/// fixture precisely because it is real model output: it mixes emphasis that
/// straddles inline math, thematic breaks, blockquotes, lists, and five display
/// equations — every construct that was rendering wrong.
@MainActor
final class AiMarkdownRenderingTests: XCTestCase {

    static let sample = #"""
        ## What that sentence means

        The author is contrasting **generative models** and **discriminative models**.

        ### 1. Discriminative model: learns $P(Y \mid X)$

        A **discriminative model** answers:

        > “Given the input $X$, what is the likely label/output $Y$?”

        Mathematically:

        $$
        P(Y \mid X)
        $$

        means **the probability of $Y$ given $X$**.

        Example: image classification.

        - $X$ = an image
        - $Y$ = the label, like “cat” or “dog”

        A discriminative model learns:

        $$
        P(\text{cat} \mid \text{image})
        $$

        So it only cares about predicting the label from the input.

        Examples include many classifiers, such as logistic regression, standard neural networks, and many Transformer classifiers.

        ---

        ### 2. Generative model: learns $P(X, Y)$

        A **generative model** tries to model the full joint distribution:

        $$
        P(X, Y)
        $$

        This means it learns how inputs and labels occur **together**.

        In other words, it tries to understand the data-generating process itself.

        Example:

        - What do cat images look like?
        - What do dog images look like?
        - How are images and labels related?

        Because it learns the data distribution more broadly, it can often **generate new samples**.

        For example, a generative model might create a new cat image after learning what cat images tend to look like.

        ---

        ## Simple analogy

        Suppose you are learning about animals.

        A **discriminative model** learns:

        > “Given this animal photo, is it a cat or a dog?”

        A **generative model** learns:

        > “What do cats and dogs look like, and how could I produce a realistic example of one?”

        So:

        - **Discriminative**: classify existing data.
        - **Generative**: understand and potentially create data.

        ---

        ## Why this matters for autoregressive models

        Autoregressive models generate data step by step.

        For a sequence:

        $$
        x_1, x_2, x_3, \dots
        $$

        they predict the next item from the previous ones:

        $$
        P(x_{t} \mid x_1, x_2, \dots, x_{t-1})
        $$

        Then they can use that prediction to generate the next value, then the next, and so on.

        That is why the author says autoregressive models are **generative**: they can create new sequences after learning patterns from old ones.
        """#

    // MARK: - The fixture itself

    /// Guards the fixture, not the parser. `sample` is a multi-line literal, so
    /// if its indentation ever drifts from the closing delimiter every line
    /// keeps a leading space run — headings and `$$` blocks silently stop
    /// parsing, and the tests below start passing vacuously against a sample
    /// that no longer contains what they are checking. That happened once while
    /// these were being written; this is the tripwire.
    func testSampleFixtureParsesIntoTheExpectedBlockKinds() {
        XCTAssertFalse(Self.sample.hasPrefix(" "), "the fixture picked up literal leading indentation")
        let blocks = MarkdownParser.parse(Self.sample)
        XCTAssertEqual(blocks.count(where: Self.isHeading), 5, "expected the sample's 5 headings")
        XCTAssertEqual(blocks.count(where: Self.isMath), 5, "expected the sample's 5 display equations")
        XCTAssertEqual(blocks.count(where: { $0 == .rule }), 3, "expected the sample's 3 thematic breaks")
        XCTAssertEqual(blocks.count(where: Self.isQuote), 3, "expected the sample's 3 blockquotes")
        XCTAssertEqual(blocks.count(where: Self.isUnordered), 3, "expected the sample's 3 bullet lists")
    }

    private static func isHeading(_ block: MarkdownBlock) -> Bool {
        if case .heading = block { return true }
        return false
    }

    private static func isMath(_ block: MarkdownBlock) -> Bool {
        if case .math = block { return true }
        return false
    }

    private static func isQuote(_ block: MarkdownBlock) -> Bool {
        if case .quote = block { return true }
        return false
    }

    private static func isUnordered(_ block: MarkdownBlock) -> Bool {
        if case .unordered = block { return true }
        return false
    }

    // MARK: - Inline emphasis across math spans

    /// The headline symptom. `MathRenderer.segments` cuts this line into
    /// "**the probability of ", math, " given ", math, "**", and parsing those
    /// fragments separately leaves every asterisk literal because none of them
    /// balances on its own.
    func testStrongEmphasisSurvivingMathSpansIsNotLiteral() {
        let pieces = InlineMarkdown.pieces(in: "means **the probability of $Y$ given $X$**.")
        let prose = Self.proseRuns(pieces)

        XCTAssertFalse(
            prose.contains { $0.text.contains("*") },
            "asterisks leaked into the rendered text: \(prose.map(\.text))")
        XCTAssertTrue(
            prose.contains { $0.text.contains("the probability of") && $0.isBold },
            "text before the first equation lost its bold: \(prose)")
        XCTAssertTrue(
            prose.contains { $0.text.contains("given") && $0.isBold },
            "text between the two equations lost its bold: \(prose)")
        XCTAssertEqual(Self.mathRuns(pieces), ["Y", "X"], "the equations must survive intact")
    }

    /// Pins the premise behind `InlineMarkdown` parsing the whole line at once.
    /// This is what the renderers used to do — hand Foundation one math-split
    /// fragment at a time — and it is why the asterisks showed up on screen: an
    /// unbalanced fragment simply is not emphasis, so the markers stay literal.
    /// If this ever stops holding, the placeholder machinery is dead weight.
    func testAMathSplitFragmentParsedAloneKeepsItsLiteralAsterisks() {
        let fragment = try? AttributedString(
            markdown: "**the probability of ",
            options: AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace))
        XCTAssertEqual(
            fragment.map { String($0.characters) }, "**the probability of ",
            "an unbalanced fragment should keep its literal markers")
    }

    /// Emphasis that does NOT cross a math span must keep working, and math
    /// outside it must stay unstyled.
    func testEmphasisOutsideMathIsUnaffected() {
        let pieces = InlineMarkdown.pieces(in: "A **discriminative model** learns $P(Y)$ well.")
        let prose = Self.proseRuns(pieces)
        XCTAssertTrue(prose.contains { $0.text == "discriminative model" && $0.isBold })
        XCTAssertTrue(prose.contains { $0.text.contains("well") && !$0.isBold })
        XCTAssertEqual(Self.mathRuns(pieces), ["P(Y)"])
    }

    func testItalicAcrossMathSpanIsNotLiteral() {
        let pieces = InlineMarkdown.pieces(in: "*before $x$ after*")
        let prose = Self.proseRuns(pieces)
        XCTAssertFalse(prose.contains { $0.text.contains("*") }, "literal asterisk survived: \(prose)")
        XCTAssertTrue(prose.allSatisfy(\.isItalic), "emphasis did not span the equation: \(prose)")
    }

    /// A line with no math at all still parses as one markdown run.
    func testPlainEmphasisWithoutMath() {
        let prose = Self.proseRuns(InlineMarkdown.pieces(in: "plain **bold** text"))
        XCTAssertTrue(prose.contains { $0.text == "bold" && $0.isBold })
        XCTAssertFalse(prose.contains { $0.text.contains("*") })
    }

    /// Currency must not be mistaken for math, and must not be emphasized.
    func testCurrencyIsNotTreatedAsMath() {
        let pieces = InlineMarkdown.pieces(in: "it costs $5 and $10 today")
        XCTAssertTrue(Self.mathRuns(pieces).isEmpty, "currency was parsed as math: \(Self.mathRuns(pieces))")
    }

    /// Nothing in the issue's whole sample reply may reach the screen with
    /// literal emphasis markers still in it.
    func testSampleReplyRendersNoLiteralEmphasisMarkers() {
        for block in MarkdownParser.parse(Self.sample) {
            for source in Self.inlineSources(of: block) {
                let prose = Self.proseRuns(InlineMarkdown.pieces(in: source))
                XCTAssertFalse(
                    prose.contains { $0.text.contains("**") },
                    "literal ** survived in block source \(source)")
            }
        }
    }

    // MARK: - Thematic breaks

    func testThematicBreakVariantsParseAsRules() {
        for line in ["---", "***", "___", "- - -", "-----", "  ---  "] {
            XCTAssertEqual(
                MarkdownParser.parse(line), [.rule],
                "\(line) should parse as a horizontal rule")
        }
    }

    /// The bug: a `---` line used to fall through to `.paragraph("---")` and
    /// render its dashes literally.
    func testRuleIsNotAParagraph() {
        XCTAssertEqual(
            MarkdownParser.parse("above\n\n---\n\nbelow"),
            [.paragraph("above"), .rule, .paragraph("below")])
    }

    /// A rule ends the paragraph above it even without a blank line between.
    func testRuleTerminatesPrecedingParagraph() {
        XCTAssertEqual(MarkdownParser.parse("above\n---"), [.paragraph("above"), .rule])
    }

    /// A table's `|---|---|` separator and a `- item` bullet both contain rule
    /// characters and must not be swallowed as rules.
    func testRuleDetectionDoesNotEatTablesOrBullets() {
        XCTAssertEqual(MarkdownParser.parse("- a\n- b"), [.unordered(["a", "b"])])
        let table = MarkdownParser.parse("|a|b|\n|---|---|\n|1|2|")
        XCTAssertEqual(table.count, 1)
        guard case .table = table.first else { return XCTFail("expected a table, got \(table)") }
    }

    func testSampleReplyHasNoLiteralDashParagraphs() {
        let blocks = MarkdownParser.parse(Self.sample)
        XCTAssertTrue(blocks.contains(.rule), "the sample's --- separators should parse as rules")
        for block in blocks {
            if case .paragraph(let text) = block {
                XCTAssertNotEqual(
                    text.trimmingCharacters(in: .whitespaces), "---",
                    "a --- line reached the renderer as a paragraph")
            }
        }
    }

    func testPlainPreviewStripsThematicBreaks() {
        XCTAssertEqual(MarkdownParser.plainPreview("above\n\n---\n\nbelow"), "above below")
        XCTAssertEqual(MarkdownParser.plainPreview("a\n\n***\n\nb"), "a b")
    }

    // MARK: - Headings deeper than ###

    func testHeadingLevelsFourThroughSixAreParsed() {
        XCTAssertEqual(MarkdownParser.parse("#### Four"), [.heading(4, "Four")])
        XCTAssertEqual(MarkdownParser.parse("##### Five"), [.heading(5, "Five")])
        XCTAssertEqual(MarkdownParser.parse("###### Six"), [.heading(6, "Six")])
    }

    func testHeadingLevelsOneThroughThreeStillParse() {
        XCTAssertEqual(MarkdownParser.parse("# One"), [.heading(1, "One")])
        XCTAssertEqual(MarkdownParser.parse("## Two"), [.heading(2, "Two")])
        XCTAssertEqual(MarkdownParser.parse("### Three"), [.heading(3, "Three")])
    }

    // MARK: - Display math bodies

    /// `$$\n…\n$$` used to keep the delimiters' own newlines in the body, which
    /// the unparseable-LaTeX fallback then rendered as blank lines.
    func testMultiLineDisplayMathBodyIsTrimmed() {
        XCTAssertEqual(MarkdownParser.parse("$$\nP(Y)\n$$"), [.math("P(Y)")])
        XCTAssertEqual(MarkdownParser.parse("\\[\nP(Y)\n\\]"), [.math("P(Y)")])
    }

    /// SwiftMath has no `\dots`, and one unknown command fails the whole
    /// equation — so it used to fall back to raw monospaced source.
    func testDotsCommandTypesets() {
        XCTAssertNotNil(
            MathRenderer.render(latex: "x_1, x_2, \\dots, x_n", fontSize: 16, color: .labelColor, display: true),
            "\\dots should be aliased to a command SwiftMath understands")
    }

    func testEveryEquationInTheSampleTypesets() {
        for block in MarkdownParser.parse(Self.sample) {
            guard case .math(let latex) = block else { continue }
            XCTAssertNotNil(
                MathRenderer.render(latex: latex, fontSize: 16, color: .labelColor, display: true),
                "equation fell back to raw source: \(latex)")
        }
    }

    // MARK: - Bubble height (the dead space under long replies)

    /// The bubble reserves `measureHeight` points and the text view lays itself
    /// out inside that. They must agree, or the difference shows up as dead
    /// space under the reply — ~400pt on this sample, because the height was
    /// measured with a TextKit 1 layout manager while `NSTextView()` handed back
    /// a TextKit 2 view that lays `paragraphSpacing` out differently.
    func testRenderedBubbleHasNoDeadSpaceUnderTheText() {
        let hosting = NSHostingView(rootView: SelectableMessageText(
            content: Self.sample, color: .primary, secondary: .secondary, onQuote: { _ in }))
        hosting.frame = NSRect(x: 0, y: 0, width: 248, height: 3000)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 300, height: 3000),
            styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView?.addSubview(hosting)
        hosting.layoutSubtreeIfNeeded()

        guard let container = Self.firstSubview(of: MessageContainerView.self, in: hosting) else {
            return XCTFail("could not locate MessageContainerView in the hosted hierarchy")
        }
        XCTAssertGreaterThan(container.frame.height, 100, "the sample should produce a tall bubble")
        XCTAssertEqual(
            container.textView.frame.height, container.frame.height, accuracy: 2,
            "the text view laid out to a different height than the bubble reserved — "
                + "the gap is dead space at the bottom of the reply")
    }

    /// The measurement above is only trustworthy while the live view and
    /// `measureHeight` share a layout engine. Pin the TextKit 1 stack.
    func testTranscriptTextViewUsesTextKit1() {
        let container = MessageContainerView(frame: NSRect(x: 0, y: 0, width: 248, height: 10))
        XCTAssertNil(
            container.textView.textLayoutManager,
            "a TextKit 2 stack would disagree with measureHeight's NSLayoutManager")
        XCTAssertNotNil(container.textView.layoutManager)
    }

    /// Both renderers must handle every block the parser can now emit; a
    /// missing `.rule` case would be a compile error, an empty render a silent
    /// regression.
    func testAttributedRendererRendersRules() {
        let attributed = AiAttributedRenderer.attributedString(
            for: "above\n\n---\n\nbelow", color: .labelColor, secondary: .secondaryLabelColor)
        XCTAssertTrue(
            attributed.string.contains("\u{FFFC}"),
            "the rule should render as an attachment, got \(attributed.string.debugDescription)")
        XCTAssertFalse(attributed.string.contains("---"), "the rule's dashes reached the screen")
    }

    // MARK: - Helpers

    private struct ProseRun: CustomStringConvertible {
        var text: String
        var isBold: Bool
        var isItalic: Bool
        var description: String { "\(text.debugDescription)[bold=\(isBold) italic=\(isItalic)]" }
    }

    /// Flatten the prose pieces into per-run text plus the emphasis that
    /// Foundation resolved for them.
    private static func proseRuns(_ pieces: [InlinePiece]) -> [ProseRun] {
        pieces.flatMap { piece -> [ProseRun] in
            guard case .prose(let attributed) = piece else { return [] }
            return attributed.runs.map { run in
                ProseRun(
                    text: String(attributed[run.range].characters),
                    isBold: run.inlinePresentationIntent?.contains(.stronglyEmphasized) ?? false,
                    isItalic: run.inlinePresentationIntent?.contains(.emphasized) ?? false)
            }
        }
    }

    private static func mathRuns(_ pieces: [InlinePiece]) -> [String] {
        pieces.compactMap { piece in
            guard case .math(let latex) = piece else { return nil }
            return latex
        }
    }

    /// Every string in a block that goes through inline markdown.
    private static func inlineSources(of block: MarkdownBlock) -> [String] {
        switch block {
        case .heading(_, let text), .paragraph(let text), .quote(let text): return [text]
        case .unordered(let items), .ordered(let items): return items
        case .code, .table, .math, .rule: return []
        }
    }

    private static func firstSubview<T: NSView>(of type: T.Type, in root: NSView) -> T? {
        if let match = root as? T { return match }
        for subview in root.subviews {
            if let match = firstSubview(of: type, in: subview) { return match }
        }
        return nil
    }
}
