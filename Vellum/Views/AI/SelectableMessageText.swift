import AppKit
import SwiftUI

// Assistant-message renderer backed by an NSTextView so the user can select any
// substring of a reply and quote it back into the composer (the floating "Quote"
// button in the reference design). Reuses `MarkdownParser` for block structure
// and flattens each block into one NSAttributedString styled to match the
// SwiftUI `MarkdownMessage` renderer used for user messages.

struct SelectableMessageText: NSViewRepresentable {
    let content: String
    /// Base text color (the assistant bubble's foreground).
    var color: Color
    /// Secondary color for the blockquote bar / muted glyphs.
    var secondary: Color
    /// Called with the selected substring when the user taps the Quote button.
    var onQuote: (String) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onQuote: onQuote) }

    func makeNSView(context: Context) -> MessageContainerView {
        let container = MessageContainerView()
        container.textView.delegate = context.coordinator
        context.coordinator.container = container
        container.onQuoteTapped = { [weak coordinator = context.coordinator] in
            coordinator?.quoteCurrentSelection()
        }
        return container
    }

    func updateNSView(_ view: MessageContainerView, context: Context) {
        context.coordinator.onQuote = onQuote
        let attributed = AiAttributedRenderer.attributedString(
            for: content,
            color: NSColor(color),
            secondary: NSColor(secondary)
        )
        if view.textView.textStorage?.string != attributed.string
            || view.textView.textStorage?.length != attributed.length {
            view.setAttributed(attributed)
        }
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: MessageContainerView, context: Context) -> CGSize? {
        let width = proposal.width ?? 248
        let clamped = min(max(width, 80), 248)
        return CGSize(width: clamped, height: nsView.height(forWidth: clamped))
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var onQuote: (String) -> Void
        weak var container: MessageContainerView?

        init(onQuote: @escaping (String) -> Void) { self.onQuote = onQuote }

        func textViewDidChangeSelection(_ notification: Notification) {
            container?.updateQuoteButton()
        }

        func quoteCurrentSelection() {
            guard let textView = container?.textView else { return }
            let range = textView.selectedRange()
            guard range.length > 0 else { return }
            let text = (textView.string as NSString).substring(with: range)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return }
            onQuote(text)
            textView.setSelectedRange(NSRange(location: 0, length: 0))
            container?.updateQuoteButton()
        }
    }
}

/// Flipped container hosting the read-only text view plus the floating Quote
/// button. Flipped so button/selection math shares the text view's top-left
/// origin.
final class MessageContainerView: NSView {
    let textView: NSTextView
    private let quoteButton = QuoteButton()
    var onQuoteTapped: (() -> Void)?

    override var isFlipped: Bool { true }

    override init(frame frameRect: NSRect) {
        textView = NSTextView()
        super.init(frame: frameRect)
        configureTextView()
        quoteButton.isHidden = true
        quoteButton.onTap = { [weak self] in self?.onQuoteTapped?() }
        addSubview(textView)
        addSubview(quoteButton)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    private func configureTextView() {
        textView.isEditable = false
        textView.isSelectable = true
        textView.drawsBackground = false
        textView.textContainerInset = .zero
        textView.textContainer?.lineFragmentPadding = 0
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.textContainer?.widthTracksTextView = true
        textView.autoresizingMask = []
    }

    private(set) var attributed = NSAttributedString()

    func setAttributed(_ attributed: NSAttributedString) {
        self.attributed = attributed
        textView.textStorage?.setAttributedString(attributed)
        needsLayout = true
    }

    /// Height for a proposed width. Measured on a THROWAWAY layout manager, never
    /// the live text view: SwiftUI calls `sizeThatFits` from inside AppKit's
    /// layout pass, and driving `ensureLayout` on the on-screen view there
    /// tripped "-ensureLayoutForTextContainer while already performing layout".
    func height(forWidth width: CGFloat) -> CGFloat {
        Self.measureHeight(attributed, width: max(1, width))
    }

    static func measureHeight(_ attributed: NSAttributedString, width: CGFloat) -> CGFloat {
        guard attributed.length > 0 else { return 0 }
        let storage = NSTextStorage(attributedString: attributed)
        let container = NSTextContainer(size: NSSize(width: width, height: .greatestFiniteMagnitude))
        container.lineFragmentPadding = 0
        let layout = NSLayoutManager()
        layout.addTextContainer(container)
        storage.addLayoutManager(layout)
        layout.ensureLayout(for: container)
        let height = layout.usedRect(for: container).height
        return height.isFinite ? ceil(height) : 0
    }

    override func layout() {
        super.layout()
        textView.frame = bounds
        updateQuoteButton()
    }

    /// Position the Quote button at the trailing top of the current selection,
    /// or hide it when nothing is selected.
    func updateQuoteButton() {
        let range = textView.selectedRange()
        guard range.length > 0,
              let container = textView.textContainer,
              let layout = textView.layoutManager else {
            quoteButton.isHidden = true
            return
        }
        let glyphRange = layout.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
        var rect = layout.boundingRect(forGlyphRange: glyphRange, in: container)
        let origin = textView.textContainerOrigin
        rect.origin.x += origin.x
        rect.origin.y += origin.y

        quoteButton.isHidden = false
        quoteButton.fitToContent()
        let size = quoteButton.frame.size
        let x = min(max(0, rect.maxX - size.width), bounds.width - size.width)
        let y = max(0, rect.minY - size.height - 2)
        quoteButton.frame = NSRect(x: x, y: y, width: size.width, height: size.height)
    }
}

/// Small dark capsule "❝ Quote" affordance drawn in AppKit so it tracks the
/// selection inside the scroll view without SwiftUI-overlay gymnastics.
final class QuoteButton: NSView {
    var onTap: (() -> Void)?
    private let title = "Quote"

    override var isFlipped: Bool { true }

    func fitToContent() {
        let textSize = (title as NSString).size(withAttributes: attributes)
        frame.size = NSSize(width: ceil(textSize.width) + 34, height: 22)
    }

    private var attributes: [NSAttributedString.Key: Any] {
        [
            .font: NSFont.systemFont(ofSize: 11, weight: .medium),
            .foregroundColor: NSColor.white,
        ]
    }

    override func draw(_ dirtyRect: NSRect) {
        let path = NSBezierPath(roundedRect: bounds, xRadius: bounds.height / 2, yRadius: bounds.height / 2)
        NSColor.black.withAlphaComponent(0.82).setFill()
        path.fill()
        let glyph = "\u{201D}" as NSString
        glyph.draw(at: NSPoint(x: 9, y: 3), withAttributes: [
            .font: NSFont.systemFont(ofSize: 12, weight: .bold),
            .foregroundColor: NSColor.white,
        ])
        (title as NSString).draw(at: NSPoint(x: 22, y: 4), withAttributes: attributes)
    }

    override func mouseDown(with event: NSEvent) { onTap?() }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .pointingHand)
    }
}

// MARK: - Attributed rendering

enum AiAttributedRenderer {
    static func attributedString(for content: String, color: NSColor, secondary: NSColor) -> NSAttributedString {
        let result = NSMutableAttributedString()
        let blocks = MarkdownParser.parse(content)
        for (index, block) in blocks.enumerated() {
            result.append(attributed(for: block, color: color, secondary: secondary))
            if index < blocks.count - 1 { result.append(NSAttributedString(string: "\n")) }
        }
        return result
    }

    private static func attributed(for block: MarkdownBlock, color: NSColor, secondary: NSColor) -> NSAttributedString {
        switch block {
        case let .heading(level, text):
            let font = NSFont.systemFont(ofSize: level == 1 ? 16 : 14, weight: .semibold)
            let paragraph = paragraphStyle(lineSpacing: 2, spacingAfter: 6)
            return inline(text, font: font, color: color, paragraph: paragraph)

        case let .paragraph(text):
            let paragraph = paragraphStyle(lineSpacing: 3, spacingAfter: 8)
            return inline(text, font: base, color: color, paragraph: paragraph)

        case let .unordered(items):
            return list(items, color: color) { _ in "•  " }

        case let .ordered(items):
            return list(items, color: color) { "\($0 + 1).  " }

        case let .quote(text):
            let paragraph = paragraphStyle(lineSpacing: 3, spacingAfter: 8)
            paragraph.firstLineHeadIndent = 12
            paragraph.headIndent = 12
            let italic = NSFont(descriptor: base.fontDescriptor.withSymbolicTraits(.italic), size: base.pointSize) ?? base
            return inline(text, font: italic, color: secondary, paragraph: paragraph)

        case let .code(text), let .table(text):
            let paragraph = paragraphStyle(lineSpacing: 2, spacingAfter: 8)
            return NSAttributedString(string: text, attributes: [
                .font: NSFont.monospacedSystemFont(ofSize: 12, weight: .regular),
                .foregroundColor: color,
                .paragraphStyle: paragraph,
            ])
        }
    }

    private static var base: NSFont { NSFont.systemFont(ofSize: 14) }

    private static func paragraphStyle(lineSpacing: CGFloat, spacingAfter: CGFloat) -> NSMutableParagraphStyle {
        let style = NSMutableParagraphStyle()
        style.lineSpacing = lineSpacing
        style.paragraphSpacing = spacingAfter
        return style
    }

    private static func list(
        _ items: [String],
        color: NSColor,
        marker: (Int) -> String
    ) -> NSAttributedString {
        let result = NSMutableAttributedString()
        let paragraph = paragraphStyle(lineSpacing: 3, spacingAfter: 4)
        paragraph.headIndent = 16
        paragraph.firstLineHeadIndent = 4
        for (index, item) in items.enumerated() {
            let line = NSMutableAttributedString(string: marker(index), attributes: [
                .font: base, .foregroundColor: color, .paragraphStyle: paragraph,
            ])
            line.append(inline(item, font: base, color: color, paragraph: paragraph))
            result.append(line)
            if index < items.count - 1 { result.append(NSAttributedString(string: "\n")) }
        }
        return result
    }

    /// Inline emphasis/strong/code/strikethrough/link handling via Foundation's
    /// markdown parser, mapped onto concrete AppKit fonts. Mirrors the SwiftUI
    /// renderer's `$math$` → italic-monospace substitution.
    private static func inline(
        _ source: String,
        font: NSFont,
        color: NSColor,
        paragraph: NSParagraphStyle
    ) -> NSAttributedString {
        let mathStyled = source.replacingOccurrences(
            of: #"\$([^$\n]+)\$"#,
            with: "*`$1`*",
            options: .regularExpression
        )
        guard let attributed = try? AttributedString(
            markdown: mathStyled,
            options: AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        ) else {
            return NSAttributedString(string: source, attributes: [
                .font: font, .foregroundColor: color, .paragraphStyle: paragraph,
            ])
        }

        let result = NSMutableAttributedString()
        for run in attributed.runs {
            let substring = String(attributed[run.range].characters)
            var runFont = font
            var traits: NSFontDescriptor.SymbolicTraits = []
            if let intent = run.inlinePresentationIntent {
                if intent.contains(.stronglyEmphasized) { traits.insert(.bold) }
                if intent.contains(.emphasized) { traits.insert(.italic) }
                if intent.contains(.code) {
                    runFont = NSFont.monospacedSystemFont(ofSize: font.pointSize - 1, weight: .regular)
                }
            }
            if !traits.isEmpty {
                runFont = NSFont(descriptor: runFont.fontDescriptor.withSymbolicTraits(traits), size: runFont.pointSize) ?? runFont
            }
            var attributes: [NSAttributedString.Key: Any] = [
                .font: runFont, .foregroundColor: color, .paragraphStyle: paragraph,
            ]
            if run.inlinePresentationIntent?.contains(.strikethrough) == true {
                attributes[.strikethroughStyle] = NSUnderlineStyle.single.rawValue
            }
            if let link = run.link {
                attributes[.link] = link
                attributes[.foregroundColor] = NSColor.linkColor
            }
            result.append(NSAttributedString(string: substring, attributes: attributes))
        }
        return result
    }
}
