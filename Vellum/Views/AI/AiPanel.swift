import SwiftUI

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
                Text("AI Assistant").font(.system(size: 14, weight: .medium))
            }
            Spacer()
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
                    }
                )
            } else {
                MarkdownMessage(content: message.content)
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
        case .tool(let summary): return summary
        }
    }

    private func errorBanner(_ error: String) -> some View {
        Text(error)
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
            ComposerTextView(text: $input, placeholder: "Ask about this document…", onSubmit: submit)
                .frame(minHeight: 36, maxHeight: 64)
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

    /// "+" attach menu: full current-page snapshot or a drag-to-crop region.
    private var attachMenu: some View {
        Menu {
            Button {
                attachCurrentPage()
            } label: {
                Label("Attach current page", systemImage: "doc.richtext")
            }
            Button {
                appStore.setMode(.snapshotRegion)
            } label: {
                Label("Snapshot region…", systemImage: "square.dashed")
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
        .disabled(appStore.document?.kind != .pdf)
        .help("Attach page or region")
        .accessibilityIdentifier("aiPanel.attach")
    }

    private func attachCurrentPage() {
        let page = appStore.currentPage
        Task {
            guard let image = await aiStore.capturePageImageHandler?(page) else { return }
            aiStore.addReference(AiReference(kind: .pageSnapshot(image: image, page: page)))
        }
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
        let task = Task {
            let image = await aiStore.capturePageImageHandler?(currentPage)
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

private struct ComposerTextView: NSViewRepresentable {
    @Binding var text: String
    let placeholder: String
    let onSubmit: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = false
        let textView = SubmitTextView()
        textView.delegate = context.coordinator
        textView.submit = onSubmit
        textView.placeholder = placeholder
        textView.drawsBackground = false
        textView.font = .systemFont(ofSize: 14)
        textView.alignment = .left
        textView.textContainerInset = NSSize(width: 8, height: 6)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        // Without an explicit large maxSize the empty text view reports an
        // oversized intrinsic height and stretches to the frame's max, leaving
        // the placeholder floating at the top. Pin min/max so it collapses to a
        // single line and grows only as content is added.
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
        textView.placeholder = placeholder
        if textView.string != text { textView.string = text }
        textView.needsDisplay = true
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: ComposerTextView
        init(parent: ComposerTextView) { self.parent = parent }
        func textDidChange(_ notification: Notification) {
            guard let view = notification.object as? NSTextView else { return }
            parent.text = view.string
        }
    }
}

private final class SubmitTextView: NSTextView {
    var submit: (() -> Void)?
    var placeholder = ""

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
