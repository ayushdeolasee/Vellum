import CShell
import Foundation
import LinuxReader
import VellumCore

@MainActor
final class ReaderChatController {
    private var document: ReaderChatDocument?
    private var store: ReadOnlyLibraryFileStore?
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

    private func cancel() {
        work?.cancel()
        if let key = sessionKey, !partial.isEmpty {
            append(.assistant, partial, key: key)
        }
        partial = ""
        busy = false
    }

    @discardableResult
    func reset(_ panel: OpaquePointer) -> Task<Void, Never>? {
        cancel()
        if let key = sessionKey { drafts[key] = String(cString: reader_chat_draft(panel)) }
        document = nil
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
        if !reader_chat_visible(panel) { cancel(); return }
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
            do {
                let messages: [ConversationText]
                if let stableKey = self.document?.key {
                    messages = try await ReaderConversation.load(key: stableKey, from: store).messages
                } else { messages = [] }
                try Task.checkCancellation()
                self.saved = messages
                self.loaded = true
                self.render(key: key, panel: panel)
                self.ready(panel: panel)
            } catch {
                if !Task.isCancelled { reader_chat_state(panel, "Could not read the saved conversation.", false, false) }
            }
        }
    }

    func stop(panel: OpaquePointer) {
        cancel()
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
        let disclosure = "Send shares document text and recent chat with \(selectedProvider.title). New messages stay in this session."
        reader_chat_state(panel, notice.isEmpty ? disclosure : notice + " " + disclosure, loaded && !busy, busy)
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
            } catch {
                guard !Task.isCancelled else { return }
                if !self.partial.isEmpty { self.append(.assistant, self.partial, key: key) }
                self.partial = ""
                self.busy = false
                self.render(key: key, panel: panel)
                self.ready(panel: panel, notice: error.localizedDescription)
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
