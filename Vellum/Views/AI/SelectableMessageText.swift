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
// reference chip), not a port of the AppKit internals. The layout substance is
// shared with main: `AttachmentText`, the attachment fit pass, the throwaway
// measurement, and the `mathMaxWidth` plumbing that lets typeset equations grow
// with the panel instead of staying pinned to a 240pt stub.

/// What an image attachment should contribute when the transcript is flattened
/// back to plain text — quoting a selection into the composer, or handing the
/// bubble a UIKit accessibility value.
///
/// Attachments otherwise surface as U+FFFC, so without this a quoted sentence
/// containing an equation pasted an object-replacement character into the
/// composer, and a thematic rule pasted one too.
final class AttachmentText: NSObject {
    /// Markdown that reproduces the attachment, so a quoted equation still
    /// renders as an equation when it is sent back. Empty for decorative
    /// attachments (thematic rules), which quote as nothing at all.
    let markdown: String
    /// What VoiceOver should hear in place of the image. Empty to skip.
    let spoken: String

    init(markdown: String, spoken: String) {
        self.markdown = markdown
        self.spoken = spoken
    }
}

extension NSAttributedString.Key {
    /// Carries an `AttachmentText` on every image-attachment run this renderer
    /// produces.
    static let vellumAttachmentText = NSAttributedString.Key("com.vellum.ai.attachment-text")
}

struct SelectableMessageText: UIViewRepresentable {
    let content: String
    /// Base text color (the assistant bubble's foreground).
    var color: Color
    /// Secondary color for the blockquote bar / muted glyphs.
    var secondary: Color
    /// Widest the rendered text may be, in points. Threaded down from the panel
    /// (which measures the live transcript column) rather than inferred here,
    /// because display math is baked into the attributed string at render time
    /// and so needs the width before layout runs.
    var maxWidth: CGFloat = 248
    /// Called with the selected substring when the user taps Quote.
    var onQuote: (String) -> Void
    /// A file or image dropped onto the bubble itself, which UIKit hands here
    /// instead of to the panel's SwiftUI `.onDrop`; nil leaves the bubble a plain
    /// non-destination so the drag springs back. Non-nil installs a drop
    /// interaction on the text view itself: a UITextView otherwise swallows a
    /// drop that lands over it before the panel's SwiftUI drop target sees it.
    var onAttachmentDrop: ((AttachmentDropPayload) -> Void)?
    /// Drives the panel's drop outline while such a drag is over the bubble.
    var onDropTargeted: (Bool) -> Void = { _ in }

    func makeUIView(context: Context) -> SelectableTextView {
        let view = SelectableTextView(textKit1ContainerIn: .zero)
        view.isEditable = false
        view.isSelectable = true
        view.isScrollEnabled = false
        view.backgroundColor = .clear
        view.textContainerInset = .zero
        view.textContainer.lineFragmentPadding = 0
        view.textContainer.widthTracksTextView = true
        view.delegate = context.coordinator
        view.setContentHuggingPriority(.required, for: .vertical)
        view.setContentCompressionResistancePriority(.required, for: .vertical)
        return view
    }

    func updateUIView(_ view: SelectableTextView, context: Context) {
        context.coordinator.onQuote = onQuote
        view.onDropTargeted = onDropTargeted
        view.setAttachmentDropHandler(onAttachmentDrop)

        let resolvedColor = UIColor(color)
        let resolvedSecondary = UIColor(secondary)
        // Compare inputs, not rendered output: attributedString(for:) is a pure
        // function of (content, colors, math width), and parsing is the expensive
        // part — so repaint only when the content OR the palette-derived colors
        // change (a light/dark switch restyles already-rendered messages).
        let contentChanged = view.appliedContent != content
        let colorsChanged = view.appliedColor != resolvedColor
            || view.appliedSecondary != resolvedSecondary
        // Display math and thematic rules are rasterized into the attributed
        // string against the bubble's width, so a column resize (a split-view
        // drag, a rotation) has to re-render even when the text and colors are
        // untouched — but ONLY those image attachments depend on that width.
        // Gating on "the last render actually produced one" keeps the early
        // return intact for the overwhelming majority of replies, which is what
        // stops a resize from re-parsing every bubble in the transcript on every
        // frame.
        let widthChanged = view.renderedContainsScaledAttachments
            && view.appliedMathWidth != mathWidth
        guard contentChanged || colorsChanged || widthChanged else { return }
        let attributed = AiAttributedRenderer.attributedString(
            for: content,
            color: resolvedColor,
            secondary: resolvedSecondary,
            mathMaxWidth: mathWidth
        )
        view.setAttributed(
            attributed,
            content: content,
            color: resolvedColor,
            secondary: resolvedSecondary,
            mathWidth: mathWidth
        )
    }

    func sizeThatFits(_ proposal: ProposedViewSize, uiView: SelectableTextView, context: Context) -> CGSize? {
        // The old hard 300pt ceiling here is what pinned replies to a narrow
        // column on a wide iPad — the cap now comes from `maxWidth`, which the
        // panel derives from the live transcript width.
        let proposed = proposal.width ?? maxWidth
        let cap = proposed.isFinite ? min(max(proposed, 80), maxWidth) : maxWidth
        // Within that cap the bubble hugs. Returning the cap itself (what this
        // used to do) painted every reply across the whole column no matter how
        // little was in it.
        let used = uiView.size(forWidth: cap)
        return CGSize(width: min(cap, max(used.width, 80)), height: used.height)
    }

    /// Cap for typeset equations: the full text width, so a wide panel shows
    /// display math at full size instead of scaling it down to the old 240pt.
    private var mathWidth: CGFloat { max(maxWidth, 80) }

    func makeCoordinator() -> Coordinator { Coordinator(onQuote: onQuote) }

    final class Coordinator: NSObject, UITextViewDelegate {
        var onQuote: (String) -> Void
        init(onQuote: @escaping (String) -> Void) { self.onQuote = onQuote }

        func textView(
            _ textView: UITextView, editMenuForTextIn range: NSRange,
            suggestedActions: [UIMenuElement]
        ) -> UIMenu? {
            guard range.length > 0 else { return UIMenu(children: suggestedActions) }
            // Not `textView.text`: that hands back a U+FFFC for every equation
            // and rule in the selection.
            let selected = SelectableTextView
                .plainText(in: textView.textStorage, range: range, form: \.markdown)
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

/// Read-only text view that also acts as an attachment-drop destination so a
/// drop over a reply bubble is forwarded to the panel instead of being
/// swallowed.
final class SelectableTextView: UITextView, UIDropInteractionDelegate {
    /// The attributed string as it was AUTHORED, before any fit pass. The text
    /// storage holds a copy fitted to the current width; keeping the originals
    /// here means widening the panel restores full-size attachments rather than
    /// compounding the scale.
    private(set) var attributed = NSAttributedString()
    /// The raw markdown last rendered into `attributed` plus the palette colors,
    /// so the SwiftUI layer can skip the parse entirely when neither changed.
    private(set) var appliedContent: String?
    private(set) var appliedColor: UIColor?
    private(set) var appliedSecondary: UIColor?
    /// Width the image attachments were AUTHORED against, so a column resize can
    /// be told apart from an unrelated update pass.
    private(set) var appliedMathWidth: CGFloat?
    /// Whether the last render actually produced image attachments — typeset
    /// equations or thematic rules, the only two things this renderer draws as
    /// images, and the only two whose rendering depends on the bubble's width.
    /// A reply with neither renders identically at every width, so the SwiftUI
    /// layer can skip it entirely while the column is being resized instead of
    /// re-parsing its markdown once per frame.
    private(set) var renderedContainsScaledAttachments = false
    /// Width the text storage's attachments were last fitted DOWN to; nil forces
    /// a refit on the next layout. Distinct from `appliedMathWidth`: that is the
    /// width the renderer drew at, this is the width `layoutSubviews()` squeezed
    /// the result into.
    private var fittedWidth: CGFloat?

    var onDropTargeted: ((Bool) -> Void)?
    private var onAttachmentDrop: ((AttachmentDropPayload) -> Void)?
    private var dropInteraction: UIDropInteraction?

    /// Builds the view on an explicit **TextKit 1** stack.
    ///
    /// `UITextView()` hands back a TextKit 2 view, but the sizing around this one
    /// is written against TextKit 1: `measureSize` sizes the bubble with a
    /// throwaway `NSLayoutManager`. The two engines do not agree about
    /// `NSParagraphStyle.paragraphSpacing` — the gap this renderer puts after
    /// every markdown block — so on a long reply the TextKit 1 measurement comes
    /// out taller than a TextKit 2 view actually lays out, leaving dead space
    /// under the answer (macOS hit exactly this in issue #57). Owning the stack
    /// keeps the measurement and the on-screen layout the same engine.
    convenience init(textKit1ContainerIn size: CGSize) {
        let storage = NSTextStorage()
        let layoutManager = NSLayoutManager()
        // Unbounded height: the bubble grows to fit, it never scrolls its text.
        let container = NSTextContainer(
            size: CGSize(width: max(0, size.width), height: .greatestFiniteMagnitude))
        storage.addLayoutManager(layoutManager)
        layoutManager.addTextContainer(container)
        self.init(frame: CGRect(origin: .zero, size: size), textContainer: container)
    }

    func setAttributed(
        _ attributed: NSAttributedString,
        content: String,
        color: UIColor,
        secondary: UIColor,
        mathWidth: CGFloat? = nil
    ) {
        self.attributed = attributed
        appliedContent = content
        appliedColor = color
        appliedSecondary = secondary
        appliedMathWidth = mathWidth
        renderedContainsScaledAttachments = attributed.containsAttachments(
            in: NSRange(location: 0, length: attributed.length))
        fittedWidth = nil
        textStorage.setAttributedString(attributed)
        // The text view reads as one accessibility element whose value is its
        // string — which is full of U+FFFC without this substitution.
        accessibilityValue = Self.plainText(
            in: attributed, range: NSRange(location: 0, length: attributed.length), form: \.spoken)
        invalidateIntrinsicContentSize()
        setNeedsLayout()
    }

    /// Size the text settles at when it is allowed to wrap at `width`: the
    /// height, plus the width the glyphs ACTUALLY occupy — which is what lets a
    /// short reply hug instead of stretching an almost-empty bubble across the
    /// column. Measured on a THROWAWAY layout manager, never the live view, so
    /// the measurement cannot re-enter the layout pass SwiftUI calls it from.
    func size(forWidth width: CGFloat) -> CGSize {
        let width = max(1, width)
        // Measure what will actually be shown: `layoutSubviews()` installs the
        // same fitted copy, and a scaled-down equation is shorter than its
        // original.
        return Self.measureSize(Self.fittedAttachments(in: attributed, width: width), width: width)
    }

    /// Scale image attachments down to the width they are actually being laid
    /// out in.
    ///
    /// `AiAttributedRenderer` authors equations and rules at `mathMaxWidth`, the
    /// usable width of the bubble the panel measured. An attachment cannot size
    /// itself against its text container, so in a narrow split view — or inside
    /// an indented list item — a full-width attachment overflows its line
    /// fragment and clips. The originals are kept in `attributed`, so widening
    /// the panel again restores full size rather than compounding the scale.
    static func fittedAttachments(in attributed: NSAttributedString, width: CGFloat) -> NSAttributedString {
        let result = NSMutableAttributedString(attributedString: attributed)
        let available = max(1, width)
        result.enumerateAttribute(.attachment, in: NSRange(location: 0, length: result.length)) { value, range, _ in
            guard let attachment = value as? NSTextAttachment else { return }
            let paragraph = result.attribute(.paragraphStyle, at: range.location, effectiveRange: nil)
                as? NSParagraphStyle
            let lineWidth = availableLineWidth(containerWidth: available, paragraph: paragraph)
            guard attachment.bounds.width > lineWidth else { return }
            // A fresh attachment rather than a mutation: the original is shared
            // with `attributed`, and scaling it in place would be cumulative.
            let fitted = NSTextAttachment()
            fitted.image = attachment.image
            var bounds = attachment.bounds
            let scale = lineWidth / bounds.width
            bounds.size = CGSize(width: lineWidth, height: max(1, bounds.height * scale))
            // `origin.y` is the negated descent, which scales with the image.
            bounds.origin.y *= scale
            fitted.bounds = bounds
            result.addAttribute(.attachment, value: fitted, range: range)
        }
        return result
    }

    /// Width a line fragment actually offers under a paragraph style, once its
    /// list/quote indents are taken out.
    private static func availableLineWidth(containerWidth: CGFloat, paragraph: NSParagraphStyle?) -> CGFloat {
        guard let paragraph else { return max(1, containerWidth) }
        let leading = max(0, max(paragraph.firstLineHeadIndent, paragraph.headIndent))
        // A positive tailIndent is an absolute column; a negative one is an
        // inset from the trailing edge. Zero means the full width.
        let trailingEdge = paragraph.tailIndent > 0
            ? min(containerWidth, paragraph.tailIndent)
            : containerWidth + paragraph.tailIndent
        return max(1, trailingEdge - leading)
    }

    /// Flatten attributed transcript content back to plain text, substituting
    /// `AttachmentText` for image attachments rather than leaking U+FFFC.
    ///
    /// `form` picks which substitution to use — `\.markdown` for quoting,
    /// `\.spoken` for accessibility. An empty substitution drops the run, which
    /// is how decorative rules disappear from both.
    static func plainText(
        in attributed: NSAttributedString,
        range requestedRange: NSRange,
        form: KeyPath<AttachmentText, String>
    ) -> String {
        let range = NSIntersectionRange(requestedRange, NSRange(location: 0, length: attributed.length))
        guard range.length > 0 else { return "" }

        var result = ""
        attributed.enumerateAttributes(in: range) { attributes, runRange, _ in
            if attributes[.attachment] is NSTextAttachment {
                guard let text = attributes[.vellumAttachmentText] as? AttachmentText else { return }
                result += text[keyPath: form]
                return
            }
            result += (attributed.string as NSString).substring(with: runRange)
        }
        return result
    }

    static func measureSize(_ attributed: NSAttributedString, width: CGFloat) -> CGSize {
        guard attributed.length > 0 else { return .zero }
        let storage = NSTextStorage(attributedString: attributed)
        let container = NSTextContainer(size: CGSize(width: width, height: .greatestFiniteMagnitude))
        container.lineFragmentPadding = 0
        let layout = NSLayoutManager()
        layout.addTextContainer(container)
        storage.addLayoutManager(layout)
        layout.ensureLayout(for: container)
        let used = layout.usedRect(for: container)
        guard used.height.isFinite, used.maxX.isFinite else { return .zero }
        // `maxX` rather than `width`: a centered display-math paragraph and an
        // indented blockquote both lay out with a non-zero origin, and the
        // bubble has to be wide enough to hold the line where it actually sits,
        // not just the run of glyphs. Attachments are laid out like any other
        // glyph, so a typeset equation is already accounted for here — an
        // equation too wide for the cap keeps the bubble at the full cap.
        //
        // Re-measuring at this narrower width can't change the answer: every
        // line already fits inside `maxX`, so the greedy line breaker produces
        // the same breaks and therefore the same height.
        return CGSize(width: ceil(used.maxX), height: ceil(used.height))
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        // Refit attachments whenever the bubble's width changes. Guarded so a
        // routine layout pass does not rewrite the text storage (which would
        // clear the selection) on every call.
        if fittedWidth == nil || abs((fittedWidth ?? 0) - bounds.width) > 0.5 {
            textStorage.setAttributedString(Self.fittedAttachments(in: attributed, width: bounds.width))
            fittedWidth = bounds.width
        }
    }

    /// Install or remove the drop interaction to match the panel's handler.
    /// Registered here (not once at setup) because the panel can swap the
    /// handler to nil.
    func setAttachmentDropHandler(_ handler: ((AttachmentDropPayload) -> Void)?) {
        onAttachmentDrop = handler
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
        onAttachmentDrop != nil && session.hasImagePayload
    }

    func dropInteraction(_ interaction: UIDropInteraction, sessionDidEnter session: UIDropSession) {
        onDropTargeted?(true)
    }

    func dropInteraction(
        _ interaction: UIDropInteraction, sessionDidUpdate session: UIDropSession
    ) -> UIDropProposal {
        UIDropProposal(operation: onAttachmentDrop != nil && session.hasImagePayload ? .copy : .cancel)
    }

    func dropInteraction(_ interaction: UIDropInteraction, sessionDidExit session: UIDropSession) {
        onDropTargeted?(false)
    }

    func dropInteraction(_ interaction: UIDropInteraction, sessionDidEnd session: UIDropSession) {
        onDropTargeted?(false)
    }

    /// Classify the whole gesture here, exactly as the panel's `.onDrop` does, so
    /// a mixed drop of three PDFs and a PNG still produces ONE notice naming the
    /// three rather than one per file.
    func dropInteraction(_ interaction: UIDropInteraction, performDrop session: UIDropSession) {
        onDropTargeted?(false)
        guard let onAttachmentDrop else { return }
        let providers = session.items.map(\.itemProvider)
        Task {
            for payload in await AttachmentDrop.payloads(for: providers) {
                onAttachmentDrop(payload)
            }
        }
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
    /// - Parameter mathMaxWidth: widest an image attachment — a typeset equation
    ///   or a thematic rule — may be drawn before it is scaled down. The
    ///   bubble's text width, so both grow with the panel rather than staying
    ///   capped at `contentWidth`, which is only the fallback for callers that
    ///   have no width to offer.
    static func attributedString(
        for content: String,
        color: UIColor,
        secondary: UIColor,
        mathMaxWidth: CGFloat = AiAttributedRenderer.contentWidth
    ) -> NSAttributedString {
        let result = NSMutableAttributedString()
        let blocks = MarkdownParser.parse(content)
        for (index, block) in blocks.enumerated() {
            result.append(attributed(for: block, color: color, secondary: secondary, mathMaxWidth: mathMaxWidth))
            if index < blocks.count - 1 { result.append(NSAttributedString(string: "\n")) }
        }
        return result
    }

    private static func attributed(
        for block: MarkdownBlock,
        color: UIColor,
        secondary: UIColor,
        mathMaxWidth: CGFloat
    ) -> NSAttributedString {
        switch block {
        case let .heading(level, text):
            let font = UIFont.systemFont(ofSize: level == 1 ? 16 : 14, weight: .semibold)
            let paragraph = paragraphStyle(lineSpacing: 2, spacingAfter: 6)
            return inline(text, font: font, color: color, paragraph: paragraph, mathMaxWidth: mathMaxWidth)

        case let .paragraph(text):
            let paragraph = paragraphStyle(lineSpacing: 3, spacingAfter: 8)
            return inline(text, font: base, color: color, paragraph: paragraph, mathMaxWidth: mathMaxWidth)

        case let .list(items):
            return list(items, color: color, mathMaxWidth: mathMaxWidth)

        case let .quote(text):
            let paragraph = paragraphStyle(lineSpacing: 3, spacingAfter: 8)
            paragraph.firstLineHeadIndent = 12
            paragraph.headIndent = 12
            let italic = italicFont(base)
            return inline(text, font: italic, color: secondary, paragraph: paragraph, mathMaxWidth: mathMaxWidth)

        case let .code(text):
            // A run background is the closest an attributed string gets to the
            // SwiftUI renderer's boxed code block.
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
            return displayMath(latex, color: color, mathMaxWidth: mathMaxWidth)

        case .rule:
            return rule(color: secondary, width: mathMaxWidth)
        }
    }

    /// A thematic break (`---`). An attributed string has no "draw a line"
    /// attribute, so the rule is a 1pt-tall image on its own paragraph, sized to
    /// the same bubble content width the math attachments are capped to — which
    /// tracks the panel, so a divider spans the reply instead of stopping at a
    /// 240pt stub in a wide panel. Left with no accessibility description: it is
    /// decorative, and its empty `AttachmentText` keeps it out of quotes and
    /// VoiceOver alike.
    private static func rule(color: UIColor, width: CGFloat) -> NSAttributedString {
        let size = CGSize(width: max(1, width), height: 1)
        let attachment = NSTextAttachment()
        attachment.image = UIGraphicsImageRenderer(size: size).image { context in
            color.withAlphaComponent(0.5).setFill()
            context.fill(CGRect(origin: .zero, size: size))
        }
        attachment.bounds = CGRect(origin: .zero, size: size)
        let paragraph = paragraphStyle(lineSpacing: 0, spacingAfter: 12)
        paragraph.paragraphSpacingBefore = 4
        let result = NSMutableAttributedString(attributedString: NSAttributedString(attachment: attachment))
        result.addAttributes(
            [
                .paragraphStyle: paragraph,
                .foregroundColor: color,
                .vellumAttachmentText: AttachmentText(markdown: "", spoken: ""),
            ],
            range: NSRange(location: 0, length: result.length)
        )
        return result
    }

    /// Display equation as a centered typeset image on its own paragraph;
    /// unparseable LaTeX falls back to monospaced source.
    private static func displayMath(_ latex: String, color: UIColor, mathMaxWidth: CGFloat) -> NSAttributedString {
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
        let result = NSMutableAttributedString(
            attributedString: attachment(for: rendered, maxWidth: mathMaxWidth, latex: latex, display: true))
        result.addAttributes(
            [.paragraphStyle: paragraph, .foregroundColor: color],
            range: NSRange(location: 0, length: result.length)
        )
        return result
    }

    /// Wrap a rendered equation in a text attachment whose bounds sit the image
    /// on the text baseline (negative y = the math's descent below it), scaled
    /// down proportionally when wider than the bubble.
    private static func attachment(
        for rendered: MathRenderer.Rendered,
        maxWidth: CGFloat,
        latex: String,
        display: Bool
    ) -> NSAttributedString {
        let attachment = NSTextAttachment()
        attachment.image = rendered.image
        // The attachment renders as an image with no text; expose the LaTeX
        // source so VoiceOver can read the equation.
        attachment.image?.setAccessibilityDescription(latex)
        var size = rendered.size
        var descent = rendered.descent
        if size.width > maxWidth {
            let scale = maxWidth / size.width
            size = CGSize(width: maxWidth, height: size.height * scale)
            descent *= scale
        }
        attachment.bounds = CGRect(x: 0, y: -descent, width: size.width, height: size.height)
        let result = NSMutableAttributedString(attributedString: NSAttributedString(attachment: attachment))
        // Quoting an equation must round-trip: re-sending the quote should
        // typeset the same equation, so the delimiters have to match the
        // position it was rendered in.
        result.addAttribute(
            .vellumAttachmentText,
            value: AttachmentText(
                markdown: display ? "$$\n\(latex)\n$$" : "$\(latex)$",
                spoken: "Equation: \(latex)"),
            range: NSRange(location: 0, length: result.length))
        return result
    }

    private static var base: UIFont { UIFont.systemFont(ofSize: 14) }

    /// Usable width inside a FALLBACK-width assistant bubble. Attachments can't
    /// be laid out relative to their text container, so anything image-backed —
    /// typeset equations, thematic breaks — is sized against `mathMaxWidth`, and
    /// this is only its default for callers that don't measure.
    static let contentWidth: CGFloat = 240

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

    /// A list, nesting and all. Each item gets its own paragraph style because
    /// the indents are per-depth; `headIndent` sits one marker-width past
    /// `firstLineHeadIndent` so a wrapped item aligns under its own text rather
    /// than back under its bullet.
    ///
    /// Mirrors `MarkdownMessage`'s SwiftUI list, including its `indent` cap.
    private static func list(
        _ items: [MarkdownListItem],
        color: UIColor,
        mathMaxWidth: CGFloat
    ) -> NSAttributedString {
        let result = NSMutableAttributedString()
        for (index, item) in items.enumerated() {
            let indent = 4 + item.indent
            let paragraph = paragraphStyle(lineSpacing: 3, spacingAfter: 4)
            paragraph.firstLineHeadIndent = indent
            paragraph.headIndent = indent + 16
            let line = NSMutableAttributedString(string: "\(item.marker.label)  ", attributes: [
                .font: base, .foregroundColor: color, .paragraphStyle: paragraph,
            ])
            line.append(
                inline(item.text, font: base, color: color, paragraph: paragraph, mathMaxWidth: mathMaxWidth))
            result.append(line)
            if index < items.count - 1 { result.append(NSAttributedString(string: "\n")) }
        }
        return result
    }

    /// Inline handling: math spans become baseline-aligned typeset attachments,
    /// the prose between them carries the emphasis/strong/code/strikethrough/
    /// link attributes `InlineMarkdown` resolved, mapped onto concrete UIKit
    /// fonts. Mirrors the SwiftUI `MarkdownMessage.inlineText` renderer — both go
    /// through `InlineMarkdown` so emphasis spanning an equation survives.
    private static func inline(
        _ source: String,
        font: UIFont,
        color: UIColor,
        paragraph: NSParagraphStyle,
        mathMaxWidth: CGFloat
    ) -> NSAttributedString {
        let result = NSMutableAttributedString()
        for piece in InlineMarkdown.pieces(in: source) {
            switch piece {
            case .prose(let attributed):
                result.append(inlineProse(attributed, font: font, color: color, paragraph: paragraph))
            case .math(let latex):
                if let rendered = MathRenderer.render(latex: latex, fontSize: font.pointSize, color: color, display: false) {
                    let math = NSMutableAttributedString(
                        attributedString: attachment(
                            for: rendered, maxWidth: mathMaxWidth, latex: latex, display: false))
                    // Keep the run's paragraph style so line spacing stays even.
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

    /// Map one already-parsed prose run's markdown attributes onto UIKit fonts
    /// and colors. Takes the parsed `AttributedString` rather than raw source
    /// because `InlineMarkdown` parses the whole line at once.
    private static func inlineProse(
        _ attributed: AttributedString,
        font: UIFont,
        color: UIColor,
        paragraph: NSParagraphStyle
    ) -> NSAttributedString {
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
