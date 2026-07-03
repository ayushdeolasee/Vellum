import Foundation

struct AiProviderResult: Sendable {
    var reply: String
    var actionResults: [String]
}

@MainActor
final class GeminiClient {
    func generate(
        apiKey: String,
        model: String,
        systemPrompt: String,
        userPrompt: String,
        image: AiPageImageSnapshot?,
        sessionIdAtStart: String,
        toolEngine: AiToolEngine
    ) async throws -> AiProviderResult {
        let encodedModel = model.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? model
        guard let url = URL(string: "https://generativelanguage.googleapis.com/v1beta/models/\(encodedModel):generateContent") else {
            throw AiClientError.message("Invalid Gemini model name.")
        }

        var userParts: [[String: Any]] = [["text": userPrompt]]
        if let image, !image.base64Data.isEmpty {
            userParts.append(["inline_data": ["mime_type": image.mediaType, "data": image.base64Data]])
        }
        var contents: [[String: Any]] = [["role": "user", "parts": userParts]]
        var actionResults: [String] = []

        for _ in 0..<6 {
            let body: [String: Any] = [
                "system_instruction": ["parts": [["text": systemPrompt]]],
                "contents": contents,
                "tools": [["function_declarations": Self.functionDeclarations]],
                "generation_config": ["temperature": 0.2],
            ]
            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.setValue(apiKey, forHTTPHeaderField: "x-goog-api-key")
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
            let response = try await sendWithRetry(request)
            let root = try Self.jsonObject(response)
            guard let candidates = root["candidates"] as? [[String: Any]],
                  let candidate = candidates.first else {
                throw AiClientError.message(Self.providerMessage(root, fallback: "Gemini returned an invalid response."))
            }
            // Safety-blocked / MAX_TOKENS candidates omit content.parts; the
            // original AI SDK tolerates that and yields empty text.
            let parts = ((candidate["content"] as? [String: Any])?["parts"] as? [[String: Any]]) ?? []

            let text = parts.compactMap { $0["text"] as? String }.joined()
            let calls = parts.compactMap { $0["functionCall"] as? [String: Any] }
            if calls.isEmpty {
                return AiProviderResult(reply: Self.finalize(text, actions: actionResults), actionResults: actionResults)
            }

            contents.append(["role": "model", "parts": parts])
            var responseParts: [[String: Any]] = []
            for call in calls {
                guard let name = call["name"] as? String else { continue }
                let arguments = Self.toolArguments(from: call["args"] as? [String: Any] ?? [:])
                let action = AiToolAction(tool: name, args: arguments)
                let result = await toolEngine.run(
                    action,
                    sessionIdAtStart: sessionIdAtStart,
                    actionCount: actionResults.count
                )
                actionResults.append(result)
                responseParts.append(["functionResponse": ["name": name, "response": ["result": result]]])
            }
            contents.append(["role": "user", "parts": responseParts])
        }
        return AiProviderResult(reply: Self.finalize("", actions: actionResults), actionResults: actionResults)
    }

    private func sendWithRetry(_ request: URLRequest) async throws -> Data {
        var lastError: Error?
        for attempt in 0...1 {
            do {
                let (data, response) = try await URLSession.shared.data(for: request)
                guard let http = response as? HTTPURLResponse else {
                    throw AiClientError.message("Gemini returned an invalid HTTP response.")
                }
                if (200..<300).contains(http.statusCode) { return data }
                let message = Self.providerMessage((try? Self.jsonObject(data)) ?? [:], fallback: String(decoding: data, as: UTF8.self))
                let error = AiClientError.message(message.isEmpty ? "Gemini request failed with status \(http.statusCode)." : message)
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
        throw lastError ?? AiClientError.message("Gemini request failed.")
    }

    private static func jsonObject(_ data: Data) throws -> [String: Any] {
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw AiClientError.message("Gemini returned invalid JSON.")
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

    private static let functionDeclarations: [[String: Any]] = [
        [
            "name": "goToPage",
            "description": "Navigate the document viewport to a specific 1-indexed page.",
            "parameters": [
                "type": "object",
                "properties": ["pageNumber": ["type": "number", "description": "1-indexed page number to navigate to. Out-of-range values are clamped."]],
                "required": ["pageNumber"],
            ],
        ],
        [
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
                "required": ["pageNumber", "text"],
            ],
        ],
        [
            "name": "addHighlight",
            "description": "Highlight an exact phrase on a page. Provide the verbatim text; the app locates and draws it.",
            "parameters": [
                "type": "object",
                "properties": [
                    "pageNumber": ["type": "number", "description": "1-indexed page number for the highlight."],
                    "text": ["type": "string", "description": "Exact phrase to highlight, quoted verbatim from the page text. The app locates it; do not supply coordinates."],
                    "color": ["type": "string", "description": "Optional CSS color (e.g. #fef08a). Invalid values fall back to yellow."],
                ],
                "required": ["pageNumber", "text"],
            ],
        ],
    ]
}

enum AiClientError: LocalizedError {
    case message(String)

    var errorDescription: String? {
        if case .message(let message) = self { return message }
        return nil
    }
}
