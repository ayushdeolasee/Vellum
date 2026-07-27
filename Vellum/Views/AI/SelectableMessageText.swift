import AppKit
import SwiftUI

fileprivate extension NSAttributedString.Key {
    static let vellumDecorativeRule = NSAttributedString.Key(
        "com.vellum.ai.decorative-rule"
    )
}

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
    /// A file or image dropped onto the bubble itself, which AppKit hands here instead of
    /// to the panel's SwiftUI `.onDrop`; nil when the model can't read images, which
    /// leaves the bubble a plain non-destination.
    var onAttachmentDrop: ((AttachmentDropPayload) -> Void)?
    /// Drives the panel's drop outline while such a drag is over the bubble.
    var onDropTargeted: (Bool) -> Void = { _ in }

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
        view.textView.onAttachmentDrop = onAttachmentDrop
        view.textView.onDropTargeted = onDropTargeted
        let resolvedColor = NSColor(color)
        let resolvedSecondary = NSColor(secondary)
        // Compare inputs, not rendered output: attributedString(for:) is a pure
        // function of (content, colors), and parsing is the expensive part —
        // during streaming this runs once per delta on the growing message, and
        // once per message on every unrelated update pass.
        // Repaint when the content OR the palette-derived colors change, so a
        // light/dark appearance switch restyles already-rendered messages.
        let contentChanged = view.appliedContent != content
        let colorsChanged = view.appliedColor != resolvedColor
            || view.appliedSecondary != resolvedSecondary
        guard contentChanged || colorsChanged else { return }
        let attributed = AiAttributedRenderer.attributedString(
            for: content,
            color: resolvedColor,
            secondary: resolvedSecondary
        )
        view.setAttributed(attributed, content: content, color: resolvedColor, secondary: resolvedSecondary)
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: MessageContainerView, context: Context) -> CGSize? {
        let width = proposal.width ?? 248
        let clamped = min(max(width, 80), 248)
        return CGSize(width: clamped, height: nsView.height(forWidth: clamped))
    }

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        var onQuote: (String) -> Void
        weak var container: MessageContainerView?

        init(onQuote: @escaping (String) -> Void) { self.onQuote = onQuote }

        func textViewDidChangeSelection(_ notification: Notification) {
            container?.updateQuoteButton()
        }

        func quoteCurrentSelection() {
            guard let textView = container?.textView,
                  let storage = textView.textStorage else { return }
            let range = textView.selectedRange()
            guard range.length > 0 else { return }
            let text = MessageContainerView.plainText(
                in: storage,
                range: range,
                mathDelimiters: true
            )
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
    let textView: TranscriptTextView
    private let quoteButton = QuoteButton()
    var onQuoteTapped: (() -> Void)?

    override var isFlipped: Bool { true }

    override init(frame frameRect: NSRect) {
        textView = TranscriptTextView(textKit1ContainerIn: frameRect.size)
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
    /// The raw markdown last rendered into `attributed` plus the palette colors,
    /// so the SwiftUI layer can skip the parse entirely when neither changed.
    private(set) var appliedContent: String?
    private(set) var appliedColor: NSColor?
    private(set) var appliedSecondary: NSColor?
    private var renderedWidth: CGFloat?

    func setAttributed(_ attributed: NSAttributedString, content: String, color: NSColor, secondary: NSColor) {
        self.attributed = attributed
        self.appliedContent = content
        self.appliedColor = color
        self.appliedSecondary = secondary
        renderedWidth = nil
        textView.textStorage?.setAttributedString(attributed)
        textView.setAccessibilityValue(
            Self.plainText(
                in: attributed,
                range: NSRange(location: 0, length: attributed.length),
                mathDelimiters: false
            )
        )
        needsLayout = true
    }

    /// Height for a proposed width. Measured on a THROWAWAY layout manager, never
    /// the live text view: SwiftUI calls `sizeThatFits` from inside AppKit's
    /// layout pass, and driving `ensureLayout` on the on-screen view there
    /// tripped "-ensureLayoutForTextContainer while already performing layout".
    func height(forWidth width: CGFloat) -> CGFloat {
        let width = max(1, width)
        return Self.measureHeight(Self.fittedAttachments(in: attributed, width: width), width: width)
    }

    /// Image-backed equations and rules are authored at the default bubble
    /// width. Scale copies for the actual proposed width so a narrow inspector
    /// cannot clip them, while retaining the originals for a later expansion.
    static func fittedAttachments(
        in attributed: NSAttributedString,
        width: CGFloat
    ) -> NSAttributedString {
        let result = NSMutableAttributedString(attributedString: attributed)
        let available = max(1, width)
        result.enumerateAttribute(
            .attachment,
            in: NSRange(location: 0, length: result.length)
        ) { value, range, _ in
            guard let attachment = value as? NSTextAttachment else { return }
            let paragraph = result.attribute(
                .paragraphStyle,
                at: range.location,
                effectiveRange: nil
            ) as? NSParagraphStyle
            let lineWidth = availableLineWidth(
                containerWidth: available,
                paragraph: paragraph
            )
            guard attachment.bounds.width > lineWidth else { return }
            let fitted = NSTextAttachment()
            fitted.image = attachment.image
            var bounds = attachment.bounds
            let scale = lineWidth / bounds.width
            bounds.size = CGSize(
                width: lineWidth,
                height: max(1, bounds.height * scale)
            )
            bounds.origin.y *= scale
            fitted.bounds = bounds
            result.addAttribute(.attachment, value: fitted, range: range)
        }
        return result
    }

    private static func availableLineWidth(
        containerWidth: CGFloat,
        paragraph: NSParagraphStyle?
    ) -> CGFloat {
        guard let paragraph else { return max(1, containerWidth) }
        let leading = max(
            0,
            max(paragraph.firstLineHeadIndent, paragraph.headIndent)
        )
        let trailingEdge = paragraph.tailIndent > 0
            ? min(containerWidth, paragraph.tailIndent)
            : containerWidth + paragraph.tailIndent
        return max(1, trailingEdge - leading)
    }

    /// Converts attributed transcript content into text suitable for quoting or
    /// AppKit accessibility. Decorative rules disappear; equations use their
    /// LaTeX source instead of leaking the object-replacement character.
    static func plainText(
        in attributed: NSAttributedString,
        range requestedRange: NSRange,
        mathDelimiters: Bool
    ) -> String {
        let range = NSIntersectionRange(
            requestedRange,
            NSRange(location: 0, length: attributed.length)
        )
        guard range.length > 0 else { return "" }

        var result = ""
        attributed.enumerateAttributes(in: range) { attributes, runRange, _ in
            if attributes[.vellumDecorativeRule] as? Bool == true {
                return
            }
            if let attachment = attributes[.attachment] as? NSTextAttachment {
                guard let latex = attachment.image?.accessibilityDescription,
                      !latex.isEmpty else {
                    return
                }
                result += mathDelimiters ? "$\(latex)$" : "Equation: \(latex)"
                return
            }
            let text = (attributed.string as NSString).substring(with: runRange)
            result += text.replacingOccurrences(of: "\u{FFFC}", with: "")
        }
        return result
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
        if renderedWidth == nil || abs((renderedWidth ?? 0) - bounds.width) > 0.5 {
            textView.textStorage?.setAttributedString(
                Self.fittedAttachments(in: attributed, width: bounds.width)
            )
            renderedWidth = bounds.width
        }
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

/// The transcript's read-only text. It fills its bubble, so a drag over a reply
/// lands on AppKit content and the panel's SwiftUI `.onDrop` never fires — the
/// same routing that the composer field already works around. Take image drops
/// here and forward them to the panel (and drive its outline while hovering);
/// everything else is left alone, so selection and the Quote button are untouched.
final class TranscriptTextView: NSTextView {
    var onAttachmentDrop: ((AttachmentDropPayload) -> Void)? {
        didSet { updateDragTypeRegistration() }
    }
    var onDropTargeted: ((Bool) -> Void)?

    /// The sizing path uses TextKit 1. Keeping the live view on the same layout
    /// engine avoids paragraph-spacing disagreements that otherwise leave a
    /// large blank region below long Markdown replies.
    convenience init(textKit1ContainerIn size: NSSize) {
        let storage = NSTextStorage()
        let layoutManager = NSLayoutManager()
        let container = NSTextContainer(
            size: NSSize(width: max(0, size.width), height: .greatestFiniteMagnitude)
        )
        storage.addLayoutManager(layoutManager)
        layoutManager.addTextContainer(container)
        self.init(frame: NSRect(origin: .zero, size: size), textContainer: container)
    }

    /// AppKit funnels every re-registration through this (it runs on window entry
    /// and whenever editable/selectable/rich-text changes) and drops a read-only
    /// view's types on the floor — so assert ours here rather than once at setup.
    override func updateDragTypeRegistration() {
        if onAttachmentDrop == nil {
            unregisterDraggedTypes()
        } else {
            registerForDraggedTypes(AttachmentDrop.draggedTypes)
        }
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard onAttachmentDrop != nil, AttachmentDrop.carriesAttachment(sender) else { return [] }
        onDropTargeted?(true)
        return .copy
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        onAttachmentDrop != nil && AttachmentDrop.carriesAttachment(sender) ? .copy : []
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        onDropTargeted?(false)
    }

    override func draggingEnded(_ sender: NSDraggingInfo) {
        onDropTargeted?(false)
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        onDropTargeted?(false)
        guard let onAttachmentDrop, let payload = AttachmentDrop.payload(sender) else { return false }
        onAttachmentDrop(payload)
        return true
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

// Main-actor because math spans are typeset through `MathRenderer` (which
// drives an offscreen AppKit label); every caller is already main-actor UI code.
@MainActor
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

        case let .code(text):
            // A run background is the closest an attributed string gets to the
            // SwiftUI renderer's boxed code block.
            let paragraph = paragraphStyle(lineSpacing: 2, spacingAfter: 8)
            return NSAttributedString(string: text, attributes: [
                .font: NSFont.monospacedSystemFont(ofSize: 12, weight: .regular),
                .foregroundColor: color,
                .backgroundColor: color.withAlphaComponent(0.08),
                .paragraphStyle: paragraph,
            ])

        case let .table(text):
            let paragraph = paragraphStyle(lineSpacing: 2, spacingAfter: 8)
            return NSAttributedString(string: text, attributes: [
                .font: NSFont.monospacedSystemFont(ofSize: 12, weight: .regular),
                .foregroundColor: color,
                .paragraphStyle: paragraph,
            ])

        case let .math(latex):
            return displayMath(latex, color: color)

        case .rule:
            return rule(color: secondary)

        case .list(let items):
            return nestedList(items, color: color)
        }
    }

    private static func rule(color: NSColor) -> NSAttributedString {
        let attachment = NSTextAttachment()
        attachment.image = NSImage(size: CGSize(width: 240, height: 1), flipped: false) { rect in
            color.withAlphaComponent(0.5).setFill()
            rect.fill()
            return true
        }
        attachment.bounds = CGRect(x: 0, y: 0, width: 240, height: 1)
        let paragraph = paragraphStyle(lineSpacing: 0, spacingAfter: 12)
        paragraph.paragraphSpacingBefore = 4
        let result = NSMutableAttributedString(attributedString: NSAttributedString(attachment: attachment))
        result.addAttributes(
            [
                .paragraphStyle: paragraph,
                .foregroundColor: color,
                .vellumDecorativeRule: true,
            ],
            range: NSRange(location: 0, length: result.length)
        )
        return result
    }

    /// Display equation as a centered typeset image on its own paragraph;
    /// unparseable LaTeX falls back to monospaced source.
    private static func displayMath(_ latex: String, color: NSColor) -> NSAttributedString {
        guard let rendered = MathRenderer.render(latex: latex, fontSize: 16, color: color, display: true) else {
            let paragraph = paragraphStyle(lineSpacing: 2, spacingAfter: 8)
            return NSAttributedString(string: latex, attributes: [
                .font: NSFont.monospacedSystemFont(ofSize: 12, weight: .regular),
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
        attachment.image?.accessibilityDescription = latex
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

    private static func nestedList(
        _ items: [MarkdownListItem],
        color: NSColor
    ) -> NSAttributedString {
        let result = NSMutableAttributedString()
        for (index, item) in items.enumerated() {
            let indent = CGFloat(4 + item.depth * 16)
            let paragraph = paragraphStyle(lineSpacing: 3, spacingAfter: 4)
            paragraph.firstLineHeadIndent = indent
            paragraph.headIndent = indent + 16
            let prefix = "\(item.marker.label)  "
            let line = NSMutableAttributedString(string: prefix, attributes: [
                .font: base, .foregroundColor: color, .paragraphStyle: paragraph,
            ])
            line.append(inline(item.text, font: base, color: color, paragraph: paragraph))
            result.append(line)
            if index < items.count - 1 {
                result.append(NSAttributedString(string: "\n"))
            }
        }
        return result
    }

    /// Inline handling: math spans become baseline-aligned typeset attachments,
    /// the prose between them goes through Foundation's markdown parser for
    /// emphasis/strong/code/strikethrough/links, mapped onto concrete AppKit
    /// fonts. Mirrors the SwiftUI `MarkdownMessage` renderer.
    private static func inline(
        _ source: String,
        font: NSFont,
        color: NSColor,
        paragraph: NSParagraphStyle
    ) -> NSAttributedString {
        let result = NSMutableAttributedString()
        for piece in InlineMarkdown.pieces(in: source) {
            switch piece {
            case .prose(let attributed):
                result.append(inlineProse(attributed, font: font, color: color, paragraph: paragraph))
            case .math(let latex):
                if let rendered = MathRenderer.render(latex: latex, fontSize: font.pointSize, color: color, display: false) {
                    let math = NSMutableAttributedString(attributedString: attachment(for: rendered, maxWidth: 240, latex: latex))
                    // Keep the run's paragraph style so line spacing stays even.
                    math.addAttributes(
                        [.paragraphStyle: paragraph, .foregroundColor: color],
                        range: NSRange(location: 0, length: math.length)
                    )
                    result.append(math)
                } else {
                    let italic = NSFont(descriptor: font.fontDescriptor.withSymbolicTraits(.italic), size: font.pointSize) ?? font
                    result.append(NSAttributedString(string: "$\(latex)$", attributes: [
                        .font: italic, .foregroundColor: color, .paragraphStyle: paragraph,
                    ]))
                }
            }
        }
        return result
    }

    private static func inlineProse(
        _ attributed: AttributedString,
        font: NSFont,
        color: NSColor,
        paragraph: NSParagraphStyle
    ) -> NSAttributedString {
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
