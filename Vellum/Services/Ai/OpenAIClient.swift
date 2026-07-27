import Foundation

@MainActor
final class OpenAIClient {
    /// Streams a reply from the Responses API (`stream: true`). Text deltas are
    /// forwarded live; function-call items run the tool loop between turns.
    func generate(
        apiKey: String,
        model: String,
        systemPrompt: String,
        prompt: AiUserPrompt,
        images: [AiPageImageSnapshot],
        thinkingMode: AiThinkingMode,
        sessionIdAtStart: String,
        toolEngine: AiToolEngine,
        onEvent: @escaping @MainActor (AiStreamEvent) -> Void
    ) async throws -> AiProviderResult {
        guard let url = URL(string: "https://api.openai.com/v1/responses") else {
            throw AiClientError.message("Invalid OpenAI endpoint.")
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

        // Cost guard: reasoning effort applies to the gpt-5 family only (others
        // reject the reasoning field). Computed up front so the output-token
        // budget can scale with it. `reasoningEffort` is the value actually sent,
        // nil = omit the field — which is what `.auto` now means. It used to be
        // rewritten to "minimal", so "Auto" wasn't "let the server decide" at
        // all; on gpt-5.5, which rejects "minimal", that made the model unusable
        // at the default setting (#94).
        let reasoningEffort = Self.supportedReasoningEffort(
            model: model, requested: thinkingMode.openAIEffort)

        for _ in 0..<8 {
            var body: [String: Any] = [
                "model": model,
                "instructions": systemPrompt,
                "input": input,
                "tools": Self.functionTools,
                "store": false,
                // Prompt caching (PR A.5): a per-session key so the stable prompt
                // prefix is reused across tool-loop iterations and follow-ups.
                "prompt_cache_key": "vellum-\(sessionIdAtStart)",
                "stream": true,
                // Cost guard: cap the visible output, scaled to the thinking mode.
                "max_output_tokens": Self.maxOutputTokens(
                    forEffort: reasoningEffort, reasoning: Self.isReasoningModel(model)),
            ]
            if let reasoningEffort {
                body["reasoning"] = ["effort": reasoningEffort]
            }
            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
            request.httpBody = try JSONSerialization.data(withJSONObject: body)

            let bytes = try await openStream(request)

            var text = ""
            var calls: [[String: Any]] = []
            var hitTokenLimit = false
            for try await payload in SSE.dataPayloads(bytes) {
                guard let object = Self.jsonObjectOrNil(payload),
                      let type = object["type"] as? String else { continue }
                switch type {
                case "response.output_text.delta":
                    if let delta = object["delta"] as? String, !delta.isEmpty {
                        text += delta
                        onEvent(.textDelta(delta))
                    }
                case "response.output_item.done":
                    if let item = object["item"] as? [String: Any],
                       item["type"] as? String == "function_call" {
                        calls.append(item)
                    }
                // Terminal event when the response was cut off. There were two
                // identical `case "response.incomplete"` arms here, so the second
                // was dead — which is why `incompleteMessage(reason:)` could
                // never actually reach a user despite being covered by a test,
                // and why a cutoff for any reason other than the token limit
                // finalized silently as if the reply had completed normally.
                //
                // Merged into one arm that keeps the better behaviour for each
                // case: a token-limit cutoff returns the partial text with a
                // truncation note (throwing away a long, nearly-complete answer
                // is worse than flagging it), while anything else — a content
                // filter, say — surfaces the reason.
                case "response.incomplete":
                    let reason = ((object["response"] as? [String: Any])?["incomplete_details"] as? [String: Any])?["reason"] as? String
                    if reason == "max_output_tokens" {
                        hitTokenLimit = true
                    } else {
                        throw AiClientError.message(Self.incompleteMessage(reason: reason ?? "unknown"))
                    }
                case "response.failed", "error":
                    let message = ((object["response"] as? [String: Any])?["error"] as? [String: Any])?["message"] as? String
                        ?? (object["message"] as? String)
                    throw AiClientError.message(message ?? "OpenAI streaming failed.")
                default:
                    break
                }
            }

            if calls.isEmpty {
                var reply = text
                if hitTokenLimit {
                    guard !reply.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                        throw AiClientError.message("OpenAI hit the output-token limit before producing any text. Try a lower thinking mode.")
                    }
                    reply += "\n\n_(reply truncated at the output-token limit)_"
                }
                return AiProviderResult(reply: Self.finalize(reply, actions: actionResults), actionResults: actionResults)
            }

            for call in calls {
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
            onEvent(.status("Thinking"))
        }
        return AiProviderResult(reply: Self.finalize("", actions: actionResults), actionResults: actionResults)
    }

    /// Whether `model` takes a `reasoning` field at all. Everything else rejects
    /// it outright, so the field is omitted for them.
    static func isReasoningModel(_ model: String) -> Bool {
        model.lowercased().hasPrefix("gpt-5")
    }

    /// Efforts ordered weakest to strongest. Used to fall back to the nearest
    /// value a model actually accepts when the user's choice isn't in its set.
    private static let effortLadder = ["none", "minimal", "low", "medium", "high", "xhigh"]

    /// The reasoning `effort` values `model` accepts.
    ///
    /// Deliberately shaped as "what this family supports" rather than the old
    /// "which families are special". That inversion is the actual fix for #94:
    /// the previous form ended with `return requested`, so every model it had
    /// never heard of landed in the *permissive* branch. `gpt-5.5` shipped, it
    /// didn't match the `gpt-5.1` check, and it was handed "minimal" — a value
    /// it rejects — which 400'd every request before streaming. Now an
    /// unrecognized model returns an empty set and we send nothing, so a new
    /// release degrades to the API's own default instead of breaking.
    static func supportedEfforts(model: String) -> Set<String> {
        let lowered = model.lowercased()
        guard isReasoningModel(lowered) else { return [] }
        // The -pro variants accept only "high".
        if lowered.contains("gpt-5-pro") || lowered.contains("gpt-5.1-pro") { return ["high"] }
        // gpt-5.5 dropped "minimal" and added "none" and "xhigh". Taken verbatim
        // from the API's own rejection: "Supported values are: 'none', 'low',
        // 'medium', 'high', and 'xhigh'."
        if lowered.contains("gpt-5.5") { return ["none", "low", "medium", "high", "xhigh"] }
        // gpt-5.1 rejects "minimal".
        if lowered.contains("gpt-5.1") { return ["low", "medium", "high"] }
        // Classic gpt-5 / gpt-5-mini / gpt-5-nano accept every effort incl. minimal.
        if lowered.hasPrefix("gpt-5-") || lowered == "gpt-5" { return ["minimal", "low", "medium", "high"] }
        // A gpt-5.x we don't know yet: omit rather than guess.
        return []
    }

    /// The reasoning `effort` to send for `model`, or nil to omit the field.
    ///
    /// `requested == nil` is the Auto mode: no explicit preference, so the field
    /// is omitted and the API applies its own default. When the user *has*
    /// chosen a mode that this model doesn't offer, fall back to the nearest
    /// rung on `effortLadder` rather than dropping the choice — ties resolve
    /// downward, so "Instant" on a model without "minimal" becomes "none" where
    /// that exists and "low" otherwise, which is the direction the user asked
    /// for.
    static func supportedReasoningEffort(model: String, requested: String?) -> String? {
        guard let requested else { return nil }
        let supported = supportedEfforts(model: model)
        guard !supported.isEmpty else { return nil }
        if supported.contains(requested) { return requested }
        guard let target = effortLadder.firstIndex(of: requested) else { return nil }
        return effortLadder.enumerated()
            .filter { supported.contains($0.element) }
            .min { abs($0.offset - target) < abs($1.offset - target) }?
            .element
    }

    /// Output budget scaled to the user's thinking mode: reasoning models burn
    /// output tokens on thinking, so a flat cap starves high-effort answers.
    ///
    /// `effort == nil` on a reasoning model means Auto — the server picks its
    /// own effort, which on current models is well above "minimal", so the
    /// budget has to assume mid-range work. Giving Auto the old 4096 would just
    /// trade the #94 error for a truncated answer. Non-reasoning models keep the
    /// flat 4096: they spend no tokens thinking, so the cap is purely about
    /// answer length.
    static func maxOutputTokens(forEffort effort: String?, reasoning: Bool) -> Int {
        guard reasoning else { return 4096 }
        switch effort {
        case "none", "minimal": return 4096
        case "low": return 8192
        case "high": return 32768
        case "xhigh": return 65536
        default: return 16384   // "medium", plus Auto and anything unrecognized
        }
    }

    /// User-facing note when the Responses API reports an incomplete response.
    static func incompleteMessage(reason: String) -> String {
        if reason == "max_output_tokens" {
            return "The response hit the output token limit before finishing. Try a higher thinking mode or a more specific request."
        }
        return "The response ended early (reason: \(reason))."
    }

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
                throw AiClientError.message("OpenAI returned an invalid HTTP response.")
            }
            if (200..<300).contains(http.statusCode) { return bytes }
            let data = try await Self.drain(bytes)
            let message = Self.providerMessage((try? Self.jsonObject(data)) ?? [:], fallback: String(decoding: data, as: UTF8.self))
            let error = AiClientError.message(message.isEmpty ? "OpenAI request failed with status \(http.statusCode)." : message)
            if attempt == 0, http.statusCode == 408 || http.statusCode == 429 || http.statusCode >= 500 {
                lastError = error
                continue // transient status: retry once
            }
            throw error // non-retryable status: escapes immediately
        }
        throw lastError ?? AiClientError.message("OpenAI request failed.")
    }

    private static func drain(_ bytes: URLSession.AsyncBytes) async throws -> Data {
        var data = Data()
        for try await byte in bytes { data.append(byte) }
        return data
    }

    private static func jsonObject(_ data: Data) throws -> [String: Any] {
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw AiClientError.message("OpenAI returned invalid JSON.")
        }
        return object
    }

    private static func jsonObjectOrNil(_ payload: String) -> [String: Any]? {
        guard let data = payload.data(using: .utf8) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    private static func providerMessage(_ object: [String: Any], fallback: String) -> String {
        ((object["error"] as? [String: Any])?["message"] as? String) ?? fallback
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
