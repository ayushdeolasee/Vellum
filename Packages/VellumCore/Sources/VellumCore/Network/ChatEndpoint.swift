import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Authentication, routing and request framing shared by Apple and Linux.
public enum ChatEndpoint: Sendable {
    case gemini, openai, openrouter, opencode, opencodeGo

    /// Apple selects an OpenRouter model separately. A provider-only picker
    /// can explicitly request OpenRouter's automatic routing model.
    public var defaultModel: String {
        switch self {
        case .gemini: "gemini-3.1-flash-lite-preview"
        case .openai: "gpt-5.5"
        case .openrouter: "openrouter/auto"
        case .opencode: "claude-opus-4-8"
        case .opencodeGo: "glm-5.2"
        }
    }

    public func request(model: String, key: String, body: Data) throws -> URLRequest {
        let address: String
        switch self {
        case .gemini:
            let name = model.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? model
            address = "https://generativelanguage.googleapis.com/v1beta/models/\(name):streamGenerateContent?alt=sse"
        case .openai: address = "https://api.openai.com/v1/responses"
        case .openrouter: address = "https://openrouter.ai/api/v1/chat/completions"
        case .opencode: address = "https://opencode.ai/zen/v1/chat/completions"
        case .opencodeGo: address = "https://opencode.ai/zen/go/v1/chat/completions"
        }
        guard let url = URL(string: address) else { throw URLError(.badURL) }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.httpBody = body
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        if self == .gemini {
            request.setValue(key, forHTTPHeaderField: "x-goog-api-key")
        } else {
            request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        }
        if self == .openrouter {
            request.setValue("Vellum", forHTTPHeaderField: "X-Title")
            request.setValue("https://vellum.app", forHTTPHeaderField: "HTTP-Referer")
        }
        return request
    }
}
