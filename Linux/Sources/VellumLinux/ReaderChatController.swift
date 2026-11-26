import CShell
import Foundation
import LinuxReader
import VellumCore

@MainActor
final class ReaderChatController {
    private var document: ReaderChatDocument?
    private var store: ReadOnlyLibraryFileStore?
    private var writer: LocalFolderFileStore?
    private var persistence: Task<Void, Never>?
    private var historyNotice = ""
    private var work: Task<Void, Never>?
    private struct SessionKey: Hashable {
        let library: URL
        let document: String
    }

    private var sessionKey: SessionKey? {
        guard let store, let id = document?.sessionKey else { return nil }
        return SessionKey(library: store.root.url, document: id)
    }

    private var saved: [ConversationText] = []
    private var session: [SessionKey: [ConversationText]] = [:]
    private var drafts: [SessionKey: String] = [:]
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

    @discardableResult
    func reset(_ panel: OpaquePointer) -> Task<Void, Never>? {
        cancel(panel)
        if let key = sessionKey { drafts[key] = String(cString: reader_chat_draft(panel)) }
        let request = work, writes = persistence
        work = Task { await request?.value; await writes?.value }
        document = nil
        writer = nil
        historyNotice = ""
        store = nil
        saved = []
        loaded = false
        reader_chat_set_transcript(panel, "")
        reader_chat_set_draft(panel, "")
        reader_chat_state(panel, "Open a document to chat.", false, false)
        return work
    }

    func bind(_ selection: ReaderChatDocument, store: ReadOnlyLibraryFileStore,
              provider: LinuxAIProvider, panel: OpaquePointer) {
        let same = document?.sessionKey == selection.sessionKey && document != nil
        document = selection
        self.store = store
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
        reader_chat_set_draft(panel, drafts[key] ?? "")
        start {
            await self.persistence?.value
            guard !Task.isCancelled else { return }
            if let stableKey = self.document?.key {
                do {
                    let conversation = try await ReaderConversation.load(key: stableKey, from: store)
                    let writer = await ReaderConversation.writer(for: store)
                    try Task.checkCancellation()
                    self.saved = conversation.messages
                    self.writer = writer
                } catch {
                    guard !Task.isCancelled else { return }
                    self.historyNotice = "Saved history could not be read."
                    self.writer = nil
                }
            }
            self.loaded = true
            self.render(key: key, panel: panel)
            self.ready(panel: panel)
            self.save(panel: panel)
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
        let destination = writer == nil ? "New messages stay in this session." : "New messages save to this library."
        let status = [notice, historyNotice, disclosure, destination].filter { !$0.isEmpty }.joined(separator: " ")
        reader_chat_state(panel, status, loaded && !busy, busy)
    }

    func refreshProvider(_ provider: LinuxAIProvider, panel: OpaquePointer) {
        selectedProvider = provider
        if loaded && !busy { ready(panel: panel) }
    }

    private func history(_ key: SessionKey) -> ArraySlice<ConversationText> {
        (saved + (session[key] ?? [])).suffix(ConversationText.messageLimit)
    }

    private func render(key: SessionKey, panel: OpaquePointer) {
        let transcript = history(key).map { ($0.role == .user ? "You" : "Assistant") + "\n" + $0.content }
        reader_chat_set_transcript(panel, transcript.joined(separator: "\n\n"))
    }

    private func append(_ role: ConversationText.Role, _ content: String, key: SessionKey) {
        let timestamp = Date().ISO8601Format(.iso8601.time(includingFractionalSeconds: true)
            .year().month().day().timeZone(separator: .omitted))
        let message = ConversationText(id: UUID().uuidString.lowercased(), role: role,
                                       content: ConversationText.limitedContent(content), createdAt: timestamp)
        session[key, default: []].append(message)
        if session[key, default: []].count > ConversationText.messageLimit { session[key]?.removeFirst() }
    }

    /// Serialize append-only saves and keep the old document's owner alive
    /// across selection/close. A failed CAS leaves the turns in memory for retry.
    private func save(panel: OpaquePointer) {
        guard let key = sessionKey, let store, let writer, session[key]?.isEmpty == false else { return }
        let prior = persistence
        persistence = Task {
            await prior?.value
            guard let turns = session[key], !turns.isEmpty else { return }
            do {
                let latest = try await ReaderConversation.load(key: key.document, from: store)
                let ids = Set(latest.messages.map(\.id))
                let additions = turns.filter { !ids.contains($0.id) }
                guard try await latest.save(appending: additions, to: writer) else { throw LibraryFileError.retryable }
                let committed = Set(turns.map(\.id))
                session[key]?.removeAll { committed.contains($0.id) }
                guard sessionKey == key, loaded else { return }
                saved = Array((latest.messages + additions).suffix(ConversationText.messageLimit))
                historyNotice = ""
            } catch {
                guard sessionKey == key, loaded else { return }
                historyNotice = "Saving failed. New messages remain in this session."
            }
            if !busy { ready(panel: panel) }
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
