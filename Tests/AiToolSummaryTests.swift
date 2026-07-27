import Foundation
import Testing
@testable import Vellum

struct AiToolSummaryTests {
    @Test(
        "Assistant text follows the available inspector width",
        arguments: [
            (proposed: CGFloat(80), expected: CGFloat(120)),
            (proposed: CGFloat(320), expected: CGFloat(320)),
            (proposed: CGFloat(520), expected: CGFloat(520)),
        ]
    )
    @MainActor
    func assistantTextUsesResponsiveWidth(input: (proposed: CGFloat, expected: CGFloat)) {
        #expect(SelectableMessageText.resolvedWidth(input.proposed) == input.expected)
    }

    @Test("Search results become bounded page sources")
    func searchResultsBecomeBoundedPageSources() throws {
        let longExcerpt = String(repeating: "evidence ", count: 80)
        let action = AiToolAction(
            tool: "searchDocument",
            args: AiToolArguments(
                pageNumber: nil,
                text: "diffraction",
                color: nil,
                x: nil,
                y: nil,
                isRegex: false
            )
        )
        let result = """
        Found 2 pages with a match:
        page 3 — "…first source…"
        page 9 — "…\(longExcerpt)…"
        """

        let summary = try #require(AiToolSummary.make(action: action, result: result))

        #expect(summary.title == "Searched for “diffraction”")
        #expect(summary.detail == "2 pages")
        #expect(summary.sources.map(\.page) == [3, 9])
        #expect(summary.sources.allSatisfy { $0.excerpt.count <= 281 })
        #expect(summary.sources[0].excerpt == "first source")
    }

    @Test("Page reads retain only a short excerpt and jump target")
    func pageReadRetainsShortExcerptAndJumpTarget() throws {
        let marker = String(repeating: "private payload ", count: 80)
        let action = AiToolAction(
            tool: "getPageText",
            args: AiToolArguments(
                pageNumber: 12,
                text: nil,
                color: nil,
                x: nil,
                y: nil,
                isRegex: nil
            )
        )

        let summary = try #require(
            AiToolSummary.make(action: action, result: "Page 12:\n\(marker)")
        )
        let source = try #require(summary.sources.first)

        #expect(summary.destinationPage == 12)
        #expect(source.page == 12)
        #expect(source.excerpt.count <= 281)
        #expect(source.excerpt.hasSuffix("…"))
    }

    @Test("Structured summaries decode from new messages and remain optional for old messages")
    func summariesAreBackwardCompatible() throws {
        let legacy = Data(
            #"{"id":"old","role":"assistant","content":"answer","createdAt":"now"}"#.utf8
        )
        let legacyMessage = try JSONDecoder().decode(AiMessage.self, from: legacy)
        #expect(legacyMessage.toolSummaries == nil)

        var current = AiMessage(
            id: "new",
            role: .assistant,
            content: "answer",
            createdAt: "now"
        )
        current.toolSummaries = [
            AiToolSummary(title: "Read page 4", destinationPage: 4)
        ]
        let decoded = try JSONDecoder().decode(
            AiMessage.self,
            from: JSONEncoder().encode(current)
        )
        #expect(decoded == current)
    }

    @Test("Assistant answer is not mixed with tool summaries")
    func conciseAnswerRemainsFirstAndIndependent() {
        let summary = AiToolSummary(title: "Searched document", detail: "8 pages")
        let content = AiStore.composeAssistantContent(
            reply: "\n  The concise answer.  \n",
            receipts: [summary]
        )

        #expect(content == "The concise answer.")
        #expect(content.contains("8 pages") == false)
    }

    @Test("Legacy inline search traces collapse without rewriting stored content")
    func legacyInlineSearchTraceGetsACompactPresentation() throws {
        let content = """
        Register allocation appears in several chapters.

        Actions:
        - Found 2 pages with a match:
        page 12 — "…table of contents…"
        page 369 — "…register coalescing…"
        """
        let message = AiMessage(
            id: "legacy",
            role: .assistant,
            content: content,
            createdAt: "now"
        )

        #expect(message.displayContent == "Register allocation appears in several chapters.")
        let summary = try #require(message.displayToolSummaries.first)
        #expect(summary.detail == "2 pages")
        #expect(summary.sources.map(\.page) == [12, 369])
        #expect(message.content == content)
    }

    @Test("Follow-up prompts retain compact tool receipts without source payloads")
    func followUpPromptUsesCompactToolReceipts() {
        var message = AiMessage(
            id: "assistant",
            role: .assistant,
            content: "The concise answer.",
            createdAt: "now"
        )
        message.toolSummaries = [
            AiToolSummary(
                title: "Searched for “register allocation”",
                detail: "8 pages",
                sources: [
                    .init(page: 369, excerpt: "A long source excerpt that belongs in the expandable UI.")
                ]
            )
        ]

        let prompt = AiPrompts.buildConversationBlock([message])

        #expect(prompt.contains("The concise answer."))
        #expect(prompt.contains("- Searched for “register allocation”"))
        #expect(prompt.contains("8 pages") == false)
        #expect(prompt.contains("long source excerpt") == false)
    }
}
