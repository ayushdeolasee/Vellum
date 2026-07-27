import Foundation

enum InlinePiece {
    case prose(AttributedString)
    case math(String)
}

/// Parses inline Markdown without losing formatting that crosses a math span.
///
/// Equations are protected with the standard object-replacement character,
/// the complete line is parsed once, and the equations are then spliced back
/// into the attributed result. This keeps `**bold $x$ text**` bold instead of
/// handing Foundation three unbalanced Markdown fragments.
enum InlineMarkdown {
    private static let placeholder: Character = "\u{FFFC}"

    nonisolated static func pieces(in source: String) -> [InlinePiece] {
        let segments = MathRenderer.segments(in: source)
        let equations = segments.compactMap { segment -> String? in
            guard case .math(let latex) = segment else { return nil }
            return latex
        }
        guard !equations.isEmpty else { return [.prose(parse(source))] }

        var protected = ""
        for segment in segments {
            switch segment {
            case .text(let text):
                protected.append(contentsOf: text.filter { $0 != placeholder })
            case .math:
                protected.append(placeholder)
            }
        }

        let parsed = parse(protected)
        guard parsed.characters.count(where: { $0 == placeholder }) == equations.count else {
            return segments.map { segment in
                switch segment {
                case .text(let text): return .prose(parse(text))
                case .math(let latex): return .math(latex)
                }
            }
        }

        var pieces: [InlinePiece] = []
        var equationIndex = 0
        var runStart = parsed.startIndex
        var index = parsed.startIndex
        while index < parsed.endIndex {
            let next = parsed.index(afterCharacter: index)
            if parsed.characters[index] == placeholder {
                if runStart < index {
                    pieces.append(.prose(AttributedString(parsed[runStart..<index])))
                }
                pieces.append(.math(equations[equationIndex]))
                equationIndex += 1
                runStart = next
            }
            index = next
        }
        if runStart < parsed.endIndex {
            pieces.append(.prose(AttributedString(parsed[runStart...])))
        }
        return pieces
    }

    nonisolated private static func parse(_ source: String) -> AttributedString {
        let parsed = (try? AttributedString(
            markdown: source,
            options: AttributedString.MarkdownParsingOptions(
                interpretedSyntax: .inlineOnlyPreservingWhitespace
            )
        )) ?? AttributedString(source)

        let rendered = String(parsed.characters)
        let leakedStrong = source.contains("**") && rendered.contains("**")
        let leakedUnderscoreStrong = source.contains("__") && rendered.contains("__")
        let starCount = source.filter { $0 == "*" }.count
        let leakedEmphasis = starCount >= 2 && rendered.contains("*")
        guard leakedStrong || leakedUnderscoreStrong || leakedEmphasis else {
            return parsed
        }

        // Model streams sometimes produce overlapping/nested emphasis such as
        // `**What **FOR UPDATE** does**`. CommonMark intentionally rejects that
        // shape and Foundation returns every marker literally. In a chat reply,
        // readable plain prose is a better failure mode than leaking syntax.
        // Only run this recovery when Foundation demonstrably leaked markers;
        // valid Markdown keeps all of its native attributes.
        let escapedStar = "\u{E000}"
        let escapedUnderscore = "\u{E001}"
        var repaired = source
            .replacingOccurrences(of: "\\*", with: escapedStar)
            .replacingOccurrences(of: "\\_", with: escapedUnderscore)
            .replacingOccurrences(of: "**", with: "")
            .replacingOccurrences(of: "__", with: "")
            .replacingOccurrences(of: "*", with: "")
            .replacingOccurrences(of: escapedStar, with: "*")
            .replacingOccurrences(of: escapedUnderscore, with: "_")
        repaired = repaired.replacingOccurrences(of: #"\s{2,}"#, with: " ", options: .regularExpression)
        return (try? AttributedString(
            markdown: repaired,
            options: AttributedString.MarkdownParsingOptions(
                interpretedSyntax: .inlineOnlyPreservingWhitespace
            )
        )) ?? AttributedString(repaired)
    }
}
