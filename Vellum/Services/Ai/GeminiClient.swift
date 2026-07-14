import Foundation

struct AiProviderResult: Sendable {
    var reply: String
    var actionResults: [String]
}

@MainActor
final class GeminiClient {
    /// Streams a reply over `:streamGenerateContent?alt=sse`. Text deltas are
    /// forwarded as they arrive; function calls run the tool loop between turns
    /// (up to 8 iterations, matching the buffered original). `onEvent` is invoked
    /// on the main actor for every delta / status / tool event.
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
        let encodedModel = model.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? model
        guard let url = URL(string: "https://generativelanguage.googleapis.com/v1beta/models/\(encodedModel):streamGenerateContent?alt=sse") else {
            throw AiClientError.message("Invalid Gemini model name.")
        }

        // Implicit caching (no cache_control breakpoints): send the fused prompt.
        var userParts: [[String: Any]] = [["text": prompt.joined]]
        for image in images where !image.base64Data.isEmpty {
            userParts.append(["inline_data": ["mime_type": image.mediaType, "data": image.base64Data]])
        }
        var contents: [[String: Any]] = [["role": "user", "parts": userParts]]
        var actionResults: [String] = []

        onEvent(.status("Thinking"))

        // Cost guard: cap output and map the user's thinking mode to a
        // thinkingBudget. Newer families ignore an unknown thinkingConfig.
        var generationConfig: [String: Any] = ["temperature": 0.2, "maxOutputTokens": 2048]
        if thinkingMode == .auto {
            // `.auto` preserves the prior default byte-for-byte: for the 2.5
            // flash family disable extended thinking (0 budget); everything else
            // omits thinkingConfig. 2.5 Pro rejects thinkingBudget 0 (its minimum
            // is 128); only 2.5 Flash/Flash-Lite accept 0, so exclude Pro.
            if model.contains("2.5") && !model.lowercased().contains("pro") {
                generationConfig["thinkingConfig"] = ["thinkingBudget": 0]
            }
        } else if let config = Self.thinkingConfig(for: thinkingMode, model: model) {
            generationConfig["thinkingConfig"] = config
        }

        for _ in 0..<8 {
            let body: [String: Any] = [
                "system_instruction": ["parts": [["text": systemPrompt]]],
                "contents": contents,
                "tools": [["function_declarations": Self.functionDeclarations]],
                "generation_config": generationConfig,
            ]
            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.setValue(apiKey, forHTTPHeaderField: "x-goog-api-key")
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
            request.httpBody = try JSONSerialization.data(withJSONObject: body)

            let bytes = try await openStream(request)

            var text = ""
            var calls: [[String: Any]] = []
            var replayParts: [[String: Any]] = []
            for try await payload in SSE.dataPayloads(bytes) {
                guard let object = Self.jsonObjectOrNil(payload),
                      let candidates = object["candidates"] as? [[String: Any]],
                      let candidate = candidates.first,
                      let parts = (candidate["content"] as? [String: Any])?["parts"] as? [[String: Any]]
                else { continue }
                for part in parts {
                    Self.accumulateReplayPart(part, into: &replayParts)
                    if let chunk = part["text"] as? String, !chunk.isEmpty,
                       (part["thought"] as? Bool) != true {
                        text += chunk
                        onEvent(.textDelta(chunk))
                    }
                    if let call = part["functionCall"] as? [String: Any] {
                        calls.append(call)
                    }
                }
            }

            if calls.isEmpty {
                return AiProviderResult(reply: Self.finalize(text, actions: actionResults), actionResults: actionResults)
            }

            contents.append(["role": "model", "parts": replayParts])

            var responseParts: [[String: Any]] = []
            for call in calls {
                guard let name = call["name"] as? String else { continue }
                let arguments = Self.toolArguments(from: call["args"] as? [String: Any] ?? [:])
                let action = AiToolAction(tool: name, args: arguments)
                onEvent(.toolStarted(summary: Self.toolSummary(action)))
                let result = await toolEngine.run(
                    action,
                    sessionIdAtStart: sessionIdAtStart,
                    actionCount: actionResults.count
                )
                actionResults.append(result)
                onEvent(.toolFinished(result: result))
                responseParts.append(["functionResponse": ["name": name, "response": ["result": result]]])
            }
            contents.append(["role": "user", "parts": responseParts])
            onEvent(.status("Thinking"))
        }
        return AiProviderResult(reply: Self.finalize("", actions: actionResults), actionResults: actionResults)
    }

    /// Accumulates a streamed model part for verbatim replay in the next tool
    /// turn. Plain unsigned visible text merges into a preceding part of the
    /// same kind; functionCall parts, thoughtSignature-carrying parts, and
    /// thought parts are kept as-is — Gemini 3 rejects tool turns whose signed
    /// parts were merged or dropped.
    static func accumulateReplayPart(_ part: [String: Any], into parts: inout [[String: Any]]) {
        func isPlainUnsignedText(_ candidate: [String: Any]) -> Bool {
            candidate["functionCall"] == nil
                && candidate["thoughtSignature"] == nil
                && (candidate["thought"] as? Bool) != true
                && candidate["text"] is String
        }
        if isPlainUnsignedText(part),
           let lastIndex = parts.indices.last,
           isPlainUnsignedText(parts[lastIndex]),
           let previous = parts[lastIndex]["text"] as? String,
           let chunk = part["text"] as? String {
            parts[lastIndex]["text"] = previous + chunk
            return
        }
        parts.append(part)
    }

    /// Open the SSE stream, retrying once on transient failures before any bytes
    /// are consumed. Reads the (small) error body to surface a real message.
    private func openStream(_ request: URLRequest) async throws -> URLSession.AsyncBytes {
        var lastError: Error?
        for attempt in 0...1 {
            do {
                let (bytes, response) = try await URLSession.shared.bytes(for: request)
                guard let http = response as? HTTPURLResponse else {
                    throw AiClientError.message("Gemini returned an invalid HTTP response.")
                }
                if (200..<300).contains(http.statusCode) { return bytes }
                let data = try await Self.drain(bytes)
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

    private static func drain(_ bytes: URLSession.AsyncBytes) async throws -> Data {
        var data = Data()
        for try await byte in bytes { data.append(byte) }
        return data
    }

    private static func jsonObject(_ data: Data) throws -> [String: Any] {
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw AiClientError.message("Gemini returned invalid JSON.")
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

    /// thinkingConfig payload for the given effort, or nil to omit it.
    /// Gemini 3 families take a discrete thinkingLevel — numeric budgets are a
    /// request error there. 2.x keeps numeric budgets (Pro floors at 128, its
    /// minimum — 2.5 Pro cannot disable thinking; -1 means dynamic, the model
    /// decides). 1.5 and unknown families send nothing. `.auto` is the
    /// caller's branch and must never be routed here.
    static func thinkingConfig(for mode: AiThinkingMode, model: String) -> [String: Any]? {
        guard mode != .auto else { return nil }
        let lowered = model.lowercased()
        if lowered.contains("1.5") { return nil }
        if lowered.contains("gemini-3") {
            // gemini-3-pro (not 3.1) supports only low/high; round toward them.
            let onlyLowHigh = lowered.contains("gemini-3-pro")
            switch mode {
            case .instant: return ["thinkingLevel": onlyLowHigh ? "low" : "minimal"]
            case .low:     return ["thinkingLevel": "low"]
            case .medium:  return ["thinkingLevel": onlyLowHigh ? "high" : "medium"]
            case .high:    return ["thinkingLevel": "high"]
            case .auto:    return nil
            }
        }
        guard lowered.contains("2.5") || lowered.contains("2.0") else { return nil }
        let isPro = lowered.contains("pro")
        switch mode {
        case .instant: return ["thinkingBudget": isPro ? 128 : 0]
        case .low:     return ["thinkingBudget": isPro ? 128 : 512]
        case .medium:  return ["thinkingBudget": -1]  // dynamic: model decides
        case .high:    return ["thinkingBudget": 24576]
        case .auto:    return nil
        }
    }

    /// Human-readable label for the activity indicator while a tool runs.
    static func toolSummary(_ action: AiToolAction) -> String {
        switch action.tool {
        case "goToPage":
            if let page = action.args.pageNumber { return "Navigating to page \(Int(page.rounded()))" }
            return "Navigating"
        case "addNote": return "Adding a note"
        case "addHighlight": return "Adding a highlight"
        case "searchDocument":
            if let query = action.args.text, !query.isEmpty { return "Searching for \"\(query)\"" }
            return "Searching the document"
        case "getPageText":
            if let page = action.args.pageNumber { return "Reading page \(Int(page.rounded()))" }
            return "Reading a page"
        default: return "Working"
        }
    }

    private static func finalize(_ text: String, actions: [String]) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { return trimmed }
        return actions.isEmpty ? "I couldn't produce a response." : "Done."
    }

    private static let functionDeclarations: [[String: Any]] = [
        [
            "name": "searchDocument",
            "description": "Search the FULL document text for a query and get back the pages that match, each with surrounding context. Use this to find where something is discussed before reading a page. Default is a case-insensitive literal substring match; set isRegex true to match a regular expression.",
            "parameters": [
                "type": "object",
                "properties": [
                    "query": ["type": "string", "description": "Text (or regular expression) to search for across every page."],
                    "isRegex": ["type": "boolean", "description": "Treat query as a regular expression instead of a literal substring. Optional; defaults to false."],
                ],
                "required": ["query"],
            ],
        ],
        [
            "name": "getPageText",
            "description": "Read the full extracted text of a single page by its 1-indexed number. Use it after searchDocument, or when the user names a specific page whose text you don't already have.",
            "parameters": [
                "type": "object",
                "properties": ["pageNumber": ["type": "number", "description": "1-indexed page number to read. Out-of-range values are clamped."]],
                "required": ["pageNumber"],
            ],
        ],
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
