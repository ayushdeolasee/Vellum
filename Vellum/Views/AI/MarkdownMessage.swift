import SwiftUI

struct MarkdownMessage: View {
    let content: String
    /// Color used for typeset math images, which can't inherit `foregroundStyle`
    /// the way text does. Pass the bubble's text color.
    var textColor: Color = .primary
    /// Body text size; headings/display math sit 2pt above, code/tables 2pt
    /// below. Defaults to the AI chat bubble size.
    var baseSize: CGFloat = 14
    /// Widest a display equation may be drawn before it scales down. The AI
    /// panel passes the live bubble width so equations grow with the resizable
    /// sidebar; fixed-width callers (notes, annotation sidebar) keep the default.
    var mathMaxWidth: CGFloat = 240
    /// Whether the message stretches to fill whatever width it is offered.
    /// The fixed-width hosts depend on it — sticky notes, the annotation
    /// sidebar and web note popovers all left-align their text inside a card
    /// whose width the card decides, not the text — so it stays the default.
    /// The AI panel's user bubbles opt out: a bubble has to hug its content,
    /// or a one-word message paints a tinted slab across a 700pt sidebar.
    var fillsAvailableWidth = true

    @Environment(\.palette) private var palette

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                blockView(block)
            }
        }
        .frame(maxWidth: fillsAvailableWidth ? .infinity : nil, alignment: .leading)
        .textSelection(.enabled)
    }

    @ViewBuilder
    private func blockView(_ block: MarkdownBlock) -> some View {
        switch block {
        case .heading(let level, let text):
            // Only `#` gets its own size; a 272pt-wide bubble has no room for a
            // six-step type scale, so `##` and deeper lean on weight alone.
            inlineText(text)
                .font(.system(size: level == 1 ? baseSize + 2 : baseSize, weight: .semibold))
                .padding(.top, level >= 3 ? 8 : 12)
                .padding(.bottom, level >= 3 ? 6 : 8)
        case .paragraph(let text):
            inlineText(text)
                .font(.system(size: baseSize))
                .lineSpacing(3)
                .padding(.bottom, 8)
        case .list(let items):
            VStack(alignment: .leading, spacing: 4) {
                ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                    HStack(alignment: .firstTextBaseline, spacing: 7) {
                        Text(item.marker.label)
                            // The glyph is decoration; `accessibilityLabel`
                            // below speaks the item's kind and number instead.
                            .accessibilityHidden(true)
                        inlineText(item.text).lineSpacing(3)
                    }
                    .padding(.leading, item.indent)
                    // Without this the bullet and the text are two separate
                    // VoiceOver stops, and the depth is inaudible.
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel(item.accessibilityLabel)
                }
            }
            .font(.system(size: baseSize))
            .padding(.leading, 12)
            .padding(.bottom, 8)
        case .quote(let text):
            HStack(spacing: 10) {
                Rectangle().fill(palette.border.opacity(0.6)).frame(width: 2)
                inlineText(text).italic().lineSpacing(3)
            }
            .font(.system(size: baseSize))
            .padding(.bottom, 8)
        case .code(let text):
            ScrollView(.horizontal) {
                Text(text)
                    .font(.system(size: baseSize - 2, design: .monospaced))
                    .padding(8)
            }
            .background(Color.black.opacity(0.15))
            .clipShape(RoundedRectangle(cornerRadius: Radius.sm))
            .overlay { RoundedRectangle(cornerRadius: Radius.sm).stroke(palette.border.opacity(0.6)) }
            .padding(.bottom, 8)
        case .table(let text):
            ScrollView(.horizontal) {
                Text(text)
                    .font(.system(size: baseSize - 2, design: .monospaced))
                    .padding(.vertical, 4)
            }
            .padding(.bottom, 8)
        case .math(let latex):
            mathBlockView(latex)
        case .rule:
            Rectangle()
                .fill(palette.border)
                .frame(height: 1)
                .padding(.vertical, 4)
                .padding(.bottom, 8)
                // Decorative: the surrounding headings already convey the split.
                .accessibilityHidden(true)
        }
    }

    /// Display equation, typeset and centered; falls back to monospaced source
    /// when the LaTeX doesn't parse.
    @ViewBuilder
    private func mathBlockView(_ latex: String) -> some View {
        if let rendered = MathRenderer.render(
            latex: latex, fontSize: baseSize + 2, color: NSColor(textColor), display: true
        ) {
            // Wide equations scale down to the bubble instead of overflowing.
            Image(nsImage: rendered.image)
                .resizable()
                .scaledToFit()
                .frame(
                    maxWidth: min(rendered.size.width, mathMaxWidth),
                    maxHeight: rendered.size.height,
                    alignment: .center
                )
                .frame(maxWidth: .infinity, alignment: .center)
                .accessibilityLabel(latex)
                .padding(.vertical, 2)
                .padding(.bottom, 8)
        } else {
            Text(latex)
                .font(.system(size: baseSize - 2, design: .monospaced))
                .padding(.bottom, 8)
        }
    }

    private func inlineText(_ source: String) -> Text {
        // Math spans become typeset images interpolated into the Text run;
        // everything else is styled by native AttributedString markdown
        // (emphasis, strong, inline code, strikethrough, links).
        //
        // `InlineMarkdown` resolves that markdown across the WHOLE line before
        // splitting the math back out, so emphasis that straddles an equation
        // ("**the probability of $Y$ given $X$**") stays bold instead of
        // leaking literal asterisks. Keep this in step with
        // `AiAttributedRenderer.inline`, which renders the same pieces in AppKit.
        var result = Text(verbatim: "")
        for piece in InlineMarkdown.pieces(in: source) {
            switch piece {
            case .prose(let attributed):
                result = result + Text(attributed)
            case .math(let latex):
                if let rendered = MathRenderer.render(
                    latex: latex, fontSize: baseSize, color: NSColor(textColor), display: false
                ) {
                    // VoiceOver reads the LaTeX source; the image itself carries
                    // no text, and it's interpolated into a Text run so a SwiftUI
                    // .accessibilityLabel can't reach it.
                    rendered.image.accessibilityDescription = latex
                    result = result + Text(Image(nsImage: rendered.image))
                        .baselineOffset(-rendered.descent)
                } else {
                    result = result + Text("$\(latex)$").italic()
                }
            }
        }
        return result
    }

    private var blocks: [MarkdownBlock] {
        MarkdownParser.parse(content)
    }
}

// Exposed (not private) so the AppKit selectable renderer in
// SelectableMessageText.swift can reuse the exact same block parsing.
enum MarkdownBlock: Equatable {
    case heading(Int, String)
    case paragraph(String)
    /// A run of consecutive list lines, bullets and numbers together. One case
    /// rather than separate `.unordered`/`.ordered` ones because a model's list
    /// routinely mixes the two across nesting levels ("2. …" with "- …"
    /// children), and splitting them threw the nesting away.
    case list([MarkdownListItem])
    case quote(String)
    case code(String)
    case table(String)
    /// Display math: the LaTeX between `$$...$$` or `\[...\]` delimiters.
    case math(String)
    /// A thematic break — a `---`, `***` or `___` line. Without this case the
    /// line fell through to `.paragraph` and the dashes rendered literally
    /// (issue #57); models emit them constantly as section separators.
    case rule
}

/// One line of a list, with the nesting the parser recovered from its indent.
struct MarkdownListItem: Equatable {
    enum Marker: Equatable {
        case unordered
        /// The number to *display*, which is not always the one the model
        /// wrote — see `MarkdownParser.listItems`.
        case ordered(Int)

        var label: String {
            switch self {
            case .unordered: "•"
            case .ordered(let number): "\(number)."
            }
        }
    }

    /// 0 for a top-level item, 1 for its children, and so on.
    let depth: Int
    let marker: Marker
    let text: String

    /// Leading inset for this item's row.
    ///
    /// Capped: an assistant bubble is 272pt wide, so past three levels the
    /// indent costs more legibility than the nesting conveys. `depth` itself is
    /// left uncapped so `accessibilityLabel` can still announce the real level.
    var indent: CGFloat { CGFloat(min(depth, 3)) * 16 }

    /// Spoken as one utterance per row — the marker glyph on its own is
    /// meaningless, and visual indentation is invisible to VoiceOver.
    var accessibilityLabel: String {
        let kind = switch marker {
        case .unordered: "List item"
        case .ordered(let number): "Item \(number)"
        }
        let readable = MarkdownParser.plainPreview(text)
        return depth == 0 ? "\(kind), \(readable)" : "\(kind), level \(depth + 1), \(readable)"
    }
}

enum MarkdownParser {
    /// One-line plain-text preview: strips block markers, inline emphasis, and
    /// math delimiters for surfaces (collapsed pills, tooltips) that can't
    /// render markdown.
    static func plainPreview(_ source: String) -> String {
        // Strip display-math delimiters first: MathRenderer.segments only
        // understands inline `$...$`, so for "$$E=mc^2$$" it consumes the inner
        // "$E=mc^2$" and leaves stray outer dollars that the later delimiter
        // replacement can't remove. Unwrap $$...$$ and \[...\] to their bodies
        // up front (dot matches newlines for multi-line display blocks).
        let unwrapped = source
            .replacingOccurrences(of: #"(?s)\$\$(.+?)\$\$"#, with: "$1", options: .regularExpression)
            .replacingOccurrences(of: #"(?s)\\\[(.+?)\\\]"#, with: "$1", options: .regularExpression)
        // Inline math: same definition as the renderers (MathRenderer.segments),
        // so "$5 and $10" stays currency in the pill exactly as it renders in
        // the note body, while "$x^2$" strips to its LaTeX body.
        var text = unwrapped.components(separatedBy: .newlines).map { line in
            MathRenderer.segments(in: line).map { segment in
                switch segment {
                case .text(let t): return t
                case .math(let latex): return latex
                }
            }.joined()
        }.joined(separator: "\n")
        for pattern in [
            #"(?m)^#{1,6}\s+"#,       // headings
            // Thematic breaks, stripped before the emphasis pass below would
            // chew "***" down to a stray "*".
            #"(?m)^[ \t]*(?:-[ \t]*){3,}$|^[ \t]*(?:\*[ \t]*){3,}$|^[ \t]*(?:_[ \t]*){3,}$"#,
            #"(?m)^>\s?"#,            // quotes
            // Bullets and ordered markers, indented or not, so a nested item's
            // leading "- " does not survive into the pill. Kept in step with
            // `listItem(_:)`, which accepts the same two marker shapes.
            #"(?m)^[ \t]*[-*+]\s+"#,   // bullets
            #"(?m)^[ \t]*\d+[.)]\s+"#, // ordered lists
            "```[a-zA-Z]*",           // code fences
            #"\*\*|\*|__|`|\$\$|\\\[|\\\]"#, // emphasis + display-math delimiters
        ] {
            text = text.replacingOccurrences(of: pattern, with: "", options: .regularExpression)
        }
        return text
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
    }

    static func parse(_ source: String) -> [MarkdownBlock] {
        let lines = source.components(separatedBy: .newlines)
        var blocks: [MarkdownBlock] = []
        var index = 0
        while index < lines.count {
            let line = lines[index]
            if line.trimmingCharacters(in: .whitespaces).isEmpty { index += 1; continue }

            if line.hasPrefix("```") {
                index += 1
                var code: [String] = []
                while index < lines.count, !lines[index].hasPrefix("```") {
                    code.append(lines[index]); index += 1
                }
                if index < lines.count { index += 1 }
                blocks.append(.code(code.joined(separator: "\n")))
                continue
            }
            if line.hasPrefix("$$") || line.hasPrefix("\\[") {
                let close = line.hasPrefix("$$") ? "$$" : "\\]"
                var math = String(line.dropFirst(2))
                var closed = false
                if math.hasSuffix(close), !math.isEmpty {
                    math = String(math.dropLast(2)); index += 1; closed = true
                } else {
                    index += 1
                    var parts = [math]
                    while index < lines.count, !lines[index].hasSuffix(close) {
                        parts.append(lines[index]); index += 1
                    }
                    if index < lines.count {
                        parts.append(String(lines[index].dropLast(2))); index += 1; closed = true
                    }
                    math = parts.joined(separator: "\n")
                }
                // The `$$\n…\n$$` shape leaves the delimiters' own newlines inside
                // the body. `MathRenderer` trims before typesetting, but the
                // fallbacks that show unparseable LaTeX as monospaced source do
                // not — they rendered those newlines as blank lines above and
                // below the equation. Trim once, here, so every consumer agrees.
                let body = math.trimmingCharacters(in: .whitespacesAndNewlines)
                // Still-open block (mid-stream): typesetting a partial equation is a
                // guaranteed MathRenderer cache miss per token — show it as code until
                // the closing delimiter arrives (same treatment as an unterminated
                // code fence above).
                blocks.append(closed ? .math(body) : .code(body))
                continue
            }
            // Before the list check: `* * *` is a thematic break, but its first
            // two characters also look like a `* ` bullet.
            if isRule(line) { blocks.append(.rule); index += 1; continue }
            if let heading = heading(line) { blocks.append(heading); index += 1; continue }
            if line.hasPrefix(">") {
                var quoted: [String] = []
                while index < lines.count, lines[index].hasPrefix(">") {
                    quoted.append(lines[index].dropFirst().trimmingCharacters(in: .whitespaces)); index += 1
                }
                blocks.append(.quote(quoted.joined(separator: "\n")))
                continue
            }
            if listLine(line) != nil {
                var run: [RawListLine] = []
                while index < lines.count, let raw = listLine(lines[index]) {
                    run.append(raw); index += 1
                }
                blocks.append(.list(listItems(run))); continue
            }
            if line.contains("|"), index + 1 < lines.count, isTableSeparator(lines[index + 1]) {
                var rows = [line]
                index += 2
                while index < lines.count, lines[index].contains("|"), !lines[index].isEmpty {
                    rows.append(lines[index]); index += 1
                }
                blocks.append(.table(formatTable(rows))); continue
            }

            var paragraph = [line]
            index += 1
            while index < lines.count, !lines[index].trimmingCharacters(in: .whitespaces).isEmpty,
                  !startsBlock(lines[index]) {
                paragraph.append(lines[index]); index += 1
            }
            blocks.append(.paragraph(paragraph.joined(separator: "\n")))
        }
        return blocks
    }

    /// Markdown defines six heading levels. Only `#`…`###` used to be
    /// recognized, so a `####` line rendered its hashes literally (issue #57).
    /// Deepest-first so `###` isn't matched as `##` followed by a stray `#`.
    private static func heading(_ line: String) -> MarkdownBlock? {
        for level in stride(from: 6, through: 1, by: -1) {
            let prefix = String(repeating: "#", count: level) + " "
            guard line.hasPrefix(prefix) else { continue }
            let text = String(line.dropFirst(prefix.count))
            // Mid-stream the marker arrives before its text. An empty heading
            // renders as a zero-height block, so the reply appears to lose its
            // last line until the next token lands; leave "## " as a paragraph
            // until there is something to head.
            guard !text.isEmpty else { return nil }
            return .heading(level, text)
        }
        return nil
    }

    /// A thematic break: three or more `-`, `*` or `_`, all the same character,
    /// alone on the line apart from spaces.
    ///
    /// Note this claims `---` even when it directly follows a paragraph line,
    /// where CommonMark would instead read the pair as a setext `##` heading.
    /// Models use `---` as a section separator far more often than they use
    /// setext headings, and a rule is the safer reading of an ambiguous line.
    private static func isRule(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard let marker = trimmed.first, "-*_".contains(marker) else { return false }
        let markers = trimmed.filter { !$0.isWhitespace }
        return markers.count >= 3 && markers.allSatisfy { $0 == marker }
    }

    /// One list line before nesting is resolved: its indent measured in
    /// columns, the marker the model wrote, and the item text.
    private struct RawListLine {
        let column: Int
        /// `nil` for a bullet; the literal number for an ordered marker.
        let number: Int?
        let text: String
    }

    /// Match a single list line, indented or not, with either a `-`/`*`/`+`
    /// bullet or an `N.`/`N)` ordered marker.
    ///
    /// Indent used to be rejected outright (`hasPrefix("- ")`), so a nested
    /// item fell through to `.paragraph` and rendered its own `- ` literally —
    /// the follow-up defect reported on this PR.
    private static func listLine(_ line: String) -> RawListLine? {
        guard let match = line.wholeMatch(of: /^([ \t]*)([-+*]|\d+[.)])[ \t]+(.+)$/) else { return nil }
        // A tab indents to the next 4-column stop in every renderer models are
        // trained against; treating it as one column would flatten tab-nested
        // lists.
        let column = match.1.reduce(into: 0) { $0 += $1 == "\t" ? 4 : 1 }
        return RawListLine(column: column, number: Int(String(match.2).dropLast()), text: String(match.3))
    }

    /// Resolve a run of list lines into depths and display numbers.
    ///
    /// Depth comes from a stack of indent columns rather than dividing the
    /// column count by a fixed step: models indent children by two spaces, four
    /// spaces or a tab depending on the model and the surrounding text, and any
    /// fixed divisor renders one of those conventions at the wrong depth.
    ///
    /// Numbering follows CommonMark: only the first marker of an ordered level
    /// is honoured and the rest of that level counts up from it. Models very
    /// often emit `1.` for every item, which must still read 1, 2, 3 — but a
    /// list that genuinely starts at `3.` must start at 3.
    private static func listItems(_ run: [RawListLine]) -> [MarkdownListItem] {
        var columns: [Int] = []      // indent column of each currently open level
        var counters: [Int: Int] = [:] // depth -> next number to display
        var items: [MarkdownListItem] = []

        for raw in run {
            while let last = columns.last, raw.column < last {
                counters[columns.count - 1] = nil
                columns.removeLast()
            }
            if columns.last != raw.column { columns.append(raw.column) }
            let depth = columns.count - 1

            let marker: MarkdownListItem.Marker
            if let number = raw.number {
                let display = counters[depth] ?? number
                counters[depth] = display + 1
                marker = .ordered(display)
            } else {
                // A bullet breaks the ordered sequence at this level, so the
                // next number after it restarts from what the model wrote.
                counters[depth] = nil
                marker = .unordered
            }
            items.append(MarkdownListItem(depth: depth, marker: marker, text: raw.text))
        }
        return items
    }

    private static func isTableSeparator(_ line: String) -> Bool {
        line.range(of: #"^\s*\|?\s*:?-{3,}:?"#, options: .regularExpression) != nil
    }

    private static func startsBlock(_ line: String) -> Bool {
        line.hasPrefix("```") || line.hasPrefix("$$") || line.hasPrefix("\\[") || line.hasPrefix(">")
            || heading(line) != nil || listLine(line) != nil || isRule(line)
    }

    private static func formatTable(_ rows: [String]) -> String {
        let cells = rows.map { row in
            row.trimmingCharacters(in: CharacterSet(charactersIn: "| "))
                .split(separator: "|", omittingEmptySubsequences: false)
                .map { $0.trimmingCharacters(in: .whitespaces) }
        }
        let columns = cells.map(\.count).max() ?? 0
        let widths = (0..<columns).map { column in
            cells.compactMap { column < $0.count ? $0[column].count : nil }.max() ?? 0
        }
        return cells.map { row in
            row.enumerated().map { column, cell in cell.padding(toLength: widths[column], withPad: " ", startingAt: 0) }
                .joined(separator: " | ")
        }.joined(separator: "\n")
    }
}
