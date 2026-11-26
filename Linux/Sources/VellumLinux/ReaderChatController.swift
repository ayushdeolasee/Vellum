import CShell
import Foundation
import LinuxReader
import VellumCore

@MainActor
final class ReaderChatController {
    private var document: ReaderChatDocument?
    private var store: ReadOnlyLibraryFileStore?
    private var writer: SharedLibraryWriteContext?
    private var historyAllowsSave = false
    private var canSave: Bool { historyAllowsSave && document?.key != nil && writer != nil }
    private var persistence: Task<Void, Never>?
    private var historyNotice = ""
    private var work: Task<Void, Never>?
    private struct ChatSessionKey: Hashable {
        let library: URL
        let rootIdentity: String
        let document: String
    }
    private var recovery: [ChatSessionKey: ChatRecovery] = [:]
    private var closing = false
    private var saveFailed = false

    private var sessionKey: ChatSessionKey? {
        guard let store, let id = document?.sessionKey else { return nil }
        return ChatSessionKey(library: store.root.url, rootIdentity: store.root.identity, document: id)
    }

    private var saved: [ConversationText] = []
    private var session: [ChatSessionKey: [ConversationText]] = [:]
    // Only turns entered while editing was enabled can be published.
    private var pending: [ChatSessionKey: [ConversationText]] = [:]
    private var drafts: [ChatSessionKey: String] = [:]
    private var partial = ""
    private var selectedProvider = ReaderPreferences.defaultProvider
    private var loaded = false
    private var busy = false

    private func cancel(_ panel: OpaquePointer) {
        work?.cancel()
        if let key = sessionKey, !partial.isEmpty {
            append(.assistant, partial, key: key)
        }
        partial = ""
        busy = false
        save(panel: panel)
    }

    func drain(_ panel: OpaquePointer, closing: Bool = false) -> Task<Void, Never>? {
        self.closing = closing
        guard work != nil || persistence != nil else { return nil }
        cancel(panel)
        let request = work, writes = persistence
        return Task {
            await request?.value
            await writes?.value
        }
    }

    func draftChanged(_ panel: OpaquePointer) {
        if loaded, let key = sessionKey { drafts[key] = String(cString: reader_chat_draft(panel)) }
    }

    func keepForNextLaunch(allDocuments: Bool) async throws {
        var failure: Error?
        for (key, versions) in recovery where allDocuments || key == sessionKey {
            do { try await versions.keep(.init(draft: drafts[key] ?? "", turns: pending[key] ?? [])) }
            catch { failure = error }
        }
        if let failure { throw failure }
    }

    /// A fresh read can resolve the same locator to another document.
    func detach(_ panel: OpaquePointer) -> Task<Void, Never>? {
        guard document != nil else { return nil }
        let pending = drain(panel)
        reset(panel)
        return pending
    }

    func reset(_ panel: OpaquePointer) {
        work?.cancel()
        saveFailed = false
        historyAllowsSave = false
        document = nil
        writer = nil
        historyNotice = ""
        store = nil
        saved = []
        loaded = false
        reader_chat_set_transcript(panel, "")
        reader_chat_set_draft(panel, "")
        reader_chat_state(panel, "Open a document to chat.", false, false)
    }

    func bind(_ selection: ReaderChatDocument, store: ReadOnlyLibraryFileStore,
              context: SharedLibraryWriteContext?, provider: LinuxAIProvider, panel: OpaquePointer) {
        let same = document?.sessionKey == selection.sessionKey && document != nil
        document = selection
        self.store = store
        self.writer = context?.root === store.root ? context : nil
        if !same && reader_chat_visible(panel) { show(provider: provider, panel: panel) }
    }

    func show(provider: LinuxAIProvider, panel: OpaquePointer) {
        selectedProvider = provider
        if !reader_chat_visible(panel) { cancel(panel); return }
        guard let key = sessionKey, let store else {
            reader_chat_state(panel, "Open a document with a readable identity to chat.", false, false)
            return
        }
        if loaded {
            render(key: key, panel: panel)
            ready(panel: panel)
            return
        }
        reader_chat_state(panel, "Opening conversation…", false, false)
        start {
            await self.persistence?.value
            guard !Task.isCancelled else { return }
            if self.recovery[key] == nil {
                let versions = ChatRecovery(root: store.root, document: key.document)
                self.recovery[key] = versions
                do {
                    let kept = try await versions.restore(root: store.root)
                    self.drafts[key] = kept.draft
                    self.pending[key] = kept.turns
                    self.session[key] = kept.turns
                } catch {
                    self.historyNotice = "A local recovery copy could not be read."
                }
            }
            guard !Task.isCancelled else { return }
            reader_chat_set_draft(panel, self.drafts[key] ?? "")
            if let stableKey = self.document?.key {
                do {
                    let conversation = try await ReaderConversation.load(key: stableKey, from: store)
                    try Task.checkCancellation()
                    self.saved = conversation.messages
                    self.historyAllowsSave = true
                } catch {
                    guard !Task.isCancelled else { return }
                    self.historyNotice = "Saved history could not be read."
                    self.historyAllowsSave = !(error is DecodingError)
                }
            }
            self.saveFailed = self.pending[key]?.isEmpty == false
            self.loaded = true
            self.render(key: key, panel: panel)
            self.ready(panel: panel)
        }
    }

    func stop(panel: OpaquePointer) {
        cancel(panel)
        if let key = sessionKey { render(key: key, panel: panel) }
        ready(panel: panel, notice: "Stopped.")
    }

    private func start(_ action: @escaping @MainActor () async -> Void) {
        let prior = work
        prior?.cancel()
        work = Task {
            await prior?.value
            if !Task.isCancelled { await action() }
        }
    }

    private func ready(panel: OpaquePointer, notice: String = "") {
        let disclosure = "Send shares document text and recent chat with \(selectedProvider.title)."
        let destination: String
        if saveFailed {
            destination = writer == nil ? "Unsaved chat is kept on this device. Enable shared editing to retry."
                : "Chat has unsaved messages. Check folder access and the 32 MiB conversation limit, then retry. You can return to this document later."
        } else if canSave && !historyNotice.isEmpty {
            destination = "If a shared save fails, chat keeps your new messages for retry."
        } else {
            destination = canSave ? "New messages save to this library." : "New messages stay in this session."
        }
        reader_chat_retry_visible(panel, saveFailed && writer != nil && !busy)
        let status = [notice, historyNotice, disclosure, destination].filter { !$0.isEmpty }.joined(separator: " ")
        reader_chat_state(panel, status, loaded && !busy, busy)
    }

    func setContext(_ context: SharedLibraryWriteContext?, provider: LinuxAIProvider, panel: OpaquePointer) {
        writer = context?.root === store?.root ? context : nil
        if reader_chat_visible(panel) { show(provider: provider, panel: panel) }
    }

    func refreshProvider(_ provider: LinuxAIProvider, panel: OpaquePointer) {
        selectedProvider = provider
        if loaded && !busy { ready(panel: panel) }
    }

    private func history(_ key: ChatSessionKey) -> ArraySlice<ConversationText> {
        let local = session[key] ?? []
        let localIDs = Set(local.map(\.id))
        return (saved.filter { !localIDs.contains($0.id) } + local).suffix(ConversationText.messageLimit)
    }

    private func render(key: ChatSessionKey, panel: OpaquePointer) {
        let transcript = history(key).map { ($0.role == .user ? "You" : "Assistant") + "\n" + $0.content }
        reader_chat_set_transcript(panel, transcript.joined(separator: "\n\n"))
    }

    private func append(_ role: ConversationText.Role, _ content: String, key: ChatSessionKey) {
        let timestamp = Date().ISO8601Format(.iso8601.time(includingFractionalSeconds: true)
            .year().month().day().timeZone(separator: .omitted))
        let message = ConversationText(id: UUID().uuidString.lowercased(), role: role,
                                       content: ConversationText.limitedContent(content), createdAt: timestamp)
        if canSave { pending[key, default: []].append(message) }
        session[key, default: []].append(message)
        if session[key, default: []].count > ConversationText.messageLimit { session[key]?.removeFirst() }
    }

    /// Serialize append-only saves and keep the old document's owner alive
    /// across selection/close. A failed CAS leaves the turns in memory for retry.
    func save(panel: OpaquePointer, retry: Bool = false) {
        guard let key = sessionKey, let target = document?.sidecarTarget, let store, let writer, pending[key]?.isEmpty == false else { return }
        if retry { reader_chat_state(panel, "Retrying shared save…", false, false) }
        let prior = persistence
        persistence = Task {
            await prior?.value
            guard let turns = pending[key], !turns.isEmpty else {
                if retry, !closing, sessionKey == key, loaded { ready(panel: panel) }
                return
            }
            let previousNotice = historyNotice
            let previouslyFailed = saveFailed
            do {
                let latest = try await ReaderConversation.load(key: key.document, from: store)
                let additions = turns.filter { !latest.messageIDs.contains($0.id) }
                let exchanged = try await latest.save(appending: additions) { url, bytes, expected in
                    try await target.validate(in: store)
                    return try await writer.replace(url, with: bytes, ifCurrent: expected)
                }
                guard exchanged else { throw LibraryFileError.retryable }
                let committed = Set(turns.map(\.id))
                pending[key]?.removeAll { committed.contains($0.id) }
                guard !closing, sessionKey == key, loaded else { return }
                saved = Array((latest.messages + additions).suffix(ConversationText.messageLimit))
                if !busy { render(key: key, panel: panel) }
                historyAllowsSave = true
                saveFailed = false
                historyNotice = ""
            } catch {
                guard !closing, sessionKey == key, loaded else { return }
                saveFailed = true
                if let changed = error as? ReaderSidecarTarget.ChangedPDF { historyNotice = changed.localizedDescription }
            }
            if !busy && (retry || previousNotice != historyNotice || previouslyFailed != saveFailed) { ready(panel: panel) }
        }
    }

    func send(provider: LinuxAIProvider, panel: OpaquePointer) {
        guard loaded, !busy, let document, let key = sessionKey else { return }
        let question = String(cString: reader_chat_draft(panel)).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !question.isEmpty else { return }
        guard selectedProvider == provider else {
            refreshProvider(provider, panel: panel)
            return
        }
        let recent = history(key).suffix(12).map { "\($0.role.rawValue): \($0.content.prefix(2000))" }.joined(separator: "\n")
        busy = true
        reader_chat_state(panel, "Preparing request for \(provider.title)…", false, true)
        start {
            do {
                let credential = await provider.readCredential()
                try Task.checkCancellation()
                let secret: String
                switch credential {
                case .value(let value): secret = value
                case .missing: throw ChatError("No \(provider.title) key is saved. Add one in Settings.")
                case .unavailable: throw ChatError("The keyring is locked or unavailable. Unlock it and try again.")
                }
                let excerpt = try await document.excerpt()
                try Task.checkCancellation()
                let prompt = "Document excerpt:\n\(excerpt)\n\nRecent conversation:\n\(recent)\n\nQuestion:\n\(question)"
                self.append(.user, question, key: key)
                reader_chat_set_draft(panel, "")
                self.render(key: key, panel: panel)
                reader_chat_append(panel, "\n\nAssistant\n")
                reader_chat_state(panel, "Waiting for \(provider.title)…", false, true)
                try await provider.stream(key: secret, prompt: prompt) { delta in
                    try self.receive(delta, panel: panel)
                }
                try Task.checkCancellation()
                guard !self.partial.isEmpty else { throw ChatError("The provider returned an empty reply.") }
                self.append(.assistant, self.partial, key: key)
                self.partial = ""
                self.busy = false
                self.render(key: key, panel: panel)
                self.ready(panel: panel)
                self.save(panel: panel)
            } catch {
                guard !Task.isCancelled else { return }
                if !self.partial.isEmpty { self.append(.assistant, self.partial, key: key) }
                self.partial = ""
                self.busy = false
                self.render(key: key, panel: panel)
                self.ready(panel: panel, notice: error.localizedDescription)
                self.save(panel: panel)
            }
        }
    }

    private func receive(_ delta: String, panel: OpaquePointer) throws {
        try Task.checkCancellation()
        guard partial.utf8.count + delta.utf8.count <= 96_000 else { throw ChatError("Reply size limit reached.") }
        partial += delta
        reader_chat_append(panel, delta)
    }
}
