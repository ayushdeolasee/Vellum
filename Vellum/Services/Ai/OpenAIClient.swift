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
                // Cost guard: cap the visible output.
                "max_output_tokens": 2048,
            ]
            // Cost guard: minimal reasoning on the gpt-5 family (others reject
            // the reasoning field, so only send it when it applies).
            if model.lowercased().hasPrefix("gpt-5") {
                body["reasoning"] = ["effort": "minimal"]
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
                case "response.failed", "error":
                    let message = ((object["response"] as? [String: Any])?["error"] as? [String: Any])?["message"] as? String
                        ?? (object["message"] as? String)
                    throw AiClientError.message(message ?? "OpenAI streaming failed.")
                default:
                    break
                }
            }

            if calls.isEmpty {
                return AiProviderResult(reply: Self.finalize(text, actions: actionResults), actionResults: actionResults)
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

    private func openStream(_ request: URLRequest) async throws -> URLSession.AsyncBytes {
        var lastError: Error?
        for attempt in 0...1 {
            do {
                let (bytes, response) = try await URLSession.shared.bytes(for: request)
                guard let http = response as? HTTPURLResponse else {
                    throw AiClientError.message("OpenAI returned an invalid HTTP response.")
                }
                if (200..<300).contains(http.statusCode) { return bytes }
                let data = try await Self.drain(bytes)
                let message = Self.providerMessage((try? Self.jsonObject(data)) ?? [:], fallback: String(decoding: data, as: UTF8.self))
                let error = AiClientError.message(message.isEmpty ? "OpenAI request failed with status \(http.statusCode)." : message)
                if attempt == 0, http.statusCode == 408 || http.statusCode == 429 || http.statusCode >= 500 {
                    lastError = error
                    continue
                }
                throw error
            } catch {
                lastError = error
                if attempt == 1 { throw error }
            }
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
