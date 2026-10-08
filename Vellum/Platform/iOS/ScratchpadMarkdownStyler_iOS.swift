#if os(iOS)
import UIKit

/// Format the source in place: native text input and undo keep the same UTF-16
/// positions while inactive paragraphs hide Markdown punctuation. The paragraph
/// being edited reveals its source, just like the previous live-preview editor.
@MainActor
final class ScratchpadMarkdownStyler {
    private var cachedSource = ""
    private var cachedParse: AttributedString?
    private static let mathRegex = try? NSRegularExpression(pattern:
        #"\$\$([\s\S]+?)\$\$|\\\[([\s\S]+?)\\\]|\\\((.+?)\\\)|\$(?![\s$])([^$\n]*[^\s$])\$"#)

    func apply(to storage: NSTextStorage, selection: NSRange?, font: UIFont, color: UIColor, width: CGFloat) {
        let source = Self.source(in: storage)
        let ns = source as NSString
        let all = NSRange(location: 0, length: ns.length)
        guard all.length > 0 else { return }
        var oldMath: [(NSRange, String)] = []
        storage.enumerateAttribute(.attachment, in: all) { value, range, _ in
            if let math = value as? ScratchpadMathAttachment { oldMath.append((range, math.openingCharacter)) }
        }
        storage.beginEditing()
        defer { storage.endEditing() }
        for (range, character) in oldMath {
            storage.replaceCharacters(in: range, with: character)
            storage.removeAttribute(.attachment, range: range)
        }
        for key: NSAttributedString.Key in [.backgroundColor, .strikethroughStyle, .link, .kern, .baselineOffset] {
            storage.removeAttribute(key, range: all)
        }
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = 3
        storage.addAttributes([.font: font, .foregroundColor: color, .paragraphStyle: paragraph], range: all)
        if source != cachedSource || cachedParse == nil {
            cachedSource = source
            cachedParse = try? AttributedString(markdown: source, options: .init(
                interpretedSyntax: .full, failurePolicy: .returnPartiallyParsedIfPossible,
                appliesSourcePositionAttributes: true))
        }
        guard let parsed = cachedParse else { return }
        let active = selection.map { ns.paragraphRange(for: NSRange(location: min($0.location, ns.length),
                                                                  length: min($0.length, ns.length - min($0.location, ns.length)))) }
        var visible = Array(repeating: false, count: ns.length)
        var codeRanges: [NSRange] = []
        for run in parsed.runs {
            guard let position = run.markdownSourcePosition, let range = Range(position, in: source) else { continue }
            let span = NSRange(range, in: source)
            guard NSMaxRange(span) <= ns.length else { continue }
            for index in span.location..<NSMaxRange(span) { visible[index] = true }
            var size = font.pointSize
            var traits: UIFontDescriptor.SymbolicTraits = []
            var code = run.inlinePresentationIntent?.contains(.code) == true
            if run.inlinePresentationIntent?.contains(.stronglyEmphasized) == true { traits.insert(.traitBold) }
            if run.inlinePresentationIntent?.contains(.emphasized) == true { traits.insert(.traitItalic) }
            if run.inlinePresentationIntent?.contains(.strikethrough) == true {
                storage.addAttribute(.strikethroughStyle, value: NSUnderlineStyle.single.rawValue, range: span)
            }
            for component in run.presentationIntent?.components ?? [] {
                switch component.kind {
                case .header(let level):
                    size += level == 1 ? 6 : 2
                    traits.insert(.traitBold)
                case .codeBlock: code = true
                case .tableCell: code = true
                case .blockQuote:
                    storage.addAttribute(.foregroundColor, value: UIColor.secondaryLabel, range: span)
                default: break
                }
            }
            var styledFont = code ? UIFont.monospacedSystemFont(ofSize: size, weight: .regular) : font.withSize(size)
            if code { traits.insert(.traitMonoSpace) }
            if let descriptor = styledFont.fontDescriptor.withSymbolicTraits(traits) {
                styledFont = UIFont(descriptor: descriptor, size: size)
            }
            storage.addAttribute(.font, value: styledFont, range: span)
            if code {
                codeRanges.append(span)
                storage.addAttribute(.backgroundColor, value: UIColor.secondarySystemBackground, range: span)
            }
            if let link = run.link { storage.addAttribute(.link, value: link, range: span) }
        }
        // List markers and pipe tables remain readable source decorations.
        // Newlines always keep their native layout and caret positions.
        var offset = 0
        for line in source.components(separatedBy: "\n") {
            let length = (line as NSString).length
            if line.range(of: #"^\s*(?:[-*+] |\d+[.)] |>)"#, options: .regularExpression) != nil || line.contains("|") {
                for index in offset..<offset + length { visible[index] = true }
            }
            offset += length + 1
        }
        var index = 0
        while index < ns.length {
            let shouldHide = !visible[index] && ns.character(at: index) != 10 && ns.character(at: index) != 13
                && (active == nil || !NSLocationInRange(index, active!))
                && storage.attribute(.attachment, at: index, effectiveRange: nil) == nil
            guard shouldHide else { index += 1; continue }
            let start = index
            repeat { index += 1 } while index < ns.length && !visible[index] && ns.character(at: index) != 10
                && ns.character(at: index) != 13 && (active == nil || !NSLocationInRange(index, active!))
                && storage.attribute(.attachment, at: index, effectiveRange: nil) == nil
            storage.addAttributes([.font: UIFont.systemFont(ofSize: 0.01), .foregroundColor: UIColor.clear],
                                  range: NSRange(location: start, length: index - start))
        }
        // The attachment occupies the opening delimiter only. Its remaining
        // source stays in place, collapsed visually, so editing and Scribble
        // never need a second document or a source-to-preview cursor map.
        guard let regex = Self.mathRegex else { return }
        for match in regex.matches(in: source, range: all) {
            guard !codeRanges.contains(where: { NSIntersectionRange($0, match.range).length > 0 }),
                  active == nil || NSIntersectionRange(active!, match.range).length == 0,
                  !Self.isEscaped(match.range.location, in: ns) else { continue }
            let content = (1...4).map { match.range(at: $0) }.first { $0.location != NSNotFound }!
            let display = match.range(at: 1).location != NSNotFound || match.range(at: 2).location != NSNotFound
            guard let rendered = MathRenderer.render(latex: ns.substring(with: content), fontSize: font.pointSize,
                                                     color: color, display: display) else { continue }
            let math = ScratchpadMathAttachment()
            math.openingCharacter = ns.substring(with: NSRange(location: match.range.location, length: 1))
            math.image = rendered.image
            math.allowsTextAttachmentView = false
            let scale = min(1, width / max(1, rendered.size.width))
            math.bounds = CGRect(x: 0, y: -rendered.descent * scale,
                                 width: rendered.size.width * scale, height: rendered.size.height * scale)
            storage.addAttributes([.font: UIFont.systemFont(ofSize: 0.01), .foregroundColor: UIColor.clear], range: match.range)
            storage.replaceCharacters(in: NSRange(location: match.range.location, length: 1),
                                      with: NSAttributedString(attachment: math))
        }
    }

    static func source(in text: NSAttributedString) -> String {
        let source = NSMutableString(string: text.string)
        text.enumerateAttribute(.attachment, in: NSRange(location: 0, length: text.length)) { value, range, _ in
            if let math = value as? ScratchpadMathAttachment { source.replaceCharacters(in: range, with: math.openingCharacter) }
        }
        return source as String
    }

    private static func isEscaped(_ location: Int, in source: NSString) -> Bool {
        var count = 0
        var index = location - 1
        while index >= 0, source.character(at: index) == 92 { count += 1; index -= 1 }
        return count % 2 == 1
    }
}

final class ScratchpadMathAttachment: NSTextAttachment {
    var openingCharacter = "$"
}
#endif
