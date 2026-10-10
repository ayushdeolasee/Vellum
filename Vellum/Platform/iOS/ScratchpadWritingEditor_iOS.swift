#if os(iOS)
import SwiftUI
import UIKit
import PencilKit
import UniformTypeIdentifiers

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
    @Binding var pencilEnabled: Bool
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
        view.pasteDelegate = view
        store.editorUndoManager = view.undoManager
        store.insertMarkdownHandler = { [weak view, weak store] markdown in
            guard let view, let store, view.editorContext == store.editorContext,
                  store.editorAcceptsChanges else { return }
            let prefix = store.text.isEmpty || store.text.hasSuffix("\n\n") ? "" : "\n\n"
            _ = store.acceptEditorChange(store.text + prefix + markdown + "\n", context: view.editorContext)
            view.applyContent()
        }
        view.apply(pencilEnabled: pencilEnabled, fontSize: fontSize, palette: palette)
        return view
    }

    func updateUIView(_ view: ScratchpadWritingTextView, context: Context) {
        view.apply(pencilEnabled: pencilEnabled, fontSize: fontSize, palette: palette)
    }

    static func dismantleUIView(_ view: ScratchpadWritingTextView, coordinator: ()) {
        view.hideTools(restoringPanning: true)
        view.store?.insertMarkdownHandler = nil
        view.store?.editorUndoManager = nil
        view.delegate = nil
        view.pasteDelegate = nil
    }
}

/// UITextView supplies UIKit's text input, selection and Scribble integration.
/// Inline attachments reserve real layout space, so typing cannot overlap ink.
final class ScratchpadWritingTextView: UITextView, UITextViewDelegate, UITextPasteDelegate, PKCanvasViewDelegate, UIScribbleInteractionDelegate {
    weak var store: ScratchpadStore?
    private(set) var editorContext = ""
    private var appliedText = ""
    private var pencilEnabled = false
    private let toolPicker = PKToolPicker()
    private weak var activeCanvas: PKCanvasView?
    private weak var drawingCanvas: ScratchpadInlineCanvas?
    private var panningBeforeStroke: Bool?
    private var panSettingsBeforeInk: (touchTypes: [NSNumber], minimumTouches: Int)?
    private var interruptingStroke = false
    private var pendingAppearance: (fontSize: Double, palette: ThemePalette)?
    private var contentUpdatePending = false
    private var pendingFocusSelection: NSRange?
    private var preservingInkLayout = false
    private var foreground = UIColor.label
    private var textFont = UIFont.systemFont(ofSize: 16)
    private var restoring = false
    private var unresolvedReferences = false
    private var appliedAttachmentRevision = 0
    private let nativeUndoManager = UndoManager()
    override var undoManager: UndoManager? { nativeUndoManager }
    private let placeholderLabel = UILabel()
    private var placingCanvases = false
    private let markdownStyler = ScratchpadMarkdownStyler()
    var isInking: Bool { pencilEnabled && store?.editorAcceptsChanges == true }
    override var canBecomeFirstResponder: Bool { !isInking && super.canBecomeFirstResponder }

    init(frame: CGRect = .zero) {
        // A nil container lets UITextView install its own TextKit 2 layout manager.
        super.init(frame: frame, textContainer: nil)
        addInteraction(UIScribbleInteraction(delegate: self))
    }

    required init?(coder: NSCoder) { fatalError("Scratchpad editor is constructed programmatically") }

    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        let touches = event?.allTouches ?? []
        if isFirstResponder, event?.type == .touches,
           touches.isEmpty || touches.contains(where: { $0.phase == .began }) {
            pendingFocusSelection = nil
        }
        if isUserInteractionEnabled, isEditable, !isInking, !isFirstResponder,
           !restoring, bounds.contains(point), event?.type == .touches,
           (touches.isEmpty || touches.contains(where: { $0.type == .direct && $0.phase == .began })),
           !touches.contains(where: { touch in
               guard touch.type == .pencil else { return false }
               switch touch.phase {
               case .began, .moved, .stationary: return true
               default: return false
               }
           }),
           let position = closestPosition(to: point),
           caretRect(for: position).intersects(bounds),
           let range = textRange(from: position, to: position) {
            // UIKit can hit-test a touch event before allTouches is populated.
            // Prime the visible insertion point before UIKit focuses its text
            // input child, rather than letting focus restore the end-of-note caret.
            pendingFocusSelection = NSRange(location: offset(from: beginningOfDocument, to: position), length: 0)
            restoring = true
            selectedTextRange = range
            restoring = false
        }
        return super.hitTest(point, with: event)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        guard !placingCanvases else { return }
        placingCanvases = true
        defer { placingCanvases = false }
        let attachments = drawingAttachments
        for canvas in subviews.compactMap({ $0 as? ScratchpadInlineCanvas }) {
            if !attachments.contains(where: { $0 === canvas.attachment }) {
                if activeCanvas === canvas { hideTools(); activeCanvas = nil }
                canvas.removeFromSuperview()
            }
        }
        textStorage.enumerateAttribute(.attachment, in: NSRange(location: 0, length: textStorage.length)) { value, range, _ in
            guard let attachment = value as? ScratchpadDrawingAttachment,
                  let start = position(from: beginningOfDocument, offset: range.location),
                  let end = position(from: start, offset: range.length),
                  let textRange = textRange(from: start, to: end) else { return }
            let rect = firstRect(for: textRange)
            guard !rect.isNull, rect.width > 0, rect.height > 0 else { return }
            let canvas: ScratchpadInlineCanvas
            if let existing = attachment.canvas as? ScratchpadInlineCanvas {
                canvas = existing
            } else {
                canvas = ScratchpadInlineCanvas()
                canvas.attachment = attachment
                canvas.backgroundColor = .clear
                canvas.isOpaque = false
                canvas.drawingPolicy = .pencilOnly
                canvas.isScrollEnabled = false
                canvas.drawing = attachment.drawing
                canvas.tool = PKInkingTool(.pen, color: .label, width: 2)
                canvas.delegate = self
                canvas.drawingGestureRecognizer.addTarget(self, action: #selector(trackPencil(_:)))
                canvas.accessibilityLabel = "Handwriting. Use the Pencil button to draw; type above or below."
                canvas.accessibilityIdentifier = "scratchpad.drawingRegion"
                canvas.onReady = { [weak self, weak attachment, weak canvas] in
                    guard let attachment, attachment.wantsTools, let canvas else { return }
                    attachment.wantsTools = false
                    self?.showTools(for: canvas)
                }
                attachment.canvas = canvas
                canvas.frame = rect
                addSubview(canvas)
            }
            // PencilKit must receive every sample in the same coordinate space.
            // A TextKit/SwiftUI layout pass can happen while a stroke is active.
            if !canvas.isUsingTool, canvas.frame != rect { canvas.frame = rect }
            canvas.isUserInteractionEnabled = isInking
            canvas.accessibilityHint = isInking ? "Scroll the note with a finger between Pencil strokes." : nil
        }
    }

    /// Reserve growth for Pencil lift. Moving the canvas or scrolling its parent
    /// while PencilKit is collecting samples stretches otherwise short strokes.
    @objc private func trackPencil(_ gesture: UIGestureRecognizer) {
        guard !interruptingStroke else { return }
        guard let canvas = drawingAttachments.compactMap(\.canvas).first(where: { $0.drawingGestureRecognizer === gesture }) else { return }
        switch gesture.state {
        case .began, .changed:
            canvasViewDidBeginUsingTool(canvas)
            extendDrawing(canvas, at: gesture.location(in: canvas))
        case .ended, .cancelled, .failed:
            canvasViewDidEndUsingTool(canvas)
        default:
            break
        }
    }

    func extendDrawing(_ canvas: PKCanvasView, at point: CGPoint) {
        guard isInking, let canvas = canvas as? ScratchpadInlineCanvas,
              let attachment = canvas.attachment else { return }
        let scale = max(0.01, canvas.bounds.width / ScratchpadDrawingAttachment.drawingWidth)
        let height = attachment.strokeHeight ?? max(attachment.drawingHeight, attachment.expandedHeight ?? 0)
        if point.y > height * scale - 140 {
            canvas.pendingHeight = max(canvas.pendingHeight ?? 0, height + max(480, bounds.height / scale))
        }
    }

    func canvasViewDidBeginUsingTool(_ canvasView: PKCanvasView) {
        guard !interruptingStroke, isInking, let canvas = canvasView as? ScratchpadInlineCanvas,
              canvas.drawingGestureRecognizer.isEnabled,
              !canvas.isUsingTool, drawingCanvas == nil,
              drawingAttachments.contains(where: { $0 === canvas.attachment }) else { return }
        if let attachment = canvas.attachment {
            attachment.strokeHeight = max(attachment.drawingHeight, attachment.expandedHeight ?? 0)
        }
        canvas.isUsingTool = true
        drawingCanvas = canvas
        stopScrollMotion()
        panningBeforeStroke = panGestureRecognizer.isEnabled
        panGestureRecognizer.isEnabled = false
    }

    func canvasViewDidEndUsingTool(_ canvasView: PKCanvasView) {
        guard !interruptingStroke, let canvas = canvasView as? ScratchpadInlineCanvas,
              canvas.isUsingTool else { return }
        preserveInkAnchor(for: canvas) {
            canvas.isUsingTool = false
            canvas.attachment?.strokeHeight = nil
            if self.drawingCanvas === canvas {
                self.drawingCanvas = nil
                if let panningBeforeStroke = self.panningBeforeStroke {
                    self.panGestureRecognizer.isEnabled = panningBeforeStroke
                }
                self.panningBeforeStroke = nil
            }
            if let height = canvas.pendingHeight, let attachment = canvas.attachment {
                attachment.expandedHeight = max(attachment.expandedHeight ?? 0, height)
                canvas.pendingHeight = nil
            }
            self.canvasViewDrawingDidChange(canvas)
            if let attachment = canvas.attachment, let expanded = attachment.expandedHeight {
                attachment.expandedHeight = max(expanded, attachment.drawingHeight + 480)
            }
            self.showTools(for: canvas)
            if let appearance = self.pendingAppearance {
                self.pendingAppearance = nil
                self.apply(pencilEnabled: self.pencilEnabled, fontSize: appearance.fontSize, palette: appearance.palette)
            }
            if self.contentUpdatePending { self.applyContent() }
        }
    }

    func canvasViewDrawingDidChange(_ canvasView: PKCanvasView) {
        guard let canvas = canvasView as? ScratchpadInlineCanvas,
              let attachment = canvas.attachment,
              drawingAttachments.contains(where: { $0 === attachment }),
              editorContext == store?.editorContext, store?.editorAcceptsChanges == true,
              canvasView.drawing != attachment.drawing else { return }
        let update = {
            attachment.drawing = canvasView.drawing
            if !canvas.isUsingTool {
                if let expanded = attachment.expandedHeight {
                    attachment.expandedHeight = max(expanded, attachment.drawingHeight + 480)
                }
                self.invalidateDrawingLayout()
            }
            self.persist(attachment)
        }
        if canvas.isUsingTool {
            update()
        } else {
            preserveInkAnchor(for: canvas, changes: update)
        }
    }

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

    private var trailingDrawing: ScratchpadDrawingAttachment? {
        let source = textStorage.string as NSString
        var end = source.length
        while end > 0,
              source.substring(with: NSRange(location: end - 1, length: 1))
                .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            end -= 1
        }
        guard end > 0 else { return nil }
        return textStorage.attribute(.attachment, at: end - 1, effectiveRange: nil) as? ScratchpadDrawingAttachment
    }

    func apply(pencilEnabled nextEnabled: Bool, fontSize: Double, palette: ThemePalette) {
        if pencilEnabled != nextEnabled || editorContext != store?.editorContext {
            pendingFocusSelection = nil
        }
        if pencilEnabled, !nextEnabled, !preservingInkLayout,
           editorContext == store?.editorContext,
           let canvas = activeCanvas as? ScratchpadInlineCanvas,
           canvas.superview === self, let attachment = canvas.attachment,
           drawingAttachments.contains(where: { $0 === attachment }) {
            // Enabling text input can follow the trailing caret even when the
            // writing region keeps its height. Anchor the entire transition.
            preserveInkAnchor(for: canvas) {
                self.apply(pencilEnabled: nextEnabled, fontSize: fontSize, palette: palette)
            }
            return
        }
        // Updates from SwiftUI can arrive between any two Pencil samples.
        // Mode/document changes cancel active input before changing its geometry;
        // cosmetic updates wait for a natural Pencil lift.
        if drawingCanvas != nil {
            if nextEnabled, editorContext == store?.editorContext, store?.editorAcceptsChanges == true {
                pendingAppearance = (fontSize, palette)
                return
            }
            hideTools()
        }
        pendingAppearance = nil
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
        let previouslyEnabled = pencilEnabled
        if previouslyEnabled, !nextEnabled { hideTools() }
        for attachment in drawingAttachments {
            attachment.canvas?.isUserInteractionEnabled = nextEnabled && store?.editorAcceptsChanges == true
        }
        if previouslyEnabled, !nextEnabled {
            // Release Pencil focus while text is still read-only, then discard
            // the synthetic caret below the ink. The next tap chooses where to
            // type instead of UIKit scrolling to that old offscreen selection.
            restoring = true
            selectedTextRange = nil
            restoring = false
        }
        pencilEnabled = nextEnabled
        configurePanningForInk(nextEnabled)
        // Scribble must not claim Pencil strokes while the user has chosen ink.
        // Return to text input only when the Pencil button is turned off.
        isEditable = store?.editorAcceptsChanges == true && !nextEnabled
        isSelectable = isEditable
        if nextEnabled, !previouslyEnabled, !changedContext {
            if let existing = trailingDrawing {
                if let canvas = existing.canvas {
                    showTools(for: canvas)
                } else {
                    existing.wantsTools = true
                    setNeedsLayout()
                }
            } else {
                insertDrawing()
            }
        }
        if !nextEnabled {
            hideTools()
            // Retain the mounted writing region so returning to text does not
            // shrink the note and move the visible content.
            invalidateDrawingLayout()
        }
        refreshMarkdown()

    }

    func applyContent() {
        guard let store else { return }
        if drawingCanvas != nil {
            if editorContext == store.editorContext {
                contentUpdatePending = true
                return
            }
            hideTools()
        }
        contentUpdatePending = false
        guard editorContext != store.editorContext || appliedText != store.text
                || (unresolvedReferences && appliedAttachmentRevision != store.attachmentRevision) else { return }
        pendingFocusSelection = nil
        let contextChanged = editorContext != store.editorContext
        // Attachment writes run asynchronously. A same-document text insertion
        // must retain the mounted drawing instead of reading older resolver bytes.
        let liveDrawings = contextChanged ? [] : drawingAttachments
        var availableDrawings = liveDrawings
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
            if let drawingID = reference.drawingID {
                if let index = availableDrawings.firstIndex(where: {
                    $0.reference.drawingID == drawingID && $0.reference.imageID == reference.imageID
                }) {
                    let ink = availableDrawings.remove(at: index)
                    ink.reference = reference
                    attachment = ink
                } else if let live = liveDrawings.first(where: {
                    $0.reference.drawingID == drawingID && $0.reference.imageID == reference.imageID
                }) {
                    // Repeated references need separate views, but share the
                    // latest ink value rather than an older persisted snapshot.
                    attachment = ScratchpadDrawingAttachment(reference: reference, drawing: live.drawing)
                } else if let bytes = store.attachmentResolver.attachment(for: drawingID)?.data,
                          let drawing = try? PKDrawing(data: bytes) {
                    attachment = ScratchpadDrawingAttachment(reference: reference, drawing: drawing)
                } else {
                    attachment = nil
                }
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
            }
            if let attachment {
                result.append(NSAttributedString(attachment: attachment))
            } else {
                unresolvedReferences = true
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
        refreshMarkdown()
    }

    func textViewDidChange(_ textView: UITextView) {
        guard !restoring else { return }
        pendingFocusSelection = nil
        publishText()
        refreshMarkdown()
    }

    func textViewDidBeginEditing(_ textView: UITextView) {
        refreshMarkdown()
    }

    func textView(_ textView: UITextView, shouldChangeTextIn range: NSRange, replacementText text: String) -> Bool {
        pendingFocusSelection = nil
        return true
    }

    func scribbleInteraction(_ interaction: UIScribbleInteraction, shouldBeginAt location: CGPoint) -> Bool {
        !isInking && store?.editorAcceptsChanges == true
    }

    func textViewDidEndEditing(_ textView: UITextView) {
        pendingFocusSelection = nil
        refreshMarkdown()
    }

    func textViewDidChangeSelection(_ textView: UITextView) {
        guard !restoring else { return }
        if isFirstResponder, let pending = pendingFocusSelection {
            pendingFocusSelection = nil
            // UIKit can replace the primed tap position with the trailing caret
            // after focus. Correct only that first collapsed end-of-note selection.
            if selectedRange.length == 0, selectedRange.location == textStorage.length,
               pending.location < textStorage.length {
                restoring = true
                selectedRange = pending
                restoring = false
            }
        }
        refreshMarkdown()
    }

    private func refreshMarkdown() {
        guard !restoring, markedTextRange == nil, drawingCanvas == nil else { return }
        restoring = true
        nativeUndoManager.disableUndoRegistration()
        markdownStyler.apply(to: textStorage, selection: isFirstResponder ? selectedRange : nil,
                                        font: textFont, color: foreground, width: max(100, bounds.width - 26))
        nativeUndoManager.enableUndoRegistration()
        typingAttributes = [.font: textFont, .foregroundColor: foreground]
        restoring = false
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
        var followsAttachment = false
        textStorage.enumerateAttributes(in: NSRange(location: 0, length: textStorage.length)) { attributes, range, _ in
            if let math = attributes[.attachment] as? ScratchpadMathAttachment {
                if followsAttachment { markdown += "\n" }
                markdown += math.openingCharacter
                followsAttachment = false
            } else if let attachment = attributes[.attachment] as? ScratchpadMarkdownAttachment {
                if !markdown.isEmpty, !markdown.hasSuffix("\n") { markdown += "\n" }
                markdown += attachment.reference.markdown
                followsAttachment = true
            } else {
                let text = (textStorage.string as NSString).substring(with: range)
                if followsAttachment, !text.hasPrefix("\n") { markdown += "\n" }
                markdown += text
                followsAttachment = false
            }
        }
        guard store?.acceptEditorChange(markdown, context: editorContext) == true else { return }
        appliedText = markdown
    }

    private func insertDrawing() {
        guard store?.editorAcceptsChanges == true else { return }
        endEditing(true)
        let position = textStorage.length
        let reference = ScratchpadWritingReference(
            range: .init(location: 0, length: 0),
            markdown: "", imageID: UUID().uuidString.lowercased(), drawingID: UUID().uuidString.lowercased())
        let attachment = ScratchpadDrawingAttachment(reference: reference, drawing: PKDrawing())
        attachment.reference.markdown = ScratchpadWritingReference.drawingMarkdown(imageID: reference.imageID, drawingID: reference.drawingID!)
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
        guard !preservingInkLayout else { return }
        invalidateDrawingLayoutImmediately()
    }

    private func invalidateDrawingLayoutImmediately() {
        if let manager = textLayoutManager, let range = manager.textContentManager?.documentRange {
            manager.invalidateLayout(for: range)
        }
        setNeedsLayout()
    }

    private func preserveInkAnchor(for canvas: ScratchpadInlineCanvas, changes: () -> Void) {
        guard !preservingInkLayout, let attachment = canvas.attachment,
              canvas.superview === self,
              drawingAttachments.contains(where: { $0 === attachment }) else {
            changes()
            return
        }
        let context = editorContext
        let origin = canvas.convert(CGPoint.zero, to: self)
        let visibleOrigin = CGPoint(x: origin.x - contentOffset.x, y: origin.y - contentOffset.y)
        preservingInkLayout = true
        defer { preservingInkLayout = false }
        UIView.performWithoutAnimation {
            changes()
            guard editorContext == context, canvas.superview === self,
                  drawingAttachments.contains(where: { $0 === attachment }) else { return }
            // Coalesce growth, late Pencil updates, and deferred editor changes.
            // TextKit may otherwise follow the trailing caret or adjust estimated
            // fragment positions while laying out the larger attachment.
            invalidateDrawingLayoutImmediately()
            if let manager = textLayoutManager, let range = manager.textContentManager?.documentRange {
                manager.ensureLayout(for: range)
            }
            // A corrective offset schedules another scroll-view layout. Settle
            // at most twice rather than leaving an asynchronous scroll correction.
            for _ in 0..<2 {
                layoutIfNeeded()
                canvas.layoutIfNeeded()
                let currentOrigin = canvas.convert(CGPoint.zero, to: self)
                let offset = CGPoint(x: currentOrigin.x - visibleOrigin.x,
                                     y: currentOrigin.y - visibleOrigin.y)
                if contentOffset == offset { break }
                setContentOffset(offset, animated: false)
            }
        }
    }

    func showTools(for canvas: PKCanvasView) {
        guard isInking, drawingCanvas == nil, activeCanvas !== canvas else { return }
        configurePanningForInk(true)
        if let previous = activeCanvas, previous !== canvas {
            toolPicker.setVisible(false, forFirstResponder: previous)
            toolPicker.removeObserver(previous)
        }
        activeCanvas = canvas
        canvas.drawingGestureRecognizer.isEnabled = true
        if let attachment = (canvas as? ScratchpadInlineCanvas)?.attachment {
            attachment.expandedHeight = max(attachment.expandedHeight ?? 0, max(attachment.drawingHeight,
                bounds.height * ScratchpadDrawingAttachment.drawingWidth / max(1, canvas.bounds.width)))
            invalidateDrawingLayout()
        }
        canvas.isUserInteractionEnabled = true
        toolPicker.addObserver(canvas)
        toolPicker.setVisible(true, forFirstResponder: canvas)
        canvas.becomeFirstResponder()
    }

    func hideTools(restoringPanning: Bool = false) {
        guard !interruptingStroke else { return }
        interruptingStroke = true
        defer { interruptingStroke = false }
        pendingAppearance = nil
        if let drawingCanvas {
            // Keep geometry frozen through cancellation and its synchronous
            // delegate callbacks. Queue the latest drawing while the old
            // attachment and editor context are still mounted.
            canvasViewDrawingDidChange(drawingCanvas)
            drawingCanvas.drawingGestureRecognizer.isEnabled = false
            canvasViewDrawingDidChange(drawingCanvas)
            drawingCanvas.isUsingTool = false
            drawingCanvas.attachment?.strokeHeight = nil
            drawingCanvas.pendingHeight = nil
            self.drawingCanvas = nil
        }
        if let panningBeforeStroke { panGestureRecognizer.isEnabled = panningBeforeStroke }
        panningBeforeStroke = nil
        if restoringPanning { configurePanningForInk(false) }
        guard let canvas = activeCanvas else { return }
        activeCanvas = nil
        // Keep the cancelled recognizer disabled until explicit ink activation.
        // Remaining samples from the interrupted touch cannot start another stroke.
        canvas.drawingGestureRecognizer.isEnabled = false
        toolPicker.setVisible(false, forFirstResponder: canvas)
        toolPicker.removeObserver(canvas)
        canvas.resignFirstResponder()
    }

    private func configurePanningForInk(_ enabled: Bool) {
        if enabled {
            guard panSettingsBeforeInk == nil else { return }
            panSettingsBeforeInk = (panGestureRecognizer.allowedTouchTypes,
                                    panGestureRecognizer.minimumNumberOfTouches)
            stopScrollMotion()
            // Fingers keep native scrolling; Pencil input belongs to the canvas.
            panGestureRecognizer.allowedTouchTypes = [NSNumber(value: UITouch.TouchType.direct.rawValue)]
            panGestureRecognizer.minimumNumberOfTouches = 1
            accessibilityHint = "Scroll the note with a finger between Pencil strokes."
        } else if let settings = panSettingsBeforeInk {
            panGestureRecognizer.allowedTouchTypes = settings.touchTypes
            panGestureRecognizer.minimumNumberOfTouches = settings.minimumTouches
            panSettingsBeforeInk = nil
            accessibilityHint = nil
        }
    }

    private func stopScrollMotion() {
        // Stop existing deceleration/scroll animations at their current position
        // without changing scrolling, safe-area insets, or the visible offset.
        setContentOffset(contentOffset, animated: false)
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
    static let drawingWidth: CGFloat = 600
    var drawing: PKDrawing
    weak var canvas: PKCanvasView?
    var wantsTools = false
    var expandedHeight: CGFloat?
    var strokeHeight: CGFloat?
    var drawingHeight: CGFloat {
        let inkBounds = drawing.bounds
        return max(240, (inkBounds.isNull || inkBounds.isInfinite ? 0 : inkBounds.maxY) + 100)
    }

    init(reference: ScratchpadWritingReference, drawing: PKDrawing) {
        self.drawing = drawing
        super.init(reference: reference)
        allowsTextAttachmentView = false
    }

    required init?(coder: NSCoder) { fatalError("Scratchpad drawings are restored from attachments") }

    override func image(for imageBounds: CGRect, attributes: [NSAttributedString.Key: Any],
                        location: any NSTextLocation, textContainer: NSTextContainer?) -> UIImage? {
        // The canvas supplies the drawing. Suppress UIKit's generic file icon
        // for a custom attachment type with no image contents.
        nil
    }

    override func attachmentBounds(for attributes: [NSAttributedString.Key: Any], location: any NSTextLocation,
                                   textContainer: NSTextContainer?, proposedLineFragment: CGRect, position: CGPoint) -> CGRect {
        let width = max(100, proposedLineFragment.width)
        let height = strokeHeight ?? max(drawingHeight, expandedHeight ?? 0)
        return CGRect(x: 0, y: 0, width: width, height: max(44, height * width / Self.drawingWidth))
    }
}

private final class ScratchpadInlineCanvas: PKCanvasView {
    weak var attachment: ScratchpadDrawingAttachment?
    var onReady: (() -> Void)?
    var isUsingTool = false
    var pendingHeight: CGFloat?
    private var configuredBoundsSize: CGSize?

    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        if let touches = event?.allTouches, !touches.isEmpty,
           !touches.contains(where: { touch in
               guard touch.type == .pencil else { return false }
               switch touch.phase {
               case .began, .moved, .stationary: return true
               default: return false
               }
           }) {
            // Let the text view receive direct finger scrolling, including when
            // a Pencil is hovering nearby. Only contact belongs to PencilKit.
            return nil
        }
        return super.hitTest(point, with: event)
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window != nil { onReady?() }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        guard !isUsingTool else { return }
        guard configuredBoundsSize != bounds.size else { return }
        let scale = bounds.width / ScratchpadDrawingAttachment.drawingWidth
        guard scale > 0 else { return }
        configuredBoundsSize = bounds.size
        let size = CGSize(width: ScratchpadDrawingAttachment.drawingWidth, height: bounds.height / scale)
        if contentSize != size { contentSize = size }
        if minimumZoomScale != scale { minimumZoomScale = scale }
        if maximumZoomScale != scale { maximumZoomScale = scale }
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
