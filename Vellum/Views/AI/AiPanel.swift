import SwiftUI
import UniformTypeIdentifiers

struct AiPanel: View {
    @Environment(AiStore.self) private var aiStore
    @Environment(AppStore.self) private var appStore
    @Environment(AnnotationStore.self) private var annotationStore
    @Environment(\.palette) private var palette

    @State private var input = ""
    @State private var settingsOpen = false
    @State private var isListening = false
    @State private var pressingMic = false
    @State private var speechService = SpeechService()
    /// True while an image drag hovers the panel (drives the dashed outline).
    @State private var dropTargeted = false
    @State private var imagePickerOpen = false

    var body: some View {
        VStack(spacing: 0) {
            header
            if settingsOpen {
                AiSettingsPanel(onStopRecognition: stopListening)
            }
            messages
            composer
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .overlay {
            if dropTargeted {
                RoundedRectangle(cornerRadius: Radius.md)
                    .strokeBorder(palette.primary, style: StrokeStyle(lineWidth: 2, dash: [6, 4]))
                    .padding(4)
                    .allowsHitTesting(false)
            }
        }
        // Registering no types at all when the model can't see images is the gate
        // itself: the panel never highlights and the drag springs back to its
        // source, instead of accepting an attachment we'd silently strip at send.
        .onDrop(
            of: aiStore.activeModelSupportsImages ? [.image] : [],
            isTargeted: $dropTargeted,
            perform: handleImageDrop
        )
        .fileImporter(
            isPresented: $imagePickerOpen,
            allowedContentTypes: [.image],
            allowsMultipleSelection: true
        ) { result in
            guard case let .success(urls) = result else { return }
            attachImages(at: urls)
        }
        .onAppear { speakLatestIfNeeded() }
        .onChange(of: aiStore.messages) { _, _ in speakLatestIfNeeded() }
        .onChange(of: aiStore.isThinking) { _, _ in speakLatestIfNeeded() }
        .onChange(of: aiStore.settings.ttsEnabled) { _, _ in speakLatestIfNeeded() }
        .onDisappear {
            speechService.stopRecognition()
            speechService.cancelSpeech()
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
                    // panel's `.onDrop` — so it forwards image drops here too.
                    onImageDrop: imageDropHandler,
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
                // `.onDrop` sees it — so it forwards image drops here instead of
                // pasting a file path. nil means "don't intercept" (no vision).
                onImageDrop: imageDropHandler,
                onDropTargeted: { dropTargeted = $0 }
            )
            if aiStore.settings.voiceMode == .pushToTalk {
                Image(systemName: isListening ? "stop.fill" : "mic")
                    .font(.system(size: 15))
                    .foregroundStyle(isListening ? palette.destructiveForeground : palette.mutedForeground)
                    .frame(width: 36, height: 36)
                    .background(isListening ? palette.destructive : Color.clear)
                    .clipShape(RoundedRectangle(cornerRadius: Radius.md))
                    .contentShape(RoundedRectangle(cornerRadius: Radius.md))
                    .gesture(
                        DragGesture(minimumDistance: 0)
                            .onChanged { _ in startListening() }
                            .onEnded { _ in stopListening() }
                    )
                    .help("Push to talk")
                    .accessibilityLabel(isListening ? "Stop listening" : "Push to talk")
                    .accessibilityAddTraits(.isButton)
                    .accessibilityIdentifier("aiPanel.pushToTalk")
            }
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

    // MARK: - Arbitrary image attachments

    /// Read and normalize each picked file off the main actor (a 48MP photo
    /// spends real time in decode + resize), then attach it as a chip.
    private func attachImages(at urls: [URL]) {
        // App sandbox is off (project.yml), so the picked URL needs no
        // security-scoped bookmark — plain file reads are enough.
        let sessionId = appStore.activeTabId
        for url in urls {
            let name = url.lastPathComponent
            Task {
                let snapshot = await Task.detached(priority: .userInitiated) {
                    guard let data = try? Data(contentsOf: url) else { return AiPageImageSnapshot?.none }
                    return aiImageSnapshot(from: data)
                }.value
                guard let snapshot else { return }
                attachIfCurrent(
                    AiReference(kind: .image(image: snapshot, name: name)), session: sessionId)
            }
        }
    }

    /// A pane's AiStore is shared by all of its tabs, and a tab switch wipes the
    /// composer — so a decode that finishes after the switch would otherwise drop
    /// document A's image into document B's next message. Same session capture
    /// `submit` uses.
    private func attachIfCurrent(_ reference: AiReference, session: String?) {
        guard appStore.activeTabId == session else { return }
        aiStore.addReference(reference)
    }

    /// Handler the panel's AppKit text views forward their drops to. nil when the
    /// model can't read images, which leaves their own drag handling untouched and
    /// matches the SwiftUI `.onDrop` gate above (the drag just springs back).
    private var imageDropHandler: ((ImageDropPayload) -> Void)? {
        guard aiStore.activeModelSupportsImages else { return nil }
        return { drop in
            switch drop {
            case let .file(url): attachImages(at: [url])
            case let .data(data, name): attachImage(data: data, name: name)
            }
        }
    }

    /// Normalize already-loaded image bytes off the main actor and attach them.
    private func attachImage(data: Data, name: String) {
        let store = aiStore
        let app = appStore
        let sessionId = appStore.activeTabId
        Task {
            let snapshot = await Task.detached(priority: .userInitiated) {
                aiImageSnapshot(from: data)
            }.value
            guard let snapshot, app.activeTabId == sessionId else { return }
            store.addReference(AiReference(kind: .image(image: snapshot, name: name)))
        }
    }

    /// Take image drops on the panel — a file from Finder, or raw bytes dragged
    /// out of Preview / a browser (`loadDataRepresentation` on `UTType.image`
    /// covers both, and every conforming subtype, in one request).
    private func handleImageDrop(_ providers: [NSItemProvider]) -> Bool {
        let imageProviders = providers.filter {
            $0.hasItemConformingToTypeIdentifier(UTType.image.identifier)
        }
        guard !imageProviders.isEmpty else { return false }
        let store = aiStore
        let app = appStore
        let sessionId = appStore.activeTabId
        for provider in imageProviders {
            let name = provider.suggestedName ?? "Dropped image"
            // The completion runs off the main actor, so the decode/resize lands
            // there too; only the attach hops back.
            provider.loadDataRepresentation(forTypeIdentifier: UTType.image.identifier) { data, _ in
                guard let data, let snapshot = aiImageSnapshot(from: data) else { return }
                Task { @MainActor in
                    guard app.activeTabId == sessionId else { return }
                    store.addReference(AiReference(kind: .image(image: snapshot, name: name)))
                }
            }
        }
        return true
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

    private func startListening() {
        guard !pressingMic, aiStore.settings.voiceMode == .pushToTalk else { return }
        pressingMic = true
        aiStore.setErrorState(nil)
        Task {
            do {
                try await speechService.startRecognition(
                    onTranscript: { transcript in
                        input = input.isEmpty ? transcript : "\(input) \(transcript)"
                    },
                    onStateChange: { isListening = $0 }
                )
                if !pressingMic { speechService.stopRecognition() }
            } catch {
                isListening = false
                if error.localizedDescription == SpeechService.unavailableMessage {
                    aiStore.setErrorState(SpeechService.unavailableMessage)
                }
            }
        }
    }

    private func stopListening() {
        pressingMic = false
        speechService.stopRecognition()
        isListening = false
    }

    private func speakLatestIfNeeded() {
        guard aiStore.settings.ttsEnabled, !aiStore.isThinking,
              let message = aiStore.messages.last(where: { $0.role == .assistant }) else { return }
        speechService.speak(message: message)
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
    /// An image dropped onto the field itself; nil disables interception, so
    /// AppKit's own drag handling (text, file paths) is left alone.
    let onImageDrop: ((ImageDropPayload) -> Void)?
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
            onImageDrop: onImageDrop,
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
    let onImageDrop: ((ImageDropPayload) -> Void)?
    let onDropTargeted: (Bool) -> Void
    @Binding var contentHeight: CGFloat

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = false
        let textView = SubmitTextView()
        textView.delegate = context.coordinator
        textView.submit = onSubmit
        textView.onImageDrop = onImageDrop
        textView.onDropTargeted = onDropTargeted
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
        context.coordinator.parent = self
        textView.submit = onSubmit
        textView.onImageDrop = onImageDrop
        textView.onDropTargeted = onDropTargeted
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

private final class SubmitTextView: NSTextView {
    var submit: (() -> Void)?
    var placeholder = ""
    /// Set when the active model can read images: an editable NSTextView is a
    /// registered drag destination, so AppKit routes a drop over the composer to
    /// it rather than to the panel's SwiftUI `.onDrop`. Take image drops here and
    /// forward the bytes; everything else still falls through to `super`, which
    /// keeps ordinary text drags working.
    var onImageDrop: ((ImageDropPayload) -> Void)?
    /// Drives the panel's drop outline; the field is its own drag destination, so
    /// SwiftUI's `isTargeted` never fires for a drag that ends up here.
    var onDropTargeted: ((Bool) -> Void)?

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard isImageDrag(sender) else { return super.draggingEntered(sender) }
        onDropTargeted?(true)
        return .copy
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        isImageDrag(sender) ? .copy : super.draggingUpdated(sender)
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
        guard isImageDrag(sender), let drop = ImageDrop.payload(sender) else {
            return super.performDragOperation(sender)
        }
        onImageDrop?(drop)
        return true
    }

    private func isImageDrag(_ sender: NSDraggingInfo) -> Bool {
        onImageDrop != nil && ImageDrop.carriesImage(sender)
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
