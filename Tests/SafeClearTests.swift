import Testing
@testable import Vellum

@MainActor
struct SafeClearTests {
    @Test("Clearing and restoring an AI conversation preserves its messages")
    func aiConversationClearIsReversible() throws {
        let store = AiStore()
        store.addLocalMessage(role: .user, content: "Question")
        store.addLocalMessage(role: .assistant, content: "Answer")

        let removed = try #require(store.clearConversation())
        #expect(store.messages.isEmpty)
        #expect(removed.messages.map(\.content) == ["Question", "Answer"])

        let displaced = store.replaceConversation(with: removed)
        #expect(displaced.messages.isEmpty)
        #expect(store.messages.map(\.content) == ["Question", "Answer"])
    }

    @Test("Clearing an empty AI conversation is a no-op")
    func emptyAiConversationDoesNotCreateUndoContent() {
        let store = AiStore()

        #expect(store.clearConversation() == nil)
        #expect(store.messages.isEmpty)
    }

    @Test("Clearing and restoring a scratchpad preserves its note")
    func scratchpadClearIsReversible() throws {
        let store = ScratchpadStore()
        store.text = "A note worth keeping"

        let removed = try #require(store.clearText())
        #expect(store.text.isEmpty)
        #expect(removed == "A note worth keeping")

        let displaced = store.replaceText(with: removed)
        #expect(displaced.isEmpty)
        #expect(store.text == "A note worth keeping")
    }

    @Test("Clearing an empty scratchpad is a no-op")
    func emptyScratchpadDoesNotCreateUndoContent() {
        let store = ScratchpadStore()

        #expect(store.clearText() == nil)
        #expect(store.text.isEmpty)
    }
}
