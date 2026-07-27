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

    private struct Delimiter {
        let range: Range<String.Index>
        let marker: Character
        let length: Int
        let canOpen: Bool
        let canClose: Bool
    }

    private struct DelimiterKind: Hashable {
        let marker: Character
        let length: Int
    }

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
        guard let repaired = repairedMalformedEmphasis(
            in: source,
            rendered: rendered
        ) else {
            return parsed
        }

        // Model streams sometimes produce overlapping/nested emphasis such as
        // `**What **FOR UPDATE** does**`. CommonMark intentionally rejects that
        // shape and Foundation returns every marker literally. In a chat reply,
        // readable plain prose is a better failure mode than leaking syntax.
        // Recovery only removes balanced, context-valid delimiter runs that
        // Foundation demonstrably leaked. Operators, escaped markers, code
        // spans, intraword underscores, and all whitespace remain untouched.
        return (try? AttributedString(
            markdown: repaired,
            options: AttributedString.MarkdownParsingOptions(
                interpretedSyntax: .inlineOnlyPreservingWhitespace
            )
        )) ?? AttributedString(repaired)
    }

    nonisolated private static func repairedMalformedEmphasis(
        in source: String,
        rendered: String
    ) -> String? {
        let delimiters = emphasisDelimiters(in: source)
        let groups = Dictionary(grouping: delimiters) {
            DelimiterKind(marker: $0.marker, length: $0.length)
        }
        let recoverable = groups.values.flatMap { group -> [Delimiter] in
            guard group.count >= 2,
                  group.count.isMultiple(of: 2),
                  group.allSatisfy({ $0.canOpen || $0.canClose }),
                  group.contains(where: \.canOpen),
                  group.contains(where: \.canClose),
                  let first = group.first else {
                return []
            }
            let token = String(repeating: String(first.marker), count: first.length)
            return rendered.contains(token) ? group : []
        }
        guard !recoverable.isEmpty else { return nil }

        let removedRanges = Set(recoverable.map(\.range.lowerBound))
        var result = ""
        var index = source.startIndex
        while index < source.endIndex {
            if removedRanges.contains(index),
               let delimiter = recoverable.first(where: { $0.range.lowerBound == index }) {
                index = delimiter.range.upperBound
            } else {
                result.append(source[index])
                index = source.index(after: index)
            }
        }
        return result
    }

    nonisolated private static func emphasisDelimiters(in source: String) -> [Delimiter] {
        var result: [Delimiter] = []
        var index = source.startIndex
        while index < source.endIndex {
            let character = source[index]

            if character == "\\" {
                index = source.index(after: index)
                if index < source.endIndex {
                    index = source.index(after: index)
                }
                continue
            }

            if character == "`" {
                let runEnd = endOfRun(in: source, from: index, matching: character)
                let token = String(source[index..<runEnd])
                if let closing = source.range(
                    of: token,
                    range: runEnd..<source.endIndex
                ) {
                    index = closing.upperBound
                } else {
                    index = runEnd
                }
                continue
            }

            guard character == "*" || character == "_" else {
                index = source.index(after: index)
                continue
            }

            let runEnd = endOfRun(in: source, from: index, matching: character)
            let length = source.distance(from: index, to: runEnd)
            guard length == 1 || length == 2 else {
                index = runEnd
                continue
            }

            let previous = index > source.startIndex
                ? source[source.index(before: index)]
                : nil
            let next = runEnd < source.endIndex ? source[runEnd] : nil
            let previousWhitespace = previous?.isWhitespace ?? true
            let nextWhitespace = next?.isWhitespace ?? true
            let previousPunctuation = isPunctuation(previous)
            let nextPunctuation = isPunctuation(next)
            let leftFlanking = !nextWhitespace
                && (!nextPunctuation || previousWhitespace || previousPunctuation)
            let rightFlanking = !previousWhitespace
                && (!previousPunctuation || nextWhitespace || nextPunctuation)
            let canOpen: Bool
            let canClose: Bool
            if character == "_" {
                canOpen = leftFlanking && (!rightFlanking || previousPunctuation)
                canClose = rightFlanking && (!leftFlanking || nextPunctuation)
            } else {
                canOpen = leftFlanking
                canClose = rightFlanking
            }
            result.append(
                Delimiter(
                    range: index..<runEnd,
                    marker: character,
                    length: length,
                    canOpen: canOpen,
                    canClose: canClose
                )
            )
            index = runEnd
        }
        return result
    }

    nonisolated private static func endOfRun(
        in source: String,
        from start: String.Index,
        matching character: Character
    ) -> String.Index {
        var end = start
        while end < source.endIndex, source[end] == character {
            end = source.index(after: end)
        }
        return end
    }

    nonisolated private static func isPunctuation(_ character: Character?) -> Bool {
        guard let character else { return false }
        return character.unicodeScalars.allSatisfy {
            CharacterSet.punctuationCharacters.contains($0)
        }
    }
}
