#if os(iOS)
import PhotosUI
import SwiftUI
import UniformTypeIdentifiers

// Touch-first port of the macOS AI chat panel (Views/AI/AiPanel.swift), brought
// to feature parity: streaming replies, an activity pill (thinking / reading /
// indexing / tool receipts), selectable assistant text with a Quote action,
// composer reference chips, image attachments (drop anywhere on the panel, the
// Photos picker, or the Files importer), a usage line per response, the model
// selector via AI settings, and cancel-in-flight on clear.
//
// Voice/TTS was removed to mirror main. The composer is a native SwiftUI
// TextField that auto-grows, not an NSTextView.
struct AiPanel_iOS: View {
    @Environment(AiStore.self) private var aiStore
    @Environment(AppStore.self) private var appStore
    @Environment(AnnotationStore.self) private var annotationStore
    @Environment(\.palette) private var palette

    @State private var input = ""
    @State private var settingsOpen = false
    /// True while an image drag hovers the panel (drives the dashed outline).
    @State private var dropTargeted = false
    @State private var fileImporterOpen = false
    @State private var photosPickerOpen = false
    @State private var photoItems: [PhotosPickerItem] = []

    var body: some View {
        VStack(spacing: 0) {
            header
            if settingsOpen {
                AiSettingsPanel()
            }
            messages
            composer
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(palette.surface)
        .overlay {
            if dropTargeted {
                RoundedRectangle(cornerRadius: Radius.md)
                    .strokeBorder(palette.primary, style: StrokeStyle(lineWidth: 2, dash: [6, 4]))
                    .padding(4)
                    .allowsHitTesting(false)
            }
        }
        // Both types are needed: a drag out of Files advertises a file URL and
        // NOT an image, so `.image` alone never matches it; Photos and browsers
        // hand over the bytes, which `.image` matches. Registering no types when
        // the model can't read images is the gate itself — the panel never
        // highlights and the drag springs back to its source.
        .onDrop(
            of: aiStore.activeModelSupportsImages ? [.image, .fileURL] : [],
            isTargeted: $dropTargeted,
            perform: handleImageDrop
        )
        .fileImporter(
            isPresented: $fileImporterOpen,
            allowedContentTypes: [.image],
            allowsMultipleSelection: true
        ) { result in
            guard case let .success(urls) = result else { return }
            attachImages(at: urls)
        }
        .photosPicker(
            isPresented: $photosPickerOpen,
            selection: $photoItems,
            maxSelectionCount: AiStore.maxImageReferences,
            matching: .images
        )
        .onChange(of: photoItems) { _, items in
            guard !items.isEmpty else { return }
            attachPhotoItems(items)
            photoItems = []
        }
    }

    // MARK: - Header

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

    /// A touch-sized icon button matching the sidebar header idiom.
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
            .scrollDismissesKeyboard(.interactively)
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
            if let usage = message.usage, !usage.isEmpty {
                usageLine(usage)
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
                    // The bubble's UITextView covers most of the transcript, and
                    // UIKit hands a drop over it to that view rather than to the
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
        .frame(maxWidth: 300, alignment: .leading)
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
            messageActionButton(system: "doc.on.doc", label: "Copy") {
                UIPasteboard.general.string = message.content
            }
            .accessibilityIdentifier("aiMessage.copy")

            messageActionButton(system: "quote.bubble", label: "Quote in reply") {
                aiStore.addReference(AiReference(kind: .quote(text: message.content, messageId: message.id)))
            }
            .accessibilityIdentifier("aiMessage.quote")

            messageActionButton(system: "note.text.badge.plus", label: "Add as note — tap the page to place it") {
                appStore.beginNoteWithContent(message.content)
            }
            .accessibilityIdentifier("aiMessage.addNote")
        }
        .foregroundStyle(palette.mutedForeground)
        .padding(.leading, 2)
    }

    private func messageActionButton(system: String, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: system)
                .font(.system(size: 12))
                .frame(width: 30, height: 30)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }

    /// Compact per-response telemetry (tokens, cache hit, provider cost).
    private func usageLine(_ usage: AiUsage) -> some View {
        Text(usageSummary(usage))
            .font(.system(size: 10))
            .foregroundStyle(palette.mutedForeground)
            .padding(.leading, 4)
            .accessibilityIdentifier("aiMessage.usage")
    }

    private func usageSummary(_ usage: AiUsage) -> String {
        var parts: [String] = []
        if usage.inputTokens > 0 || usage.outputTokens > 0 {
            parts.append("\(usage.inputTokens.formatted()) in / \(usage.outputTokens.formatted()) out")
        }
        if let ratio = usage.cacheHitRatio, ratio > 0 {
            parts.append("\(Int((ratio * 100).rounded()))% cached")
        }
        if let cost = usage.costUSD, cost > 0 {
            parts.append(String(format: "$%.4f", cost))
        }
        return parts.joined(separator: " · ")
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

    // MARK: - Composer

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
            TextField("Ask about this document…", text: $input, axis: .vertical)
                .font(.system(size: 15))
                .foregroundStyle(palette.foreground)
                .lineLimit(1...5)
                .submitLabel(.send)
                .onSubmit(submit)
                .padding(.horizontal, 4)
                .frame(minHeight: 40)
                // A native text input can consume the UIKit drop before the
                // panel-level destination sees it. Register the same handler
                // directly on the composer so "drop anywhere" is literal.
                .onDrop(
                    of: aiStore.activeModelSupportsImages ? [.image, .fileURL] : [],
                    isTargeted: $dropTargeted,
                    perform: handleImageDrop
                )

            Button(action: submit) {
                Image(systemName: "paperplane.fill")
                    .font(.system(size: 15))
                    .frame(width: 40, height: 40)
                    .background(.tint, in: RoundedRectangle(cornerRadius: Radius.lg))
                    .foregroundStyle(palette.primaryForeground)
            }
            .buttonStyle(.plain)
            .disabled(!canSend)
            .opacity(canSend ? 1 : 0.4)
            .accessibilityLabel("Send message")
            .accessibilityIdentifier("aiPanel.send")
        }
    }

    /// "+" attach menu: a current-page snapshot or drag-to-crop region of the
    /// open document, plus an arbitrary image from Photos or Files.
    private var attachMenu: some View {
        Menu {
            // Both document entries work on web too (the web viewer registers
            // capturePageImageHandler and mounts the same region overlay); only
            // "no document at all" leaves nothing to snapshot.
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
                    photosPickerOpen = true
                } label: {
                    Label("Photo Library…", systemImage: "photo")
                }
                .accessibilityIdentifier("aiPanel.attachPhoto")
                Button {
                    fileImporterOpen = true
                } label: {
                    Label("Files…", systemImage: "folder")
                }
                .accessibilityIdentifier("aiPanel.attachFile")
            }
        } label: {
            Image(systemName: "plus")
                .font(.system(size: 15))
                .foregroundStyle(palette.mutedForeground)
                .frame(width: 40, height: 40)
                .contentShape(RoundedRectangle(cornerRadius: Radius.md))
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .disabled(appStore.document == nil && !aiStore.activeModelSupportsImages)
        .accessibilityLabel("Attach page, region, or image")
        .accessibilityIdentifier("aiPanel.attach")
    }

    private func attachCurrentPage() {
        let page = appStore.currentPage
        let sessionId = appStore.activeTabId
        Task {
            guard let image = await aiStore.capturePageImageHandler?(page) else { return }
            guard appStore.activeTabId == sessionId else { return }
            aiStore.addReference(AiReference(kind: .pageSnapshot(image: image, page: page)))
        }
    }

    // MARK: - Arbitrary image attachments

    /// Read and normalize each picked file off the main actor (a 48MP photo
    /// spends real time in decode + resize), then attach it as a chip.
    private func attachImages(at urls: [URL]) {
        let sessionId = appStore.activeTabId
        for url in urls {
            let name = url.lastPathComponent
            Task {
                let snapshot = await Task.detached(priority: .userInitiated) {
                    // Files-picked URLs are security-scoped; open access around
                    // the read.
                    let scoped = url.startAccessingSecurityScopedResource()
                    defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                    guard let data = try? Data(contentsOf: url) else { return AiPageImageSnapshot?.none }
                    return aiImageSnapshot(from: data)
                }.value
                guard let snapshot else { return }
                attachIfCurrent(
                    AiReference(kind: .image(image: snapshot, name: name)), session: sessionId)
            }
        }
    }

    /// Photos-picker items: load each item's bytes, then normalize/attach off the
    /// main actor. Re-checks the active tab before landing each chip.
    private func attachPhotoItems(_ items: [PhotosPickerItem]) {
        let sessionId = appStore.activeTabId
        for (index, item) in items.enumerated() {
            Task {
                guard let data = try? await item.loadTransferable(type: Data.self) else { return }
                let snapshot = await Task.detached(priority: .userInitiated) {
                    aiImageSnapshot(from: data)
                }.value
                guard let snapshot else { return }
                attachIfCurrent(
                    AiReference(kind: .image(image: snapshot, name: "Photo \(index + 1)")),
                    session: sessionId)
            }
        }
    }

    /// A pane's AiStore is shared by all of its tabs, and a tab switch wipes the
    /// composer — so a decode that finishes after the switch would otherwise drop
    /// document A's image into document B's next message.
    private func attachIfCurrent(_ reference: AiReference, session: String?) {
        guard appStore.activeTabId == session else { return }
        aiStore.addReference(reference)
    }

    /// Handler the panel's UITextView bubbles forward their drops to. nil when the
    /// model can't read images, which leaves their own handling untouched and
    /// matches the SwiftUI `.onDrop` gate above (the drag just springs back).
    private var imageDropHandler: (([NSItemProvider]) -> Void)? {
        guard aiStore.activeModelSupportsImages else { return nil }
        return { providers in _ = handleImageDrop(providers) }
    }

    /// Take image drops on the panel — a file from Files, or raw bytes dragged
    /// out of Photos / a browser. Reading, decoding, and resizing all happen off
    /// the main actor; only the attach hops back, and re-checks the active tab.
    private func handleImageDrop(_ providers: [NSItemProvider]) -> Bool {
        let sessionId = appStore.activeTabId
        var handled = false

        for provider in providers {
            if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
                handled = true
                provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier) { item, _ in
                    guard let url = fileURL(fromDropItem: item),
                          let type = UTType(filenameExtension: url.pathExtension),
                          type.conforms(to: .image) else { return }
                    Task { @MainActor in attachImages(at: [url]) }
                }
                continue
            }
            if provider.hasItemConformingToTypeIdentifier(UTType.image.identifier) {
                handled = true
                let name = provider.suggestedName ?? "Dropped image"
                provider.loadDataRepresentation(forTypeIdentifier: UTType.image.identifier) { data, _ in
                    guard let data else { return }
                    let snapshot = aiImageSnapshot(from: data)
                    guard let snapshot else { return }
                    Task { @MainActor in
                        attachIfCurrent(
                            AiReference(kind: .image(image: snapshot, name: name)), session: sessionId)
                    }
                }
            }
        }
        return handled
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
        // Capture the session and context synchronously, before any await, so a
        // tab switch during image capture can't send to the wrong tab.
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
            // anyway). Extract first so the decision uses the real text.
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

/// `NSItemProvider.loadItem` for a file URL hands back whichever of these the
/// drag source registered — a `URL`, an `NSURL`, or the URL's bytes. Nonisolated:
/// it runs on the provider's completion queue, off the main actor.
func fileURL(fromDropItem item: NSSecureCoding?) -> URL? {
    switch item {
    case let url as URL: url
    case let url as NSURL: url as URL
    case let data as Data: URL(dataRepresentation: data, relativeTo: nil)
    default: nil
    }
}
#endif
