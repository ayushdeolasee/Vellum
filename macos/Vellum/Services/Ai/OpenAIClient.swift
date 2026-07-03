import Foundation

@MainActor
final class OpenAIClient {
    func generate(
        apiKey: String,
        model: String,
        systemPrompt: String,
        userPrompt: String,
        image: AiPageImageSnapshot?,
        sessionIdAtStart: String,
        toolEngine: AiToolEngine
    ) async throws -> AiProviderResult {
        guard let url = URL(string: "https://api.openai.com/v1/responses") else {
            throw AiClientError.message("Invalid OpenAI endpoint.")
        }
        var content: [[String: Any]] = [["type": "input_text", "text": userPrompt]]
        if let image, !image.base64Data.isEmpty {
            content.append([
                "type": "input_image",
                "image_url": "data:\(image.mediaType);base64,\(image.base64Data)",
            ])
        }
        var input: [[String: Any]] = [["role": "user", "content": content]]
        var actionResults: [String] = []

        for _ in 0..<6 {
            let body: [String: Any] = [
                "model": model,
                "instructions": systemPrompt,
                "input": input,
                "tools": Self.functionTools,
                "store": false,
            ]
            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
            let data = try await sendWithRetry(request)
            let root = try Self.jsonObject(data)
            guard let output = root["output"] as? [[String: Any]] else {
                throw AiClientError.message(Self.providerMessage(root, fallback: "OpenAI returned an invalid response."))
            }
            let text = Self.outputText(from: output)
            let calls = output.filter { $0["type"] as? String == "function_call" }
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
                let result = await toolEngine.run(
                    action,
                    sessionIdAtStart: sessionIdAtStart,
                    actionCount: actionResults.count
                )
                actionResults.append(result)
                input.append(["type": "function_call_output", "call_id": callId, "output": result])
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
                    throw AiClientError.message("OpenAI returned an invalid HTTP response.")
                }
                if (200..<300).contains(http.statusCode) { return data }
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

    private static func jsonObject(_ data: Data) throws -> [String: Any] {
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw AiClientError.message("OpenAI returned invalid JSON.")
        }
        return object
    }

    private static func providerMessage(_ object: [String: Any], fallback: String) -> String {
        ((object["error"] as? [String: Any])?["message"] as? String) ?? fallback
    }

    private static func outputText(from output: [[String: Any]]) -> String {
        output.compactMap { item -> String? in
            guard item["type"] as? String == "message",
                  let content = item["content"] as? [[String: Any]] else { return nil }
            return content.compactMap { part in
                guard part["type"] as? String == "output_text" else { return nil }
                return part["text"] as? String
            }.joined()
        }.joined()
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

    private static let functionTools: [[String: Any]] = [
        [
            "type": "function", "name": "goToPage",
            "description": "Navigate the document viewport to a specific 1-indexed page.",
            "parameters": [
                "type": "object",
                "properties": ["pageNumber": ["type": "number", "description": "1-indexed page number to navigate to. Out-of-range values are clamped."]],
                "required": ["pageNumber"], "additionalProperties": false,
            ],
            "strict": true,
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
            "strict": true,
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
            "strict": true,
        ],
    ]
}
