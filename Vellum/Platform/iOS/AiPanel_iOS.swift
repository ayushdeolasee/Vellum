#if os(iOS)
import SwiftUI
import UIKit

// Touch-first port of the macOS AI chat panel (Views/AI/AiPanel.swift). Same
// message list, thinking/error/empty states, and settings — but the composer
// is a native SwiftUI TextField/TextEditor instead of an NSTextView, and the
// push-to-talk mic is a plain tap toggle instead of a click-drag gesture
// (there's no mouse-down/mouse-up on a touch surface).
struct AiPanel_iOS: View {
    @Environment(AiStore.self) private var aiStore
    @Environment(AppStore.self) private var appStore
    @Environment(AnnotationStore.self) private var annotationStore
    @Environment(\.palette) private var palette

    @State private var input = ""
    @State private var settingsOpen = false
    @State private var isListening = false
    @State private var speechService = SpeechService()
    @FocusState private var composerFocused: Bool

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
        .background(palette.surface)
        .onAppear { speakLatestIfNeeded() }
        .onChange(of: aiStore.messages) { _, _ in speakLatestIfNeeded() }
        .onChange(of: aiStore.isThinking) { _, _ in speakLatestIfNeeded() }
        .onChange(of: aiStore.settings.ttsEnabled) { _, _ in speakLatestIfNeeded() }
        .onDisappear {
            speechService.stopRecognition()
            speechService.cancelSpeech()
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack {
            HStack(spacing: 8) {
                Image(systemName: "sparkles")
                    .font(.system(size: 15))
                    .foregroundStyle(palette.primary)
                Text("AI Assistant").font(.system(size: 14, weight: .medium))
            }
            Spacer()
            HStack(spacing: 4) {
                touchIconButton(
                    system: "gearshape", label: "AI settings", active: settingsOpen
                ) {
                    settingsOpen.toggle()
                }
                .accessibilityIdentifier("aiPanel.settings")
                touchIconButton(
                    system: "trash", label: "Clear conversation"
                ) {
                    aiStore.clearConversation()
                }
                .accessibilityIdentifier("aiPanel.clearConversation")
            }
        }
        .foregroundStyle(palette.foreground)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .overlay(alignment: .bottom) { Divider() }
    }

    /// A 44pt touch icon button matching the toolbar's Liquid Glass tool
    /// buttons, sized for a compact sidebar header instead of a full pod.
    private func touchIconButton(
        system: String, label: String, active: Bool = false, action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: system)
                .font(.system(size: 15))
                .foregroundStyle(active ? palette.primary : palette.mutedForeground)
                .frame(width: 36, height: 36)
                .background {
                    if active { Circle().fill(palette.primary.opacity(0.16)) }
                }
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
        .accessibilityAddTraits(active ? [.isButton, .isSelected] : .isButton)
    }

    // MARK: - Messages

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
            .scrollDismissesKeyboard(.interactively)
            .onChange(of: aiStore.messages.count) { _, _ in scrollToBottom(proxy) }
            .onChange(of: aiStore.isThinking) { _, _ in scrollToBottom(proxy) }
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

            MarkdownMessage(content: message.content)
                .font(.system(size: 14))
                .foregroundStyle(message.role == .user ? palette.primaryForeground : palette.foreground)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .frame(maxWidth: 320, alignment: .leading)
                .background(
                    message.role == .user
                        ? AnyShapeStyle(palette.primary)
                        : AnyShapeStyle(.quaternary.opacity(0.45)))
                .clipShape(UnevenRoundedRectangle(
                    topLeadingRadius: message.role == .assistant ? Radius.sm : Radius.xl,
                    bottomLeadingRadius: Radius.xl,
                    bottomTrailingRadius: Radius.xl,
                    topTrailingRadius: message.role == .user ? Radius.sm : Radius.xl
                ))
                .contextMenu {
                    Button {
                        UIPasteboard.general.string = message.content
                    } label: {
                        Label("Copy", systemImage: "doc.on.doc")
                    }
                }
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

    // MARK: - Composer

    private var composer: some View {
        HStack(alignment: .bottom, spacing: 8) {
            TextField("Ask about this document…", text: $input, axis: .vertical)
                .font(.system(size: 15))
                .foregroundStyle(palette.foreground)
                .lineLimit(1...4)
                .focused($composerFocused)
                .submitLabel(.send)
                .onSubmit(submit)
                .padding(.horizontal, 10)
                .frame(minHeight: 40)

            if aiStore.settings.voiceMode == .pushToTalk {
                micButton
            }

            Button(action: submit) {
                Image(systemName: "paperplane.fill")
                    .font(.system(size: 15))
                    .frame(width: 44, height: 44)
                    .background(.tint, in: RoundedRectangle(cornerRadius: Radius.lg))
                    .foregroundStyle(palette.primaryForeground)
            }
            .buttonStyle(.plain)
            .disabled(isSendDisabled)
            .opacity(isSendDisabled ? 0.4 : 1)
            .accessibilityLabel("Send message")
            .accessibilityIdentifier("aiPanel.send")
        }
        .padding(6)
        .glassEffect(.regular, in: .rect(cornerRadius: Radius.xl))
        .padding(12)
        .overlay(alignment: .top) { Divider() }
    }

    /// Push-to-talk on a touch surface: tap to start, tap again to stop —
    /// the macOS mouse-down/mouse-up gesture has no touch equivalent, so this
    /// is a simple toggle rather than a hold gesture.
    private var micButton: some View {
        Button {
            isListening ? stopListening() : startListening()
        } label: {
            Image(systemName: isListening ? "stop.fill" : "mic")
                .font(.system(size: 15))
                .foregroundStyle(isListening ? palette.destructiveForeground : palette.mutedForeground)
                .frame(width: 44, height: 44)
                .background(isListening ? palette.destructive : Color.clear)
                .clipShape(RoundedRectangle(cornerRadius: Radius.md))
                .contentShape(RoundedRectangle(cornerRadius: Radius.md))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(isListening ? "Stop listening" : "Push to talk")
        .accessibilityIdentifier("aiPanel.pushToTalk")
    }

    private var isSendDisabled: Bool {
        input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || aiStore.isThinking
    }

    private func submit() {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !aiStore.isThinking else { return }
        input = ""
        // Capture the session and context synchronously, before any await, so
        // a tab switch during image capture can't send to the wrong tab
        // (mirrors the macOS panel's atomic submit -> sendMessage state read).
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

    // MARK: - Voice

    private func startListening() {
        guard aiStore.settings.voiceMode == .pushToTalk else { return }
        aiStore.setErrorState(nil)
        Task {
            do {
                try await speechService.startRecognition(
                    onTranscript: { transcript in
                        input = input.isEmpty ? transcript : "\(input) \(transcript)"
                    },
                    onStateChange: { isListening = $0 }
                )
            } catch {
                isListening = false
                if error.localizedDescription == SpeechService.unavailableMessage {
                    aiStore.setErrorState(SpeechService.unavailableMessage)
                }
            }
        }
    }

    private func stopListening() {
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
#endif
