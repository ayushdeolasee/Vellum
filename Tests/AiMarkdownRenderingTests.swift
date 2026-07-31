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
        XCTAssertEqual(blocks.count(where: Self.isList), 3, "expected the sample's 3 bullet lists")
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

    private static func isList(_ block: MarkdownBlock) -> Bool {
        if case .list = block { return true }
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
        XCTAssertEqual(MarkdownParser.parse("- a\n- b"), [.list([
            MarkdownListItem(depth: 0, marker: .unordered, text: "a"),
            MarkdownListItem(depth: 0, marker: .unordered, text: "b"),
        ])])
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

    /// Rule detection runs on the raw line, so it must not reach inside a code
    /// fence and turn a line of dashes in a snippet into a horizontal rule.
    func testRuleDetectionDoesNotReachIntoCodeFences() {
        XCTAssertEqual(
            MarkdownParser.parse("```\n---\n***\n```"),
            [.code("---\n***")])
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

    // MARK: - Nested lists

    /// The follow-up defect reported on this PR: a model's sub-bullets are
    /// indented, and indent used to disqualify a line from being a list item at
    /// all — so the whole nested group fell through to `.paragraph` and showed
    /// its own `- ` markers, with the code spans inside them unstyled because a
    /// paragraph is not a list.
    func testIndentedSubItemsParseAsNestedListItems() {
        let source = """
            1. If the next characters are whitespace, skip them.
            2. Otherwise, try every token pattern, like:
               - `int\\b` for the `int` keyword
               - `[0-9]+\\b` for constants like `2`
            3. Choose the **longest match at the start**.
            """
        let blocks = MarkdownParser.parse(source)
        guard case .list(let items) = blocks.first, blocks.count == 1 else {
            return XCTFail("expected one nested list, got \(blocks)")
        }
        XCTAssertEqual(items.map(\.depth), [0, 0, 1, 1, 0])
        XCTAssertEqual(items.map(\.marker), [
            .ordered(1), .ordered(2), .unordered, .unordered, .ordered(3),
        ])
        XCTAssertFalse(
            items.contains { $0.text.hasPrefix("- ") },
            "a marker survived into the item text: \(items.map(\.text))")
    }

    // MARK: - Code spans containing math delimiters (#99)

    /// Text and code-intent for every prose run of a line, as the renderers see
    /// it. Both message renderers consume `InlineMarkdown.pieces` — the SwiftUI
    /// `MarkdownMessage` and the AppKit `AiAttributedRenderer` — so asserting
    /// here covers both inline paths at their shared layer.
    private static func runs(_ line: String) -> [(String, Bool)] {
        InlineMarkdown.pieces(in: line).flatMap { piece -> [(String, Bool)] in
            guard case .prose(let attributed) = piece else { return [] }
            return attributed.runs.map {
                (String(attributed[$0.range].characters),
                 $0.inlinePresentationIntent?.contains(.code) ?? false)
            }
        }
    }

    private static func hasMath(_ line: String) -> Bool {
        InlineMarkdown.pieces(in: line).contains { piece in
            if case .math = piece { return true }
            return false
        }
    }

    /// The #99 repros. `MathRenderer.segments` runs before the markdown parse,
    /// so a code span holding a `$` or a `\(…\)` was cut apart before anything
    /// knew it was code — the span was typeset as an equation and its backticks
    /// were eaten.
    func testCodeSpansHoldingMathDelimitersStayCode() {
        let cases = [
            ("Use `$1` and `$2` backrefs", ["$1", "$2"]),
            ("matches `\\(a\\|b\\)` here", ["\\(a\\|b\\)"]),
            ("write `$$x$$` for display", ["$$x$$"]),
            ("`a$b` alone", ["a$b"]),
        ]
        for (line, spans) in cases {
            XCTAssertFalse(Self.hasMath(line), "\(line) was typeset as math")
            let runs = Self.runs(line)
            for span in spans {
                XCTAssertTrue(
                    runs.contains { $0.0 == span && $0.1 },
                    "\(line): expected code run \(span), got \(runs)")
            }
            XCTAssertFalse(
                runs.contains { $0.0.contains("`") }, "\(line): backticks reached the screen: \(runs)")
        }
    }

    /// The guard is code spans, not backticks: real inline math elsewhere on the
    /// line must still typeset, and a `$` used as currency must still not.
    func testMathAndCurrencyOutsideCodeSpansAreUnaffected() {
        XCTAssertTrue(Self.hasMath("`grep` finds $x^2$ fast"))
        XCTAssertTrue(Self.hasMath("the value $x^2$ appears here"))
        XCTAssertFalse(Self.hasMath("it cost $5 and $10 today"))
        XCTAssertFalse(Self.hasMath("`grep` costs $5 and $10"))
    }

    /// The AppKit renderer specifically: math becomes an `NSTextAttachment`, so
    /// a code span that is no longer mistaken for math must produce none — and
    /// its `$` must survive as literal text.
    func testAppKitRendererDoesNotTypesetCodeSpanDollars() {
        func attachmentCount(_ source: String) -> Int {
            let attributed = AiAttributedRenderer.attributedString(
                for: source, color: .labelColor, secondary: .secondaryLabelColor)
            var count = 0
            attributed.enumerateAttribute(
                .attachment, in: NSRange(location: 0, length: attributed.length)
            ) { value, _, _ in
                if value is NSTextAttachment { count += 1 }
            }
            return count
        }
        let rendered = AiAttributedRenderer.attributedString(
            for: "Use `$1` and `$2` backrefs", color: .labelColor, secondary: .secondaryLabelColor)
        XCTAssertTrue(rendered.string.contains("$1"), "got \(rendered.string)")
        XCTAssertTrue(rendered.string.contains("$2"), "got \(rendered.string)")
        XCTAssertFalse(rendered.string.contains("`"), "got \(rendered.string)")
        XCTAssertEqual(attachmentCount("Use `$1` and `$2` backrefs"), 0)
        // Positive control: real math on the same path still typesets, so the
        // assertion above is about the code span and not about attachments
        // having stopped working.
        XCTAssertGreaterThan(attachmentCount("the value $x^2$ appears"), 0)
    }

    /// The sidebar pill, quoting and accessibility text go through
    /// `plainPreview`, which calls `segments` directly — the third caller, and
    /// the reason #99 is fixed in `MathRenderer` rather than in `InlineMarkdown`.
    func testPlainPreviewKeepsCodeSpanContentIntact() {
        XCTAssertEqual(MarkdownParser.plainPreview("Use `$1` and `$2` backrefs"),
                       "Use $1 and $2 backrefs")
        XCTAssertEqual(MarkdownParser.plainPreview("matches `\\(a\\|b\\)` here"),
                       "matches \\(a\\|b\\) here")
    }

    /// Known residual, pinned so it stays a decision rather than a surprise:
    /// `plainPreview` unwraps `$$…$$` and strips math delimiters with its own
    /// regexes, which run before `segments` and have no notion of code spans —
    /// so a `$$` inside a code span still loses its delimiters in the pill.
    ///
    /// Out of scope for #99 and materially different from it: no text is eaten
    /// and nothing is reordered (the "x" survives), which is the same lossy
    /// contract this one-line preview already applies to `**`, backticks and
    /// every other delimiter. The bug #99 is about — the splitter consuming the
    /// backticks and the prose between two spans — is fixed here, as the test
    /// above shows.
    func testPlainPreviewStillStripsDisplayDelimitersInsideCodeSpans() {
        XCTAssertEqual(MarkdownParser.plainPreview("write `$$x$$` for display"),
                       "write x for display")
    }

    /// The code spans inside those sub-items must still style as code.
    func testCodeSpansInsideNestedItemsAreMonospaced() {
        guard case .list(let items) = MarkdownParser.parse("- a\n  - `int\\b` for the `int` keyword").first else {
            return XCTFail("expected a nested list")
        }
        let runs = InlineMarkdown.pieces(in: items[1].text).flatMap { piece -> [(String, Bool)] in
            guard case .prose(let attributed) = piece else { return [] }
            return attributed.runs.map {
                (String(attributed[$0.range].characters),
                 $0.inlinePresentationIntent?.contains(.code) ?? false)
            }
        }
        XCTAssertTrue(runs.contains { $0.0 == "int\\b" && $0.1 }, "backtick span lost its code intent: \(runs)")
        XCTAssertFalse(runs.contains { $0.0.contains("`") }, "backticks reached the screen: \(runs)")
    }

    /// Depth comes from a stack of observed indent columns, not a fixed
    /// divisor, so two-space and four-space nesting both read as one level.
    func testNestingDepthIsIndependentOfIndentWidth() {
        for indent in ["  ", "    ", "\t"] {
            guard case .list(let items) = MarkdownParser.parse("- a\n\(indent)- b\n- c").first else {
                return XCTFail("expected a list for indent \(indent.debugDescription)")
            }
            XCTAssertEqual(items.map(\.depth), [0, 1, 0], "indent \(indent.debugDescription)")
        }
    }

    /// CommonMark honours only the first number of an ordered level. Models
    /// very often write `1.` for every item, which must still read 1, 2, 3 —
    /// but a list that genuinely starts at 3 must start at 3.
    func testOrderedNumberingFollowsTheFirstMarker() {
        guard case .list(let repeated) = MarkdownParser.parse("1. a\n1. b\n1. c").first else {
            return XCTFail("expected a list")
        }
        XCTAssertEqual(repeated.map(\.marker), [.ordered(1), .ordered(2), .ordered(3)])

        guard case .list(let offset) = MarkdownParser.parse("3. three\n4. four").first else {
            return XCTFail("expected a list")
        }
        XCTAssertEqual(offset.map(\.marker), [.ordered(3), .ordered(4)])
    }

    /// A mixed list keeps both marker kinds instead of being split into two
    /// blocks that lose their relationship.
    func testMixedMarkersStayOneList() {
        guard case .list(let items) = MarkdownParser.parse("1. step\n   - detail\n2. step").first else {
            return XCTFail("expected one mixed list")
        }
        XCTAssertEqual(items.map(\.marker), [.ordered(1), .unordered, .ordered(2)])
    }

    func testPlainPreviewStripsIndentedListMarkers() {
        XCTAssertEqual(MarkdownParser.plainPreview("- a\n  - b\n  2. c"), "a b c")
    }

    // MARK: - Emphasis edge cases

    /// Same-marker nesting — `**a **b** c**` — is invalid CommonMark, and
    /// models emit it constantly.
    ///
    /// PR #80 added a hand-rolled delimiter-flanking recovery pass here on the
    /// premise that Foundation leaves every marker literal for these shapes.
    /// It does not: Foundation resolves all of them itself, so that pass was
    /// dropped during consolidation as machinery that never fired. These are
    /// the exact inputs it was written for, pinned so the omission stays
    /// justified — if Foundation ever regresses, this goes red and the case for
    /// a recovery pass is real again.
    func testOverlappingEmphasisDoesNotLeakMarkers() {
        for source in [
            "**What **FOR UPDATE** does**",
            "*an *overlap* here*",
            "**a **b** c**",
            "__a __b__ c__",
            "***triple*** emphasis",
            "**What **FOR UPDATE SKIP LOCKED** does** and *an *overlap* here*",
        ] {
            let visible = Self.visibleText(InlineMarkdown.pieces(in: source))
            XCTAssertFalse(visible.contains("*"), "\(source) leaked an asterisk: \(visible.debugDescription)")
            XCTAssertFalse(visible.contains("_"), "\(source) leaked an underscore: \(visible.debugDescription)")
        }
    }

    /// The other half of that decision: the markers that *must* reach the
    /// screen. Every one of these is a false positive for any "strip the
    /// delimiters Foundation leaked" repair — an operator, an escaped literal,
    /// a marker still arriving mid-stream, and a code span. Emphasis elsewhere
    /// on the same line must still resolve.
    func testLiteralMarkersSurviveAndEmphasisAroundThemStillResolves() {
        let cases = [
            ("2 * 3 and **bold**", "2 * 3 and bold"),
            (#"\*\*a\*\* and **b**"#, "**a** and b"),
            ("**unclosed emphasis", "**unclosed emphasis"),
            ("`a*b` stays code", "a*b stays code"),
            ("a **b** c ** d", "a b c ** d"),
        ]
        for (source, expected) in cases {
            XCTAssertEqual(Self.visibleText(InlineMarkdown.pieces(in: source)), expected, source)
        }
        for source in ["2 * 3 and **bold**", #"\*\*a\*\* and **b**"#, "a **b** c ** d"] {
            XCTAssertTrue(
                Self.proseRuns(InlineMarkdown.pieces(in: source)).contains(where: \.isBold),
                "a literal marker on the line disabled real emphasis: \(source)")
        }
        XCTAssertFalse(
            Self.proseRuns(InlineMarkdown.pieces(in: "use snake_case_names here")).contains(where: \.isItalic),
            "intraword underscores are not emphasis")
    }

    // MARK: - Streaming prefixes

    /// Every prefix of a reply is rendered as it arrives. None may crash, lose
    /// the text that has already landed, or leak a half-arrived marker.
    func testPartialRepliesStayRenderable() {
        let cases: [(source: String, mustContain: String)] = [
            ("#", "#"),
            ("# ", "#"),
            ("# Heading\n\n**bold", "bold"),
            ("# Heading\n\n**bold $x", "bold"),
            ("# Heading\n\n**bold $x$ text**\n\n$", "text"),
            ("# Heading\n\n**bold $x$ text**\n\n$$\n\\frac{a}", "text"),
        ]
        for (source, expected) in cases {
            let rendered = AiAttributedRenderer.attributedString(
                for: source, color: .labelColor, secondary: .secondaryLabelColor)
            XCTAssertTrue(
                rendered.string.contains(expected),
                "\(source.debugDescription) dropped \(expected.debugDescription): \(rendered.string.debugDescription)")
        }
        // A heading marker with no text yet stays visible as a paragraph rather
        // than collapsing to a zero-height block that hides the last token.
        XCTAssertEqual(MarkdownParser.parse("## "), [.paragraph("## ")])
        XCTAssertEqual(MarkdownParser.parse("## T"), [.heading(2, "T")])
    }

    func testMalformedBlocksDegradeInsteadOfDisappearing() {
        XCTAssertEqual(MarkdownParser.parse("$$\n\\frac{a}{b}"), [.code("\\frac{a}{b}")])
        XCTAssertEqual(MarkdownParser.parse("####### not a heading"), [.paragraph("####### not a heading")])
        for source in ["**unclosed emphasis", "[broken link](https://example.com", "```\nunclosed code", "-"] {
            let rendered = AiAttributedRenderer.attributedString(
                for: source, color: .labelColor, secondary: .secondaryLabelColor)
            XCTAssertGreaterThan(rendered.length, 0, source)
            XCTAssertTrue(MessageContainerView.measureHeight(rendered, width: 120).isFinite, source)
        }
    }

    // MARK: - Attachments at narrow widths

    /// Equations and rules are authored at the bubble's default content width,
    /// but the inspector column goes down to 240pt and list items indent
    /// further still. An attachment cannot size itself against its container,
    /// so it has to be scaled to the line fragment it will actually occupy.
    func testAttachmentsAreScaledIntoTheirLineFragment() {
        let source = "- Parent\n    - Wide $\\frac{abcdefghijklmnopqrstuvwxyz}{1234567890}$\n\n---\n\n$$\nP(X, Y)\n$$"
        let attributed = AiAttributedRenderer.attributedString(
            for: source, color: .labelColor, secondary: .secondaryLabelColor)

        for width in [248.0, 120.0] as [CGFloat] {
            let fitted = MessageContainerView.fittedAttachments(in: attributed, width: width)
            var seen = 0
            fitted.enumerateAttribute(.attachment, in: NSRange(location: 0, length: fitted.length)) { value, range, _ in
                guard let attachment = value as? NSTextAttachment else { return }
                seen += 1
                let paragraph = fitted.attribute(.paragraphStyle, at: range.location, effectiveRange: nil)
                    as? NSParagraphStyle
                let indent = max(paragraph?.firstLineHeadIndent ?? 0, paragraph?.headIndent ?? 0)
                XCTAssertLessThanOrEqual(
                    attachment.bounds.width, width - indent + 0.5,
                    "attachment overflows its indented line fragment at \(width)")
            }
            XCTAssertGreaterThan(seen, 0, "expected attachments to fit at \(width)")
        }

        // The originals are untouched, so widening the panel restores full size
        // rather than compounding the scale.
        let widths = Self.attachmentWidths(in: attributed)
        _ = MessageContainerView.fittedAttachments(in: attributed, width: 100)
        XCTAssertEqual(Self.attachmentWidths(in: attributed), widths)
    }

    // MARK: - Quoting and accessibility

    /// `textView.string` is full of U+FFFC — one per equation and per rule — so
    /// quoting a selection used to paste object-replacement characters into the
    /// composer, and the bubble's accessibility value read them out.
    func testAttachmentsBecomeSourceTextRatherThanReplacementCharacters() {
        let content = "Before $x^2$ here\n\n---\n\n$$\nP(X, Y)\n$$"
        let attributed = AiAttributedRenderer.attributedString(
            for: content, color: .labelColor, secondary: .secondaryLabelColor)
        XCTAssertTrue(attributed.string.contains("\u{FFFC}"), "attachments should be present to begin with")

        let quoted = MessageContainerView.plainText(
            in: attributed, range: NSRange(location: 0, length: attributed.length), form: \.markdown)
        XCTAssertFalse(quoted.contains("\u{FFFC}"), quoted.debugDescription)
        XCTAssertTrue(quoted.contains("$x^2$"), "inline math should quote with its delimiters: \(quoted)")
        XCTAssertTrue(quoted.contains("$$\nP(X, Y)\n$$"), "display math should quote as display math: \(quoted)")
        XCTAssertFalse(quoted.contains("---"), "the decorative rule should quote as nothing")

        let container = MessageContainerView(frame: NSRect(x: 0, y: 0, width: 248, height: 80))
        container.setAttributed(attributed, content: content, color: .labelColor, secondary: .secondaryLabelColor)
        let spoken = container.textView.accessibilityValue()
        XCTAssertNotNil(spoken)
        XCTAssertFalse(spoken?.contains("\u{FFFC}") ?? true, "VoiceOver would read the replacement character")
        XCTAssertTrue(spoken?.contains("Equation: x^2") ?? false, "the equation was not spoken: \(spoken ?? "nil")")
    }

    private static func attachmentWidths(in attributed: NSAttributedString) -> [CGFloat] {
        var widths: [CGFloat] = []
        attributed.enumerateAttribute(.attachment, in: NSRange(location: 0, length: attributed.length)) { value, _, _ in
            if let attachment = value as? NSTextAttachment { widths.append(attachment.bounds.width) }
        }
        return widths
    }

    private static func visibleText(_ pieces: [InlinePiece]) -> String {
        pieces.compactMap { piece in
            guard case .prose(let prose) = piece else { return nil }
            return String(prose.characters)
        }.joined()
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
        case .list(let items): return items.map(\.text)
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
