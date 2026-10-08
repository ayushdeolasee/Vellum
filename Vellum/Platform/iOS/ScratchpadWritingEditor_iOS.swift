#if os(iOS)
import SwiftUI
import UIKit
import PencilKit
import UniformTypeIdentifiers

enum ScratchpadWritingMode: Hashable {
    case text, ink, markdown
}

/// Markdown remains the note's storage format. Native ink is represented by a
/// normal preview image followed by a hidden reference to the editable strokes.
/// Both references travel through the existing attachment/rekey/archive paths.
struct ScratchpadWritingReference {
    var range: NSRange
    var markdown: String
    var imageID: String
    var drawingID: String?

    static func drawingMarkdown(imageID: String, drawingID: String) -> String {
        "![Handwriting](vellum-scratchpad://\(imageID))\n<!-- vellum-drawing: vellum-scratchpad://\(drawingID) -->"
    }

    static func references(in markdown: String) -> [Self] {
        let pattern = #"^!\[[^\]\n]*\]\(vellum-scratchpad://([0-9a-fA-F-]+)\)(?:\n<!-- vellum-drawing: vellum-scratchpad://([0-9a-fA-F-]+) -->)?$"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: .anchorsMatchLines) else { return [] }
        let source = markdown as NSString
        // Do not hide attachment-looking text inside Markdown code fences.
        var fencedRanges: [NSRange] = []
        var fence: (character: Character, count: Int, start: Int)?
        var offset = 0
        for line in markdown.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if let first = trimmed.first, first == "`" || first == "~" {
                let count = trimmed.prefix(while: { $0 == first }).count
                if let open = fence {
                    if first == open.character, count >= open.count,
                       trimmed.dropFirst(count).trimmingCharacters(in: .whitespaces).isEmpty {
                        fencedRanges.append(NSRange(location: open.start, length: offset + (line as NSString).length - open.start))
                        fence = nil
                    }
                } else if count >= 3 {
                    fence = (first, count, offset)
                }
            }
            offset += (line as NSString).length + 1
        }
        if let open = fence {
            fencedRanges.append(NSRange(location: open.start, length: source.length - open.start))
        }
        return regex.matches(in: markdown, range: NSRange(location: 0, length: source.length)).compactMap { match in
            guard !fencedRanges.contains(where: { NSIntersectionRange($0, match.range).length > 0 }) else { return nil }
            let drawingRange = match.range(at: 2)
            return Self(range: match.range, markdown: source.substring(with: match.range),
                        imageID: source.substring(with: match.range(at: 1)).lowercased(),
                        drawingID: drawingRange.location == NSNotFound ? nil : source.substring(with: drawingRange).lowercased())
        }
    }
}

struct ScratchpadWritingEditor: UIViewRepresentable {
    let store: ScratchpadStore
    let mode: ScratchpadWritingMode
    let attachmentRevision: Int
    let fontSize: Double
    let palette: ThemePalette

    func makeUIView(context: Context) -> ScratchpadWritingTextView {
        let view = ScratchpadWritingTextView()
        view.store = store
        view.backgroundColor = .clear
        view.textContainerInset = UIEdgeInsets(top: 12, left: 8, bottom: 24, right: 8)
        view.keyboardDismissMode = .interactive
        view.accessibilityIdentifier = "scratchpad.nativeText"
        view.accessibilityLabel = "Scratchpad text. Write with Apple Pencil to convert handwriting to text."
        view.delegate = view
        view.textPasteDelegate = view
        store.editorUndoManager = view.undoManager
        store.insertMarkdownHandler = { [weak view, weak store] markdown in
            guard let view, let store, view.editorContext == store.editorContext,
                  store.editorAcceptsChanges else { return }
            let prefix = store.text.isEmpty || store.text.hasSuffix("\n\n") ? "" : "\n\n"
            _ = store.acceptEditorChange(store.text + prefix + markdown + "\n", context: view.editorContext)
            view.applyContent()
        }
        view.apply(mode: mode, fontSize: fontSize, palette: palette)
        return view
    }

    func updateUIView(_ view: ScratchpadWritingTextView, context: Context) {
        view.apply(mode: mode, fontSize: fontSize, palette: palette)
    }

    static func dismantleUIView(_ view: ScratchpadWritingTextView, coordinator: ()) {
        view.hideTools()
        view.store?.insertMarkdownHandler = nil
        view.store?.editorUndoManager = nil
        view.delegate = nil
        view.textPasteDelegate = nil
    }
}

/// UITextView supplies UIKit's text input, selection and Scribble integration.
/// Inline view attachments reserve real layout space, so typing cannot overlap ink.
final class ScratchpadWritingTextView: UITextView, UITextViewDelegate, UITextPasteDelegate {
    private let nativeContentStorage: NSTextContentStorage
    weak var store: ScratchpadStore?
    private(set) var editorContext = ""
    private var appliedText = ""
    private var mode: ScratchpadWritingMode = .text
    private let toolPicker = PKToolPicker()
    private weak var activeCanvas: PKCanvasView?
    private var foreground = UIColor.label
    private var textFont = UIFont.systemFont(ofSize: 16)
    private var restoring = false
    private var unresolvedReferences = false
    private var appliedAttachmentRevision = 0
    private let nativeUndoManager = UndoManager()
    override var undoManager: UndoManager? { nativeUndoManager }
    private let placeholderLabel = UILabel()
    var isInking: Bool { mode == .ink && store?.editorAcceptsChanges == true }

    init(frame: CGRect = .zero) {
        let storage = NSTextContentStorage()
        let manager = NSTextLayoutManager()
        storage.addTextLayoutManager(manager)
        let container = NSTextContainer(size: .zero)
        manager.textContainer = container
        nativeContentStorage = storage
        super.init(frame: frame, textContainer: container)
    }

    required init?(coder: NSCoder) { fatalError("Scratchpad editor is constructed programmatically") }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if placeholderLabel.superview == nil {
            placeholderLabel.text = "Type, or write with Apple Pencil to enter text."
            placeholderLabel.textColor = .secondaryLabel
            placeholderLabel.numberOfLines = 0
            placeholderLabel.isUserInteractionEnabled = false
            placeholderLabel.translatesAutoresizingMaskIntoConstraints = false
            addSubview(placeholderLabel)
            NSLayoutConstraint.activate([
                placeholderLabel.leadingAnchor.constraint(equalTo: frameLayoutGuide.leadingAnchor, constant: 13),
                placeholderLabel.trailingAnchor.constraint(equalTo: frameLayoutGuide.trailingAnchor, constant: -13),
                placeholderLabel.topAnchor.constraint(equalTo: contentLayoutGuide.topAnchor, constant: 12)
            ])
        }
    }

    private var drawingAttachments: [ScratchpadDrawingAttachment] {
        var result: [ScratchpadDrawingAttachment] = []
        textStorage.enumerateAttribute(.attachment, in: NSRange(location: 0, length: textStorage.length)) { value, _, _ in
            if let attachment = value as? ScratchpadDrawingAttachment { result.append(attachment) }
        }
        return result
    }

    func apply(mode nextMode: ScratchpadWritingMode, fontSize: Double, palette: ThemePalette) {
        let newFont = UIFont.systemFont(ofSize: fontSize)
        let newForeground = UIColor(palette.foreground)
        let styleChanged = newFont != textFont || newForeground != foreground
        textFont = newFont
        foreground = newForeground
        placeholderLabel.font = textFont
        tintColor = UIColor(palette.primary)
        if styleChanged {
            textStorage.addAttributes([.font: textFont, .foregroundColor: foreground],
                                      range: NSRange(location: 0, length: textStorage.length))
        }
        typingAttributes = [.font: textFont, .foregroundColor: foreground]
        let changedContext = editorContext != store?.editorContext
        if changedContext { hideTools(); undoManager?.removeAllActions() }
        applyContent()
        let previousMode = mode
        mode = nextMode
        isEditable = nextMode == .text && store?.editorAcceptsChanges == true
        isSelectable = store?.editorAcceptsChanges == true
        for attachment in drawingAttachments {
            attachment.canvas?.isUserInteractionEnabled = nextMode == .ink && store?.editorAcceptsChanges == true
        }
        if nextMode == .ink, previousMode != .ink, !changedContext {
            let cursor = min(selectedRange.location, max(0, textStorage.length - 1))
            let existing = textStorage.length > 0 ? textStorage.attribute(.attachment, at: cursor, effectiveRange: nil) as? ScratchpadDrawingAttachment : nil
            if let canvas = existing?.canvas {
                showTools(for: canvas)
            } else {
                insertDrawing()
            }
        }
        if nextMode != .ink { hideTools() }
    }

    func applyContent() {
        guard let store else { return }
        guard editorContext != store.editorContext || appliedText != store.text
                || (unresolvedReferences && appliedAttachmentRevision != store.attachmentRevision) else { return }
        let contextChanged = editorContext != store.editorContext
        if contextChanged {
            nativeUndoManager.removeAllActions()
        } else {
            nativeUndoManager.removeAllActions(withTarget: self)
        }
        editorContext = store.editorContext
        appliedText = store.text
        appliedAttachmentRevision = store.attachmentRevision
        unresolvedReferences = false
        let source = store.text as NSString
        let result = NSMutableAttributedString(string: "")
        var cursor = 0
        for reference in ScratchpadWritingReference.references(in: store.text) {
            result.append(NSAttributedString(string: source.substring(with: NSRange(location: cursor, length: reference.range.location - cursor))))
            let attachment: ScratchpadMarkdownAttachment?
            if let drawingID = reference.drawingID,
               let bytes = store.attachmentResolver.attachment(for: drawingID)?.data,
               let drawing = try? PKDrawing(data: bytes) {
                let ink = ScratchpadDrawingAttachment(reference: reference, drawing: drawing)
                ink.owner = self
                attachment = ink
            } else if reference.drawingID == nil,
                      let bytes = store.attachmentResolver.attachment(for: reference.imageID)?.data,
                      let image = UIImage(data: bytes) {
                let snapshot = ScratchpadMarkdownAttachment(reference: reference)
                snapshot.image = image
                snapshot.allowsTextAttachmentView = false
                let width = max(100, bounds.width - 32)
                let height = width * image.size.height / max(1, image.size.width)
                snapshot.bounds = CGRect(x: 0, y: 0, width: width, height: height)
                attachment = snapshot
            } else {
                attachment = nil // Keep unavailable references visible and recoverable.
                unresolvedReferences = true
            }
            if let attachment {
                result.append(NSAttributedString(attachment: attachment))
            } else {
                result.append(NSAttributedString(string: reference.markdown))
            }
            cursor = NSMaxRange(reference.range)
        }
        result.append(NSAttributedString(string: source.substring(from: cursor)))
        result.addAttributes([.font: textFont, .foregroundColor: foreground], range: NSRange(location: 0, length: result.length))
        let selection = selectedRange
        restoring = true
        attributedText = result
        selectedRange = contextChanged ? NSRange(location: 0, length: 0) : NSRange(location: min(selection.location, result.length), length: 0)
        restoring = false
        placeholderLabel.isHidden = textStorage.length > 0
    }

    func textViewDidChange(_ textView: UITextView) {
        guard !restoring else { return }
        publishText()
    }

    func textPasteConfigurationSupporting(_ supporting: any UITextPasteConfigurationSupporting,
                                          transform item: any UITextPasteItem) {
        guard item.itemProvider.hasItemConformingToTypeIdentifier(UTType.image.identifier) else {
            item.setDefaultResult()
            return
        }
        // Route image paste/drop through the same attachment store as snapshots,
        // rather than persisting a UIKit-only rich-text attachment character.
        item.setNoResult()
        let context = editorContext
        loadScratchpadCapture(from: item.itemProvider) { [weak self] capture in
            DispatchQueue.main.async {
                guard let self, let store = self.store, self.editorContext == context,
                      store.editorContext == context, store.editorAcceptsChanges else { return }
                guard let capture else { store.warnUnsupportedDrop(); return }
                store.addImage(capture, label: "Image")
            }
        }
    }

    private func publishText() {
        placeholderLabel.isHidden = textStorage.length > 0
        var markdown = ""
        textStorage.enumerateAttributes(in: NSRange(location: 0, length: textStorage.length)) { attributes, range, _ in
            if let attachment = attributes[.attachment] as? ScratchpadMarkdownAttachment {
                markdown += attachment.reference.markdown
            } else {
                markdown += (textStorage.string as NSString).substring(with: range)
            }
        }
        guard store?.acceptEditorChange(markdown, context: editorContext) == true else { return }
        appliedText = markdown
    }

    private func insertDrawing() {
        guard store?.editorAcceptsChanges == true else { return }
        endEditing(true)
        let position = min(selectedRange.location, textStorage.length)
        let reference = ScratchpadWritingReference(
            range: .init(location: 0, length: 0),
            markdown: "", imageID: UUID().uuidString.lowercased(), drawingID: UUID().uuidString.lowercased())
        let attachment = ScratchpadDrawingAttachment(reference: reference, drawing: PKDrawing())
        attachment.reference.markdown = ScratchpadWritingReference.drawingMarkdown(imageID: reference.imageID, drawingID: reference.drawingID!)
        attachment.owner = self
        attachment.wantsTools = true
        let insertion = NSMutableAttributedString(string: position > 0 && (textStorage.string as NSString).substring(with: NSRange(location: position - 1, length: 1)) != "\n" ? "\n" : "")
        insertion.append(NSAttributedString(attachment: attachment))
        insertion.append(NSAttributedString(string: "\n"))
        insertion.addAttributes([.font: textFont, .foregroundColor: foreground], range: NSRange(location: 0, length: insertion.length))
        replaceContent(in: NSRange(location: position, length: 0), with: insertion)
        persist(attachment)
        scrollRangeToVisible(NSRange(location: position, length: insertion.length))
    }

    /// Register rich-text insertion/removal with the native undo manager.
    private func replaceContent(in range: NSRange, with content: NSAttributedString) {
        let old = textStorage.attributedSubstring(from: range)
        let undoRange = NSRange(location: range.location, length: content.length)
        undoManager?.registerUndo(withTarget: self) { target in
            target.replaceContent(in: undoRange, with: old)
        }
        textStorage.replaceCharacters(in: range, with: content)
        selectedRange = NSRange(location: range.location + content.length, length: 0)
        publishText()
        content.enumerateAttribute(.attachment, in: NSRange(location: 0, length: content.length)) { value, _, _ in
            if let attachment = value as? ScratchpadDrawingAttachment { persist(attachment) }
        }
    }

    func persist(_ attachment: ScratchpadDrawingAttachment) {
        guard drawingAttachments.contains(where: { $0 === attachment }),
              let drawingID = attachment.reference.drawingID else { return }
        let snapshot = ScratchpadDrawingSnapshot(drawing: attachment.drawing,
                                                imageID: attachment.reference.imageID, drawingID: drawingID)
        store?.queueAttachmentUpdate(id: drawingID, context: editorContext) { snapshot.attachments() }
    }

    func invalidateDrawingLayout() {
        if let manager = textLayoutManager, let range = manager.textContentManager?.documentRange {
            manager.invalidateLayout(for: range)
        }
        setNeedsLayout()
    }

    func showTools(for canvas: PKCanvasView) {
        guard store?.editorAcceptsChanges == true else { return }
        if let previous = activeCanvas, previous !== canvas {
            toolPicker.setVisible(false, forFirstResponder: previous)
            toolPicker.removeObserver(previous)
        }
        activeCanvas = canvas
        canvas.isUserInteractionEnabled = true
        toolPicker.addObserver(canvas)
        toolPicker.setVisible(true, forFirstResponder: canvas)
        canvas.becomeFirstResponder()
    }

    func hideTools() {
        guard let canvas = activeCanvas else { return }
        toolPicker.setVisible(false, forFirstResponder: canvas)
        toolPicker.removeObserver(canvas)
        canvas.resignFirstResponder()
    }
}

class ScratchpadMarkdownAttachment: NSTextAttachment {
    var reference: ScratchpadWritingReference

    init(reference: ScratchpadWritingReference) {
        self.reference = reference
        super.init(data: nil, ofType: nil)
    }

    required init?(coder: NSCoder) { fatalError("Scratchpad attachments are restored from Markdown") }

    override func attachmentBounds(for attributes: [NSAttributedString.Key: Any], location: any NSTextLocation,
                                   textContainer: NSTextContainer?, proposedLineFragment: CGRect, position: CGPoint) -> CGRect {
        guard let image else { return bounds }
        let width = max(100, proposedLineFragment.width)
        return CGRect(x: 0, y: 0, width: width, height: width * image.size.height / max(1, image.size.width))
    }
}

final class ScratchpadDrawingAttachment: ScratchpadMarkdownAttachment {
    static let drawingFileType = "com.ayushdeolasee.vellum.scratchpad-drawing"
    static let drawingWidth: CGFloat = 600
    var drawing: PKDrawing
    weak var owner: ScratchpadWritingTextView?
    weak var canvas: PKCanvasView?
    var wantsTools = false
    var drawingHeight: CGFloat {
        let inkBounds = drawing.bounds
        return max(240, (inkBounds.isNull || inkBounds.isInfinite ? 0 : inkBounds.maxY) + 100)
    }

    init(reference: ScratchpadWritingReference, drawing: PKDrawing) {
        self.drawing = drawing
        super.init(reference: reference)
        fileType = Self.drawingFileType
        allowsTextAttachmentView = true
    }

    required init?(coder: NSCoder) { fatalError("Scratchpad drawings are restored from attachments") }

    override func attachmentBounds(for attributes: [NSAttributedString.Key: Any], location: any NSTextLocation,
                                   textContainer: NSTextContainer?, proposedLineFragment: CGRect, position: CGPoint) -> CGRect {
        let width = max(100, proposedLineFragment.width)
        return CGRect(x: 0, y: 0, width: width, height: max(240, drawingHeight * width / Self.drawingWidth))
    }

    override func viewProvider(for parentView: UIView?, location: any NSTextLocation, textContainer: NSTextContainer?) -> NSTextAttachmentViewProvider? {
        ScratchpadDrawingViewProvider(textAttachment: self, parentView: parentView,
                                      textLayoutManager: textContainer?.textLayoutManager, location: location)
    }
}

/// UIKit invokes attachment-view creation on the UI thread, although this
/// Objective-C override has no actor annotation. Only that callback crosses
/// into the main actor; the provider is never sent to drawing worker tasks.
final class ScratchpadDrawingViewProvider: NSTextAttachmentViewProvider, PKCanvasViewDelegate {
    override func loadView() {
        nonisolated(unsafe) let provider = self
        MainActor.assumeIsolated { provider.makeCanvas() }
    }

    @MainActor
    private func makeCanvas() {
        guard let attachment = textAttachment as? ScratchpadDrawingAttachment else { return }
        let canvas = ScratchpadInlineCanvas()
        canvas.onReady = { [weak attachment, weak canvas] in
            guard let attachment, attachment.wantsTools, let canvas else { return }
            attachment.wantsTools = false
            attachment.owner?.showTools(for: canvas)
        }
        canvas.backgroundColor = .secondarySystemBackground
        canvas.layer.cornerRadius = 8
        canvas.isOpaque = false
        canvas.drawingPolicy = .pencilOnly
        canvas.isScrollEnabled = false
        canvas.drawing = attachment.drawing
        canvas.tool = PKInkingTool(.pen, color: .label, width: 2)
        canvas.delegate = self
        canvas.accessibilityLabel = "Handwriting region. Use Ink mode to draw; type above or below."
        canvas.accessibilityIdentifier = "scratchpad.drawingRegion"
        canvas.isUserInteractionEnabled = attachment.owner?.isInking == true
        attachment.canvas = canvas
        view = canvas
        tracksTextAttachmentViewBounds = true
    }

    override func attachmentBounds(for attributes: [NSAttributedString.Key: Any], location: any NSTextLocation,
                                   textContainer: NSTextContainer?, proposedLineFragment: CGRect, position: CGPoint) -> CGRect {
        guard let attachment = textAttachment as? ScratchpadDrawingAttachment else { return .zero }
        return attachment.attachmentBounds(for: attributes, location: location, textContainer: textContainer,
                                           proposedLineFragment: proposedLineFragment, position: position)
    }

    func canvasViewDidBeginUsingTool(_ canvasView: PKCanvasView) {
        (textAttachment as? ScratchpadDrawingAttachment)?.owner?.showTools(for: canvasView)
    }

    func canvasViewDrawingDidChange(_ canvasView: PKCanvasView) {
        guard let attachment = textAttachment as? ScratchpadDrawingAttachment,
              attachment.owner?.store?.editorAcceptsChanges == true,
              canvasView.drawing != attachment.drawing else { return }
        attachment.drawing = canvasView.drawing
        attachment.owner?.invalidateDrawingLayout()
        attachment.owner?.persist(attachment)
    }
}

private final class ScratchpadInlineCanvas: PKCanvasView {
    var onReady: (() -> Void)?

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window != nil { onReady?() }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let scale = bounds.width / ScratchpadDrawingAttachment.drawingWidth
        guard scale > 0 else { return }
        contentSize = CGSize(width: ScratchpadDrawingAttachment.drawingWidth, height: bounds.height / scale)
        minimumZoomScale = scale
        maximumZoomScale = scale
        if zoomScale != scale { setZoomScale(scale, animated: false) }
    }
}

/// A frozen value snapshot is used by one background task only. PencilKit's
/// drawing copy remains independent of subsequent edits to the canvas.
private struct ScratchpadDrawingSnapshot: @unchecked Sendable {
    let drawing: PKDrawing
    let imageID: String
    let drawingID: String

    func attachments() -> [ScratchpadStagedAttachment] {
        let inkBounds = drawing.bounds
        let height = max(240, (inkBounds.isNull || inkBounds.isInfinite ? 0 : inkBounds.maxY) + 100)
        let rect = CGRect(x: 0, y: 0, width: ScratchpadDrawingAttachment.drawingWidth, height: height)
        let scale = min(2, 2000 / max(rect.width, rect.height))
        guard let preview = drawing.image(from: rect, scale: scale).pngData() else { return [] }
        return [.init(id: drawingID, name: "\(drawingID).drawing", data: drawing.dataRepresentation()),
                .init(id: imageID, name: "\(imageID).png", data: preview)]
    }
}
#endif
