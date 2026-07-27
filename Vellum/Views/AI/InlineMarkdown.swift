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

    /// Foundation's inline-only markdown parse, with a recovery pass for the
    /// overlapping emphasis models routinely produce.
    ///
    /// Whitespace is preserved so a run's leading/trailing spaces survive into
    /// the rendered line; source that isn't valid markdown falls back to its
    /// literal text.
    nonisolated private static func parse(_ source: String) -> AttributedString {
        let parsed = foundationParse(source)
        guard let repaired = repairingLeakedEmphasis(in: source, parsed: parsed) else { return parsed }
        return repaired
    }

    nonisolated private static func foundationParse(_ source: String) -> AttributedString {
        (try? AttributedString(
            markdown: source,
            options: AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        )) ?? AttributedString(source)
    }

    // MARK: - Overlapping emphasis

    /// Recover readable prose from emphasis CommonMark refuses to pair up.
    ///
    /// Models produce nested-same-marker shapes like `**What **FOR UPDATE**
    /// does**` constantly. CommonMark rejects them by design, and Foundation
    /// then leaves *every* marker on screen as literal `**` — the same class of
    /// leaked-syntax artifact issue #57 is about. Dropping the emphasis and
    /// showing clean prose is a better failure mode in a chat bubble than
    /// showing the syntax.
    ///
    /// Returns nil (keep the original parse) unless the repair is provably an
    /// improvement. Two conditions gate it:
    ///
    /// 1. Only balanced, context-valid delimiter runs Foundation *demonstrably*
    ///    leaked are candidates. Operators (`2 * 3`), escaped markers, code
    ///    spans and intraword underscores never qualify.
    /// 2. The repaired source must re-parse with the leak actually gone. This
    ///    is what protects legitimate emphasis: in `\*\*a\*\* and **b**` the
    ///    leaked `**` comes from the *escaped* pair, so stripping the real
    ///    `**b**` would silently de-bold `b` while the leak survives. The
    ///    re-check sees `**` still present and abandons the repair.
    nonisolated private static func repairingLeakedEmphasis(
        in source: String,
        parsed: AttributedString
    ) -> AttributedString? {
        let rendered = String(parsed.characters)
        let delimiters = emphasisDelimiters(in: source)
        let groups = Dictionary(grouping: delimiters) { DelimiterKind(marker: $0.marker, length: $0.length) }
        let recoverable = groups.values.flatMap { group -> [Delimiter] in
            // An odd count cannot be a fully paired run, and a group with no
            // opener or no closer was never emphasis to begin with.
            guard group.count >= 2,
                  group.count.isMultiple(of: 2),
                  group.allSatisfy({ $0.canOpen || $0.canClose }),
                  group.contains(where: \.canOpen),
                  group.contains(where: \.canClose),
                  let first = group.first else { return [] }
            let token = String(repeating: String(first.marker), count: first.length)
            return rendered.contains(token) ? group : []
        }
        guard !recoverable.isEmpty else { return nil }

        var stripped = ""
        var index = source.startIndex
        while index < source.endIndex {
            if let delimiter = recoverable.first(where: { $0.range.lowerBound == index }) {
                index = delimiter.range.upperBound
            } else {
                stripped.append(source[index])
                index = source.index(after: index)
            }
        }

        let repaired = foundationParse(stripped)
        let repairedText = String(repaired.characters)
        let stillLeaking = Set(recoverable.map { String(repeating: String($0.marker), count: $0.length) })
            .contains { repairedText.contains($0) }
        return stillLeaking ? nil : repaired
    }

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

    /// Every `*`/`_` run in the source with CommonMark's left/right-flanking
    /// classification, skipping the two contexts where a marker is not a
    /// delimiter at all: backslash escapes and inline code spans.
    nonisolated private static func emphasisDelimiters(in source: String) -> [Delimiter] {
        var result: [Delimiter] = []
        var index = source.startIndex
        while index < source.endIndex {
            let character = source[index]

            if character == "\\" {
                index = source.index(after: index)
                if index < source.endIndex { index = source.index(after: index) }
                continue
            }

            // A code span is opened and closed by equal-length backtick runs;
            // anything between is literal, so `a*b` must not yield delimiters.
            if character == "`" {
                let runEnd = endOfRun(in: source, from: index, matching: character)
                let token = String(source[index..<runEnd])
                if let closing = source.range(of: token, range: runEnd..<source.endIndex) {
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
            // Runs of three or more are CommonMark's combined strong+emphasis;
            // pairing them up is beyond what this recovery tries to do.
            guard length == 1 || length == 2 else {
                index = runEnd
                continue
            }

            let previous = index > source.startIndex ? source[source.index(before: index)] : nil
            let next = runEnd < source.endIndex ? source[runEnd] : nil
            // Absent neighbours count as whitespace: CommonMark treats the
            // start and end of the line as a space for flanking purposes.
            let previousWhitespace = previous?.isWhitespace ?? true
            let nextWhitespace = next?.isWhitespace ?? true
            let previousPunctuation = isPunctuation(previous)
            let nextPunctuation = isPunctuation(next)
            let leftFlanking = !nextWhitespace && (!nextPunctuation || previousWhitespace || previousPunctuation)
            let rightFlanking = !previousWhitespace && (!previousPunctuation || nextWhitespace || nextPunctuation)
            let canOpen: Bool
            let canClose: Bool
            if character == "_" {
                // `_` cannot open or close intraword, which is why snake_case
                // identifiers survive unstyled.
                canOpen = leftFlanking && (!rightFlanking || previousPunctuation)
                canClose = rightFlanking && (!leftFlanking || nextPunctuation)
            } else {
                canOpen = leftFlanking
                canClose = rightFlanking
            }
            result.append(Delimiter(
                range: index..<runEnd, marker: character, length: length, canOpen: canOpen, canClose: canClose))
            index = runEnd
        }
        return result
    }

    nonisolated private static func endOfRun(
        in source: String, from start: String.Index, matching character: Character
    ) -> String.Index {
        var end = start
        while end < source.endIndex, source[end] == character { end = source.index(after: end) }
        return end
    }

    nonisolated private static func isPunctuation(_ character: Character?) -> Bool {
        guard let character else { return false }
        return character.unicodeScalars.allSatisfy { CharacterSet.punctuationCharacters.contains($0) }
    }
}
