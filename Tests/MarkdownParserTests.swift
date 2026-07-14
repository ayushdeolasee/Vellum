import XCTest
@testable import Vellum

/// Pins the current behavior of `MarkdownParser.parse` and
/// `MathRenderer.segments` — the pure parsing core behind every rendered AI
/// message and sticky note — plus `MarkdownParser.plainPreview`'s corrected
/// currency-vs-math `$` handling (see advisor-plans/011).
final class MarkdownParserTests: XCTestCase {

    // MARK: - Blocks: headings

    func testHeadings() {
        XCTAssertEqual(MarkdownParser.parse("# Title"), [.heading(1, "Title")])
        XCTAssertEqual(MarkdownParser.parse("### Sub"), [.heading(3, "Sub")])
    }

    // MARK: - Blocks: paragraphs

    func testParagraphs() {
        XCTAssertEqual(
            MarkdownParser.parse("line1\nline2\n\nline3"),
            [.paragraph("line1\nline2"), .paragraph("line3")])
    }

    // MARK: - Blocks: lists

    func testLists() {
        XCTAssertEqual(MarkdownParser.parse("- a\n- b"), [.unordered(["a", "b"])])
        XCTAssertEqual(MarkdownParser.parse("1. a\n2. b"), [.ordered(["a", "b"])])
    }

    // MARK: - Blocks: quotes

    func testQuote() {
        XCTAssertEqual(MarkdownParser.parse("> q1\n> q2"), [.quote("q1\nq2")])
    }

    // MARK: - Blocks: code fences

    func testCodeFence() {
        XCTAssertEqual(
            MarkdownParser.parse("```swift\nlet x = 1\n```"),
            [.code("let x = 1")])
    }

    func testUnterminatedCodeFenceDegradesToCode() {
        // No closing ``` — pins the existing degrade-to-code convention.
        XCTAssertEqual(
            MarkdownParser.parse("```\nfoo\nbar"),
            [.code("foo\nbar")])
    }

    // MARK: - Blocks: tables

    func testTableProducesSingleTableBlock() {
        let blocks = MarkdownParser.parse("|a|b|\n|---|---|\n|1|2|")
        XCTAssertEqual(blocks.count, 1)
        guard case .table = blocks.first else {
            XCTFail("expected a single .table block, got \(blocks)")
            return
        }
    }

    // MARK: - Blocks: display math

    func testDisplayMathSingleLine() {
        XCTAssertEqual(MarkdownParser.parse("$$E=mc^2$$"), [.math("E=mc^2")])
    }

    func testDisplayMathMultiLine() {
        let blocks = MarkdownParser.parse("$$\na+b\n$$")
        XCTAssertEqual(blocks.count, 1)
        guard case .math(let content) = blocks.first else {
            XCTFail("expected a single .math block, got \(blocks)")
            return
        }
        XCTAssertTrue(content.contains("a+b"), "expected math body to contain a+b, got \(content)")
    }

    // MARK: - Blocks: display math (streaming gate, advisor-plans/009)

    func testDisplayMathClosedSingleLineStillTypesets() {
        XCTAssertEqual(MarkdownParser.parse("$$E = mc^2$$"), [.math("E = mc^2")])
    }

    func testDisplayMathClosedMultiLineStillTypesets() {
        let blocks = MarkdownParser.parse("$$\na + b\n= c\n$$")
        XCTAssertEqual(blocks.count, 1)
        guard case .math(let content) = blocks.first else {
            XCTFail("expected a single .math block, got \(blocks)")
            return
        }
        XCTAssertTrue(content.contains("a + b"), "expected math body to contain a + b, got \(content)")
        XCTAssertTrue(content.contains("= c"), "expected math body to contain = c, got \(content)")
    }

    func testDisplayMathUnclosedDegradesToCode() {
        // No closing $$ yet — the mid-stream shape. Typesetting this on every
        // streamed token is exactly the per-token cache-miss cost this plan
        // removes, so it must degrade to .code (like an unterminated fence)
        // rather than .math.
        let blocks = MarkdownParser.parse("$$\n\\frac{a}{b}")
        XCTAssertEqual(blocks.count, 1)
        guard case .code(let content) = blocks.first else {
            XCTFail("expected a single .code block, got \(blocks)")
            return
        }
        XCTAssertTrue(content.contains("\\frac{a}{b}"), "expected code body to contain \\frac{a}{b}, got \(content)")
    }

    func testDisplayMathClosingDoesNotLeakIntoNeighbors() {
        XCTAssertEqual(
            MarkdownParser.parse("before\n$$x$$\nafter"),
            [.paragraph("before"), .math("x"), .paragraph("after")])
    }

    // MARK: - Segments: MathRenderer.segments(in:)

    func testSegmentsCurrencyIsNotMath() {
        // The doc-comment contract: "$5 and $10" stays currency.
        XCTAssertEqual(MathRenderer.segments(in: "$5 and $10"), [.text("$5 and $10")])
    }

    func testSegmentsDollarMath() {
        XCTAssertEqual(MathRenderer.segments(in: "$x^2$"), [.math("x^2")])
    }

    func testSegmentsParenMath() {
        XCTAssertEqual(
            MathRenderer.segments(in: "a \\(y\\) b"),
            [.text("a "), .math("y"), .text(" b")])
    }

    func testSegmentsMixedCurrencyAndMath() {
        let segments = MathRenderer.segments(in: "pay $5 for $x^2$")
        // "$5" stays inside a .text segment; "x^2" is its own .math segment.
        guard case .text(let leading) = segments.first else {
            XCTFail("expected leading .text segment, got \(segments)")
            return
        }
        XCTAssertTrue(leading.contains("$5"), "expected $5 to remain in text, got \(leading)")
        XCTAssertTrue(segments.contains(.math("x^2")), "expected an .math(\"x^2\") segment, got \(segments)")
    }

    // MARK: - plainPreview

    func testPlainPreviewStripsEmphasis() {
        XCTAssertEqual(MarkdownParser.plainPreview("**bold** text"), "bold text")
    }

    func testPlainPreviewPreservesCurrency() {
        // Currency preserved — fails before the step-2 fix, which routes
        // plainPreview's math stripping through MathRenderer.segments.
        XCTAssertEqual(
            MarkdownParser.plainPreview("$5 and $10 for the plan"),
            "$5 and $10 for the plan")
    }

    func testPlainPreviewStripsMathDelimiters() {
        XCTAssertEqual(MarkdownParser.plainPreview("solve $x^2$ now"), "solve x^2 now")
    }

    func testPlainPreviewStripsBlockMarkers() {
        XCTAssertEqual(MarkdownParser.plainPreview("# H\n- item"), "H item")
    }
}
