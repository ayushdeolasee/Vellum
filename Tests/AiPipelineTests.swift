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
    /// is composed from compact receipts, so the marker must never survive into
    /// the message — or, transitively, into the next request's prompt.
    func testRawRetrievalOutputCannotReachTheNextPrompt() {
        let marker = "UNIQUE-RETRIEVAL-MARKER-93b1f2"
        // What the tool loop saw (transient, provider-side only):
        let rawToolOutput = "Page 20:\nlorem ipsum \(marker) dolor sit amet"
        XCTAssertTrue(rawToolOutput.contains(marker), "fixture sanity")

        // What the store persists: reply + compact receipts.
        let persisted = AiStore.composeAssistantContent(
            reply: "Page 20 discusses the marker experiment.",
            receipts: ["Read page 20.", "Searched the document for \"marker\"."]
        )
        XCTAssertFalse(persisted.contains(marker))
        XCTAssertTrue(persisted.contains("Read page 20."))

        // And the next turn's conversation block (built from persisted
        // messages) cannot resend it.
        let history = [
            AiPersistence.makeMessage(role: .user, content: "What's on page 20?"),
            AiPersistence.makeMessage(role: .assistant, content: persisted),
        ]
        XCTAssertFalse(AiPrompts.buildConversationBlock(history).contains(marker))
    }

    func testComposeAssistantContentWithoutReceiptsIsJustTheReply() {
        XCTAssertEqual(AiStore.composeAssistantContent(reply: "Hello.", receipts: []), "Hello.")
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
        XCTAssertEqual(OpenAIClient.maxOutputTokens(forEffort: "minimal"), 4096)
        XCTAssertEqual(OpenAIClient.maxOutputTokens(forEffort: "low"), 8192)
        XCTAssertEqual(OpenAIClient.maxOutputTokens(forEffort: "medium"), 16384)
        XCTAssertEqual(OpenAIClient.maxOutputTokens(forEffort: "high"), 32768)
        XCTAssertEqual(OpenAIClient.maxOutputTokens(forEffort: "unknown"), 4096)
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
        XCTAssertNil(try JSONDecoder().decode(AiMessage.self, from: legacy).usage)
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

    /// The gate the attach affordances read: text-only models say no, built-in
    /// multimodal catalogs say yes, and an OpenRouter id we don't know about
    /// stays permissive (the catalog may still be loading).
    func testSupportsVisionResolution() {
        XCTAssertFalse(AiModelCatalog.supportsVision(provider: .opencode, model: "kimi-k2.6", catalog: nil))
        XCTAssertTrue(AiModelCatalog.supportsVision(provider: .opencode, model: "claude-sonnet-5", catalog: nil))
        XCTAssertTrue(AiModelCatalog.supportsVision(provider: .gemini, model: "anything", catalog: nil))
        XCTAssertTrue(AiModelCatalog.supportsVision(provider: .openrouter, model: "vendor/unknown", catalog: nil))
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
