import UIKit
import XCTest
@testable import Vellum

// Deterministic tests for the AI request pipeline (issue #37 review):
// retrieval-persistence, prompt-prefix fixtures, signed Gemini tool turns,
// request-body invariants, SSE fixtures, and usage parsing. Everything runs
// against pure helpers — no network, no provider keys.

@MainActor
final class AiPipelineTests: XCTestCase {

    // MARK: - §1 Retrieval persistence

    /// Raw tool output carries a unique marker; the persisted assistant content
    /// is kept separate from compact summaries, so the marker must never survive
    /// into the message — or, transitively, into the next request's prompt.
    func testRawRetrievalOutputCannotReachTheNextPrompt() {
        let marker = "UNIQUE-RETRIEVAL-MARKER-93b1f2"
        // What the tool loop saw (transient, provider-side only):
        let rawToolOutput = "Page 20:\nlorem ipsum \(marker) dolor sit amet"
        XCTAssertTrue(rawToolOutput.contains(marker), "fixture sanity")

        // What the store persists as the answer. The trace of what produced it
        // is a separate structured field, and it too is built only from bounded
        // excerpts — never the raw payload.
        let persisted = AiStore.assistantAnswerText(reply: "Page 20 discusses the marker experiment.")
        XCTAssertFalse(persisted.contains(marker))
        XCTAssertEqual(persisted, "Page 20 discusses the marker experiment.")

        // And the next turn's conversation block (built from persisted
        // messages, including their tool summaries) cannot resend it.
        var assistant = AiPersistence.makeMessage(role: .assistant, content: persisted)
        assistant.toolSummaries = [AiToolSummary(
            title: "Read page 20",
            sources: [.init(page: 20, excerpt: "a bounded excerpt")],
            destinationPage: 20
        )]
        let history = [
            AiPersistence.makeMessage(role: .user, content: "What's on page 20?"),
            assistant,
        ]
        XCTAssertFalse(AiPrompts.buildConversationBlock(history).contains(marker))
    }

    /// The answer is the reply and nothing else: no receipts spliced on, and no
    /// stray whitespace from the provider's framing. Both halves matter —
    /// `content` is what Copy, Quote and Add-as-note hand to the user.
    func testAssistantAnswerIsTheTrimmedReplyAndNothingElse() {
        XCTAssertEqual(AiStore.assistantAnswerText(reply: "\n  Hello.  \n"), "Hello.")
        XCTAssertFalse(AiStore.assistantAnswerText(reply: "Hello.").contains("Actions:"))
    }

    func testPageReadIsBounded() {
        let hugePage = String(repeating: "x", count: AiToolEngine.maxPageReadCharacters * 3)
        let output = AiToolEngine.boundedPageRead(page: 7, text: hugePage)
        XCTAssertTrue(output.hasPrefix("Page 7:\n"))
        XCTAssertTrue(output.contains("[truncated"))
        // Header + cap + truncation notice, with room to spare.
        XCTAssertLessThan(output.count, AiToolEngine.maxPageReadCharacters + 200)

        let smallPage = "short page text"
        XCTAssertEqual(AiToolEngine.boundedPageRead(page: 2, text: smallPage), "Page 2:\nshort page text")
    }

    /// getPageText appends the page's highlights and notes: highlights quote
    /// their selected text (plus any user comment), notes list their content,
    /// bookmarks and empty annotations are skipped, and long text is clipped.
    func testAnnotationsSectionFormatsHighlightsAndNotes() {
        func annotation(_ type: AnnotationType, content: String? = nil, selectedText: String? = nil) -> Annotation {
            let position = selectedText.map {
                PositionData(rects: [], pageWidth: 612, pageHeight: 792, selectedText: $0)
            }
            return Annotation(
                id: UUID().uuidString, type: type, pageNumber: 3, color: nil,
                content: content, positionData: position, createdAt: "", updatedAt: ""
            )
        }

        let section = AiToolEngine.annotationsSection(page: 3, annotations: [
            annotation(.highlight, selectedText: "the key theorem"),
            annotation(.highlight, content: "revisit this", selectedText: "a second passage"),
            annotation(.note, content: "check the appendix"),
            annotation(.bookmark),
            annotation(.note, content: "   "),
            annotation(.highlight, content: "comment without captured text"),
            annotation(.highlight, content: String(repeating: "y", count: AiToolEngine.maxAnnotationReadCharacters * 2),
                       selectedText: String(repeating: "x", count: AiToolEngine.maxAnnotationReadCharacters * 2)),
        ])

        let expectedClipped = String(repeating: "x", count: AiToolEngine.maxAnnotationReadCharacters) + "…"
        XCTAssertEqual(section, """
        User highlights and notes on page 3:
        - Highlight: "the key theorem"
        - Highlight: "a second passage" — user comment: revisit this
        - Note: check the appendix
        - Highlight comment: comment without captured text
        - Highlight: "\(expectedClipped)" — user comment: \(String(repeating: "y", count: AiToolEngine.maxAnnotationReadCharacters))…
        """)
    }

    /// A heavily marked-up page can't blow the token budget: the section lists
    /// at most maxAnnotationsPerRead entries, keeps the NEWEST ones (input is
    /// creation-ordered), and says how many older ones were hidden.
    func testAnnotationsSectionCapsEntryCountKeepingNewest() {
        let total = AiToolEngine.maxAnnotationsPerRead + 5
        let many = (1...total).map { index in
            Annotation(
                id: "n\(index)", type: .note, pageNumber: 9, color: nil,
                content: "note \(index)", positionData: nil, createdAt: "", updatedAt: ""
            )
        }
        let section = AiToolEngine.annotationsSection(page: 9, annotations: many)!
        let lines = section.split(separator: "\n").map(String.init)
        // Header + capped entries + the "not shown" tail.
        XCTAssertEqual(lines.count, AiToolEngine.maxAnnotationsPerRead + 2)
        // The 5 oldest are dropped; the newest survives.
        XCTAssertFalse(lines.contains("- Note: note 5"))
        XCTAssertTrue(lines.contains("- Note: note 6"))
        XCTAssertTrue(lines.contains("- Note: note \(total)"))
        XCTAssertEqual(lines.last, "…and 5 earlier annotations on this page (not shown).")
    }

    /// No highlights or notes → no section at all, so an unannotated page read
    /// looks exactly as before.
    func testAnnotationsSectionIsNilWhenPageHasNone() {
        XCTAssertNil(AiToolEngine.annotationsSection(page: 1, annotations: []))
        let bookmark = Annotation(
            id: "b1", type: .bookmark, pageNumber: 1, color: nil,
            content: nil, positionData: nil, createdAt: "", updatedAt: ""
        )
        XCTAssertNil(AiToolEngine.annotationsSection(page: 1, annotations: [bookmark]))
    }

    // MARK: - §2 Prompt duplication & prefix fixtures

    func testQuizMenuBuildsScopedRequests() {
        XCTAssertEqual(
            AiPrompts.quizRequest(for: .currentPage(12)),
            "Quiz me on page 12. Ask one question at a time."
        )
        XCTAssertEqual(
            AiPrompts.quizRequest(for: .attachedMaterial),
            "Quiz me on the attached material. Ask one question at a time."
        )
        XCTAssertEqual(
            AiPrompts.quizRequest(for: .document),
            "Quiz me on this document. Ask one question at a time."
        )
    }

    /// The newest user request must appear exactly once in the joined prompt:
    /// under "### Latest User Request", not also inside the conversation block.
    func testLatestUserRequestAppearsExactlyOnce() {
        let request = "second question UNIQUE-REQ-7f3a"
        // sendMessage appends the user message, then builds the conversation
        // from promptHistory (everything before it).
        let messagesWithUser = [
            AiPersistence.makeMessage(role: .user, content: "first question"),
            AiPersistence.makeMessage(role: .assistant, content: "first answer"),
            AiPersistence.makeMessage(role: .user, content: request),
        ]
        let history = AiStore.promptHistory(from: messagesWithUser)
        XCTAssertEqual(history.count, 2)

        let conversation = AiPrompts.buildConversationBlock(history)
        let prompt = AiPrompts.buildNativeToolUserPrompt(AiPromptParameters(
            conversation: conversation.isEmpty ? "(start of conversation)" : conversation,
            context: "Document title: Fixture",
            latestUserRequest: request
        ))
        let occurrences = prompt.joined.components(separatedBy: "UNIQUE-REQ-7f3a").count - 1
        XCTAssertEqual(occurrences, 1)
    }

    /// Turns 1–3: each turn's conversation block is an exact prefix of the next
    /// turn's, so the shared prompt prefix grows monotonically (until rollover).
    func testConversationBlockIsAPrefixAcrossTurns() {
        var messages: [AiMessage] = []
        var previous = ""
        for turn in 1...3 {
            messages.append(AiPersistence.makeMessage(role: .user, content: "question \(turn)"))
            let conversation = AiPrompts.buildConversationBlock(AiStore.promptHistory(from: messages))
            if !previous.isEmpty {
                XCTAssertTrue(conversation.hasPrefix(previous), "turn \(turn) diverged from the prior prefix")
                XCTAssertGreaterThan(conversation.count, previous.count)
            }
            previous = conversation
            messages.append(AiPersistence.makeMessage(role: .assistant, content: "answer \(turn)"))
        }
    }

    /// The conversation block carries only the last ten messages; older ones
    /// roll off the front.
    func testConversationRollsOverAtTenMessages() {
        let messages = (1...12).map { index in
            AiPersistence.makeMessage(
                role: index.isMultiple(of: 2) ? .assistant : .user,
                content: "msg-\(String(format: "%02d", index))"
            )
        }
        let block = AiPrompts.buildConversationBlock(messages)
        XCTAssertFalse(block.contains("msg-01"))
        XCTAssertFalse(block.contains("msg-02"))
        XCTAssertTrue(block.contains("msg-03"))
        XCTAssertTrue(block.contains("msg-12"))
    }

    // MARK: - §3/§5 Gemini signed tool turns & thinking config

    /// Streamed model parts must be replayed verbatim: text chunks merge, but a
    /// functionCall part keeps its exact payload including `thoughtSignature`.
    func testGeminiReplayPreservesThoughtSignatures() {
        var parts: [[String: Any]] = []
        GeminiClient.accumulateReplayPart(["text": "Let me "], into: &parts)
        GeminiClient.accumulateReplayPart(["text": "check page 20."], into: &parts)
        GeminiClient.accumulateReplayPart(
            [
                "functionCall": ["name": "getPageText", "args": ["pageNumber": 20]],
                "thoughtSignature": "sig-abc123",
            ],
            into: &parts
        )
        GeminiClient.accumulateReplayPart(["text": "And also ", "thoughtSignature": "sig-def456"], into: &parts)
        GeminiClient.accumulateReplayPart(["text": "tail text"], into: &parts)

        XCTAssertEqual(parts.count, 4)
        XCTAssertEqual(parts[0]["text"] as? String, "Let me check page 20.")
        XCTAssertEqual(parts[1]["thoughtSignature"] as? String, "sig-abc123")
        XCTAssertEqual((parts[1]["functionCall"] as? [String: Any])?["name"] as? String, "getPageText")
        // A signed text part is never merged into — the signature stays put.
        XCTAssertEqual(parts[2]["thoughtSignature"] as? String, "sig-def456")
        XCTAssertEqual(parts[2]["text"] as? String, "And also ")
        XCTAssertEqual(parts[3]["text"] as? String, "tail text")
    }

    func testGeminiThoughtPartsAreNotMergedWithVisibleText() {
        var parts: [[String: Any]] = []
        GeminiClient.accumulateReplayPart(["text": "thinking…", "thought": true], into: &parts)
        GeminiClient.accumulateReplayPart(["text": "visible"], into: &parts)
        XCTAssertEqual(parts.count, 2)
    }

    /// Gemini 3 models take a discrete thinkingLevel (numeric budgets are a
    /// request error there); 2.x keeps numeric budgets; 1.5 sends nothing.
    func testGeminiThinkingConfigMatchesModelFamily() {
        XCTAssertEqual(
            GeminiClient.thinkingConfig(for: .high, model: "gemini-2.5-flash")?["thinkingBudget"] as? Int,
            24576
        )
        XCTAssertEqual(
            GeminiClient.thinkingConfig(for: .low, model: "gemini-3.1-flash-lite-preview")?["thinkingLevel"] as? String,
            "low"
        )
        XCTAssertNil(
            GeminiClient.thinkingConfig(for: .low, model: "gemini-3.1-flash-lite-preview")?["thinkingBudget"],
            "Gemini 3 must never receive a numeric budget"
        )
        XCTAssertEqual(
            GeminiClient.thinkingConfig(for: .instant, model: "gemini-3-flash-preview")?["thinkingLevel"] as? String,
            "minimal"
        )
        // 3-pro has no minimal/medium: round to its supported low/high.
        XCTAssertEqual(
            GeminiClient.thinkingConfig(for: .instant, model: "gemini-3-pro-preview")?["thinkingLevel"] as? String,
            "low"
        )
        XCTAssertEqual(
            GeminiClient.thinkingConfig(for: .medium, model: "gemini-3-pro-preview")?["thinkingLevel"] as? String,
            "high"
        )
        XCTAssertEqual(
            GeminiClient.thinkingConfig(for: .medium, model: "gemini-3.1-pro-preview")?["thinkingLevel"] as? String,
            "medium"
        )
        XCTAssertNil(GeminiClient.thinkingConfig(for: .high, model: "gemini-1.5-pro"))
        XCTAssertNil(GeminiClient.thinkingConfig(for: .auto, model: "gemini-3-pro-preview"), "`.auto` is the caller's branch")
    }

    // MARK: - §5 OpenAI output budget

    func testOpenAIOutputBudgetScalesWithEffort() {
        XCTAssertEqual(OpenAIClient.maxOutputTokens(forEffort: "none", reasoning: true), 4096)
        XCTAssertEqual(OpenAIClient.maxOutputTokens(forEffort: "minimal", reasoning: true), 4096)
        XCTAssertEqual(OpenAIClient.maxOutputTokens(forEffort: "low", reasoning: true), 8192)
        XCTAssertEqual(OpenAIClient.maxOutputTokens(forEffort: "medium", reasoning: true), 16384)
        XCTAssertEqual(OpenAIClient.maxOutputTokens(forEffort: "high", reasoning: true), 32768)
        XCTAssertEqual(OpenAIClient.maxOutputTokens(forEffort: "xhigh", reasoning: true), 65536)
    }

    /// A non-reasoning model spends no tokens thinking, so its cap is purely
    /// about answer length and stays flat whatever the thinking mode says.
    func testOpenAIOutputBudgetIsFlatForNonReasoningModels() {
        XCTAssertEqual(OpenAIClient.maxOutputTokens(forEffort: nil, reasoning: false), 4096)
        XCTAssertEqual(OpenAIClient.maxOutputTokens(forEffort: "high", reasoning: false), 4096)
    }

    /// Auto omits the effort, so the server picks — and current models default
    /// well above "minimal". Budgeting Auto at the old 4096 would swap the #94
    /// error for a truncated answer, so it has to assume mid-range work.
    func testOpenAIAutoGetsAMidRangeBudgetNotTheMinimalOne() {
        XCTAssertEqual(OpenAIClient.maxOutputTokens(forEffort: nil, reasoning: true), 16384)
    }

    // MARK: - §5 OpenAI reasoning effort (#94)

    /// The bug: `.auto` was rewritten to "minimal" before being sent, so "Auto"
    /// never meant "let the server decide". gpt-5.5 rejects "minimal" outright,
    /// which made the model unusable at the default Thinking setting.
    func testAutoOmitsTheEffortFieldEntirely() {
        for model in ["gpt-5.5", "gpt-5", "gpt-5.1", "gpt-5-pro", "gpt-4o"] {
            XCTAssertNil(
                OpenAIClient.supportedReasoningEffort(model: model, requested: nil),
                "Auto must send no effort for \(model)")
        }
    }

    /// The values are quoted from the API's own rejection message.
    func testGpt55RejectsMinimalAndOffersNoneAndXhigh() {
        let supported = OpenAIClient.supportedEfforts(model: "gpt-5.5")
        XCTAssertEqual(supported, ["none", "low", "medium", "high", "xhigh"])
        XCTAssertFalse(supported.contains("minimal"))
    }

    /// Instant asks for as little thinking as possible. gpt-5.5 has no
    /// "minimal", so it resolves *down* to "none" rather than up to "low".
    func testInstantResolvesDownwardOnGpt55() {
        XCTAssertEqual(
            OpenAIClient.supportedReasoningEffort(model: "gpt-5.5", requested: "minimal"), "none")
    }

    /// The regression guard that matters most: an OpenAI model nobody has taught
    /// this code about must send nothing rather than fall through to a guessed
    /// value. The old `return requested` fall-through is exactly how gpt-5.5
    /// broke, and the next model would have broken the same way.
    func testUnknownGpt5VariantOmitsRatherThanGuessing() {
        XCTAssertNil(OpenAIClient.supportedReasoningEffort(model: "gpt-5.9-turbo", requested: "minimal"))
        XCTAssertNil(OpenAIClient.supportedReasoningEffort(model: "gpt-6", requested: "high"))
    }

    func testKnownFamiliesKeepTheirEffortVocabularies() {
        // Classic gpt-5 still takes "minimal".
        XCTAssertEqual(
            OpenAIClient.supportedReasoningEffort(model: "gpt-5-mini", requested: "minimal"), "minimal")
        // gpt-5.1 dropped "minimal" and gained "none", so Instant lands there.
        XCTAssertEqual(
            OpenAIClient.supportedReasoningEffort(model: "gpt-5.1", requested: "minimal"), "none")
        // Dated snapshots resolve to their family, not to the unknown row.
        XCTAssertEqual(
            OpenAIClient.supportedReasoningEffort(model: "gpt-5.1-2025-11-13", requested: "minimal"), "none")
        // gpt-5-pro accepts only "high", whatever was asked for.
        XCTAssertEqual(
            OpenAIClient.supportedReasoningEffort(model: "gpt-5-pro", requested: "low"), "high")
        // Non-reasoning models never get the field.
        XCTAssertNil(OpenAIClient.supportedReasoningEffort(model: "gpt-4o", requested: "high"))
    }

    /// Omitting a family is not the safe default it looks like: gpt-5.2/5.4
    /// default to `reasoning.effort: none`, so an omitted field means the user
    /// picked "High" and got *no* reasoning. Every gpt-5 id the pickers actually
    /// ship has to resolve an explicit mode to something.
    func testEveryShippedGpt5ModelHonoursAnExplicitMode() {
        let shipped = AiModelCatalog.openAI + AiModelCatalog.opencode
        for model in Set(shipped).filter({ $0.hasPrefix("gpt-5") }).sorted() {
            XCTAssertNotNil(
                OpenAIClient.supportedReasoningEffort(model: model, requested: "high"),
                "\(model) is in a model picker but High resolves to no effort at all")
        }
    }

    /// 5.2 through 5.5 share one vocabulary, but their -pro variants do not, and
    /// the -pro rows are checked first so they can't inherit a value they reject.
    func testProVariantsDoNotInheritTheirFamilysVocabulary() {
        XCTAssertEqual(
            OpenAIClient.supportedReasoningEffort(model: "gpt-5.4", requested: "minimal"), "none")
        XCTAssertEqual(
            OpenAIClient.supportedReasoningEffort(model: "gpt-5.4-mini", requested: "minimal"), "none")
        // gpt-5.4-pro takes only medium/high/xhigh — inheriting gpt-5.4's "none"
        // would 400 the same way #94 did.
        XCTAssertEqual(
            OpenAIClient.supportedReasoningEffort(model: "gpt-5.4-pro", requested: "minimal"), "medium")
        // A -pro variant with no row of its own omits rather than guessing.
        XCTAssertNil(OpenAIClient.supportedReasoningEffort(model: "gpt-5.5-pro", requested: "low"))
    }

    /// Two families that don't match the plain `gpt-5.x` shapes: codex slugs on
    /// the classic line reject "minimal", and the o-series takes reasoning
    /// effort despite not starting with "gpt" — `openai/o3` reaches this table
    /// through OpenRouter's live catalog.
    func testCodexAndOSeriesResolveToValuesTheyAccept() {
        XCTAssertEqual(
            OpenAIClient.supportedReasoningEffort(model: "gpt-5-codex", requested: "minimal"), "low")
        XCTAssertEqual(OpenAIClient.supportedReasoningEffort(model: "o3", requested: "high"), "high")
        XCTAssertEqual(
            OpenAIClient.supportedReasoningEffort(model: "o4-mini", requested: "minimal"), "low")
        // o1-mini is the one reasoning model with no effort parameter at all.
        XCTAssertNil(OpenAIClient.supportedReasoningEffort(model: "o1-mini", requested: "high"))
    }

    /// Explicit choices a model does support must survive untouched.
    func testExplicitSupportedEffortsArePreserved() {
        for effort in ["low", "medium", "high", "xhigh"] {
            XCTAssertEqual(
                OpenAIClient.supportedReasoningEffort(model: "gpt-5.5", requested: effort), effort)
        }
    }

    func testOpenAIIncompleteMessageNamesTheLimit() {
        XCTAssertTrue(OpenAIClient.incompleteMessage(reason: "max_output_tokens").contains("output token limit"))
        XCTAssertTrue(OpenAIClient.incompleteMessage(reason: "content_filter").contains("content_filter"))
    }

    // MARK: - §3 OpenRouter request body

    /// The body carries the per-tab sticky-session key, and the message list
    /// holds exactly two cache breakpoints (system, document context) no matter
    /// how many images are attached — Anthropic rejects more than four.
    func testOpenRouterBodyHasSessionIdAndBoundedBreakpoints() throws {
        let prompt = AiUserPrompt(stable: "### Document Context\nstable", volatile: "### Latest User Request\nvolatile")
        let images = (1...3).map { page in
            AiPageImageSnapshot(pageNumber: page, base64Data: "aGVsbG8=", mediaType: "image/jpeg", width: 8, height: 8)
        }
        let messages = OpenRouterClient.initialMessages(systemPrompt: "system", prompt: prompt, images: images)
        let body = OpenRouterClient.requestBody(
            model: "anthropic/claude-sonnet-5",
            messages: messages,
            thinkingMode: .medium,
            allowTools: true,
            sessionId: "tab-42"
        )

        XCTAssertEqual(body["session_id"] as? String, "vellum-tab-42")
        XCTAssertEqual((body["usage"] as? [String: Any])?["include"] as? Bool, true)
        XCTAssertEqual((body["reasoning"] as? [String: Any])?["effort"] as? String, "medium")
        XCTAssertNotNil(body["tools"])

        XCTAssertEqual(Self.countOccurrences(of: "cache_control", in: messages), 2)
        // All three images are still attached, just without breakpoints.
        let userContent = try XCTUnwrap(messages.last?["content"] as? [[String: Any]])
        XCTAssertEqual(userContent.filter { $0["type"] as? String == "image_url" }.count, 3)
    }

    /// OpenRouter resolves `openai/` ids through the shared table, so the
    /// gateway inherits both halves of #94: gpt-5.5 must not receive "minimal",
    /// and a model the table has nothing to say about must not lose the user's
    /// choice — `openai/o3` reasons, it just doesn't start with "gpt".
    func testOpenRouterResolvesOpenAIEffortsThroughTheSharedTable() {
        func effort(_ model: String, _ mode: AiThinkingMode) -> String? {
            let body = OpenRouterClient.requestBody(
                model: model, messages: [], thinkingMode: mode, allowTools: false, sessionId: "t")
            return (body["reasoning"] as? [String: Any])?["effort"] as? String
        }
        XCTAssertEqual(effort("openai/gpt-5.5", .instant), "none")
        XCTAssertEqual(effort("openai/gpt-5.4", .high), "high")
        XCTAssertEqual(effort("openai/o3", .high), "high")
        XCTAssertEqual(effort("openai/o3", .instant), "low")
        // Non-reasoning OpenAI models take no reasoning field at all.
        XCTAssertNil(effort("openai/gpt-4o", .high))
        // Everything else on the gateway keeps the plain low/medium/high rule.
        XCTAssertEqual(effort("anthropic/claude-sonnet-5", .instant), "low")
        XCTAssertNil(effort("openai/gpt-5.5", .auto))
    }

    /// Counts a key recursively through the nested JSON-ish structure.
    private static func countOccurrences(of key: String, in value: Any) -> Int {
        if let dictionary = value as? [String: Any] {
            return dictionary.reduce(dictionary[key] != nil ? 1 : 0) { count, pair in
                count + countOccurrences(of: key, in: pair.value)
            }
        }
        if let array = value as? [Any] {
            return array.reduce(0) { $0 + countOccurrences(of: key, in: $1) }
        }
        return 0
    }

    // MARK: - SSE fixtures

    private struct FixtureBytes: AsyncSequence {
        typealias Element = UInt8
        let bytes: [UInt8]

        struct Iterator: AsyncIteratorProtocol {
            var remaining: ArraySlice<UInt8>
            mutating func next() async -> UInt8? { remaining.popFirst() }
        }

        func makeAsyncIterator() -> Iterator { Iterator(remaining: bytes[...]) }
    }

    func testSSEPayloadExtractionFromFixture() async throws {
        let fixture = """
        event: response.output_text.delta
        data: {"type":"response.output_text.delta","delta":"Hel"}

        data: {"type":"response.output_text.delta","delta":"lo"}
        : keep-alive comment
        data:
        data: [DONE]
        """
        var payloads: [String] = []
        for try await payload in SSE.dataPayloads(FixtureBytes(bytes: Array(fixture.utf8))) {
            payloads.append(payload)
        }
        XCTAssertEqual(payloads.count, 2)
        XCTAssertTrue(payloads[0].contains("Hel"))
        XCTAssertTrue(payloads[1].contains("lo"))
    }

    // MARK: - Tool loop vs. the output-token limit (#107)

    /// An OpenAI Responses stream that completes a `function_call` item and THEN
    /// reports a `max_output_tokens` cutoff — the exact ordering issue #107 is
    /// about. When `truncated` is false the stream ends the way a real completed
    /// one does, with `response.completed`. The intermediate
    /// `function_call_arguments.delta` is there because the real API sends it and
    /// the client must ignore it (the completed item is the source of truth).
    private func toolCallFixture(truncated: Bool, text: String = "Let me check page 4") -> FixtureBytes {
        var lines = ""
        if !text.isEmpty {
            lines += """
            event: response.output_text.delta
            data: {"type":"response.output_text.delta","delta":"\(text)"}


            """
        }
        lines += """
        event: response.function_call_arguments.delta
        data: {"type":"response.function_call_arguments.delta","item_id":"fc_1","delta":"{\\"pageNu"}

        event: response.output_item.done
        data: {"type":"response.output_item.done","item":{"type":"function_call","name":"goToPage","call_id":"call_1","arguments":"{\\"pageNumber\\":4}"}}

        """
        if truncated {
            lines += """

            event: response.incomplete
            data: {"type":"response.incomplete","response":{"incomplete_details":{"reason":"max_output_tokens"}}}
            """
        } else {
            lines += """

            event: response.completed
            data: {"type":"response.completed","response":{"status":"completed"}}
            """
        }
        return FixtureBytes(bytes: Array(lines.utf8))
    }

    /// The regression: a response cut off at its token budget must NOT run the
    /// function call it had already queued, and must not start another turn.
    /// Before the gate, a non-empty `calls` sent the loop straight into
    /// `toolEngine.run` — spending more tokens right after the budget said stop.
    func testTokenLimitDropsQueuedFunctionCallsInsteadOfRunningThem() async throws {
        var deltas: [String] = []
        let turn = try await OpenAIClient.consumeTurn(
            toolCallFixture(truncated: true),
            onEvent: { if case .textDelta(let delta) = $0 { deltas.append(delta) } })
        // Fixture sanity: the model really did queue a call before the cutoff,
        // and the text it streamed was forwarded live on the way through.
        XCTAssertEqual(turn.calls.count, 1)
        XCTAssertTrue(turn.hitTokenLimit)
        XCTAssertEqual(deltas, ["Let me check page 4"])

        switch try OpenAIClient.turnOutcome(turn, hasPriorActions: false) {
        case .runTools:
            XCTFail("a truncated response must not run its queued function calls")
        case .finish(let reply):
            // The truncation still surfaces exactly as it does with no calls.
            XCTAssertTrue(reply.hasPrefix("Let me check page 4"))
            XCTAssertTrue(reply.hasSuffix("_(reply truncated at the output-token limit)_"))
        }
    }

    /// The gate must be scoped to the cutoff: an ordinary response that queued
    /// the same call still runs it, so the tool loop keeps working.
    func testQueuedFunctionCallsStillRunWhenTheResponseWasNotTruncated() async throws {
        let turn = try await OpenAIClient.consumeTurn(
            toolCallFixture(truncated: false), onEvent: { _ in })
        XCTAssertFalse(turn.hitTokenLimit)

        switch try OpenAIClient.turnOutcome(turn, hasPriorActions: false) {
        case .finish:
            XCTFail("a completed response must still run its queued function calls")
        case .runTools(let queued):
            XCTAssertEqual(queued.count, 1)
            XCTAssertEqual(queued.first?["name"] as? String, "goToPage")
            // The streamed argument fragment must not be mistaken for a call.
            XCTAssertEqual(queued.first?["arguments"] as? String, #"{"pageNumber":4}"#)
        }
    }

    /// A cutoff that streamed no text at all, on the FIRST turn, still reaches
    /// the error the no-calls path has always produced.
    func testTokenLimitWithNoTextAndNoPriorWorkErrorsRatherThanRunningTools() async throws {
        let turn = try await OpenAIClient.consumeTurn(
            toolCallFixture(truncated: true, text: ""), onEvent: { _ in })
        XCTAssertEqual(turn.calls.count, 1)
        XCTAssertTrue(turn.text.isEmpty)

        XCTAssertThrowsError(
            try OpenAIClient.turnOutcome(turn, hasPriorActions: false)
        ) { error in
            guard case AiClientError.message(let message) = error else {
                return XCTFail("expected an AiClientError.message, got \(error)")
            }
            XCTAssertTrue(message.hasPrefix("OpenAI hit the output-token limit"))
        }
    }

    /// Stopping must not mean erasing. A reasoning model can spend its whole
    /// budget thinking and emit one function call with no visible text — so when
    /// EARLIER turns of the same request already ran tools (which have already
    /// changed the document), the request ends with the cutoff named and their
    /// results kept, instead of throwing them away with an error.
    func testTokenLimitKeepsWorkDoneByEarlierTurnsInsteadOfThrowing() async throws {
        let turn = try await OpenAIClient.consumeTurn(
            toolCallFixture(truncated: true, text: ""), onEvent: { _ in })

        switch try OpenAIClient.turnOutcome(turn, hasPriorActions: true) {
        case .runTools:
            XCTFail("a truncated response must not run its queued function calls")
        case .finish(let reply):
            XCTAssertTrue(reply.contains("output-token limit"),
                          "the cutoff must still be named for the user")
        }
    }

    /// A non-token cutoff surfaces the reason instead of finalizing silently.
    func testNonTokenIncompleteReasonSurfaces() async throws {
        let filtered = """
        event: response.incomplete
        data: {"type":"response.incomplete","response":{"incomplete_details":{"reason":"content_filter"}}}
        """
        func fixture() -> FixtureBytes { FixtureBytes(bytes: Array(filtered.utf8)) }

        do {
            _ = try await OpenAIClient.consumeTurn(
                fixture(), onEvent: { _ in })
            XCTFail("the direct client must surface a non-token cutoff")
        } catch {
            XCTAssertTrue(
                error.localizedDescription.contains("content_filter"),
                "the direct client must name the reason it stopped for")
        }
    }

    // MARK: - §4 Usage parsing

    func testUsageParsingAcrossProviderShapes() {
        let openRouter = AiUsage.fromChatCompletions([
            "prompt_tokens": 10_000,
            "completion_tokens": 800,
            "cost": 0.0042,
            "prompt_tokens_details": ["cached_tokens": 6_000],
            "completion_tokens_details": ["reasoning_tokens": 300],
        ])
        XCTAssertEqual(openRouter.inputTokens, 10_000)
        XCTAssertEqual(openRouter.cachedInputTokens, 6_000)
        XCTAssertEqual(openRouter.reasoningTokens, 300)
        XCTAssertEqual(openRouter.outputTokens, 800)
        XCTAssertEqual(openRouter.costUSD, 0.0042)
        XCTAssertEqual(openRouter.cacheHitRatio.map { Int(($0 * 100).rounded()) }, 60)

        let responses = AiUsage.fromResponses([
            "input_tokens": 5_000,
            "output_tokens": 400,
            "input_tokens_details": ["cached_tokens": 2_500],
            "output_tokens_details": ["reasoning_tokens": 128],
        ])
        XCTAssertEqual(responses.inputTokens, 5_000)
        XCTAssertEqual(responses.cachedInputTokens, 2_500)
        XCTAssertEqual(responses.reasoningTokens, 128)
        XCTAssertEqual(responses.outputTokens, 400)
        XCTAssertNil(responses.costUSD)

        let gemini = AiUsage.fromGemini([
            "promptTokenCount": 3_000,
            "candidatesTokenCount": 250,
            "thoughtsTokenCount": 75,
            "cachedContentTokenCount": 1_000,
        ])
        XCTAssertEqual(gemini.inputTokens, 3_000)
        XCTAssertEqual(gemini.cachedInputTokens, 1_000)
        XCTAssertEqual(gemini.reasoningTokens, 75)
        XCTAssertEqual(gemini.outputTokens, 250)

        XCTAssertTrue(AiUsage.fromChatCompletions([:]).isEmpty)
    }

    func testUsageAccumulatesAcrossToolLoopTurns() {
        var total = AiUsage()
        total.accumulate(AiUsage(inputTokens: 1_000, cachedInputTokens: 0, outputTokens: 50))
        total.accumulate(AiUsage(inputTokens: 1_200, cachedInputTokens: 1_000, outputTokens: 300, costUSD: 0.001))
        XCTAssertEqual(total.inputTokens, 2_200)
        XCTAssertEqual(total.cachedInputTokens, 1_000)
        XCTAssertEqual(total.outputTokens, 350)
        XCTAssertEqual(total.costUSD, 0.001)
    }

    /// Usage round-trips through the persisted conversation JSON.
    func testUsageSurvivesMessageEncodingRoundTrip() throws {
        var message = AiPersistence.makeMessage(role: .assistant, content: "hi")
        message.usage = AiUsage(inputTokens: 42, cachedInputTokens: 10, outputTokens: 7)
        let data = try JSONEncoder().encode(message)
        let decoded = try JSONDecoder().decode(AiMessage.self, from: data)
        XCTAssertEqual(decoded.usage, message.usage)

        // And messages persisted before telemetry (no usage key) still decode.
        let legacy = Data(#"{"id":"a","role":"assistant","content":"old","createdAt":"2026-01-01T00:00:00.000Z"}"#.utf8)
        let decodedLegacy = try JSONDecoder().decode(AiMessage.self, from: legacy)
        XCTAssertNil(decodedLegacy.usage)
        XCTAssertTrue(decodedLegacy.references.isEmpty)
    }

    // MARK: - Composer focus requests

    /// Attaching context reveals the AI panel AND asks the composer for the
    /// keyboard, every time — including the second attach in a row, which a Bool
    /// flag would swallow. Tokens are one-shot: once consumed there is no
    /// pending request left to replay.
    func testAddingReferenceOpensAiAndRequestsComposerFocus() throws {
        let workspace = WorkspaceStore(sessions: DocumentSessionManager())
        let store = workspace.focusedPane.ai
        workspace.sidebarOpen = false
        workspace.sidebarTab = .annotations
        XCTAssertNil(store.composerFocusRequest, "no request before any attach")

        store.addReference(AiReference(kind: .selection(text: "First", page: 1)))
        XCTAssertTrue(workspace.sidebarOpen)
        XCTAssertEqual(workspace.sidebarTab, .ai)
        XCTAssertEqual(store.composerReferences.count, 1)
        let first = try XCTUnwrap(store.composerFocusRequest)

        store.consumeComposerFocusRequest(first)
        XCTAssertNil(store.composerFocusRequest)

        store.addReference(AiReference(kind: .selection(text: "Second", page: 2)))
        let second = try XCTUnwrap(store.composerFocusRequest)
        XCTAssertNotEqual(second, first, "a second attach must be a distinct request")
        XCTAssertEqual(store.composerReferences.count, 2)
    }

    /// A stale token — one a torn-down composer fulfilled before the user
    /// attached again — must not cancel the request that is actually pending.
    func testConsumingAStaleFocusRequestLeavesTheCurrentOnePending() throws {
        let workspace = WorkspaceStore(sessions: DocumentSessionManager())
        let store = workspace.focusedPane.ai
        store.addReference(AiReference(kind: .selection(text: "First", page: 1)))
        let stale = try XCTUnwrap(store.composerFocusRequest)
        store.consumeComposerFocusRequest(stale)
        store.addReference(AiReference(kind: .selection(text: "Second", page: 2)))
        let current = try XCTUnwrap(store.composerFocusRequest)

        store.consumeComposerFocusRequest(stale)

        XCTAssertEqual(store.composerFocusRequest, current)
    }

    /// Split panes each own their focus namespace, so attaching in one pane
    /// can't pull the keyboard into the other pane's composer.
    func testComposerFocusRequestsAreScopedToTheirSplitPane() throws {
        let workspace = WorkspaceStore(sessions: DocumentSessionManager())
        let original = workspace.focusedPane.ai
        original.addReference(AiReference(kind: .selection(text: "Left", page: 1)))
        let originalRequest = try XCTUnwrap(original.composerFocusRequest)
        original.consumeComposerFocusRequest(originalRequest)

        workspace.splitFocused(.horizontal)
        let split = workspace.focusedPane.ai
        split.addReference(AiReference(kind: .selection(text: "Right", page: 1)))

        XCTAssertNil(original.composerFocusRequest)
        XCTAssertNotNil(split.composerFocusRequest)
        XCTAssertNotEqual(split.composerFocusRequest, originalRequest)
    }

    // MARK: - Capture targets survive the await

    /// A page render that finishes after the user switched tabs must not attach
    /// the old document's pixels to the new one.
    func testPdfPageCaptureAfterAwaitIsRejectedAfterTabSwitch() throws {
        let workspace = WorkspaceStore(sessions: DocumentSessionManager())
        let store = workspace.focusedPane.ai
        let app = workspace.focusedPane.app
        app.attachTab(Self.tab(id: "pdf-a", document: DocumentInfo(
            kind: .pdf, pdfPath: "/tmp/a.pdf", title: "A",
            pageCount: 1, lastPage: 1, docId: "doc-a")))
        let target = try XCTUnwrap(store.currentReferenceTarget())
        app.attachTab(Self.tab(id: "pdf-b", document: DocumentInfo(
            kind: .pdf, pdfPath: "/tmp/b.pdf", title: "B",
            pageCount: 1, lastPage: 1, docId: "doc-b")))

        let attached = store.addCapturedReference(
            AiReference(kind: .pageSnapshot(image: Self.snapshot, page: 1)), target: target)

        XCTAssertFalse(attached)
        XCTAssertTrue(store.composerReferences.isEmpty)
    }

    /// The same guard covers web region crops, whose capture is also async.
    func testWebRegionCaptureAfterAwaitIsRejectedAfterTabSwitch() throws {
        let workspace = WorkspaceStore(sessions: DocumentSessionManager())
        let store = workspace.focusedPane.ai
        let app = workspace.focusedPane.app
        app.attachTab(Self.tab(id: "web-a", document: DocumentInfo(
            kind: .web, pdfPath: "https://a.example", title: "A",
            pageCount: 1, lastPage: 1, docId: "web-doc-a")))
        let target = try XCTUnwrap(store.currentReferenceTarget())
        app.attachTab(Self.tab(id: "web-b", document: DocumentInfo(
            kind: .web, pdfPath: "https://b.example", title: "B",
            pageCount: 1, lastPage: 1, docId: "web-doc-b")))

        let attached = store.addCapturedReference(
            AiReference(kind: .region(image: Self.snapshot, page: 1)), target: target)

        XCTAssertFalse(attached)
        XCTAssertTrue(store.composerReferences.isEmpty)
    }

    /// The guard must not be so strict that the ordinary case — nothing changed
    /// while the page rendered — is rejected too.
    func testCaptureIsAttachedWhenTheTabIsStillTheSameOne() throws {
        let workspace = WorkspaceStore(sessions: DocumentSessionManager())
        let store = workspace.focusedPane.ai
        let app = workspace.focusedPane.app
        app.attachTab(Self.tab(id: "pdf-a", document: DocumentInfo(
            kind: .pdf, pdfPath: "/tmp/a.pdf", title: "A",
            pageCount: 1, lastPage: 1, docId: "doc-a")))
        let target = try XCTUnwrap(store.currentReferenceTarget())

        let attached = store.addCapturedReference(
            AiReference(kind: .pageSnapshot(image: Self.snapshot, page: 1)), target: target)

        XCTAssertTrue(attached)
        XCTAssertEqual(store.composerReferences.count, 1)
    }

    private static let snapshot = AiPageImageSnapshot(
        pageNumber: 1, base64Data: "aGVsbG8=", mediaType: "image/png", width: 12, height: 9)

    private static func tab(id: String, document: DocumentInfo) -> PdfTab {
        PdfTab(
            id: id, document: document, currentPage: 1, numPages: 1, zoom: 1,
            visiblePages: [1], webVisibleRange: nil, webVisibleBookmarks: [], mode: .view)
    }

    // MARK: - Auto page-image gating

    /// Pages with real text send no auto screenshot; scanned/low-text pages
    /// (and pages not yet extracted) do.
    func testAutoPageImageAttachesOnlyForLowTextPages() {
        XCTAssertTrue(AiStore.shouldAutoAttachPageImage(pageText: nil))
        XCTAssertTrue(AiStore.shouldAutoAttachPageImage(pageText: ""))
        XCTAssertTrue(AiStore.shouldAutoAttachPageImage(
            pageText: String(repeating: "a", count: AiStore.autoPageImageTextThreshold - 1)))
        XCTAssertFalse(AiStore.shouldAutoAttachPageImage(
            pageText: String(repeating: "a", count: AiStore.autoPageImageTextThreshold)))
    }

    // MARK: - Conversation persistence write-behind

    /// A save is visible to an immediate load (via the in-memory cache) even
    /// before the coalesced disk flush has run.
    func testSaveIsImmediatelyVisibleToLoad() {
        let document = DocumentInfo(
            kind: .pdf, pdfPath: "/tmp/ai-persistence-test-a.pdf", title: "A", pageCount: 1, lastPage: 1)
        let message = AiPersistence.makeMessage(role: .user, content: "hello persistence")
        AiPersistence.saveConversation(for: document, messages: [message])
        let loaded = AiPersistence.loadConversation(for: document)
        XCTAssertEqual(loaded.map(\.content), ["hello persistence"])
        // Cleanup so repeated test runs don't accumulate:
        AiPersistence.saveConversation(for: document, messages: [])
    }

    /// awaitPendingFlush drains the coalesced write.
    func testAwaitPendingFlushCompletes() async {
        let document = DocumentInfo(
            kind: .pdf, pdfPath: "/tmp/ai-persistence-test-b.pdf", title: "B", pageCount: 1, lastPage: 1)
        AiPersistence.saveConversation(
            for: document,
            messages: [AiPersistence.makeMessage(role: .user, content: "flush me")]
        )
        await AiPersistence.awaitPendingFlush()
        AiPersistence.saveConversation(for: document, messages: [])
        await AiPersistence.awaitPendingFlush()
    }

    /// iOS may assign a new data-container UUID after reinstall/update. The
    /// imported PDF remains identifiable by its unique library filename, so an
    /// existing conversation must follow it to the new absolute path.
    func testConversationSurvivesContainerPathChange() async {
        let filename = "ai-container-migration-\(UUID().uuidString).pdf"
        let oldDocument = DocumentInfo(
            kind: .pdf,
            pdfPath: "/old/container/Library/\(filename)",
            title: "Migration",
            pageCount: 1,
            lastPage: 1)
        let movedDocument = DocumentInfo(
            kind: .pdf,
            pdfPath: "/new/container/Library/\(filename)",
            title: "Migration",
            pageCount: 1,
            lastPage: 1)
        AiPersistence.saveConversation(
            for: oldDocument,
            messages: [AiPersistence.makeMessage(role: .user, content: "survives move")]
        )

        XCTAssertEqual(
            AiPersistence.loadConversation(for: movedDocument).map(\.content),
            ["survives move"])

        AiPersistence.saveConversation(for: movedDocument, messages: [])
        await AiPersistence.awaitPendingFlush()
    }

    /// Web URLs are exact identities even when their path happens to end in
    /// `.pdf`; they must never claim a local PDF conversation by filename.
    func testWebPdfUrlDoesNotMigrateLocalConversation() async {
        let filename = "ai-web-collision-\(UUID().uuidString).pdf"
        let localDocument = DocumentInfo(
            kind: .pdf,
            pdfPath: "/old/container/Library/\(filename)",
            title: "Local PDF",
            pageCount: 1,
            lastPage: 1)
        let webDocument = DocumentInfo(
            kind: .web,
            pdfPath: "https://example.com/downloads/\(filename)",
            title: "Web PDF",
            pageCount: nil,
            lastPage: nil)
        AiPersistence.saveConversation(
            for: localDocument,
            messages: [AiPersistence.makeMessage(role: .user, content: "local only")]
        )

        XCTAssertTrue(AiPersistence.loadConversation(for: webDocument).isEmpty)

        AiPersistence.saveConversation(for: localDocument, messages: [])
        await AiPersistence.awaitPendingFlush()
    }

    // MARK: - §6 Arbitrary image attachments

    /// An oversized opaque image is downscaled to the request budget and
    /// re-encoded as JPEG, with no page (it isn't part of the document).
    func testAttachedImageIsDownscaledAndTranscoded() throws {
        let data = Self.bitmap(width: 3000, height: 1000, alpha: false)
        let snapshot = try XCTUnwrap(aiImageSnapshot(from: data, maxSide: 1568))
        XCTAssertEqual(snapshot.width, 1568)
        XCTAssertEqual(snapshot.height, 523)  // aspect preserved
        XCTAssertEqual(snapshot.mediaType, "image/jpeg")
        XCTAssertNil(snapshot.pageNumber)
        XCTAssertFalse(snapshot.base64Data.isEmpty)
    }

    /// Transparency only survives in PNG, so an alpha image must not become JPEG.
    func testAttachedImageWithAlphaStaysPng() throws {
        let snapshot = try XCTUnwrap(aiImageSnapshot(from: Self.bitmap(width: 40, height: 40, alpha: true)))
        XCTAssertEqual(snapshot.mediaType, "image/png")
        XCTAssertEqual(snapshot.width, 40)  // under the cap: not upscaled
    }

    func testAttachedImageRejectsNonImageBytes() {
        XCTAssertNil(aiImageSnapshot(from: Data("not an image".utf8)))
    }

    /// The prompt names an attached image by file name and claims no page.
    func testReferenceLineForAttachedImageHasNoPage() {
        let snapshot = AiPageImageSnapshot(
            pageNumber: nil, base64Data: "aGVsbG8=", mediaType: "image/png", width: 12, height: 9)
        let context = AiContextSnapshot(
            title: "Doc", numPages: 3, currentPage: 1, visiblePages: [1], annotations: [],
            currentPageImage: nil,
            references: [AiReference(kind: .image(image: snapshot, name: "diagram.png"))]
        )
        let block = AiPrompts.buildContextBlock(pageTexts: [1: "text"], context: context)
        XCTAssertTrue(block.contains("[attached image: diagram.png] image attached (12x9)"))
        XCTAssertFalse(block.contains("[attached image: diagram.png] image attached (12x9), p."))
    }

    // (Removed `testReferenceLineForAttachedFileCarriesContents`: the AI chat is
    // images-only now, so no `.file(text:name:)` reference is ever produced and
    // the prompt no longer has a file-text branch to exercise.)

    /// Only images can be attached: an image with an image extension comes back
    /// as a snapshot; a text file is declined by name (never carried as text).
    func testFileAttachmentClassification() throws {
        let textURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("ai-file-attachment-test.md")
        try Data("# Notes\nhello".utf8).write(to: textURL)
        defer { try? FileManager.default.removeItem(at: textURL) }
        guard case let .rejected(name)? = aiFileAttachment(from: textURL) else {
            return XCTFail("expected a rejected non-image file")
        }
        XCTAssertEqual(name, "ai-file-attachment-test.md")

        let imageURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("ai-file-attachment-test.png")
        try Self.bitmap(width: 20, height: 10, alpha: false).write(to: imageURL)
        defer { try? FileManager.default.removeItem(at: imageURL) }
        guard case let .image(snapshot, _)? = aiFileAttachment(from: imageURL) else {
            return XCTFail("expected an image attachment")
        }
        XCTAssertEqual(snapshot.width, 20)
    }

    /// A binary (non-image) file is declined by name — never attached as a
    /// placeholder, so the drop is explained without smuggling in file bytes.
    func testBinaryFileIsRejectedByName() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("ai-file-attachment-test.bin")
        try Data([0xFF, 0xFE, 0x00, 0x81, 0x92, 0xA3]).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        guard case let .rejected(name)? = aiFileAttachment(from: url) else {
            return XCTFail("expected a rejected non-image file")
        }
        XCTAssertEqual(name, "ai-file-attachment-test.bin")
    }

    /// The gate the attach affordances read: text-only models say no, built-in
    /// multimodal catalogs say yes, and an OpenRouter id we don't know about
    /// stays permissive (the catalog may still be loading).
    func testSupportsVisionResolution() {
        XCTAssertFalse(AiModelCatalog.supportsVision(provider: .opencode, model: "kimi-k2.6", catalog: nil))
        XCTAssertTrue(AiModelCatalog.supportsVision(provider: .opencode, model: "claude-sonnet-5", catalog: nil))
        XCTAssertTrue(AiModelCatalog.supportsVision(provider: .gemini, model: "anything", catalog: nil))
        XCTAssertTrue(AiModelCatalog.supportsVision(provider: .openrouter, model: "vendor/unknown", catalog: nil))
    }

    // MARK: - §5 Gemini thinking levels & output budget (#96)

    /// `maxOutputTokens` for the mode/model, read off the body that actually
    /// ships rather than the helper, so a wiring mistake in `generationConfig`
    /// fails these too.
    private static func geminiBody(_ mode: AiThinkingMode, _ model: String) -> [String: Any] {
        GeminiClient.requestBody(
            systemPrompt: "system",
            contents: [["role": "user", "parts": [["text": "hi"]]]],
            generationConfig: GeminiClient.generationConfig(for: mode, model: model)
        )
    }

    private static func geminiConfig(_ mode: AiThinkingMode, _ model: String) -> [String: Any] {
        (geminiBody(mode, model)["generation_config"] as? [String: Any]) ?? [:]
    }

    private static func geminiCap(_ mode: AiThinkingMode, _ model: String) -> Int? {
        geminiConfig(mode, model)["maxOutputTokens"] as? Int
    }

    private static func geminiLevel(_ mode: AiThinkingMode, _ model: String) -> String? {
        (geminiConfig(mode, model)["thinkingConfig"] as? [String: Any])?["thinkingLevel"] as? String
    }

    private static func geminiBudget(_ mode: AiThinkingMode, _ model: String) -> Int? {
        (geminiConfig(mode, model)["thinkingConfig"] as? [String: Any])?["thinkingBudget"] as? Int
    }

    /// The #96 regression: `.auto` sends no thinkingConfig on every family but
    /// 2.5 flash, so the server picks the level — and Google documents that pick
    /// as `high` on the Pro and 3-flash rows and dynamic on 2.5. The cap stayed
    /// at the flat 8192 base anyway, leaving zero headroom for reasoning the
    /// model was going to do regardless, on the app's default provider at its
    /// default thinking mode.
    ///
    /// The reserve is sized off each family's *documented* default rather than a
    /// blanket assumption, so the expected caps below differ per row.
    func testGeminiAutoBudgetsForTheThinkingTheServerWillDo() {
        for model in ["gemini-3-pro-preview", "gemini-3-flash-preview", "gemini-2.5-pro"] {
            XCTAssertNil(
                Self.geminiConfig(.auto, model)["thinkingConfig"],
                "Auto must leave the level to the server on \(model)")
            XCTAssertEqual(
                Self.geminiCap(.auto, model), 32768,
                "Auto must budget for server-chosen thinking on \(model)")
        }
        // 3.5-flash defaults to `medium`, so it reserves a medium's worth.
        XCTAssertEqual(Self.geminiCap(.auto, "gemini-3.5-flash"), 24576)
    }

    /// The flash-lite rows document their default as `minimal`, so there is
    /// nothing for Auto to reserve and the base stands — including on
    /// `gemini-3.1-flash-lite-preview`, which is the app's default model. Pinned
    /// because the tempting blanket fix ("Auto always budgets as High") would
    /// quadruple the cost guard on the single most common request the app makes,
    /// for thinking the server has documented it will not do.
    func testGeminiAutoKeepsTheBaseWhereTheServerDefaultsToMinimal() {
        XCTAssertNil(Self.geminiConfig(.auto, "gemini-3.1-flash-lite-preview")["thinkingConfig"])
        XCTAssertEqual(Self.geminiCap(.auto, "gemini-3.1-flash-lite-preview"), 8192)
    }

    /// A family with no row keeps the flat base in *every* mode. The safe branch
    /// for a budget is the conservative one, opposite to `supportedThinkingLevels`:
    /// several ids this endpoint serves cap output at 8192, and Gemini rejects a
    /// `maxOutputTokens` above the model's limit — so guessing generously would
    /// turn a truncated answer into a request that fails outright.
    func testGeminiUnknownFamiliesKeepTheBaseBudget() {
        for model in ["gemini-9-ultra", "gemma-3-27b-it", "gemini-1.0-pro"] {
            for mode in AiThinkingMode.allCases {
                XCTAssertEqual(Self.geminiCap(mode, model), 8192, "\(model)/\(mode)")
            }
        }
    }

    /// The reserve keys off "no config is going out while the model thinks
    /// anyway", not off the mode — so a family can never have its High budgeted
    /// below its Auto for the very same request JSON.
    func testGeminiAutoIsNeverBudgetedAboveAnExplicitMode() {
        for model in AiModelCatalog.gemini + ["gemini-9-ultra", "gemini-3.9-ultra"] {
            let auto = Self.geminiCap(.auto, model) ?? 0
            let high = Self.geminiCap(.high, model) ?? 0
            XCTAssertLessThanOrEqual(
                auto, high,
                "\(model): Auto (\(auto)) must not out-budget High (\(high))")
        }
    }

    /// Auto on 2.5 flash still disables thinking outright, so its budget stays
    /// at the base — the mode sends `thinkingBudget: 0` and there is nothing to
    /// reserve for. Unchanged by #96, and pinned so the new Auto branch can't
    /// quietly widen it.
    func testGeminiAutoKeepsTheBaseBudgetWhereThinkingIsDisabled() {
        for model in ["gemini-2.5-flash", "gemini-2.5-flash-lite"] {
            XCTAssertEqual(Self.geminiBudget(.auto, model), 0)
            XCTAssertEqual(Self.geminiCap(.auto, model), 8192)
        }
    }

    /// The 2.0 flash models and the 1.5 line don't think at all *and* cap output
    /// at 8192 tokens total, so handing them a reasoning reserve would ask for
    /// more than the model can return. Every mode stays at the base.
    func testGeminiNonThinkingFamiliesNeverExceedTheirOutputLimit() {
        for model in ["gemini-2.0-flash", "gemini-2.0-flash-lite",
                      "gemini-1.5-pro", "gemini-1.5-flash"] {
            for mode in AiThinkingMode.allCases {
                XCTAssertNil(Self.geminiConfig(mode, model)["thinkingConfig"], "\(model)/\(mode)")
                XCTAssertEqual(Self.geminiCap(mode, model), 8192, "\(model)/\(mode)")
            }
        }
    }

    /// The `contains("gemini-3-pro")` bug: `gemini-3.1-pro` does not contain
    /// that substring, so it fell into the branch that sends `minimal` — a level
    /// the 3.1 Pro row doesn't have, which 400s the request the way #94 did.
    /// Google's rows: 3-pro is low/high, 3.1-pro adds medium but still has no
    /// minimal, and the flash line takes the full ladder.
    func testGeminiThinkingLevelRowsMatchTheDocumentedFamilies() {
        XCTAssertEqual(GeminiClient.supportedThinkingLevels(model: "gemini-3-pro-preview"),
                       ["low", "high"])
        XCTAssertEqual(GeminiClient.supportedThinkingLevels(model: "gemini-3.1-pro-preview"),
                       ["low", "medium", "high"])
        XCTAssertEqual(GeminiClient.supportedThinkingLevels(model: "gemini-3-flash-preview"),
                       ["minimal", "low", "medium", "high"])
        XCTAssertEqual(GeminiClient.supportedThinkingLevels(model: "gemini-3.1-flash-lite-preview"),
                       ["minimal", "low", "medium", "high"])
        XCTAssertEqual(GeminiClient.supportedThinkingLevels(model: "gemini-3.5-flash"),
                       ["minimal", "low", "medium", "high"])
        // Off the 3 line there is no level vocabulary at all.
        XCTAssertTrue(GeminiClient.supportedThinkingLevels(model: "gemini-2.5-pro").isEmpty)
        // The image variants are the exception to "the flash line takes the full
        // ladder", and the substring that matches the flash rows would otherwise
        // swallow them and send a level they reject.
        XCTAssertEqual(GeminiClient.supportedThinkingLevels(model: "gemini-3.1-flash-lite-image"),
                       ["minimal", "high"])
        // An unrecognized 3.x id gets the intersection of the text rows, so it
        // can never be sent a level some future Pro release rejects.
        XCTAssertEqual(GeminiClient.supportedThinkingLevels(model: "gemini-3.9-ultra"),
                       ["low", "high"])
    }

    /// What the server does when the field is omitted, which is what the Auto
    /// reserve is sized from. Written out per family because the whole point of
    /// the #96 fix is that this is *not* uniform across the line.
    func testGeminiDocumentedDefaultsDriveTheAutoReserve() {
        func level(_ model: String) -> String? {
            GeminiClient.unconfiguredThinking(model: model)?["thinkingLevel"] as? String
        }
        XCTAssertEqual(level("gemini-3-pro-preview"), "high")
        XCTAssertEqual(level("gemini-3-flash-preview"), "high")
        XCTAssertEqual(level("gemini-3.5-flash"), "medium")
        XCTAssertEqual(level("gemini-3.1-flash-lite-preview"), "minimal")
        // 2.5 defaults to dynamic thinking, which is the -1 budget.
        XCTAssertEqual(
            GeminiClient.unconfiguredThinking(model: "gemini-2.5-pro")?["thinkingBudget"] as? Int, -1)
        // Families that do no thinking, and ids with no row at all, reserve
        // nothing — an omitted config there really means zero reasoning tokens.
        for model in ["gemini-2.0-flash", "gemini-1.5-pro", "gemma-3-27b-it", "gemini-9-ultra"] {
            XCTAssertNil(GeminiClient.unconfiguredThinking(model: model), model)
        }
    }

    /// The end-to-end shape of the bug above, asserted on the request body: no
    /// shipped Gemini id may ever be sent a level outside its own row.
    func testNoShippedGeminiModelIsSentAnUnsupportedLevel() {
        for model in AiModelCatalog.gemini {
            let supported = GeminiClient.supportedThinkingLevels(model: model)
            for mode in AiThinkingMode.allCases {
                guard let level = Self.geminiLevel(mode, model) else { continue }
                XCTAssertTrue(
                    supported.contains(level),
                    "\(model) must not be sent thinkingLevel \(level) for \(mode)")
            }
        }
        // Specifically: Instant on a Pro row rounds to `low` instead of sending
        // the `minimal` that row doesn't have.
        XCTAssertEqual(Self.geminiLevel(.instant, "gemini-3.1-pro-preview"), "low")
        XCTAssertEqual(Self.geminiLevel(.instant, "gemini-3-pro-preview"), "low")
        // …while a flash row, which does have it, still gets `minimal`.
        XCTAssertEqual(Self.geminiLevel(.instant, "gemini-3.1-flash-lite-preview"), "minimal")
    }

    /// Ties round up on the Gemini ladder: 3-pro offers only low/high, and
    /// Medium sits equidistant between them. Rounding down would demote a
    /// Medium request to the weakest setting the model has.
    func testGeminiLevelTiesRoundUp() {
        XCTAssertEqual(Self.geminiLevel(.medium, "gemini-3-pro-preview"), "high")
        // 3.1-pro has a real `medium`, so nothing to round.
        XCTAssertEqual(Self.geminiLevel(.medium, "gemini-3.1-pro-preview"), "medium")
    }

    /// Explicit modes budget off the level actually sent, so the cap tracks the
    /// resolved level rather than the requested one.
    func testGeminiExplicitModeBudgetsTrackTheResolvedLevel() {
        XCTAssertEqual(Self.geminiCap(.instant, "gemini-3.1-flash-lite-preview"), 8192)
        XCTAssertEqual(Self.geminiCap(.low, "gemini-3.1-flash-lite-preview"), 16384)
        XCTAssertEqual(Self.geminiCap(.medium, "gemini-3.1-flash-lite-preview"), 24576)
        XCTAssertEqual(Self.geminiCap(.high, "gemini-3.1-flash-lite-preview"), 32768)
        // Instant on 3-pro resolves up to `low`, and the cap follows it up too.
        XCTAssertEqual(Self.geminiCap(.instant, "gemini-3-pro-preview"), 16384)
        // 2.5 Pro cannot disable thinking; its floor is the documented 128.
        XCTAssertEqual(Self.geminiBudget(.instant, "gemini-2.5-pro"), 128)
        XCTAssertEqual(Self.geminiCap(.instant, "gemini-2.5-pro"), 8320)
    }

    /// Every cap the shipped catalog can produce stays inside the model's own
    /// documented output limit. The limits are written out per id rather than
    /// derived from the code under test: reading them back out of the
    /// implementation would let a misclassified model raise its own allowed
    /// limit and pass green while the app sent a cap the API rejects.
    func testGeminiCapsStayInsideDocumentedOutputLimits() {
        let documentedLimit = [
            "gemini-3.1-flash-lite-preview": 65536,
            "gemini-3-pro-preview": 65536,
            "gemini-3-flash-preview": 65536,
            "gemini-2.5-pro": 65536,
            "gemini-2.5-flash": 65536,
            "gemini-2.5-flash-lite": 65536,
            "gemini-2.0-flash": 8192,
            "gemini-2.0-flash-lite": 8192,
            "gemini-1.5-pro": 8192,
            "gemini-1.5-flash": 8192,
        ]
        // Fails loudly when the catalog gains a model this table doesn't cover,
        // rather than skipping it.
        XCTAssertEqual(Set(documentedLimit.keys), Set(AiModelCatalog.gemini))
        for (model, limit) in documentedLimit {
            for mode in AiThinkingMode.allCases {
                let cap = Self.geminiCap(mode, model) ?? 0
                XCTAssertLessThanOrEqual(cap, limit, "\(model)/\(mode) asks for more than it can return")
                XCTAssertGreaterThan(cap, 0, "\(model)/\(mode)")
            }
        }
    }

    /// The body still carries everything the turn needs; `generation_config` is
    /// the only part #96 reshapes.
    func testGeminiRequestBodyKeepsItsTurnPayload() throws {
        let body = Self.geminiBody(.high, "gemini-3-flash-preview")
        let instruction = try XCTUnwrap(body["system_instruction"] as? [String: Any])
        XCTAssertEqual(((instruction["parts"] as? [[String: Any]])?.first?["text"]) as? String, "system")
        XCTAssertNotNil(body["contents"])
        XCTAssertNotNil(body["tools"])
        XCTAssertEqual(Self.geminiConfig(.high, "gemini-3-flash-preview")["temperature"] as? Double, 0.2)
    }

    /// Bytes for a blank bitmap in PNG, as a stand-in for a dropped file. The
    /// `opaque` flag controls whether the encoded PNG carries an alpha channel,
    /// which is exactly what `aiImageSnapshot` inspects to choose PNG vs JPEG.
    private static func bitmap(width: Int, height: Int, alpha: Bool) -> Data {
        let format = UIGraphicsImageRendererFormat.preferred()
        format.scale = 1
        format.opaque = !alpha
        let image = UIGraphicsImageRenderer(
            size: CGSize(width: width, height: height), format: format
        ).image { ctx in
            (alpha ? UIColor.clear : UIColor.white).setFill()
            ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        }
        return image.pngData()!
    }
}
