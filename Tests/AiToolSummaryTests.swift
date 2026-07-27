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

    @Test("Ordinary Actions sections remain part of message content")
    func legitimateActionsContentIsNotTreatedAsLegacyReceipts() {
        let assistantContent = """
        Here is the plan.

        Actions:
        - Review the introduction
        - Compare the two arguments
        """
        let assistant = AiMessage(
            id: "assistant-plan",
            role: .assistant,
            content: assistantContent,
            createdAt: "now"
        )
        let userContent = """
        Please remember this:

        Actions:
        - Read page 12.
        """
        let user = AiMessage(
            id: "user-actions",
            role: .user,
            content: userContent,
            createdAt: "now"
        )

        #expect(assistant.displayContent == assistantContent)
        #expect(assistant.displayToolSummaries.isEmpty)
        #expect(assistant.promptContent == assistantContent)
        #expect(user.displayContent == userContent)
        #expect(user.displayToolSummaries.isEmpty)
        #expect(user.promptContent == userContent)
    }

    @Test("Legacy raw retrieval payloads become compact follow-up receipts")
    func legacyRawPayloadIsCompactedForPrompt() {
        let marker = "RAW-SOURCE-MARKER"
        let message = AiMessage(
            id: "legacy-raw",
            role: .assistant,
            content: """
            The answer.

            Actions:
            - Found 2 pages with a match:
            page 4 — "…\(marker) first…"
            page 9 — "…\(marker) second…"
            """,
            createdAt: "now"
        )

        let prompt = message.promptContent

        #expect(prompt.contains("The answer."))
        #expect(prompt.contains("- Document search"))
        #expect(prompt.contains(marker) == false)
        #expect(prompt.contains("page 4 —") == false)
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

    @Test("Imported structured summaries are bounded at the shared persistence boundary")
    func hostileImportedSummariesAreBounded() throws {
        let huge = String(repeating: "oversized ", count: 2_000)
        var message = AiMessage(
            id: "hostile-import",
            role: .assistant,
            content: "answer",
            createdAt: "now"
        )
        message.toolSummaries = (0..<(AiPersistence.maxToolSummariesPerMessage + 10)).map { index in
            AiToolSummary(
                id: huge,
                title: "\(index)-\(huge)",
                detail: huge,
                sources: (0..<(AiPersistence.maxToolSourcesPerSummary + 5)).map { sourceIndex in
                    .init(
                        id: huge,
                        page: sourceIndex == 0 ? Int.max : sourceIndex + 1,
                        excerpt: huge
                    )
                },
                destinationPage: Int.max
            )
        }

        let boundedMessage = try #require(AiPersistence.limitedMessages([message]).first)
        let summaries = try #require(boundedMessage.toolSummaries)
        let first = try #require(summaries.first)

        #expect(summaries.count == AiPersistence.maxToolSummariesPerMessage)
        #expect(first.id.count <= AiPersistence.maxToolIdentifierCharacters)
        #expect(first.title.count <= AiPersistence.maxToolSummaryTitleCharacters)
        #expect((first.detail?.count ?? 0) <= AiPersistence.maxToolSummaryDetailCharacters)
        #expect(first.sources.count == AiPersistence.maxToolSourcesPerSummary)
        #expect(first.sources[0].id.count <= AiPersistence.maxToolIdentifierCharacters)
        #expect(first.sources[0].excerpt.count <= AiPersistence.maxToolSourceExcerptCharacters)
        #expect(first.destinationPage == nil)
        #expect(first.sources[0].page == nil)
        #expect(Set(summaries.map(\.id)).count == summaries.count)
        #expect(Set(first.sources.map(\.id)).count == first.sources.count)
        #expect(AiPersistence.sanitizeToolSummaries(summaries) == summaries)
    }

    @Test("Reparsed legacy summaries retain stable disclosure identity")
    func legacySummaryIdentityIsStableAcrossRenders() throws {
        let message = AiMessage(
            id: "stable-message",
            role: .assistant,
            content: """
            Answer.

            Actions:
            - Found 2 pages with a match:
            page 2 — "…alpha…"
            page 7 — "…beta…"
            """,
            createdAt: "now"
        )

        let firstRender = try #require(message.displayToolSummaries.first)
        let secondRender = try #require(message.displayToolSummaries.first)

        #expect(firstRender.id == secondRender.id)
        #expect(firstRender.sources.map(\.id) == secondRender.sources.map(\.id))
        #expect(Set(firstRender.sources.map(\.id)).count == firstRender.sources.count)
    }
}
