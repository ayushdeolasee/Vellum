import Foundation

/// OpenRouter chat client. Uses the OpenAI-compatible **Chat Completions** API
/// (not the Responses API `OpenAIClient` targets). Image and tool support are
/// gated by the caller: `image` is passed nil for non-vision models and
/// `allowTools` is false for models that don't support function calling.
@MainActor
final class OpenRouterClient {
    func generate(
        apiKey: String,
        model: String,
        systemPrompt: String,
        userPrompt: String,
        image: AiPageImageSnapshot?,
        allowTools: Bool,
        sessionIdAtStart: String,
        toolEngine: AiToolEngine
    ) async throws -> AiProviderResult {
        guard let url = URL(string: "https://openrouter.ai/api/v1/chat/completions") else {
            throw AiClientError.message("Invalid OpenRouter endpoint.")
        }

        var userContent: [[String: Any]] = [["type": "text", "text": userPrompt]]
        if let image, !image.base64Data.isEmpty {
            userContent.append([
                "type": "image_url",
                "image_url": ["url": "data:\(image.mediaType);base64,\(image.base64Data)"],
            ])
        }
        var messages: [[String: Any]] = [
            ["role": "system", "content": systemPrompt],
            ["role": "user", "content": userContent],
        ]
        var actionResults: [String] = []

        for _ in 0..<6 {
            var body: [String: Any] = [
                "model": model,
                "messages": messages,
            ]
            if allowTools {
                body["tools"] = Self.functionTools
            }
            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.setValue("Vellum", forHTTPHeaderField: "X-Title")
            request.setValue("https://vellum.app", forHTTPHeaderField: "HTTP-Referer")
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
            let data = try await sendWithRetry(request)
            let root = try Self.jsonObject(data)
            guard let choices = root["choices"] as? [[String: Any]],
                  let message = choices.first?["message"] as? [String: Any] else {
                throw AiClientError.message(Self.providerMessage(root, fallback: "OpenRouter returned an invalid response."))
            }
            let text = message["content"] as? String ?? ""
            let toolCalls = message["tool_calls"] as? [[String: Any]] ?? []
            if toolCalls.isEmpty {
                return AiProviderResult(reply: Self.finalize(text, actions: actionResults), actionResults: actionResults)
            }

            // Echo the assistant turn (with its tool_calls) before the results.
            var assistantMessage: [String: Any] = ["role": "assistant", "tool_calls": toolCalls]
            assistantMessage["content"] = text.isEmpty ? NSNull() : text
            messages.append(assistantMessage)

            for call in toolCalls {
                guard let callId = call["id"] as? String,
                      let function = call["function"] as? [String: Any],
                      let name = function["name"] as? String else { continue }
                let argumentsText = function["arguments"] as? String ?? "{}"
                let values = (try? JSONSerialization.jsonObject(with: Data(argumentsText.utf8))) as? [String: Any] ?? [:]
                let action = AiToolAction(tool: name, args: Self.toolArguments(from: values))
                let result = await toolEngine.run(
                    action,
                    sessionIdAtStart: sessionIdAtStart,
                    actionCount: actionResults.count
                )
                actionResults.append(result)
                messages.append([
                    "role": "tool",
                    "tool_call_id": callId,
                    "content": result,
                ])
            }
        }
        return AiProviderResult(reply: Self.finalize("", actions: actionResults), actionResults: actionResults)
    }

    private func sendWithRetry(_ request: URLRequest) async throws -> Data {
        var lastError: Error?
        for attempt in 0...1 {
            do {
                let (data, response) = try await URLSession.shared.data(for: request)
                guard let http = response as? HTTPURLResponse else {
                    throw AiClientError.message("OpenRouter returned an invalid HTTP response.")
                }
                if (200..<300).contains(http.statusCode) { return data }
                let message = Self.providerMessage((try? Self.jsonObject(data)) ?? [:], fallback: String(decoding: data, as: UTF8.self))
                let error = AiClientError.message(message.isEmpty ? "OpenRouter request failed with status \(http.statusCode)." : message)
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
        throw lastError ?? AiClientError.message("OpenRouter request failed.")
    }

    private static func jsonObject(_ data: Data) throws -> [String: Any] {
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw AiClientError.message("OpenRouter returned invalid JSON.")
        }
        return object
    }

    private static func providerMessage(_ object: [String: Any], fallback: String) -> String {
        ((object["error"] as? [String: Any])?["message"] as? String) ?? fallback
    }

    private static func toolArguments(from value: [String: Any]) -> AiToolArguments {
        AiToolArguments(
            pageNumber: (value["pageNumber"] as? NSNumber)?.doubleValue,
            text: value["text"] as? String,
            color: value["color"] as? String,
            x: (value["x"] as? NSNumber)?.doubleValue,
            y: (value["y"] as? NSNumber)?.doubleValue
        )
    }

    private static func finalize(_ text: String, actions: [String]) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { return trimmed }
        return actions.isEmpty ? "I couldn't produce a response." : "Done."
    }

    /// Chat Completions tool schema (function wrapped), mirroring the three
    /// tools defined for the other providers.
    private static let functionTools: [[String: Any]] = [
        [
            "type": "function",
            "function": [
                "name": "goToPage",
                "description": "Navigate the document viewport to a specific 1-indexed page.",
                "parameters": [
                    "type": "object",
                    "properties": ["pageNumber": ["type": "number", "description": "1-indexed page number to navigate to. Out-of-range values are clamped."]],
                    "required": ["pageNumber"], "additionalProperties": false,
                ],
            ],
        ],
        [
            "type": "function",
            "function": [
                "name": "addNote",
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
        ],
        [
            "type": "function",
            "function": [
                "name": "addHighlight",
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
        ],
    ]
}
