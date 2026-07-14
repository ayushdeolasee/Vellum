import SwiftUI
import UIKit
import UniformTypeIdentifiers

// Assistant-message renderer backed by a read-only UITextView so the user can
// select any substring of a reply and quote it back into the composer (the
// "Quote" affordance from the reference design). Reuses `MarkdownParser` for
// block structure and flattens each block into one NSAttributedString styled to
// match the SwiftUI `MarkdownMessage` renderer used for user messages.
//
// This is the iOS-native rebuild of macOS's NSTextView-backed version — same
// BEHAVIOR (per-message selection + a Quote action that creates a composer
// reference chip), not a port of the AppKit internals.
struct SelectableMessageText: UIViewRepresentable {
    let content: String
    /// Base text color (the assistant bubble's foreground).
    var color: Color
    /// Secondary color for the blockquote bar / muted glyphs.
    var secondary: Color
    /// Called with the selected substring when the user taps Quote.
    var onQuote: (String) -> Void
    /// Forwarded image drops. nil when the active model can't read images —
    /// which leaves the bubble a plain non-destination so the drag springs back,
    /// matching the panel's `.onDrop` gate. Non-nil installs a drop interaction
    /// on the text view itself: a UITextView otherwise swallows a drop that lands
    /// over it before the panel's SwiftUI drop target ever sees it.
    var onImageDrop: (([NSItemProvider]) -> Void)?
    /// Drives the panel's dashed outline while such a drag is over the bubble.
    var onDropTargeted: (Bool) -> Void = { _ in }

    /// Widest the bubble text lays out to before wrapping (kept a touch under the
    /// bubble's own max width so padding never clips the last glyph).
    private static let maxWidth: CGFloat = 300

    func makeUIView(context: Context) -> SelectableTextView {
        let view = SelectableTextView()
        view.isEditable = false
        view.isSelectable = true
        view.isScrollEnabled = false
        view.backgroundColor = .clear
        view.textContainerInset = .zero
        view.textContainer.lineFragmentPadding = 0
        view.delegate = context.coordinator
        view.setContentHuggingPriority(.required, for: .vertical)
        view.setContentCompressionResistancePriority(.required, for: .vertical)
        return view
    }

    func updateUIView(_ view: SelectableTextView, context: Context) {
        context.coordinator.onQuote = onQuote
        view.onDropTargeted = onDropTargeted
        view.setImageDropHandler(onImageDrop)

        let resolvedColor = UIColor(color)
        let resolvedSecondary = UIColor(secondary)
        // Compare inputs, not rendered output: attributedString(for:) is a pure
        // function of (content, colors), and parsing is the expensive part — so
        // repaint only when the content OR the palette-derived colors change (a
        // light/dark switch restyles already-rendered messages).
        let contentChanged = view.appliedContent != content
        let colorsChanged = view.appliedColor != resolvedColor
            || view.appliedSecondary != resolvedSecondary
        guard contentChanged || colorsChanged else { return }
        let attributed = AiAttributedRenderer.attributedString(
            for: content, color: resolvedColor, secondary: resolvedSecondary)
        view.setAttributed(attributed, content: content, color: resolvedColor, secondary: resolvedSecondary)
    }

    func sizeThatFits(_ proposal: ProposedViewSize, uiView: SelectableTextView, context: Context) -> CGSize? {
        let width = min(max(proposal.width ?? Self.maxWidth, 80), Self.maxWidth)
        let fitted = uiView.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude))
        return CGSize(width: width, height: ceil(fitted.height))
    }

    func makeCoordinator() -> Coordinator { Coordinator(onQuote: onQuote) }

    final class Coordinator: NSObject, UITextViewDelegate {
        var onQuote: (String) -> Void
        init(onQuote: @escaping (String) -> Void) { self.onQuote = onQuote }

        func textView(
            _ textView: UITextView, editMenuForTextIn range: NSRange,
            suggestedActions: [UIMenuElement]
        ) -> UIMenu? {
            guard range.length > 0 else { return UIMenu(children: suggestedActions) }
            let selected = (textView.text as NSString).substring(with: range)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !selected.isEmpty else { return UIMenu(children: suggestedActions) }
            let quote = UIAction(title: "Quote", image: UIImage(systemName: "quote.bubble")) { [onQuote] _ in
                onQuote(selected)
                textView.selectedTextRange = nil
            }
            return UIMenu(children: [quote] + suggestedActions)
        }
    }
}

/// Read-only text view that also acts as an image-drop destination so a drop
/// over a reply bubble is forwarded to the panel instead of being swallowed.
final class SelectableTextView: UITextView, UIDropInteractionDelegate {
    private(set) var appliedContent: String?
    private(set) var appliedColor: UIColor?
    private(set) var appliedSecondary: UIColor?

    var onDropTargeted: ((Bool) -> Void)?
    private var onImageDrop: (([NSItemProvider]) -> Void)?
    private var dropInteraction: UIDropInteraction?

    func setAttributed(_ attributed: NSAttributedString, content: String, color: UIColor, secondary: UIColor) {
        attributedText = attributed
        appliedContent = content
        appliedColor = color
        appliedSecondary = secondary
        invalidateIntrinsicContentSize()
    }

    /// Install or remove the image drop interaction to match the active model's
    /// vision capability. Registered here (not once at setup) because the panel
    /// swaps the handler to nil when a non-vision model becomes active.
    func setImageDropHandler(_ handler: (([NSItemProvider]) -> Void)?) {
        onImageDrop = handler
        if handler != nil, dropInteraction == nil {
            let interaction = UIDropInteraction(delegate: self)
            addInteraction(interaction)
            dropInteraction = interaction
        } else if handler == nil, let interaction = dropInteraction {
            removeInteraction(interaction)
            dropInteraction = nil
        }
    }

    func dropInteraction(_ interaction: UIDropInteraction, canHandle session: UIDropSession) -> Bool {
        onImageDrop != nil && session.hasImagePayload
    }

    func dropInteraction(_ interaction: UIDropInteraction, sessionDidEnter session: UIDropSession) {
        onDropTargeted?(true)
    }

    func dropInteraction(
        _ interaction: UIDropInteraction, sessionDidUpdate session: UIDropSession
    ) -> UIDropProposal {
        UIDropProposal(operation: onImageDrop != nil && session.hasImagePayload ? .copy : .cancel)
    }

    func dropInteraction(_ interaction: UIDropInteraction, sessionDidExit session: UIDropSession) {
        onDropTargeted?(false)
    }

    func dropInteraction(_ interaction: UIDropInteraction, sessionDidEnd session: UIDropSession) {
        onDropTargeted?(false)
    }

    func dropInteraction(_ interaction: UIDropInteraction, performDrop session: UIDropSession) {
        onDropTargeted?(false)
        onImageDrop?(session.items.map(\.itemProvider))
    }
}

extension UIDropSession {
    /// Whether the drag carries an image (raw image bytes, or a file that
    /// conforms to an image type).
    var hasImagePayload: Bool {
        hasItemsConforming(toTypeIdentifiers: [UTType.image.identifier])
            || items.contains { $0.itemProvider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) }
    }
}

// MARK: - Attributed rendering

/// Main-actor because math spans are typeset through `MathRenderer` (which
/// drives an offscreen UIKit label); every caller is already main-actor UI code.
@MainActor
enum AiAttributedRenderer {
    static func attributedString(for content: String, color: UIColor, secondary: UIColor) -> NSAttributedString {
        let result = NSMutableAttributedString()
        let blocks = MarkdownParser.parse(content)
        for (index, block) in blocks.enumerated() {
            result.append(attributed(for: block, color: color, secondary: secondary))
            if index < blocks.count - 1 { result.append(NSAttributedString(string: "\n")) }
        }
        return result
    }

    private static func attributed(for block: MarkdownBlock, color: UIColor, secondary: UIColor) -> NSAttributedString {
        switch block {
        case let .heading(level, text):
            let font = UIFont.systemFont(ofSize: level == 1 ? 16 : 14, weight: .semibold)
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
            let italic = italicFont(base)
            return inline(text, font: italic, color: secondary, paragraph: paragraph)

        case let .code(text):
            let paragraph = paragraphStyle(lineSpacing: 2, spacingAfter: 8)
            return NSAttributedString(string: text, attributes: [
                .font: UIFont.monospacedSystemFont(ofSize: 12, weight: .regular),
                .foregroundColor: color,
                .backgroundColor: color.withAlphaComponent(0.08),
                .paragraphStyle: paragraph,
            ])

        case let .table(text):
            let paragraph = paragraphStyle(lineSpacing: 2, spacingAfter: 8)
            return NSAttributedString(string: text, attributes: [
                .font: UIFont.monospacedSystemFont(ofSize: 12, weight: .regular),
                .foregroundColor: color,
                .paragraphStyle: paragraph,
            ])

        case let .math(latex):
            return displayMath(latex, color: color)
        }
    }

    /// Display equation as a centered typeset image on its own paragraph;
    /// unparseable LaTeX falls back to monospaced source.
    private static func displayMath(_ latex: String, color: UIColor) -> NSAttributedString {
        guard let rendered = MathRenderer.render(latex: latex, fontSize: 16, color: color, display: true) else {
            let paragraph = paragraphStyle(lineSpacing: 2, spacingAfter: 8)
            return NSAttributedString(string: latex, attributes: [
                .font: UIFont.monospacedSystemFont(ofSize: 12, weight: .regular),
                .foregroundColor: color,
                .paragraphStyle: paragraph,
            ])
        }
        let paragraph = paragraphStyle(lineSpacing: 2, spacingAfter: 10)
        paragraph.alignment = .center
        let result = NSMutableAttributedString(attributedString: attachment(for: rendered, maxWidth: 240, latex: latex))
        result.addAttributes(
            [.paragraphStyle: paragraph, .foregroundColor: color],
            range: NSRange(location: 0, length: result.length)
        )
        return result
    }

    /// Wrap a rendered equation in a text attachment whose bounds sit the image
    /// on the text baseline (negative y = the math's descent below it), scaled
    /// down proportionally when wider than the bubble.
    private static func attachment(for rendered: MathRenderer.Rendered, maxWidth: CGFloat, latex: String) -> NSAttributedString {
        let attachment = NSTextAttachment()
        attachment.image = rendered.image
        // The attachment renders as an image with no text; expose the LaTeX
        // source so VoiceOver can read the equation.
        attachment.image?.accessibilityLabel = latex
        var size = rendered.size
        var descent = rendered.descent
        if size.width > maxWidth {
            let scale = maxWidth / size.width
            size = CGSize(width: maxWidth, height: size.height * scale)
            descent *= scale
        }
        attachment.bounds = CGRect(x: 0, y: -descent, width: size.width, height: size.height)
        return NSAttributedString(attachment: attachment)
    }

    private static var base: UIFont { UIFont.systemFont(ofSize: 14) }

    private static func italicFont(_ font: UIFont) -> UIFont {
        guard let descriptor = font.fontDescriptor.withSymbolicTraits(.traitItalic) else { return font }
        return UIFont(descriptor: descriptor, size: font.pointSize)
    }

    private static func paragraphStyle(lineSpacing: CGFloat, spacingAfter: CGFloat) -> NSMutableParagraphStyle {
        let style = NSMutableParagraphStyle()
        style.lineSpacing = lineSpacing
        style.paragraphSpacing = spacingAfter
        return style
    }

    private static func list(
        _ items: [String],
        color: UIColor,
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

    /// Inline handling: math spans become baseline-aligned typeset attachments,
    /// the prose between them goes through Foundation's markdown parser for
    /// emphasis/strong/code/strikethrough/links, mapped onto concrete UIKit
    /// fonts. Mirrors the SwiftUI `MarkdownMessage` renderer.
    private static func inline(
        _ source: String,
        font: UIFont,
        color: UIColor,
        paragraph: NSParagraphStyle
    ) -> NSAttributedString {
        let result = NSMutableAttributedString()
        for segment in MathRenderer.segments(in: source) {
            switch segment {
            case .text(let text):
                result.append(inlineProse(text, font: font, color: color, paragraph: paragraph))
            case .math(let latex):
                if let rendered = MathRenderer.render(latex: latex, fontSize: font.pointSize, color: color, display: false) {
                    let math = NSMutableAttributedString(attributedString: attachment(for: rendered, maxWidth: 240, latex: latex))
                    math.addAttributes(
                        [.paragraphStyle: paragraph, .foregroundColor: color],
                        range: NSRange(location: 0, length: math.length)
                    )
                    result.append(math)
                } else {
                    let italic = italicFont(font)
                    result.append(NSAttributedString(string: "$\(latex)$", attributes: [
                        .font: italic, .foregroundColor: color, .paragraphStyle: paragraph,
                    ]))
                }
            }
        }
        return result
    }

    private static func inlineProse(
        _ source: String,
        font: UIFont,
        color: UIColor,
        paragraph: NSParagraphStyle
    ) -> NSAttributedString {
        guard let attributed = try? AttributedString(
            markdown: source,
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
            var traits: UIFontDescriptor.SymbolicTraits = []
            if let intent = run.inlinePresentationIntent {
                if intent.contains(.stronglyEmphasized) { traits.insert(.traitBold) }
                if intent.contains(.emphasized) { traits.insert(.traitItalic) }
                if intent.contains(.code) {
                    runFont = UIFont.monospacedSystemFont(ofSize: font.pointSize - 1, weight: .regular)
                }
            }
            if !traits.isEmpty, let descriptor = runFont.fontDescriptor.withSymbolicTraits(traits) {
                runFont = UIFont(descriptor: descriptor, size: runFont.pointSize)
            }
            var attributes: [NSAttributedString.Key: Any] = [
                .font: runFont, .foregroundColor: color, .paragraphStyle: paragraph,
            ]
            if run.inlinePresentationIntent?.contains(.strikethrough) == true {
                attributes[.strikethroughStyle] = NSUnderlineStyle.single.rawValue
            }
            if let link = run.link {
                attributes[.link] = link
                attributes[.foregroundColor] = UIColor.link
            }
            result.append(NSAttributedString(string: substring, attributes: attributes))
        }
        return result
    }
}
