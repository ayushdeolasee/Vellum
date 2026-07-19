import SwiftUI
import UniformTypeIdentifiers

struct AiPanel: View {
    @Environment(AiStore.self) private var aiStore
    @Environment(AppStore.self) private var appStore
    @Environment(AnnotationStore.self) private var annotationStore
    @Environment(WorkspaceStore.self) private var workspace
    @Environment(\.palette) private var palette

    /// The sidebar keeps every panel mounted (ContentView's ZStack), so this
    /// one exists — with live AppKit text views (the composer + transcript
    /// bubbles) — even while another tab is in front. Those views are their own
    /// AppKit drag destinations, and AppKit's drag routing ignores SwiftUI's
    /// `opacity(0)`/`allowsHitTesting(false)`; so their drop registration is
    /// gated on actually being the visible tab, otherwise a hidden panel's text
    /// views would swallow drags aimed at the panel on top of it.
    ///
    /// The panel's *own* whole-area drop target no longer lives here: the three
    /// stacked panels share ONE AppKit drag catcher on the sidebar container
    /// (`SidebarDropCatcher` in `SidebarPanelStack`), which dispatches to
    /// `aiStore.handleDrop` when this is the visible tab. That catcher sits
    /// frontmost, so these text views' own drop overrides are unreachable while
    /// it is present — kept only as belt-and-braces. See `SidebarDropRoutingTests`.
    private var isVisibleTab: Bool { workspace.sidebarTab == .ai }

    @State private var input = ""
    @State private var settingsOpen = false
    /// True while an attachable drag hovers the panel (drives the dashed outline).
    @State private var dropTargeted = false
    @State private var imagePickerOpen = false

    var body: some View {
        VStack(spacing: 0) {
            header
            if settingsOpen {
                AiSettingsPanel()
            }
            messages
                // Floating toast for declined attachment drops — overlaid on the
                // messages area so it sits above the composer WITHOUT moving it,
                // and never shoves the transcript the way an inline banner would.
                .overlay(alignment: .bottom) {
                    if let notice = aiStore.attachmentNotice {
                        attachmentNoticeBanner(notice)
                            .padding(12)
                            .transition(.move(edge: .bottom).combined(with: .opacity))
                    }
                }
                .animation(.easeInOut(duration: 0.2), value: aiStore.attachmentNotice)
            composer
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // The whole-area drag destination lives on the sidebar container
        // (`SidebarDropCatcher` in `SidebarPanelStack`), which routes drops here
        // via `aiStore.handleDrop`. This local outline only lights for drags
        // handled by the panel's own AppKit text views (composer / transcript) —
        // reachable only if the container catcher is ever absent; the container
        // draws the sidebar-wide outline for the normal path.
        .overlay {
            if dropTargeted {
                RoundedRectangle(cornerRadius: Radius.md)
                    .strokeBorder(palette.primary, style: StrokeStyle(lineWidth: 2, dash: [6, 4]))
                    .padding(4)
                    .allowsHitTesting(false)
            }
        }
        .fileImporter(
            isPresented: $imagePickerOpen,
            allowedContentTypes: [.image],
            allowsMultipleSelection: true
        ) { result in
            guard case let .success(urls) = result else { return }
            aiStore.attachFiles(at: urls)
        }
    }

    private var header: some View {
        HStack {
            HStack(spacing: 8) {
                Image(systemName: "sparkles")
                    .font(.system(size: 15))
                    .foregroundStyle(palette.primary)
                Text("AI Assistant")
                    .font(.system(size: 14, weight: .medium))
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            Spacer(minLength: 8)
            HStack(spacing: 2) {
                IconButton(
                    variant: settingsOpen ? .active : .ghost,
                    help: "AI settings",
                    action: { settingsOpen.toggle() }
                ) {
                    Image(systemName: "gearshape").font(.system(size: 15))
                }
                .accessibilityIdentifier("aiPanel.settings")
                .accessibilityAddTraits(settingsOpen ? .isSelected : [])
                IconButton(help: "Clear conversation", action: aiStore.clearConversation) {
                    Image(systemName: "trash").font(.system(size: 15))
                }
                .accessibilityIdentifier("aiPanel.clearConversation")
            }
        }
        .foregroundStyle(palette.foreground)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .overlay(alignment: .bottom) { Divider() }
    }

    private var messages: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    if aiStore.messages.isEmpty { emptyState }
                    ForEach(aiStore.messages) { message in
                        // The empty streaming placeholder is represented by the
                        // activity pill below until its first token arrives.
                        if !(message.id == aiStore.streamingMessageId && message.content.isEmpty) {
                            messageRow(message)
                        }
                    }
                    if aiStore.isThinking && aiStore.activity != .streaming { activityPill }
                    if let error = aiStore.error { errorBanner(error) }
                    Color.clear.frame(height: 1).id("ai-bottom")
                }
                .padding(12)
            }
            .onChange(of: aiStore.messages.count) { _, _ in scrollToBottom(proxy) }
            .onChange(of: aiStore.isThinking) { _, _ in scrollToBottom(proxy) }
            // Streaming appends to a single message, so follow its growing length.
            .onChange(of: aiStore.messages.last?.content.count ?? 0) { _, _ in scrollToBottom(proxy) }
        }
        .frame(maxHeight: .infinity)
    }

    private var emptyState: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "sparkles")
                .font(.system(size: 15, weight: .regular))
                .foregroundStyle(palette.primary)
                .frame(width: 30, height: 30)
                .background(palette.muted)
                .clipShape(RoundedRectangle(cornerRadius: Radius.md))
                .overlay { RoundedRectangle(cornerRadius: Radius.md).stroke(palette.border) }

            VStack(alignment: .leading, spacing: 3) {
                Text("Ask about this document")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(palette.foreground)
                Text("The assistant can read the page, jump around, and create notes and highlights for you.")
                    .font(.system(size: 12))
                    .foregroundStyle(palette.mutedForeground)
                    .lineSpacing(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: Radius.lg))
        .overlay { RoundedRectangle(cornerRadius: Radius.lg).strokeBorder(palette.border) }
    }

    private func messageRow(_ message: AiMessage) -> some View {
        VStack(alignment: message.role == .user ? .trailing : .leading, spacing: 4) {
            HStack(spacing: 4) {
                Image(systemName: message.role == .user ? "person" : "sparkles")
                    .font(.system(size: 11))
                Text(message.role == .user ? "You" : "Assistant")
            }
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(palette.mutedForeground)
            .padding(.horizontal, 4)

            messageBubble(message)

            if message.role == .assistant, !message.content.isEmpty {
                messageActions(message)
            }
        }
        .frame(maxWidth: .infinity, alignment: message.role == .user ? .trailing : .leading)
    }

    @ViewBuilder
    private func messageBubble(_ message: AiMessage) -> some View {
        Group {
            if message.role == .assistant {
                SelectableMessageText(
                    content: message.content,
                    color: palette.foreground,
                    secondary: palette.mutedForeground,
                    onQuote: { text in
                        aiStore.addReference(AiReference(kind: .quote(text: text, messageId: message.id)))
                    },
                    // The bubble's NSTextView covers most of the transcript, and
                    // AppKit hands a drop over it to that view rather than to the
                    // panel's `.onDrop` — so it forwards attachment drops here too.
                    onAttachmentDrop: attachmentDropHandler,
                    onDropTargeted: { dropTargeted = $0 }
                )
            } else {
                MarkdownMessage(content: message.content, textColor: palette.primaryForeground)
                    .font(.system(size: 14))
                    .foregroundStyle(palette.primaryForeground)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .frame(maxWidth: 272, alignment: .leading)
        .background(
            message.role == .user
                ? AnyShapeStyle(.tint)
                : AnyShapeStyle(.quaternary.opacity(0.45)))
        .clipShape(UnevenRoundedRectangle(
            topLeadingRadius: message.role == .assistant ? Radius.sm : Radius.xl,
            bottomLeadingRadius: Radius.xl,
            bottomTrailingRadius: Radius.xl,
            topTrailingRadius: message.role == .user ? Radius.sm : Radius.xl
        ))
    }

    /// Copy / Quote / Add-as-note row under each assistant reply.
    private func messageActions(_ message: AiMessage) -> some View {
        HStack(spacing: 2) {
            IconButton(help: "Copy", action: { copyToPasteboard(message.content) }) {
                Image(systemName: "doc.on.doc").font(.system(size: 12))
            }
            .accessibilityIdentifier("aiMessage.copy")

            IconButton(help: "Quote in reply", action: {
                aiStore.addReference(AiReference(kind: .quote(text: message.content, messageId: message.id)))
            }) {
                Image(systemName: "quote.bubble").font(.system(size: 12))
            }
            .accessibilityIdentifier("aiMessage.quote")

            IconButton(help: "Add as note — click on the page to place it", action: {
                appStore.beginNoteWithContent(message.content)
            }) {
                Image(systemName: "note.text.badge.plus").font(.system(size: 12))
            }
            .accessibilityIdentifier("aiMessage.addNote")
        }
        .foregroundStyle(palette.mutedForeground)
        .padding(.leading, 2)
    }

    private func copyToPasteboard(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    private var activityPill: some View {
        HStack(spacing: 8) {
            Image(systemName: "sparkles").font(.system(size: 12)).foregroundStyle(palette.primary)
            Text(activityLabel)
            AnimatedDots()
        }
        .font(.system(size: 12))
        .foregroundStyle(palette.mutedForeground)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: Radius.xl))
        .transition(.opacity)
    }

    private var activityLabel: String {
        switch aiStore.activity {
        case .idle, .streaming, .thinking: return "Thinking"
        case .reading: return "Reading document"
        case .indexing: return "Indexing document"
        case .tool(let summary): return summary
        }
    }

    /// The declined-attachment toast. Modeled on `ScratchpadPanel`'s
    /// `dropWarningBanner` so the two sidebar panels feel consistent: a warning
    /// icon, the wrapping message, and an × to dismiss, on a `.regularMaterial`
    /// card with a destructive-tinted stroke.
    private func attachmentNoticeBanner(_ text: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 13))
                .foregroundStyle(palette.destructive)
            Text(text)
                .font(.system(size: 12))
                .foregroundStyle(palette.foreground)
                // Multi-line notices must wrap, not clip. Safe here (this is not
                // inside an `.inspector`-collapsing toolbar) because the leading
                // `.frame(maxWidth:.infinity)` constrains the width first.
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 8)
            IconButton(help: "Dismiss", action: aiStore.dismissAttachmentNotice) {
                Image(systemName: "xmark").font(.system(size: 11))
            }
            .accessibilityIdentifier("aiPanel.attachmentNotice.dismiss")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: Radius.md))
        .overlay {
            RoundedRectangle(cornerRadius: Radius.md)
                .strokeBorder(palette.destructive.opacity(0.35))
        }
        .accessibilityIdentifier("aiPanel.attachmentNotice")
    }

    private func errorBanner(_ error: String, icon: String? = nil) -> some View {
        Group {
            if let icon {
                Label(error, systemImage: icon)
            } else {
                Text(error)
            }
        }
            .font(.system(size: 12))
            .foregroundStyle(palette.destructive)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(palette.destructive.opacity(0.1))
            .clipShape(RoundedRectangle(cornerRadius: Radius.md))
            .overlay { RoundedRectangle(cornerRadius: Radius.md).stroke(palette.destructive.opacity(0.3)) }
    }

    private var composer: some View {
        VStack(spacing: 6) {
            if let notice = strandedImagesNotice {
                errorBanner(notice, icon: "exclamationmark.triangle")
                    .accessibilityIdentifier("aiPanel.imagesUnsupportedNotice")
            }
            if !aiStore.composerReferences.isEmpty {
                ReferenceChipRow(
                    references: aiStore.composerReferences,
                    onRemove: { aiStore.removeReference(id: $0) }
                )
            }
            composerControls
        }
        .padding(6)
        .glassEffect(.regular, in: .rect(cornerRadius: Radius.xl))
        .padding(12)
        .overlay(alignment: .top) { Divider() }
    }

    private var composerControls: some View {
        HStack(alignment: .bottom, spacing: 8) {
            attachMenu
            ComposerTextView(
                text: $input,
                placeholder: "Ask about this document…",
                onSubmit: submit,
                // The composer's NSTextView is a registered drag destination and
                // AppKit hands it any drop over its bounds before SwiftUI's
                // `.onDrop` sees it — so it forwards attachment drops here instead of
                // pasting a file path. nil means "don't intercept" (no vision).
                onAttachmentDrop: attachmentDropHandler,
                onDropTargeted: { dropTargeted = $0 }
            )
            Button(action: submit) {
                Image(systemName: "paperplane.fill")
                    .font(.system(size: 15))
                    .frame(width: 36, height: 36)
                    .background(.tint, in: RoundedRectangle(cornerRadius: Radius.lg))
                    .foregroundStyle(palette.primaryForeground)
            }
            .buttonStyle(.plain)
            .disabled(!canSend)
            .opacity(canSend ? 1 : 0.4)
            .help("Send message")
            .accessibilityLabel("Send message")
            .accessibilityIdentifier("aiPanel.send")
        }
    }

    /// "+" attach menu: a current-page snapshot or drag-to-crop region of the
    /// open document, plus an arbitrary image from disk.
    private var attachMenu: some View {
        Menu {
            // Both document entries work on web too (the web viewer registers
            // capturePageImageHandler and mounts the same RegionCaptureOverlay);
            // only "no document at all" leaves nothing to snapshot.
            if appStore.document != nil {
                Button {
                    attachCurrentPage()
                } label: {
                    Label("Attach current page", systemImage: "doc.richtext")
                }
                Button {
                    appStore.beginRegionCapture(target: .ai)
                } label: {
                    Label("Snapshot region…", systemImage: "square.dashed")
                }
            }
            // An arbitrary image has nothing to do with the document, so it's
            // offered with or without one — but only to a model that can read it.
            // (Deliberately images-only; dropping is the way to attach other files.)
            if aiStore.activeModelSupportsImages {
                Button {
                    imagePickerOpen = true
                } label: {
                    Label("Attach image…", systemImage: "photo")
                }
                .accessibilityIdentifier("aiPanel.attachImage")
            }
        } label: {
            Image(systemName: "plus")
                .font(.system(size: 15))
                .foregroundStyle(palette.mutedForeground)
                .frame(width: 36, height: 36)
                .contentShape(RoundedRectangle(cornerRadius: Radius.md))
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .disabled(appStore.document == nil && !aiStore.activeModelSupportsImages)
        .help("Attach page, region, or image")
        .accessibilityIdentifier("aiPanel.attach")
    }

    private func attachCurrentPage() {
        let page = appStore.currentPage
        Task {
            guard let image = await aiStore.capturePageImageHandler?(page) else { return }
            aiStore.addReference(AiReference(kind: .pageSnapshot(image: image, page: page)))
        }
    }

    // MARK: - Arbitrary file attachments

    /// Handler the panel's AppKit text views forward their drops to. Set while
    /// this is the visible tab (nil unregisters the views — see `isVisibleTab`);
    /// forwards to the store's shared attach logic. A stranded image (attached,
    /// then the model switched to one without vision) is flagged by
    /// `strandedImagesNotice` rather than blocked at the drop.
    private var attachmentDropHandler: ((AttachmentDropPayload) -> Void)? {
        guard isVisibleTab else { return nil }
        let store = aiStore
        return { drop in
            switch drop {
            case let .files(urls): store.attachFiles(at: urls)
            case let .imageData(data, name): store.attachImage(data: data, name: name)
            }
        }
    }

    /// Attaching is gated on vision support, but the model can be switched
    /// afterwards — and AiStore then sends the message with `images: []` while the
    /// prompt still names the attachment. The chips are the user's, so say what
    /// will happen rather than deleting them.
    private var strandedImagesNotice: String? {
        guard !aiStore.activeModelSupportsImages,
              aiStore.composerReferences.contains(where: { $0.image != nil }) else { return nil }
        return "Image attachments won't be sent — \(aiStore.activeModelName) doesn't support images."
    }

    private var canSend: Bool {
        guard !aiStore.isThinking else { return false }
        return !input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || !aiStore.composerReferences.isEmpty
    }

    private func submit() {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        let references = aiStore.composerReferences
        guard (!trimmed.isEmpty || !references.isEmpty), !aiStore.isThinking else { return }
        // With only references attached, send a light default prompt so the
        // request is non-empty and the model knows to act on them.
        let messageText = trimmed.isEmpty ? "Help me with the attached reference." : trimmed
        input = ""
        aiStore.clearComposerReferences()
        // Capture the session and context synchronously, before any await, so
        // a tab switch during image capture can't send to the wrong tab
        // (mirrors the original's atomic submit -> sendMessage state read).
        let sessionId = appStore.activeTabId
        let document = appStore.document
        let currentPage = appStore.currentPage
        let numPages = appStore.numPages
        let visiblePages = appStore.visiblePages
        let annotations = annotationStore.annotations
        let pageText = aiStore.pageTexts[currentPage]
        let task = Task {
            // Resolve the page's text before the vision-fallback decision. On a
            // cache miss `pageText` is nil, which would wrongly attach an image
            // for a page that actually has a text layer (sendMessage extracts it
            // anyway). Extract first so the decision uses the real text; pages
            // already cached skip the extraction and behave as before.
            var resolvedPageText = pageText
            if resolvedPageText == nil {
                _ = await aiStore.ensureExtracted(pages: [currentPage])
                resolvedPageText = aiStore.pageTexts[currentPage]
            }
            let image: AiPageImageSnapshot?
            if AiStore.shouldAutoAttachPageImage(pageText: resolvedPageText) {
                image = await aiStore.capturePageImageHandler?(currentPage)
            } else {
                image = nil
            }
            guard !Task.isCancelled, appStore.activeTabId == sessionId else { return }
            let context = AiContextSnapshot(
                title: document?.title,
                numPages: numPages,
                currentPage: currentPage,
                visiblePages: visiblePages,
                annotations: annotations,
                currentPageImage: image,
                references: references
            )
            await aiStore.sendMessage(messageText, context: context)
        }
        // Hand the task to the store so clearing the conversation can cancel it.
        aiStore.registerSendTask(task)
    }

    private func scrollToBottom(_ proxy: ScrollViewProxy) {
        DispatchQueue.main.async { proxy.scrollTo("ai-bottom", anchor: .bottom) }
    }
}

/// Three dots that fade in sequence — the "…" of a thinking indicator.
private struct AnimatedDots: View {
    var body: some View {
        TimelineView(.animation(minimumInterval: 0.25)) { context in
            let tick = Int(context.date.timeIntervalSinceReferenceDate * 4) % 3
            HStack(spacing: 3) {
                ForEach(0..<3, id: \.self) { index in
                    Circle()
                        .frame(width: 4, height: 4)
                        .opacity(index == tick ? 1 : 0.3)
                }
            }
        }
        .accessibilityHidden(true)
    }
}

/// Single-line-by-default composer field that grows with content up to a cap.
///
/// SwiftUI won't reliably size an `NSScrollView`-backed representable to its
/// text content, so instead of leaning on intrinsic size we measure the laid-out
/// text height in the coordinator and drive an explicit SwiftUI `frame(height:)`.
/// That keeps the box hugging one centered line when empty (aligned with the
/// +/send buttons) and expanding only as lines are added.
private struct ComposerTextView: View {
    @Binding var text: String
    let placeholder: String
    let onSubmit: () -> Void
    /// A file or image dropped onto the field itself; nil disables interception, so
    /// AppKit's own drag handling (text, file paths) is left alone.
    let onAttachmentDrop: ((AttachmentDropPayload) -> Void)?
    /// Drives the panel's drop outline while such a drag is over the field.
    let onDropTargeted: (Bool) -> Void

    /// One line + vertical insets. Also the floor the box collapses to.
    static let minHeight: CGFloat = 36
    static let maxHeight: CGFloat = 120

    @State private var contentHeight: CGFloat = ComposerTextView.minHeight

    var body: some View {
        ComposerTextViewRep(
            text: $text,
            placeholder: placeholder,
            onSubmit: onSubmit,
            onAttachmentDrop: onAttachmentDrop,
            onDropTargeted: onDropTargeted,
            contentHeight: $contentHeight
        )
        .frame(height: min(max(contentHeight, Self.minHeight), Self.maxHeight))
    }
}

private struct ComposerTextViewRep: NSViewRepresentable {
    @Binding var text: String
    let placeholder: String
    let onSubmit: () -> Void
    let onAttachmentDrop: ((AttachmentDropPayload) -> Void)?
    let onDropTargeted: (Bool) -> Void
    @Binding var contentHeight: CGFloat

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = ComposerDropScrollView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = false
        scroll.onAttachmentDrop = onAttachmentDrop
        scroll.onDropTargeted = onDropTargeted
        let textView = SubmitTextView()
        textView.delegate = context.coordinator
        textView.submit = onSubmit
        textView.onAttachmentDrop = onAttachmentDrop
        textView.onDropTargeted = onDropTargeted
        textView.updateDragTypeRegistration()
        textView.placeholder = placeholder
        textView.drawsBackground = false
        textView.font = .systemFont(ofSize: 14)
        textView.alignment = .left
        // Center a single line vertically in the 36pt composer row: a 14pt system
        // line is ~17pt tall, so (36 - 17) / 2 ≈ 9.5 of top/bottom inset keeps the
        // caret and placeholder centered against the +/send buttons.
        textView.textContainerInset = NSSize(width: 8, height: 9.5)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.minSize = NSSize(width: 0, height: 0)
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.lineFragmentPadding = 0
        scroll.documentView = textView
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let textView = scroll.documentView as? SubmitTextView else { return }
        if let dropScroll = scroll as? ComposerDropScrollView {
            dropScroll.onAttachmentDrop = onAttachmentDrop
            dropScroll.onDropTargeted = onDropTargeted
        }
        context.coordinator.parent = self
        textView.submit = onSubmit
        textView.onAttachmentDrop = onAttachmentDrop
        textView.onDropTargeted = onDropTargeted
        textView.updateDragTypeRegistration()
        textView.placeholder = placeholder
        if textView.string != text { textView.string = text }
        textView.needsDisplay = true
        context.coordinator.publishHeight(for: textView)
    }

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: ComposerTextViewRep
        init(parent: ComposerTextViewRep) { self.parent = parent }

        func textDidChange(_ notification: Notification) {
            guard let view = notification.object as? SubmitTextView else { return }
            parent.text = view.string
            publishHeight(for: view)
        }

        /// Push the fitted content height back to SwiftUI, deferred to the next
        /// runloop tick to avoid "modifying state during view update" churn when
        /// called from `updateNSView`.
        func publishHeight(for textView: SubmitTextView) {
            let height = textView.fittingHeight()
            Task { @MainActor in
                if parent.contentHeight != height { parent.contentHeight = height }
            }
        }
    }
}

/// The scroll view is the stable AppKit surface underneath the composer. Depending
/// on where the pointer lands (padding, clip view, or text), AppKit may select this
/// view instead of its document `NSTextView` as the drag destination, so both
/// surfaces forward the same image payload.
///
/// Internal (not `private`) so `AttachmentDropTests` can drive the real dragging
/// overrides with a fake `NSDraggingInfo` instead of testing a copy of them.
final class ComposerDropScrollView: NSScrollView {
    var onAttachmentDrop: ((AttachmentDropPayload) -> Void)? {
        didSet { updateDropRegistration() }
    }
    var onDropTargeted: ((Bool) -> Void)?

    private func updateDropRegistration() {
        if onAttachmentDrop == nil {
            unregisterDraggedTypes()
        } else {
            registerForDraggedTypes(AttachmentDrop.draggedTypes)
        }
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard onAttachmentDrop != nil, AttachmentDrop.carriesAttachment(sender) else {
            return super.draggingEntered(sender)
        }
        onDropTargeted?(true)
        return .copy
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard onAttachmentDrop != nil, AttachmentDrop.carriesAttachment(sender) else {
            return super.draggingUpdated(sender)
        }
        return .copy
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        onDropTargeted?(false)
        super.draggingExited(sender)
    }

    override func draggingEnded(_ sender: NSDraggingInfo) {
        onDropTargeted?(false)
        super.draggingEnded(sender)
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        onDropTargeted?(false)
        guard let onAttachmentDrop, let payload = AttachmentDrop.payload(sender) else {
            return super.performDragOperation(sender)
        }
        onAttachmentDrop(payload)
        return true
    }
}

/// Internal (not `private`) so `AttachmentDropTests` can drive the real dragging
/// overrides with a fake `NSDraggingInfo` instead of testing a copy of them.
final class SubmitTextView: NSTextView {
    var submit: (() -> Void)?
    var placeholder = ""
    /// An editable NSTextView is a registered drag destination, so AppKit routes
    /// a drop over the composer to it rather than to the panel's SwiftUI
    /// `.onDrop`. Take attachment drops here and forward the payload; everything
    /// else still falls through to `super`, which keeps ordinary text drags
    /// working.
    var onAttachmentDrop: ((AttachmentDropPayload) -> Void)?
    /// Drives the panel's drop outline; the field is its own drag destination, so
    /// SwiftUI's `isTargeted` never fires for a drag that ends up here.
    var onDropTargeted: ((Bool) -> Void)?

    /// NSTextView is itself a drag destination. Register the attachment types
    /// here so Finder drops that land directly on the composer are delivered to
    /// this view instead of disappearing before the panel's SwiftUI `.onDrop`
    /// runs.
    override func updateDragTypeRegistration() {
        if onAttachmentDrop == nil {
            unregisterDraggedTypes()
        } else {
            registerForDraggedTypes(AttachmentDrop.draggedTypes)
        }
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard isAttachmentDrag(sender) else { return super.draggingEntered(sender) }
        onDropTargeted?(true)
        return .copy
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        isAttachmentDrag(sender) ? .copy : super.draggingUpdated(sender)
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        onDropTargeted?(false)
        super.draggingExited(sender)
    }

    override func draggingEnded(_ sender: NSDraggingInfo) {
        onDropTargeted?(false)
        super.draggingEnded(sender)
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        onDropTargeted?(false)
        guard isAttachmentDrag(sender), let drop = AttachmentDrop.payload(sender) else {
            return super.performDragOperation(sender)
        }
        onAttachmentDrop?(drop)
        return true
    }

    private func isAttachmentDrag(_ sender: NSDraggingInfo) -> Bool {
        onAttachmentDrop != nil && AttachmentDrop.carriesAttachment(sender)
    }

    /// Height of the laid-out text plus vertical insets — one line when empty,
    /// growing as content is added.
    func fittingHeight() -> CGFloat {
        guard let layoutManager, let textContainer else { return ComposerTextView.minHeight }
        layoutManager.ensureLayout(for: textContainer)
        let used = layoutManager.usedRect(for: textContainer).height
        return used + textContainerInset.height * 2
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 36, !event.modifierFlags.contains(.shift) {
            submit?()
        } else {
            super.keyDown(with: event)
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard string.isEmpty else { return }
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font ?? NSFont.systemFont(ofSize: 14),
            .foregroundColor: NSColor.secondaryLabelColor,
        ]
        placeholder.draw(at: NSPoint(x: textContainerInset.width, y: textContainerInset.height), withAttributes: attributes)
    }
}
