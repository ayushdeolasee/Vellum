import AppKit
import SwiftUI
import XCTest
@testable import Vellum

/// A content-shaped regression corpus for issue #57. These tests exercise the
/// same parser and AppKit renderer used by assistant messages, including the
/// incomplete prefixes seen while a response is streaming.
@MainActor
final class AiMarkdownRegressionTests: XCTestCase {
    private static let corpus = #"""
    # Model comparison

    This is **bold**, *italic*, and `inline code`.

    ### Probability

    The model learns **the probability of $Y$ given $X$**.

    ---

    - Parent
      - Nested child with $x^2$
        1. Deep ordered child
    - Sibling

    $$
    P(Y \mid X) = \frac{P(X,Y)}{P(X)}
    $$

    ```swift
    let value = "**not emphasis inside code**"
    ```

    | Model | Learns |
    |:------|-------:|
    | Discriminative | $P(Y \mid X)$ |
    | Generative | $P(X,Y)$ |
    """#

    func testCorpusContainsEveryExpectedBlockKind() {
        let blocks = MarkdownParser.parse(Self.corpus)
        XCTAssertTrue(blocks.contains { if case .heading = $0 { true } else { false } })
        XCTAssertTrue(blocks.contains(.rule))
        XCTAssertTrue(blocks.contains { if case .list = $0 { true } else { false } })
        XCTAssertTrue(blocks.contains { if case .math = $0 { true } else { false } })
        XCTAssertTrue(blocks.contains { if case .code = $0 { true } else { false } })
        XCTAssertTrue(blocks.contains { if case .table = $0 { true } else { false } })
    }

    func testAllSixHeadingLevelsAndRuleVariants() {
        for level in 1...6 {
            let source = "\(String(repeating: "#", count: level)) Heading"
            XCTAssertEqual(MarkdownParser.parse(source), [.heading(level, "Heading")])
        }
        for source in ["---", "***", "___", "- - -", "  -----  "] {
            XCTAssertEqual(MarkdownParser.parse(source), [.rule], source)
        }
    }

    func testEmphasisCanCrossMultipleInlineEquations() {
        let pieces = InlineMarkdown.pieces(in: "**the probability of $Y$ given $X$**")
        let proseRuns = pieces.flatMap { piece -> [(String, Bool)] in
            guard case .prose(let attributed) = piece else { return [] }
            return attributed.runs.map { run in
                (
                    String(attributed[run.range].characters),
                    run.inlinePresentationIntent?.contains(.stronglyEmphasized) ?? false
                )
            }
        }
        XCTAssertFalse(proseRuns.contains { $0.0.contains("*") }, "\(proseRuns)")
        XCTAssertTrue(proseRuns.filter { !$0.0.isEmpty }.allSatisfy(\.1), "\(proseRuns)")
        XCTAssertEqual(pieces.compactMap {
            if case .math(let latex) = $0 { latex } else { nil }
        }, ["Y", "X"])
    }

    func testNestedAndMixedListsPreserveDepthAndMarkers() {
        let blocks = MarkdownParser.parse(
            "- Parent\n  - Child\n    3. Deep child\n- Sibling"
        )
        guard case .list(let items) = blocks.first else {
            return XCTFail("expected semantic nested list, got \(blocks)")
        }
        XCTAssertEqual(items.map(\.depth), [0, 1, 2, 0])
        XCTAssertEqual(items.map(\.marker), [
            .unordered, .unordered, .ordered(3), .unordered,
        ])
        XCTAssertEqual(items.map(\.text), ["Parent", "Child", "Deep child", "Sibling"])
        guard case .list(let customNumbered) = MarkdownParser.parse("3. Three").first else {
            return XCTFail("custom list numbering must be preserved")
        }
        XCTAssertEqual(customNumbered.first?.marker, .ordered(3))
    }

    func testCodeAndTableContentRemainLiteralAndStructured() {
        XCTAssertEqual(
            MarkdownParser.parse("```swift\n# not a heading\n**not bold**\n```"),
            [.code("# not a heading\n**not bold**")]
        )
        let blocks = MarkdownParser.parse("| A | B |\n|---|:---:|\n| 1 | 2 |")
        guard case .table(let table) = blocks.first else {
            return XCTFail("expected table, got \(blocks)")
        }
        XCTAssertTrue(table.contains("A"))
        XCTAssertTrue(table.contains("2"))
        XCTAssertFalse(table.contains("---"))
    }

    func testDisplayAndInlineMathRenderOrDegradeWithoutLosingSource() {
        XCTAssertEqual(
            MarkdownParser.parse("$$\nP(Y \\mid X)\n$$"),
            [.math("P(Y \\mid X)")]
        )
        XCTAssertEqual(
            MarkdownParser.parse("before $x^2$ after"),
            [.paragraph("before $x^2$ after")]
        )
        XCTAssertNotNil(
            MathRenderer.render(
                latex: "x_1, x_2, \\dots, x_n",
                fontSize: 16,
                color: .labelColor,
                display: true
            )
        )
    }

    func testStreamingBoundariesAlwaysProduceRenderableOutput() {
        let prefixes = [
            "#", "# ", "# Heading\n\n**",
            "# Heading\n\n**bold",
            "# Heading\n\n**bold $x",
            "# Heading\n\n**bold $x$ text**\n\n$",
            "# Heading\n\n**bold $x$ text**\n\n$$\n\\frac{a}",
            "# Heading\n\n**bold $x$ text**\n\n$$\n\\frac{a}{b}\n$$",
            Self.corpus,
        ]
        for prefix in prefixes {
            let blocks = MarkdownParser.parse(prefix)
            XCTAssertFalse(blocks.isEmpty, prefix.debugDescription)
            let rendered = AiAttributedRenderer.attributedString(
                for: prefix,
                color: .labelColor,
                secondary: .secondaryLabelColor
            )
            XCTAssertGreaterThan(rendered.length, 0, prefix.debugDescription)
        }
    }

    func testMalformedMarkdownDegradesToReadableText() {
        let malformed = [
            "**unclosed emphasis",
            "[broken link](https://example.com",
            "```\nunclosed code",
            "$$\n\\frac{a}{b}",
            "| header | only",
            "-",
            "####### not a heading",
        ]
        for source in malformed {
            let rendered = AiAttributedRenderer.attributedString(
                for: source,
                color: .labelColor,
                secondary: .secondaryLabelColor
            )
            XCTAssertGreaterThan(rendered.length, 0, source)
            XCTAssertTrue(
                MessageContainerView.measureHeight(rendered, width: 120).isFinite,
                source
            )
        }
        XCTAssertEqual(
            MarkdownParser.parse("$$\n\\frac{a}{b}"),
            [.code("\\frac{a}{b}")]
        )
    }

    func testOverlappingModelEmphasisDoesNotLeakSyntax() {
        let pieces = InlineMarkdown.pieces(
            in: "**What **FOR UPDATE SKIP LOCKED** does** and *an *overlap* here*"
        )
        let visible = pieces.compactMap { piece -> String? in
            guard case .prose(let prose) = piece else { return nil }
            return String(prose.characters)
        }.joined()
        XCTAssertEqual(
            visible,
            "What FOR UPDATE SKIP LOCKED does and an overlap here"
        )
        XCTAssertFalse(visible.contains("*"))
    }

    func testMalformedEmphasisRecoveryPreservesLiteralOperatorsCodeAndWhitespace() {
        let source = """
        2 * 3 and **bold**
        `a*b` stays code

        **What **FOR UPDATE** does**
        """
        let pieces = InlineMarkdown.pieces(in: source)
        let visible = pieces.compactMap { piece -> String? in
            guard case .prose(let prose) = piece else { return nil }
            return String(prose.characters)
        }.joined()

        XCTAssertEqual(
            visible,
            """
            2 * 3 and bold
            a*b stays code

            What FOR UPDATE does
            """
        )
        XCTAssertTrue(visible.contains("2 * 3"))
        XCTAssertTrue(visible.contains("a*b"))
        XCTAssertTrue(visible.contains("\n\n"))
    }

    func testCorpusLayoutIsFiniteAtNarrowAndDefaultWidths() {
        let attributed = AiAttributedRenderer.attributedString(
            for: Self.corpus,
            color: .labelColor,
            secondary: .secondaryLabelColor
        )
        for width in [120.0, 248.0] as [CGFloat] {
            let height = MessageContainerView.measureHeight(attributed, width: width)
            XCTAssertTrue(height.isFinite, "non-finite height at \(width)")
            XCTAssertGreaterThan(height, 100, "corpus unexpectedly collapsed at \(width)")
        }

        let narrow = MessageContainerView.fittedAttachments(
            in: attributed,
            width: 120
        )
        narrow.enumerateAttribute(
            .attachment,
            in: NSRange(location: 0, length: narrow.length)
        ) { value, _, _ in
            guard let attachment = value as? NSTextAttachment else { return }
            XCTAssertLessThanOrEqual(attachment.bounds.width, 120)
        }
    }

    func testNestedListAttachmentsFitIndentedLineFragments() {
        let source = """
        - Parent
            - A deliberately wide equation $\\frac{abcdefghijklmnopqrstuvwxyz}{1234567890}$
        """
        let attributed = AiAttributedRenderer.attributedString(
            for: source,
            color: .labelColor,
            secondary: .secondaryLabelColor
        )

        for width in [248.0, 120.0] as [CGFloat] {
            let fitted = MessageContainerView.fittedAttachments(
                in: attributed,
                width: width
            )
            let storage = NSTextStorage(attributedString: fitted)
            let container = NSTextContainer(
                size: NSSize(width: width, height: .greatestFiniteMagnitude)
            )
            container.lineFragmentPadding = 0
            let layout = NSLayoutManager()
            layout.addTextContainer(container)
            storage.addLayoutManager(layout)
            layout.ensureLayout(for: container)

            fitted.enumerateAttribute(
                .attachment,
                in: NSRange(location: 0, length: fitted.length)
            ) { value, range, _ in
                guard let attachment = value as? NSTextAttachment else { return }
                let paragraph = fitted.attribute(
                    .paragraphStyle,
                    at: range.location,
                    effectiveRange: nil
                ) as? NSParagraphStyle
                let available = width - max(
                    paragraph?.firstLineHeadIndent ?? 0,
                    paragraph?.headIndent ?? 0
                )
                XCTAssertLessThanOrEqual(
                    attachment.bounds.width,
                    available + 0.5,
                    "attachment exceeds indented line width at \(width)"
                )

                let glyphRange = layout.glyphRange(
                    forCharacterRange: range,
                    actualCharacterRange: nil
                )
                guard glyphRange.length > 0 else {
                    return XCTFail("attachment produced no glyph")
                }
                let attachmentRect = layout.boundingRect(
                    forGlyphRange: glyphRange,
                    in: container
                )
                let lineRect = layout.lineFragmentUsedRect(
                    forGlyphAt: glyphRange.location,
                    effectiveRange: nil
                )
                XCTAssertLessThanOrEqual(
                    attachmentRect.maxX,
                    lineRect.maxX + 0.5,
                    "attachment clips its line fragment at \(width)"
                )
                XCTAssertLessThanOrEqual(attachmentRect.maxX, width + 0.5)
            }
        }
    }

    func testDecorativeRuleDoesNotLeakIntoQuotesOrAccessibility() {
        let attributed = AiAttributedRenderer.attributedString(
            for: "Before\n\n---\n\nAfter",
            color: .labelColor,
            secondary: .secondaryLabelColor
        )
        XCTAssertTrue(attributed.string.contains("\u{FFFC}"))

        let plain = MessageContainerView.plainText(
            in: attributed,
            range: NSRange(location: 0, length: attributed.length),
            mathDelimiters: true
        )
        XCTAssertFalse(plain.contains("\u{FFFC}"))
        XCTAssertEqual(
            plain.split(whereSeparator: \.isWhitespace).joined(separator: " "),
            "Before After"
        )

        let view = MessageContainerView(
            frame: NSRect(x: 0, y: 0, width: 248, height: 80)
        )
        view.setAttributed(
            attributed,
            content: "Before\n\n---\n\nAfter",
            color: .labelColor,
            secondary: .secondaryLabelColor
        )
        let accessibilityValue = view.textView.accessibilityValue() as? String
        XCTAssertNotNil(accessibilityValue)
        XCTAssertFalse(accessibilityValue?.contains("\u{FFFC}") ?? true)
        XCTAssertFalse(accessibilityValue?.contains("---") ?? true)
    }

    func testLiveTextViewUsesSameLayoutEngineAsMeasurement() {
        let container = MessageContainerView(
            frame: NSRect(x: 0, y: 0, width: 248, height: 10)
        )
        XCTAssertNil(container.textView.textLayoutManager)
        XCTAssertNotNil(container.textView.layoutManager)
    }
}
