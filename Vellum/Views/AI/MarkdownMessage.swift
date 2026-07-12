import SwiftUI

struct MarkdownMessage: View {
    let content: String
    /// Color used for typeset math images, which can't inherit `foregroundStyle`
    /// the way text does. Pass the bubble's text color.
    var textColor: Color = .primary
    /// Body text size; headings/display math sit 2pt above, code/tables 2pt
    /// below. Defaults to the AI chat bubble size.
    var baseSize: CGFloat = 14

    @Environment(\.palette) private var palette

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                blockView(block)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .textSelection(.enabled)
    }

    @ViewBuilder
    private func blockView(_ block: MarkdownBlock) -> some View {
        switch block {
        case .heading(let level, let text):
            inlineText(text)
                .font(.system(size: level == 1 ? baseSize + 2 : baseSize, weight: .semibold))
                .padding(.top, level == 3 ? 8 : 12)
                .padding(.bottom, level == 3 ? 6 : 8)
        case .paragraph(let text):
            inlineText(text)
                .font(.system(size: baseSize))
                .lineSpacing(3)
                .padding(.bottom, 8)
        case .unordered(let items):
            VStack(alignment: .leading, spacing: 4) {
                ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                    HStack(alignment: .firstTextBaseline, spacing: 7) {
                        Text("•")
                        inlineText(item).lineSpacing(3)
                    }
                }
            }
            .padding(.leading, 12)
            .padding(.bottom, 8)
        case .ordered(let items):
            VStack(alignment: .leading, spacing: 4) {
                ForEach(Array(items.enumerated()), id: \.offset) { index, item in
                    HStack(alignment: .firstTextBaseline, spacing: 7) {
                        Text("\(index + 1).")
                        inlineText(item).lineSpacing(3)
                    }
                }
            }
            .padding(.leading, 12)
            .padding(.bottom, 8)
        case .quote(let text):
            HStack(spacing: 10) {
                Rectangle().fill(palette.border.opacity(0.6)).frame(width: 2)
                inlineText(text).italic().lineSpacing(3)
            }
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
                    maxWidth: min(rendered.size.width, 240),
                    maxHeight: rendered.size.height,
                    alignment: .center
                )
                .frame(maxWidth: .infinity, alignment: .center)
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
        // everything else goes through native AttributedString markdown
        // (emphasis, strong, inline code, strikethrough, links).
        var result = Text(verbatim: "")
        for segment in MathRenderer.segments(in: source) {
            switch segment {
            case .text(let text):
                let attributed = (try? AttributedString(
                    markdown: text,
                    options: AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
                )) ?? AttributedString(text)
                result = result + Text(attributed)
            case .math(let latex):
                if let rendered = MathRenderer.render(
                    latex: latex, fontSize: baseSize, color: NSColor(textColor), display: false
                ) {
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
    case unordered([String])
    case ordered([String])
    case quote(String)
    case code(String)
    case table(String)
    /// Display math: the LaTeX between `$$...$$` or `\[...\]` delimiters.
    case math(String)
}

enum MarkdownParser {
    /// One-line plain-text preview: strips block markers, inline emphasis, and
    /// math delimiters for surfaces (collapsed pills, tooltips) that can't
    /// render markdown.
    static func plainPreview(_ source: String) -> String {
        var text = source
        for pattern in [
            #"(?m)^#{1,3}\s+"#,       // headings
            #"(?m)^>\s?"#,            // quotes
            #"(?m)^[-*+]\s+"#,        // bullets
            #"(?m)^\d+\.\s+"#,        // ordered lists
            "```[a-zA-Z]*",           // code fences
            #"\*\*|\*|__|`|\\\[|\\\]|\\\(|\\\)|\$\$|\$"#, // emphasis + math delimiters
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
                if math.hasSuffix(close), !math.isEmpty { math = String(math.dropLast(2)); index += 1 }
                else {
                    index += 1
                    var parts = [math]
                    while index < lines.count, !lines[index].hasSuffix(close) {
                        parts.append(lines[index]); index += 1
                    }
                    if index < lines.count { parts.append(String(lines[index].dropLast(2))); index += 1 }
                    math = parts.joined(separator: "\n")
                }
                blocks.append(.math(math))
                continue
            }
            if let heading = heading(line) { blocks.append(heading); index += 1; continue }
            if line.hasPrefix(">") {
                var quoted: [String] = []
                while index < lines.count, lines[index].hasPrefix(">") {
                    quoted.append(lines[index].dropFirst().trimmingCharacters(in: .whitespaces)); index += 1
                }
                blocks.append(.quote(quoted.joined(separator: "\n")))
                continue
            }
            if isUnordered(line) {
                var items: [String] = []
                while index < lines.count, isUnordered(lines[index]) {
                    items.append(String(lines[index].dropFirst(2))); index += 1
                }
                blocks.append(.unordered(items)); continue
            }
            if orderedText(line) != nil {
                var items: [String] = []
                while index < lines.count, let item = orderedText(lines[index]) {
                    items.append(item); index += 1
                }
                blocks.append(.ordered(items)); continue
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

    private static func heading(_ line: String) -> MarkdownBlock? {
        for level in 1...3 {
            let prefix = String(repeating: "#", count: level) + " "
            if line.hasPrefix(prefix) { return .heading(level, String(line.dropFirst(prefix.count))) }
        }
        return nil
    }

    private static func isUnordered(_ line: String) -> Bool {
        line.hasPrefix("- ") || line.hasPrefix("* ") || line.hasPrefix("+ ")
    }

    private static func orderedText(_ line: String) -> String? {
        guard let range = line.range(of: #"^\d+\.\s+"#, options: .regularExpression) else { return nil }
        return String(line[range.upperBound...])
    }

    private static func isTableSeparator(_ line: String) -> Bool {
        line.range(of: #"^\s*\|?\s*:?-{3,}:?"#, options: .regularExpression) != nil
    }

    private static func startsBlock(_ line: String) -> Bool {
        line.hasPrefix("```") || line.hasPrefix("$$") || line.hasPrefix("\\[") || line.hasPrefix(">")
            || heading(line) != nil || isUnordered(line) || orderedText(line) != nil
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
