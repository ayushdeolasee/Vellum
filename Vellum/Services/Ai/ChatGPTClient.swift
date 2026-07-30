import Foundation

/// Streams a reply from the ChatGPT-subscription Codex backend
/// (`https://chatgpt.com/backend-api/codex/responses`) using the Responses API,
/// authenticated with the OAuth access token from `ChatGPTAuth` rather than an
/// API key. Shape mirrors `OpenAIClient` (same tool loop, same SSE events); the
/// differences are the base URL, the OAuth/account headers, and per-turn token
/// refresh.
@MainActor
final class ChatGPTClient {
    private let auth: ChatGPTAuth
    /// Stable id for this conversation turn, sent as `session-id` like the CLI.
    private let sessionId = UUID().uuidString

    init(auth: ChatGPTAuth) {
        self.auth = auth
    }

    func generate(
        model: String,
        systemPrompt: String,
        prompt: AiUserPrompt,
        images: [AiPageImageSnapshot],
        thinkingMode: AiThinkingMode,
        sessionIdAtStart: String,
        toolEngine: AiToolEngine,
        onEvent: @escaping @MainActor (AiStreamEvent) -> Void
    ) async throws -> AiProviderResult {
        guard let url = URL(string: "https://chatgpt.com/backend-api/codex/responses") else {
            throw AiClientError.message("Invalid ChatGPT endpoint.")
        }
        // Responses API caching is keyed by prompt_cache_key + prefix, not
        // cache_control parts, so send the fused prompt as a single text part.
        var content: [[String: Any]] = [["type": "input_text", "text": prompt.joined]]
        for image in images where !image.base64Data.isEmpty {
            content.append([
                "type": "input_image",
                "image_url": "data:\(image.mediaType);base64,\(image.base64Data)",
            ])
        }
        var input: [[String: Any]] = [["role": "user", "content": content]]
        var actionResults: [String] = []

        onEvent(.status("Thinking"))

        for _ in 0..<8 {
            let body = Self.requestBody(
                model: model,
                systemPrompt: systemPrompt,
                input: input,
                thinkingMode: thinkingMode,
                sessionIdAtStart: sessionIdAtStart
            )
            let request = try await makeRequest(url: url, body: body)
            let bytes = try await openStream(request)

            // Same parse AND same gate as the direct client. This loop used to be
            // a second copy of both, which is how #107 came to be fixed in one
            // client and not the other; the one remaining behavioural difference
            // is now the `throwsOnUnexpectedIncomplete` argument rather than a
            // divergent body. A turn cut off at the token limit never runs its
            // queued calls or starts another turn.
            let turn = try await OpenAIClient.consumeTurn(
                bytes, provider: "ChatGPT", throwsOnUnexpectedIncomplete: false, onEvent: onEvent)

            switch try OpenAIClient.turnOutcome(
                turn, provider: "ChatGPT", hasPriorActions: !actionResults.isEmpty) {
            case .finish(let reply):
                return AiProviderResult(reply: Self.finalize(reply, actions: actionResults), actionResults: actionResults)
            case .runTools(let queued):
                for call in queued {
                    guard let name = call["name"] as? String,
                          let callId = call["call_id"] as? String else { continue }
                    let argumentsText = call["arguments"] as? String ?? "{}"
                    let values = (try? JSONSerialization.jsonObject(with: Data(argumentsText.utf8))) as? [String: Any] ?? [:]
                    let action = AiToolAction(tool: name, args: Self.toolArguments(from: values))
                    input.append([
                        "type": "function_call",
                        "call_id": callId,
                        "name": name,
                        "arguments": argumentsText,
                    ])
                    onEvent(.toolStarted(summary: GeminiClient.toolSummary(action)))
                    let result = await toolEngine.run(
                        action,
                        sessionIdAtStart: sessionIdAtStart,
                        actionCount: actionResults.count
                    )
                    actionResults.append(result)
                    onEvent(.toolFinished(result: result))
                    input.append(["type": "function_call_output", "call_id": callId, "output": result])
                }
            }
            onEvent(.status("Thinking"))
        }
        return AiProviderResult(reply: Self.finalize("", actions: actionResults), actionResults: actionResults)
    }

    /// The cap this client sent for every mode before #96, kept as the floor so
    /// the fix can only ever raise a budget.
    static let previousFlatOutputCap = 8192

    /// Request body for one tool-loop turn.
    ///
    /// Reasoning effort on the gpt-5 family: `.auto` omits the field so the
    /// Codex backend applies its own default (the removed codex-CLI path sent
    /// none); explicit modes set it — resolved through the same per-family table
    /// the direct client uses. The Codex slugs name the same models, so passing
    /// the raw value through meant Instant sent "minimal" to gpt-5.5 (the
    /// default here), which is the value #94 is about: the family rejects it
    /// outright.
    ///
    /// The output cap is scaled by that same resolved effort through
    /// `OpenAIClient.maxOutputTokens`. It used to be a flat 8192 for every mode,
    /// which is the #96 bug: reasoning tokens are billed against
    /// `max_output_tokens` on the Responses API, so High spent most of one
    /// shared budget thinking and got the same room for the answer as Instant —
    /// which is exactly how a long High answer ends up truncated. Every slug
    /// this client ships is a gpt-5 variant, so `isReasoningModel` is true for
    /// all of them today; it is still passed rather than assumed so a future
    /// non-reasoning slug keeps the flat cap.
    ///
    /// Floored at `previousFlatOutputCap`, so the fix only ever raises a cap.
    /// Without the floor, Instant would *fall* to 4096 on the four slugs whose
    /// `minimal` resolves to effort `none`: `none` spends no reasoning tokens at
    /// all, so that reduction would come entirely out of visible answer length —
    /// reintroducing this issue's own symptom on the one mode it wasn't reported
    /// for. The direct `OpenAIClient` keeps the unfloored table because 4096 has
    /// been its shipped Instant budget since #95; here 8192 is the shipped value
    /// and lowering it isn't this fix's job.
    static func requestBody(
        model: String,
        systemPrompt: String,
        input: [[String: Any]],
        thinkingMode: AiThinkingMode,
        sessionIdAtStart: String
    ) -> [String: Any] {
        let effort = OpenAIClient.supportedReasoningEffort(
            model: model, requested: thinkingMode.openAIEffort)
        var body: [String: Any] = [
            "model": model,
            "instructions": systemPrompt,
            "input": input,
            "tools": Self.functionTools,
            "tool_choice": "auto",
            "parallel_tool_calls": true,
            "store": false,
            // Prompt caching (PR A.5): a per-session key so the stable prompt
            // prefix is reused across tool-loop iterations and follow-ups.
            // NOTE: acceptance by the ChatGPT OAuth (Codex) backend is pending
            // live verification; drop from this client only if the backend 400s.
            "prompt_cache_key": "vellum-\(sessionIdAtStart)",
            "stream": true,
            // Cost guard: cap the output, scaled to the thinking mode. Hitting
            // it is surfaced via `response.incomplete` instead of clipping
            // silently.
            "max_output_tokens": max(
                previousFlatOutputCap,
                OpenAIClient.maxOutputTokens(
                    forEffort: effort, reasoning: OpenAIClient.isReasoningModel(model))),
        ]
        if let effort {
            body["reasoning"] = ["effort": effort]
        }
        return body
    }

    /// Builds a Responses request with fresh OAuth credentials and the CLI's
    /// account/session headers. Refreshes the token first if it's near expiry.
    private func makeRequest(url: URL, body: [String: Any]) async throws -> URLRequest {
        let credentials = try await auth.validCredentials()
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(credentials.accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue(credentials.accountId, forHTTPHeaderField: "ChatGPT-Account-ID")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        request.setValue(sessionId, forHTTPHeaderField: "session-id")
        request.setValue("codex_cli_rs", forHTTPHeaderField: "originator")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        return request
    }

    /// Only the network call is wrapped in the retry `catch`; non-retryable HTTP
    /// statuses and cancellation escape immediately instead of being retried.
    private func openStream(_ request: URLRequest) async throws -> URLSession.AsyncBytes {
        var lastError: Error?
        for attempt in 0...1 {
            let bytes: URLSession.AsyncBytes
            let response: URLResponse
            do {
                (bytes, response) = try await URLSession.shared.bytes(for: request)
            } catch is CancellationError {
                throw CancellationError() // user-initiated abort: never retry
            } catch let error as URLError where error.code == .cancelled {
                throw CancellationError() // URLSession task cancelled: never retry
            } catch {
                lastError = error
                if attempt == 1 { throw error }
                continue // transient network failure: retry once
            }

            guard let http = response as? HTTPURLResponse else {
                throw AiClientError.message("ChatGPT returned an invalid HTTP response.")
            }
            if (200..<300).contains(http.statusCode) { return bytes }
            let data = try await Self.drain(bytes)
            let message = Self.providerMessage((try? Self.jsonObject(data)) ?? [:], fallback: String(decoding: data, as: UTF8.self))
            let error = AiClientError.message(message.isEmpty ? "ChatGPT request failed with status \(http.statusCode)." : message)
            if attempt == 0, http.statusCode == 408 || http.statusCode == 429 || http.statusCode >= 500 {
                lastError = error
                continue // transient status: retry once
            }
            throw error // non-retryable status: escapes immediately
        }
        throw lastError ?? AiClientError.message("ChatGPT request failed.")
    }

    private static func drain(_ bytes: URLSession.AsyncBytes) async throws -> Data {
        var data = Data()
        for try await byte in bytes { data.append(byte) }
        return data
    }

    private static func jsonObject(_ data: Data) throws -> [String: Any] {
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw AiClientError.message("ChatGPT returned invalid JSON.")
        }
        return object
    }

    private static func jsonObjectOrNil(_ payload: String) -> [String: Any]? {
        guard let data = payload.data(using: .utf8) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    private static func providerMessage(_ object: [String: Any], fallback: String) -> String {
        ((object["error"] as? [String: Any])?["message"] as? String)
            ?? (object["detail"] as? String)
            ?? fallback
    }

    private static func toolArguments(from value: [String: Any]) -> AiToolArguments {
        AiToolArguments(
            pageNumber: (value["pageNumber"] as? NSNumber)?.doubleValue,
            text: (value["text"] as? String) ?? (value["query"] as? String),
            color: value["color"] as? String,
            x: (value["x"] as? NSNumber)?.doubleValue,
            y: (value["y"] as? NSNumber)?.doubleValue,
            isRegex: value["isRegex"] as? Bool
        )
    }

    private static func finalize(_ text: String, actions: [String]) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { return trimmed }
        return actions.isEmpty ? "I couldn't produce a response." : "Done."
    }

    private static let functionTools: [[String: Any]] = [
        [
            "type": "function", "name": "searchDocument",
            "description": "Search the FULL document text for a query and get back the pages that match, each with surrounding context. Use this to find where something is discussed before reading a page. Default is a case-insensitive literal substring match; set isRegex true to match a regular expression.",
            "parameters": [
                "type": "object",
                "properties": [
                    "query": ["type": "string", "description": "Text (or regular expression) to search for across every page."],
                    "isRegex": ["type": "boolean", "description": "Treat query as a regular expression instead of a literal substring. Optional; defaults to false."],
                ],
                "required": ["query"], "additionalProperties": false,
            ],
        ],
        [
            "type": "function", "name": "getPageText",
            "description": "Read the full extracted text of a single page by its 1-indexed number. Use it after searchDocument, or when the user names a specific page whose text you don't already have.",
            "parameters": [
                "type": "object",
                "properties": ["pageNumber": ["type": "number", "description": "1-indexed page number to read. Out-of-range values are clamped."]],
                "required": ["pageNumber"], "additionalProperties": false,
            ],
        ],
        [
            "type": "function", "name": "getAnnotations",
            "description": "List the user's annotations (notes and highlights) across the WHOLE document, or for a single page when pageNumber is given. The context you receive only includes the current page's annotations — call this when the user asks about their notes or highlights elsewhere.",
            "parameters": [
                "type": "object",
                "properties": ["pageNumber": ["type": "number", "description": "Optional 1-indexed page to filter by. Omit to list every page's annotations."]],
                "additionalProperties": false,
            ],
        ],
        [
            "type": "function", "name": "goToPage",
            "description": "Navigate the document viewport to a specific 1-indexed page.",
            "parameters": [
                "type": "object",
                "properties": ["pageNumber": ["type": "number", "description": "1-indexed page number to navigate to. Out-of-range values are clamped."]],
                "required": ["pageNumber"], "additionalProperties": false,
            ],
        ],
        [
            "type": "function", "name": "addNote",
            "description": "Create a sticky-note annotation with visible text on a page.",
            "parameters": [
                "type": "object",
                "properties": [
                    "pageNumber": ["type": "number", "description": "1-indexed page number for the note."],
                    "text": ["type": "string", "description": "Note body. Must be non-empty."],
                    "x": ["type": "number", "description": "Optional top-left x in PDF points (default 72)."],
                    "y": ["type": "number", "description": "Optional top-left y in PDF points (default 96)."],
                ],
                "required": ["pageNumber", "text"], "additionalProperties": false,
            ],
        ],
        [
            "type": "function", "name": "addHighlight",
            "description": "Highlight an exact phrase on a page. Provide the verbatim text; the app locates and draws it.",
            "parameters": [
                "type": "object",
                "properties": [
                    "pageNumber": ["type": "number", "description": "1-indexed page number for the highlight."],
                    "text": ["type": "string", "description": "Exact phrase to highlight, quoted verbatim from the page text. The app locates it; do not supply coordinates."],
                    "color": ["type": "string", "description": "Optional CSS color (e.g. #fef08a). Invalid values fall back to yellow."],
                ],
                "required": ["pageNumber", "text"], "additionalProperties": false,
            ],
        ],
    ]
}
