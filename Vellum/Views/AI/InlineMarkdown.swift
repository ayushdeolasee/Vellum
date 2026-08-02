import Foundation

// Inline (within-a-block) markdown for the AI chat bubbles. `MarkdownParser`
// splits a reply into blocks; this splits the *inside* of one block into styled
// prose and math spans. Both message renderers consume it — the SwiftUI
// `MarkdownMessage` (user bubbles) and the AppKit-backed `AiAttributedRenderer`
// (assistant bubbles) — so emphasis behaves identically in each.

/// One resolved piece of a line of inline markdown.
enum InlinePiece {
    /// Prose whose markdown — emphasis, strong, inline code, strikethrough,
    /// links — is already resolved into attributes.
    case prose(AttributedString)
    /// A math span: LaTeX source with its `$…$` / `\(…\)` delimiters stripped.
    case math(String)
}

enum InlineMarkdown {
    /// Stands in for a math span while Foundation parses the line's markdown.
    ///
    /// U+FFFC (OBJECT REPLACEMENT CHARACTER) is the standard "a non-text object
    /// belongs here" code point — it is exactly what TextKit itself uses for an
    /// `NSTextAttachment`. It carries no markdown meaning, and CommonMark's
    /// emphasis-flanking rules treat it the same whether they classify it as
    /// punctuation or not, so `**bold $x$ text**` still closes around it.
    private static let placeholder: Character = "\u{FFFC}"

    /// Split a line into styled prose and math spans.
    ///
    /// The math is spliced out and replaced by `placeholder` *before* the line
    /// is handed to Foundation's markdown parser, then substituted back
    /// afterwards. Parsing each prose run on its own — what both renderers used
    /// to do — breaks any emphasis that spans a math span: for
    /// `**the probability of $Y$ given $X$**`, `MathRenderer.segments` yields
    /// the text fragments `"**the probability of "`, `" given "` and `"**"`,
    /// each with unbalanced asterisks, so Foundation leaves every one of them
    /// as literal `**` on screen. That is the artifact reported in issue #57.
    nonisolated static func pieces(in source: String) -> [InlinePiece] {
        let segments = MathRenderer.segments(in: source)
        let latex: [String] = segments.compactMap { segment in
            guard case .math(let value) = segment else { return nil }
            return value
        }
        // No math: the line is a single markdown parse, which is also the path
        // the overwhelming majority of replies take.
        guard !latex.isEmpty else { return [.prose(parse(source))] }

        var protected = ""
        for segment in segments {
            switch segment {
            case .text(let text):
                // Drop any placeholder the model itself emitted so that the Nth
                // placeholder in the parsed output is always the Nth math span.
                protected.append(contentsOf: text.filter { $0 != placeholder })
            case .math:
                protected.append(placeholder)
            }
        }

        let parsed = parse(protected)
        guard parsed.characters.count(where: { $0 == placeholder }) == latex.count else {
            // Markdown parsing rewrote or dropped a placeholder (it should not),
            // so position N no longer identifies math span N. Pairing them up
            // anyway would put the wrong equation on screen — fall back to the
            // old segment-at-a-time parse, which renders every span correctly
            // and only loses emphasis that straddles one.
            return segments.map { segment in
                switch segment {
                case .text(let text): return .prose(parse(text))
                case .math(let value): return .math(value)
                }
            }
        }

        var pieces: [InlinePiece] = []
        var mathIndex = 0
        var runStart = parsed.startIndex
        var index = parsed.startIndex
        while index < parsed.endIndex {
            let next = parsed.index(afterCharacter: index)
            if parsed.characters[index] == placeholder {
                // Slicing the parsed string (rather than re-parsing the prose)
                // is what carries the emphasis across the span boundary.
                if runStart < index { pieces.append(.prose(AttributedString(parsed[runStart..<index]))) }
                pieces.append(.math(latex[mathIndex]))
                mathIndex += 1
                runStart = next
            }
            index = next
        }
        if runStart < parsed.endIndex { pieces.append(.prose(AttributedString(parsed[runStart...]))) }
        return pieces
    }

    /// Foundation's inline-only markdown parse. Whitespace is preserved so a
    /// run's leading/trailing spaces survive into the rendered line; source
    /// that isn't valid markdown falls back to its literal text.
    nonisolated private static func parse(_ source: String) -> AttributedString {
        (try? AttributedString(
            markdown: source,
            options: AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        )) ?? AttributedString(source)
    }
}
