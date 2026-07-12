import Foundation

/// OpenCode chat client, shared by the two OpenCode gateways:
///
/// - **Zen** (https://opencode.ai/zen) — curated multi-model gateway of both
///   proprietary flagships and open-weight/free models.
/// - **Go** (https://opencode.ai/go) — low-cost subscription of open coding
///   models (GLM, Kimi, Qwen, DeepSeek, MiniMax, MiMo, …).
///
/// Each is authenticated with its own pasted API key (`sk-…` from
/// opencode.ai/auth — the two keys are distinct) and exposes an
/// OpenAI-compatible `/chat/completions` endpoint that the gateway translates to
/// each model's native backend, so this mirrors `OpenRouterClient`.
@MainActor
final class OpenCodeClient {
    /// Which OpenCode gateway to talk to. Selects the endpoint and the name used
    /// in surfaced error messages; the wire protocol is identical.
    enum Gateway {
        case zen
        case go

        var endpoint: String {
            switch self {
            case .zen: "https://opencode.ai/zen/v1/chat/completions"
            case .go: "https://opencode.ai/zen/go/v1/chat/completions"
            }
        }

        var name: String {
            switch self {
            case .zen: "OpenCode Zen"
            case .go: "OpenCode Go"
            }
        }
    }

    private let gateway: Gateway

    init(gateway: Gateway) {
        self.gateway = gateway
    }

    private struct ToolCallAccumulator {
        var id = ""
        var name = ""
        var arguments = ""
    }

    func generate(
        apiKey: String,
        model: String,
        systemPrompt: String,
        userPrompt: String,
        image: AiPageImageSnapshot?,
        sessionIdAtStart: String,
        toolEngine: AiToolEngine,
        onEvent: @escaping @MainActor (AiStreamEvent) -> Void
    ) async throws -> AiProviderResult {
        guard let url = URL(string: gateway.endpoint) else {
            throw AiClientError.message("Invalid \(gateway.name) endpoint.")
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

        onEvent(.status("Thinking"))

        for _ in 0..<6 {
            let body: [String: Any] = [
                "model": model,
                "messages": messages,
                "tools": Self.functionTools,
                "stream": true,
            ]
            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
            request.httpBody = try JSONSerialization.data(withJSONObject: body)

            let bytes = try await openStream(request)

            var text = ""
            var toolAccumulators: [Int: ToolCallAccumulator] = [:]
            for try await payload in SSE.dataPayloads(bytes) {
                guard let object = Self.jsonObjectOrNil(payload) else { continue }
                if let error = object["error"] as? [String: Any],
                   let message = error["message"] as? String {
                    throw AiClientError.message(message)
                }
                guard let choices = object["choices"] as? [[String: Any]],
                      let delta = choices.first?["delta"] as? [String: Any] else { continue }
                if let chunk = delta["content"] as? String, !chunk.isEmpty {
                    text += chunk
                    onEvent(.textDelta(chunk))
                }
                if let toolDeltas = delta["tool_calls"] as? [[String: Any]] {
                    for toolDelta in toolDeltas {
                        let index = (toolDelta["index"] as? NSNumber)?.intValue ?? 0
                        var entry = toolAccumulators[index] ?? ToolCallAccumulator()
                        if let id = toolDelta["id"] as? String, !id.isEmpty { entry.id = id }
                        if let function = toolDelta["function"] as? [String: Any] {
                            if let name = function["name"] as? String, !name.isEmpty { entry.name = name }
                            if let arguments = function["arguments"] as? String { entry.arguments += arguments }
                        }
                        toolAccumulators[index] = entry
                    }
                }
            }

            let calls = toolAccumulators.sorted { $0.key < $1.key }.map(\.value)
                .filter { !$0.name.isEmpty }
            if calls.isEmpty {
                return AiProviderResult(reply: Self.finalize(text, actions: actionResults), actionResults: actionResults)
            }

            let toolCallsPayload: [[String: Any]] = calls.map { call in
                [
                    "id": call.id,
                    "type": "function",
                    "function": ["name": call.name, "arguments": call.arguments],
                ]
            }
            var assistantMessage: [String: Any] = ["role": "assistant", "tool_calls": toolCallsPayload]
            assistantMessage["content"] = text.isEmpty ? NSNull() : text
            messages.append(assistantMessage)

            for call in calls {
                let argumentsText = call.arguments.isEmpty ? "{}" : call.arguments
                let values = (try? JSONSerialization.jsonObject(with: Data(argumentsText.utf8))) as? [String: Any] ?? [:]
                let action = AiToolAction(tool: call.name, args: Self.toolArguments(from: values))
                onEvent(.toolStarted(summary: GeminiClient.toolSummary(action)))
                let result = await toolEngine.run(
                    action,
                    sessionIdAtStart: sessionIdAtStart,
                    actionCount: actionResults.count
                )
                actionResults.append(result)
                onEvent(.toolFinished(result: result))
                messages.append([
                    "role": "tool",
                    "tool_call_id": call.id,
                    "content": result,
                ])
            }
            onEvent(.status("Thinking"))
        }
        return AiProviderResult(reply: Self.finalize("", actions: actionResults), actionResults: actionResults)
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
                throw AiClientError.message("\(gateway.name) returned an invalid HTTP response.")
            }
            if (200..<300).contains(http.statusCode) { return bytes }
            let data = try await Self.drain(bytes)
            let message = Self.providerMessage((try? Self.jsonObject(data)) ?? [:], fallback: String(decoding: data, as: UTF8.self))
            let error = AiClientError.message(message.isEmpty ? "\(gateway.name) request failed with status \(http.statusCode)." : message)
            if attempt == 0, http.statusCode == 408 || http.statusCode == 429 || http.statusCode >= 500 {
                lastError = error
                continue // transient status: retry once
            }
            throw error // non-retryable status: escapes immediately
        }
        throw lastError ?? AiClientError.message("\(gateway.name) request failed.")
    }

    private static func drain(_ bytes: URLSession.AsyncBytes) async throws -> Data {
        var data = Data()
        for try await byte in bytes { data.append(byte) }
        return data
    }

    private static func jsonObject(_ data: Data) throws -> [String: Any] {
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw AiClientError.message("OpenCode returned invalid JSON.")
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
