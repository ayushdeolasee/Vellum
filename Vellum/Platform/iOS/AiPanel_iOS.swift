#if os(iOS)
import PhotosUI
import SwiftUI
import UniformTypeIdentifiers

// Touch-first port of the macOS AI chat panel (Views/AI/AiPanel.swift), brought
// to feature parity: streaming replies, an activity pill (thinking / reading /
// indexing / tool receipts), selectable assistant text with a Quote action,
// composer reference chips, sent-reference chips and the collapsed "sources &
// actions" trace under each reply, image attachments (drop anywhere on the
// panel, the Photos picker, or the Files importer), a usage line per response,
// the model selector via AI settings, stick-to-bottom scroll follow with a
// Jump-to-latest pill, and clear-with-undo.
//
// Voice/TTS was removed to mirror main. The composer is a native SwiftUI
// TextField that auto-grows, not an NSTextView.
struct AiPanel_iOS: View {
    @Environment(AiStore.self) private var aiStore
    @Environment(AppStore.self) private var appStore
    @Environment(AnnotationStore.self) private var annotationStore
    @Environment(WorkspaceStore.self) private var workspace
    @Environment(\.palette) private var palette
    @Environment(\.undoManager) private var undoManager

    @State private var input = ""
    @State private var settingsOpen = false
    /// True while an attachable drag hovers the panel (drives the dashed outline).
    @State private var dropTargeted = false
    @State private var fileImporterOpen = false
    @State private var photosPickerOpen = false
    @State private var photoItems: [PhotosPickerItem] = []
    /// Focus for the composer, driven by `AiStore.composerFocusRequest` so that
    /// attaching context from elsewhere in the app also raises the keyboard.
    @FocusState private var composerFocused: Bool

    /// Live width of the transcript column. The AI panel shares a resizable
    /// sidebar with the scratchpad and inspector, and bubbles used to be pinned
    /// to a fixed 300pt — so widening it only grew the empty gutter beside them.
    /// Tracking the real width lets `bubbleMaxWidth(for:)` spend the extra space.
    @State private var transcriptWidth: CGFloat = 0

    /// Whether the transcript follows the tail of a streaming reply.
    ///
    /// It used to follow unconditionally — every streamed token re-ran
    /// `scrollToBottom`, so scrolling up to re-read something earlier in the
    /// answer yanked you straight back down and reading back mid-generation was
    /// impossible (issue #57). Now this is the usual "stick to bottom": true
    /// while the reader is parked at the end, false the moment they scroll away,
    /// true again when they come back (or take the Jump to latest shortcut).
    @State private var followsTail = true

    /// How close to the end still counts as "at the bottom", in points. Absorbs
    /// sub-pixel rounding, the 1pt bottom anchor, and the few points a reader
    /// drifts without meaning to leave the tail.
    ///
    /// Must stay above the transcript's 12pt bottom padding: `scrollToBottom`
    /// aligns the 1pt `ai-bottom` anchor with the viewport's bottom edge, which
    /// leaves that padding below it — so even a perfectly followed transcript
    /// reports ~12pt of `distanceFromBottom`.
    static let bottomSlack: CGFloat = 24

    var body: some View {
        VStack(spacing: 0) {
            header
            if !aiStore.settings.isConfigured(chatGPTSignedIn: workspace.chatgptAuth.isSignedIn) {
                configureAiBanner
            }
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
        // Registered unconditionally — see `AttachmentDrop.draggedTypes`. A drop
        // the panel can't use is declined with a notice naming the files, which
        // is far more legible than a drag that springs back to its source.
        .onDrop(
            of: AttachmentDrop.draggedTypes,
            isTargeted: $dropTargeted,
            perform: handleAttachmentDrop
        )
        .fileImporter(
            isPresented: $fileImporterOpen,
            allowedContentTypes: [.image],
            allowsMultipleSelection: true
        ) { result in
            guard case let .success(urls) = result else { return }
            // The store owns the security-scoped read, the images-only policy,
            // the decline notices and the tab-identity guard — the panel just
            // hands over the URLs.
            aiStore.attachFiles(at: urls)
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
        // Attaching context is always the prelude to typing about it, so an
        // "Add to AI Chat" action anywhere in the app raises the keyboard here.
        .onChange(of: aiStore.composerFocusRequest) { _, request in
            guard let request else { return }
            composerFocused = true
            aiStore.consumeComposerFocusRequest(request)
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
                    system: "trash", label: "Clear AI conversation",
                    disabled: aiStore.messages.isEmpty, action: clearConversation
                )
                .accessibilityIdentifier("aiPanel.clearConversation")
            }
        }
        .foregroundStyle(palette.foreground)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .overlay(alignment: .bottom) { Divider() }
    }

    /// Clear first, then register Undo if this context has an undo manager.
    /// SwiftUI only supplies `\.undoManager` where the environment supports
    /// undo, so gating the clear itself on one would leave the only clear
    /// affordance permanently disabled wherever it is absent.
    private func clearConversation() {
        guard let transaction = aiStore.clearConversation() else { return }
        guard let undoManager else { return }
        registerConversationUndo(transaction, store: aiStore, undoManager: undoManager)
    }

    /// Shown until there is a usable provider credential. On iPad the button
    /// reveals the panel's own inline `AiSettingsPanel` rather than opening a
    /// separate Settings window — that inline panel is the iPad's only
    /// in-context path to the provider/model pickers.
    private var configureAiBanner: some View {
        HStack(spacing: 8) {
            Image(systemName: "key")
                .foregroundStyle(palette.mutedForeground)
            Text("Configure AI to start chatting.")
                .font(.system(size: 12))
                .foregroundStyle(palette.mutedForeground)
            Spacer(minLength: 4)
            Button("Configure AI in Settings") { settingsOpen = true }
                .buttonStyle(.borderless)
                .accessibilityIdentifier("aiPanel.configureAi")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(palette.surfaceMuted)
        .overlay(alignment: .bottom) { Divider() }
    }

    /// A touch-sized icon button matching the sidebar header idiom.
    ///
    /// `disabled` is a parameter rather than a `.disabled(_:)` applied at the
    /// call site so the dimmed styling lives with the enabled styling: every
    /// header control dims the same way instead of each caller inventing its own
    /// opacity.
    private func touchIconButton(
        system: String, label: String, active: Bool = false, disabled: Bool = false,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: system)
                .font(.system(size: 15))
                .foregroundStyle(active ? palette.primary : palette.mutedForeground)
                .opacity(disabled ? 0.4 : 1)
                .frame(width: 36, height: 36)
                .background {
                    if active { Circle().fill(palette.primary.opacity(0.16)) }
                }
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .disabled(disabled)
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
                .padding(transcriptPadding)
            }
            .scrollDismissesKeyboard(.interactively)
            // Width only — the scroll geometry below tracks the vertical side.
            // Separate observers on purpose: this one has to fire on a sidebar
            // drag, which does not move the scroll offset at all.
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { transcriptWidth = $0 }
            .onScrollGeometryChange(for: ScrollMetrics.self) { geometry in
                ScrollMetrics(
                    offsetY: geometry.contentOffset.y,
                    contentHeight: geometry.contentSize.height,
                    viewportHeight: geometry.containerSize.height
                )
            } action: { old, new in
                let wasFollowing = followsTail
                followsTail = Self.follows(was: wasFollowing, from: old, to: new)
                // A viewport that shrank under a *followed* transcript has just
                // pushed the tail off the bottom of the screen without anyone
                // scrolling, and nothing else will put it back: `followTail` only
                // runs on a message/token change, which may be a long way off —
                // or never, if the reply already finished. Close the gap here.
                // On iPad the software keyboard appearing is exactly this case.
                if followsTail, wasFollowing,
                   new.viewportHeight != old.viewportHeight,
                   new.distanceFromBottom > Self.bottomSlack {
                    scrollToBottom(proxy)
                }
            }
            .onChange(of: aiStore.messages.count) { _, _ in
                // A cleared conversation has no tail to be away from.
                if aiStore.messages.isEmpty { followsTail = true }
                followTail(proxy)
            }
            // A tab switch swaps the whole transcript: `AiStore` reloads
            // `messages` for the incoming document. Whatever the reader had
            // scrolled away from no longer exists, so re-arm rather than opening
            // an unrelated conversation stranded mid-history behind a Jump to
            // latest pill. (The message *count* can easily match across the two
            // conversations, so the `messages.count` handler above is not enough.)
            .onChange(of: appStore.activeTabId) { _, _ in
                followsTail = true
                followTail(proxy)
            }
            .onChange(of: aiStore.isThinking) { _, _ in followTail(proxy) }
            // Streaming appends to a single message, so follow its growing length.
            .onChange(of: aiStore.messages.last?.content.count ?? 0) { _, _ in followTail(proxy) }
            // Both float over the transcript so they sit above the composer
            // WITHOUT moving it, and never shove the transcript the way an
            // inline banner would — which would itself shrink the viewport and
            // unstick a reader who never scrolled. Stacked rather than overlaid
            // on each other so a declined drop and a scrolled-up reader coexist.
            .overlay(alignment: .bottom) {
                VStack(spacing: 8) {
                    if showsJumpToLatest {
                        jumpToLatestButton(proxy)
                            .transition(.move(edge: .bottom).combined(with: .opacity))
                    }
                    if let notice = aiStore.attachmentNotice {
                        attachmentNoticeBanner(notice)
                            .transition(.move(edge: .bottom).combined(with: .opacity))
                    }
                }
                .padding(12)
            }
            .animation(.easeInOut(duration: 0.2), value: aiStore.attachmentNotice)
            .animation(.easeInOut(duration: 0.2), value: showsJumpToLatest)
        }
        .frame(maxHeight: .infinity)
    }

    /// Inset around the transcript's content, subtracted from the measured
    /// scroll-view width to get the usable column.
    private let transcriptPadding: CGFloat = 12

    /// Widest a bubble of `role` may be, for the transcript width measured above.
    private func bubbleMaxWidth(for role: AiRole) -> CGFloat {
        Self.bubbleMaxWidth(for: role, contentWidth: transcriptWidth - transcriptPadding * 2)
    }

    /// Widest a bubble of `role` may be inside a content column of
    /// `contentWidth` points. Assistant replies are long-form (prose, code,
    /// typeset math) so they take the whole column; user messages stop a little
    /// short of it, which is what keeps the trailing-aligned "You" bubbles
    /// readable as a distinct column at any panel width.
    ///
    /// Before the first geometry pass — and if the measurement ever comes back
    /// degenerate — this falls back to the pre-resize 272pt so a bubble is
    /// never laid out at zero width. `isFinite` is checked alongside `> 0`
    /// because this width is also the cap handed to the math rasterizers: an
    /// infinite column wouldn't just look odd, it would switch off equation
    /// downscaling altogether and let a wide display equation overflow.
    ///
    /// Static (and not private) so those degenerate inputs are testable without
    /// mounting the panel and the four stores it reads from the environment.
    static func bubbleMaxWidth(for role: AiRole, contentWidth: CGFloat) -> CGFloat {
        let column = contentWidth.isFinite && contentWidth > 0 ? max(contentWidth, 160) : 272
        guard role == .user else { return column }
        return max(column * 0.82, min(column, 200))
    }

    /// The scroll state the stick-to-bottom rule is derived from. Equatable so
    /// `onScrollGeometryChange` only wakes us when one of these actually moves.
    struct ScrollMetrics: Equatable {
        var offsetY: CGFloat
        var contentHeight: CGFloat
        var viewportHeight: CGFloat

        /// Points of content below the viewport. Clamped at zero so rubber-band
        /// overscroll past the end doesn't read as "far from the bottom".
        var distanceFromBottom: CGFloat {
            max(0, contentHeight - viewportHeight - offsetY)
        }
    }

    /// The stick-to-bottom rule itself: given the previous scroll state and the
    /// new one, should the transcript still follow the tail?
    ///
    /// Lifted out of the `onScrollGeometryChange` closure and made pure so it can
    /// be exercised headlessly (`AiTranscriptFollowTests`). Every scenario this
    /// has to get right — a reader scrolling up mid-stream, scrolling back down,
    /// the panel's own chrome resizing underneath them — otherwise needs a live
    /// streamed reply to reproduce, which is why the original went out untested.
    ///
    /// Being away from the end is not by itself evidence the reader moved. Three
    /// very different things land us there and only one of them is a person:
    ///  • the transcript grew, so a streamed token moved the end away from a
    ///    stationary reader. That must NOT unstick them, which is exactly what a
    ///    naive "am I at the end?" test would do.
    ///  • the viewport shrank, which moves the end away by just as much with
    ///    nobody touching the scroller. This panel does that constantly: opening
    ///    the settings section, a reference chip appearing, the composer growing
    ///    from 36pt to 120pt as the user types a multi-line question, or the
    ///    window being resized all steal height from the transcript. Watching
    ///    only `contentHeight` here meant typing a three-line question unstuck a
    ///    reader who had never scrolled, froze the streaming reply in place and
    ///    popped the Jump to latest pill.
    ///  • the offset moved, i.e. the reader scrolled. This is the signal that
    ///    stops us following.
    ///
    /// A resize is still conclusive in one direction: neither appending text nor
    /// shrinking the viewport can move you UP, so an offset that decreased across
    /// one is unambiguously the reader. (The viewport *growing* can clamp the
    /// offset down, but only for a reader already at the end — who is caught by
    /// the at-the-bottom check first.)
    static func follows(was following: Bool, from old: ScrollMetrics, to new: ScrollMetrics) -> Bool {
        // Parked at the end IS the followed state, however the reader got there
        // — this is what re-arms following when they scroll back down by hand
        // mid-generation.
        guard new.distanceFromBottom > bottomSlack else { return true }
        let resized = new.contentHeight != old.contentHeight
            || new.viewportHeight != old.viewportHeight
        guard !resized || new.offsetY < old.offsetY else { return following }
        return false
    }

    /// Offered only while there is a tail worth returning to.
    private var showsJumpToLatest: Bool {
        !followsTail && !aiStore.messages.isEmpty
    }

    /// Shortcut back to the end of a reply the reader scrolled away from, which
    /// also re-arms follow-the-tail. Uses the composer's glass treatment so it
    /// reads as a floating control rather than transcript content.
    private func jumpToLatestButton(_ proxy: ScrollViewProxy) -> some View {
        Button {
            followsTail = true
            scrollToBottom(proxy)
        } label: {
            HStack(spacing: 5) {
                Image(systemName: "arrow.down")
                    .font(.system(size: 10, weight: .semibold))
                Text("Jump to latest")
                    .font(.system(size: 11, weight: .medium))
            }
            .foregroundStyle(palette.foreground)
            .padding(.horizontal, 12)
            // Taller than the Mac's 6pt: this is a finger target, and the pill
            // floats over the transcript with nothing else nearby to mis-hit.
            .padding(.vertical, 10)
            .frame(minHeight: 36)
            .glassEffect(.regular, in: .capsule)
            .overlay { Capsule().strokeBorder(palette.border.opacity(0.6)) }
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("aiPanel.jumpToLatest")
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

            // What this prompt was sent with. Sits above the bubble rather than
            // inside it because the referenced text is not part of the message
            // body — it travelled in the prompt's context block — so folding it
            // into the bubble would misrepresent what the user actually typed.
            if !message.references.isEmpty {
                SentReferenceChips(
                    references: message.references,
                    onGoToPage: { appStore.goToPage($0) },
                    // Pixels for an image reference don't live on the message —
                    // they're stripped before it is persisted — so the store
                    // resolves them from this session's cache. nil means "not
                    // previewable", which the popover states outright.
                    previewData: { aiStore.referencePreviewData(for: $0) },
                    // The same cap the bubble below gets, so the chips wrap on
                    // the bubble's column instead of the full transcript width.
                    maxWidth: bubbleMaxWidth(for: message.role)
                )
            }

            messageBubble(message)

            if message.role == .assistant, !message.content.isEmpty {
                let summaries = message.displayToolSummaries
                if summaries.isEmpty == false {
                    toolSummaries(summaries)
                }
                messageActions(message)
            }
            if let usage = message.usage, !usage.isEmpty {
                usageLine(usage)
            }
        }
        .frame(maxWidth: .infinity, alignment: message.role == .user ? .trailing : .leading)
    }

    /// The collapsed "what I looked at" trace under an assistant reply.
    ///
    /// Deliberately a SIBLING of the bubble rather than content inside it, and
    /// so deliberately NOT wrapped in `BubbleWidthCap`. The bubble hugs its
    /// prose because a two-word reply shouldn't paint a slab; a source list is
    /// a stack of rows that genuinely wants the whole column, and hugging it
    /// would make every disclosure row a different width. `.infinity` here is
    /// therefore the right answer and does not compete with the bubble's cap —
    /// the two never lay out the same subtree.
    private func toolSummaries(_ summaries: [AiToolSummary]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Sources & actions")
                .font(.caption)
                .foregroundStyle(palette.mutedForeground)
                .padding(.horizontal, 4)

            ForEach(summaries) { summary in
                AiToolSummaryView(summary: summary, onJumpToPage: appStore.goToPage)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Sources and actions")
    }

    @ViewBuilder
    private func messageBubble(_ message: AiMessage) -> some View {
        // Text width inside the bubble: the bubble's cap minus its own padding.
        // Handed to the renderers explicitly so they can cap typeset math images,
        // which can't read the SwiftUI frame back out.
        let bubbleWidth = bubbleMaxWidth(for: message.role)
        let textWidth = max(bubbleWidth - 24, 80)
        BubbleWidthCap(maxWidth: textWidth) {
            if message.role == .assistant {
                SelectableMessageText(
                    // `displayContent`, not `content`: a reply persisted by an
                    // older build has its tool receipts glued onto the end of
                    // the text. Those are now rendered as a separate collapsed
                    // trace, so they have to come off the bubble — without
                    // rewriting what is stored on disk.
                    content: message.displayContent,
                    color: palette.foreground,
                    secondary: palette.mutedForeground,
                    maxWidth: textWidth,
                    onQuote: { text in
                        aiStore.addReference(AiReference(kind: .quote(text: text, messageId: message.id)))
                    },
                    // The bubble's UITextView covers most of the transcript, and
                    // UIKit hands a drop over it to that view rather than to the
                    // panel's `.onDrop` — so it forwards attachment drops here too.
                    onAttachmentDrop: attachmentDropHandler,
                    onDropTargeted: { dropTargeted = $0 }
                )
            } else {
                MarkdownMessage(
                    content: message.content,
                    textColor: palette.primaryForeground,
                    mathMaxWidth: textWidth,
                    // Hug, so a short "You" message is a small tinted bubble
                    // rather than a bar the width of the panel. The other
                    // MarkdownMessage hosts keep the filling default.
                    fillsAvailableWidth: false
                )
                .font(.system(size: 14))
                .foregroundStyle(palette.primaryForeground)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
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
    ///
    /// All three act on `displayContent` — the answer as shown in the bubble.
    /// Copying a reply must not silently drag a legacy "Actions:" receipt list
    /// into the user's clipboard or into a note they place on the page.
    private func messageActions(_ message: AiMessage) -> some View {
        HStack(spacing: 2) {
            messageActionButton(system: "doc.on.doc", label: "Copy answer") {
                UIPasteboard.general.string = message.displayContent
            }
            .accessibilityIdentifier("aiMessage.copy")

            messageActionButton(system: "quote.bubble", label: "Quote in reply") {
                aiStore.addReference(AiReference(kind: .quote(
                    text: message.displayContent,
                    messageId: message.id
                )))
            }
            .accessibilityIdentifier("aiMessage.quote")

            messageActionButton(system: "note.text.badge.plus", label: "Add as note — tap the page to place it") {
                appStore.beginNoteWithContent(message.displayContent)
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

    /// The declined-attachment toast. Modeled on `ScratchpadPanel_iOS`'s drop
    /// warning so the two sidebar panels feel consistent: a warning icon, the
    /// wrapping message, and an × to dismiss, on a `.regularMaterial` card with
    /// a destructive-tinted stroke.
    private func attachmentNoticeBanner(_ text: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 13))
                .foregroundStyle(palette.destructive)
            Text(text)
                .font(.system(size: 12))
                .foregroundStyle(palette.foreground)
                // Multi-line notices must wrap, not clip. Safe here because the
                // trailing `.frame(maxWidth: .infinity)` constrains the width first.
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 8)
            Button(action: aiStore.dismissAttachmentNotice) {
                Image(systemName: "xmark")
                    .font(.system(size: 11))
                    .foregroundStyle(palette.mutedForeground)
                    // Frame + contentShape INSIDE the label so the whole 32pt
                    // square is tappable, not just the glyph's bounds.
                    .frame(width: 32, height: 32)
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Dismiss")
            .accessibilityIdentifier("aiPanel.attachmentNotice.dismiss")
        }
        .padding(.leading, 12)
        .padding(.trailing, 4)
        .padding(.vertical, 6)
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
                .focused($composerFocused)
                .padding(.horizontal, 4)
                .frame(minHeight: 40)
                // A native text input can consume the UIKit drop before the
                // panel-level destination sees it. Register the same handler
                // directly on the composer so "drop anywhere" is literal.
                .onDrop(
                    of: AttachmentDrop.draggedTypes,
                    isTargeted: $dropTargeted,
                    perform: handleAttachmentDrop
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
            // Two sources rather than the Mac's single "Attach image…": the
            // Photos picker is an iPad-only affordance worth keeping.
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
        // Rendering a page to JPEG is slow enough that switching tabs in the
        // meantime is ordinary behaviour, not a race. Pin the destination now
        // and let `addCapturedReference` discard the bytes if the pane has moved
        // on — otherwise page 4 of the PDF you just left shows up attached to a
        // question about a completely different document.
        guard let target = aiStore.currentReferenceTarget(),
              let capturePage = aiStore.capturePageImageHandler
        else { return }
        Task {
            guard let image = await capturePage(page) else { return }
            aiStore.addCapturedReference(
                AiReference(kind: .pageSnapshot(image: image, page: page)), target: target)
        }
    }

    // MARK: - Arbitrary file attachments

    /// Photos-picker items: load each item's bytes on the main actor (that is
    /// where `loadTransferable` delivers), then hand them to the store, which
    /// normalizes off the main actor and applies the image cap and the
    /// tab-identity guard in one place. Kept in the view because PhotosPicker
    /// yields `Data`, not a URL, so there is nothing for `attachFiles` to open.
    private func attachPhotoItems(_ items: [PhotosPickerItem]) {
        for (index, item) in items.enumerated() {
            Task {
                guard let data = try? await item.loadTransferable(type: Data.self) else { return }
                aiStore.attachImage(data: data, name: "Photo \(index + 1)")
            }
        }
    }

    /// Handler the panel's transcript UITextViews forward their drops to. The
    /// bubble classifies the gesture itself (it holds the `UIDropSession`), so
    /// this takes an already-coalesced payload rather than raw providers.
    ///
    /// No longer gated on vision support: main stopped gating the drop, and a
    /// stranded image is explained by `strandedImagesNotice` rather than by a
    /// drag that springs back with no explanation. Non-nil unconditionally, so
    /// every bubble stays a drop destination.
    private var attachmentDropHandler: ((AttachmentDropPayload) -> Void)? {
        { payload in _ = aiStore.handleDrop(payload) }
    }

    /// Take a drop on the panel — files out of Files, or raw bytes dragged out
    /// of Photos / a browser.
    ///
    /// Returns synchronously (as `.onDrop` requires) and does the classification
    /// in a `Task`, because loading even a file URL out of an `NSItemProvider` is
    /// async. `AttachmentDrop.payloads(for:)` coalesces the whole gesture's file
    /// URLs into ONE payload so a mixed drop of three PDFs and a PNG attaches
    /// the PNG and shows a single notice naming the three — not three notices.
    /// Everything after that (security-scoped reads, the images-only policy, the
    /// decline notices, the tab-identity guard) belongs to `AiStore`.
    @discardableResult
    private func handleAttachmentDrop(_ providers: [NSItemProvider]) -> Bool {
        let accepted = providers.contains(where: AttachmentDrop.carriesAttachment)
        guard accepted else { return false }
        Task {
            for payload in await AttachmentDrop.payloads(for: providers) {
                _ = aiStore.handleDrop(payload)
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
        // Sending is an explicit "show me what happens next", so it re-arms
        // follow-the-tail even if the reader had scrolled up to compose.
        followsTail = true
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

    /// Scroll to the end only while the reader is still parked there — the
    /// stick-to-bottom rule that lets them read back mid-generation.
    private func followTail(_ proxy: ScrollViewProxy) {
        guard followsTail else { return }
        scrollToBottom(proxy)
    }

    private func scrollToBottom(_ proxy: ScrollViewProxy) {
        DispatchQueue.main.async { proxy.scrollTo("ai-bottom", anchor: .bottom) }
    }
}

@MainActor
private func registerConversationRedo(
    _ transaction: AiConversationClearTransaction,
    store: AiStore,
    undoManager: UndoManager
) {
    undoManager.registerUndo(withTarget: store) { target in
        guard target.redoClear(transaction) else { return }
        registerConversationUndo(transaction, store: target, undoManager: undoManager)
    }
    undoManager.setActionName("Clear AI Conversation")
}

@MainActor
private func registerConversationUndo(
    _ transaction: AiConversationClearTransaction,
    store: AiStore,
    undoManager: UndoManager
) {
    undoManager.registerUndo(withTarget: store) { target in
        guard target.undoClear(transaction) else { return }
        registerConversationRedo(transaction, store: target, undoManager: undoManager)
    }
    undoManager.setActionName("Clear AI Conversation")
}

/// A width cap that doesn't stretch: it offers its content at most `maxWidth`
/// and then reports back whatever narrower width the content actually wanted.
///
/// `.frame(maxWidth:)` cannot do this. A flexible frame takes the whole clamped
/// proposal — `Text("Hi").frame(maxWidth: 400)` measures 400pt wide, not 13 —
/// so wrapping a bubble in one painted every message across the full column no
/// matter how little was in it. Invisible at the old fixed cap, glaring once the
/// cap tracks a resizable sidebar (#51).
///
/// Internal (not private) so `SelectableMessageTests` can measure the real
/// layout rather than a reimplementation of it.
struct BubbleWidthCap: Layout {
    let maxWidth: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard let content = subviews.first else { return .zero }
        return content.sizeThatFits(
            ProposedViewSize(width: cap(for: proposal), height: proposal.height))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        guard let content = subviews.first else { return }
        // Place at the bubble's own (already hugged) size, not the cap, so the
        // text lands against the leading edge of the background it was measured
        // for instead of floating in a wider box.
        content.place(
            at: bounds.origin,
            anchor: .topLeading,
            proposal: ProposedViewSize(width: bounds.width, height: bounds.height)
        )
    }

    /// A nil proposal (SwiftUI asking for the ideal size) and an infinite one
    /// both mean "take what you like", which for a bubble means the cap.
    private func cap(for proposal: ProposedViewSize) -> CGFloat {
        guard let width = proposal.width, width.isFinite else { return maxWidth }
        return min(width, maxWidth)
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
#endif
