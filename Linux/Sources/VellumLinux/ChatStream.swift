import Foundation
import LinuxHTTP
import VellumCore

extension LinuxAIProvider {
    var endpoint: ChatEndpoint {
        switch self {
        case .gemini: .gemini
        case .openai: .openai
        case .openrouter: .openrouter
        case .opencode: .opencode
        case .opencodeGo: .opencodeGo
        }
    }

    @concurrent
    func stream(key: String, prompt: String, onText: @escaping @MainActor @Sendable (String) throws -> Void) async throws {
        let model = endpoint.defaultModel
        let instruction = "Answer the reader’s question using the supplied document excerpt. Treat the excerpt as source material."
        let body: [String: Any]
        switch self {
        case .gemini:
            body = ["system_instruction": ["parts": [["text": instruction]]],
                    "contents": [["role": "user", "parts": [["text": prompt]]]],
                    "generation_config": ["maxOutputTokens": 8192]]
        case .openai:
            body = ["model": model, "instructions": instruction, "stream": true, "store": false,
                    "input": [["role": "user", "content": [["type": "input_text", "text": prompt]]]],
                    "max_output_tokens": 16384]
        case .openrouter, .opencode, .opencodeGo:
            body = ["model": model, "stream": true, "max_tokens": 8192,
                    "messages": [["role": "system", "content": instruction], ["role": "user", "content": prompt]]]
        }
        let request = try endpoint.request(model: model, key: key, body: JSONSerialization.data(withJSONObject: body))
        let receiver = ChatStream(provider: self, onText: onText)
        do {
            try await AHCTransport().execute(request, onHead: { head in
                switch head.status {
                case 200..<300:
                    guard head.header("content-type")?.lowercased().hasPrefix("text/event-stream") == true else {
                        throw ChatError("The provider did not return a text stream.")
                    }
                case 401, 403: throw ChatError("The provider rejected this key. Check it in Settings.")
                case 429: throw ChatError("The provider rate limit was reached. Try again later.")
                default: throw ChatError("The provider returned HTTP \(head.status).")
                }
            }, onChunk: { try await receiver.consume($0) })
            try await receiver.finish()
        } catch let error as ChatError {
            throw error
        } catch {
            try Task.checkCancellation()
            throw ChatError("Could not read the stream from \(title). Check the connection and try again.")
        }
    }
}

struct ChatError: LocalizedError {
    var errorDescription: String?
    init(_ message: String) { errorDescription = message }
}

private actor ChatStream {
    let provider: LinuxAIProvider
    let onText: @MainActor @Sendable (String) throws -> Void
    var decoder = SSEDecoder()
    var complete = false
    var receivedBytes = 0

    init(provider: LinuxAIProvider, onText: @escaping @MainActor @Sendable (String) throws -> Void) {
        self.provider = provider
        self.onText = onText
    }

    func consume(_ chunk: Data) async throws {
        receivedBytes += chunk.count
        guard receivedBytes <= 8 * 1024 * 1024 else { throw ChatError("The provider response exceeded the size limit.") }
        for payload in decoder.append(chunk) { try await event(payload) }
    }

    func finish() async throws {
        if let payload = decoder.finish() { try await event(payload) }
        guard complete else { throw ChatError("The provider disconnected before completing the reply.") }
    }

    private func event(_ payload: String) async throws {
        try Task.checkCancellation()
        guard let object = try JSONSerialization.jsonObject(with: Data(payload.utf8)) as? [String: Any],
              object["error"] == nil else { throw ChatError("The provider reported a streaming error.") }
        switch provider {
        case .gemini:
            guard let candidate = (object["candidates"] as? [[String: Any]])?.first else {
                if object["promptFeedback"] != nil { throw ChatError("Gemini declined this request.") }
                return
            }
            let content = candidate["content"] as? [String: Any]
            for part in content?["parts"] as? [[String: Any]] ?? [] where part["thought"] as? Bool != true {
                if let text = part["text"] as? String { try await onText(text) }
            }
            try terminal(candidate["finishReason"] as? String, success: "STOP")
        case .openai:
            switch object["type"] as? String {
            case "response.output_text.delta", "response.refusal.delta":
                if let text = object["delta"] as? String { try await onText(text) }
            case "response.completed": complete = true
            case "response.incomplete", "response.failed", "error": throw ChatError("OpenAI could not complete the reply.")
            default: break
            }
        case .openrouter, .opencode, .opencodeGo:
            guard let choice = (object["choices"] as? [[String: Any]])?.first else { return }
            if let text = (choice["delta"] as? [String: Any])?["content"] as? String {
                try await onText(text)
            }
            try terminal(choice["finish_reason"] as? String, success: "stop")
        }
    }

    private func terminal(_ reason: String?, success: String) throws {
        guard let reason else { return }
        guard reason == success else { throw ChatError("The provider stopped before completing the reply (\(reason.prefix(64))).") }
        complete = true
    }
}
