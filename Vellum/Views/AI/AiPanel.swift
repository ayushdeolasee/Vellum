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
                    ForEach(aiStore.messages) { message in messageRow(message) }
                    if aiStore.isThinking { thinkingPill }
                    if let error = aiStore.error { errorBanner(error) }
                    Color.clear.frame(height: 1).id("ai-bottom")
                }
                .padding(12)
            }
            .onChange(of: aiStore.messages.count) { _, _ in scrollToBottom(proxy) }
            .onChange(of: aiStore.isThinking) { _, _ in scrollToBottom(proxy) }
        }
        .frame(maxHeight: .infinity)
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "sparkles")
                .font(.system(size: 20, weight: .light))
                .foregroundStyle(palette.primary)
                .frame(width: 48, height: 48)
                .background(palette.muted)
                .clipShape(Circle())
                .overlay { Circle().stroke(palette.border) }
            Text("Ask anything about this document. The assistant can read the page, jump around, and create notes and highlights for you.")
                .font(.system(size: 12))
                .foregroundStyle(palette.mutedForeground)
                .lineSpacing(3)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 16)
        .padding(.vertical, 32)
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

            MarkdownMessage(content: message.content)
                .font(.system(size: 14))
                .foregroundStyle(message.role == .user ? palette.primaryForeground : palette.foreground)
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
        .frame(maxWidth: .infinity, alignment: message.role == .user ? .trailing : .leading)
    }

    private var thinkingPill: some View {
        HStack(spacing: 8) {
            Image(systemName: "sparkles").font(.system(size: 12)).foregroundStyle(palette.primary)
            Text("Thinking…")
        }
        .font(.system(size: 12))
        .foregroundStyle(palette.mutedForeground)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: Radius.xl))
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
        HStack(alignment: .bottom, spacing: 8) {
            ComposerTextView(text: $input, placeholder: "Ask about this document…", onSubmit: submit)
                .frame(minHeight: 40, maxHeight: 64)
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
            .disabled(input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || aiStore.isThinking)
            .opacity(input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || aiStore.isThinking ? 0.4 : 1)
            .help("Send message")
            .accessibilityLabel("Send message")
            .accessibilityIdentifier("aiPanel.send")
        }
        .padding(6)
        .glassEffect(.regular, in: .rect(cornerRadius: Radius.xl))
        .padding(12)
        .overlay(alignment: .top) { Divider() }
    }

    private func submit() {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !aiStore.isThinking else { return }
        input = ""
        // Capture the session and context synchronously, before any await, so
        // a tab switch during image capture can't send to the wrong tab
        // (mirrors the original's atomic submit -> sendMessage state read).
        let sessionId = appStore.activeTabId
        let document = appStore.document
        let currentPage = appStore.currentPage
        let numPages = appStore.numPages
        let visiblePages = appStore.visiblePages
        let annotations = annotationStore.annotations
        Task {
            let image = await aiStore.capturePageImageHandler?(currentPage)
            guard appStore.activeTabId == sessionId else { return }
            let context = AiContextSnapshot(
                title: document?.title,
                numPages: numPages,
                currentPage: currentPage,
                visiblePages: visiblePages,
                annotations: annotations,
                currentPageImage: image
            )
            await aiStore.sendMessage(trimmed, context: context)
        }
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
        textView.textContainerInset = NSSize(width: 8, height: 6)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true
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
        placeholder.draw(at: NSPoint(x: textContainerInset.width + 5, y: textContainerInset.height), withAttributes: attributes)
    }
}
