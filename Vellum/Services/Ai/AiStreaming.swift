import Foundation
import VellumCore

// Streaming plumbing shared by the AI providers. Gemini and OpenAI stream token
// deltas over SSE; the store turns these events into a live-updating assistant
// message and activity states. Codex stays buffered (structured-output JSON that
// can't be partially streamed) but still emits status/tool events for parity.

/// Incremental events a provider emits while producing a reply. Delivered on the
/// main actor so the store can mutate `@Observable` UI state directly.
enum AiStreamEvent: Sendable {
    /// Coarse phase label for the activity indicator ("Thinking…", "Reading…").
    case status(String)
    /// A chunk of assistant reply text to append to the live message.
    case textDelta(String)
    /// A tool call has started (human-readable summary, e.g. "Navigating to page 5").
    case toolStarted(summary: String)
    /// A tool call finished with this result line (mirrors the buffered
    /// `actionResults` entries so persistence/formatting stay identical).
    case toolFinished(result: String)
}

/// A provider can retry a failed connection or a transient HTTP status once.
@MainActor
enum AiStreaming {
    enum Provider {
        case openAI, openRouter, openCode(String), gemini

        var name: String {
            switch self {
            case .openAI: "OpenAI"
            case .openRouter: "OpenRouter"
            case .openCode(let name): name
            case .gemini: "Gemini"
            }
        }
    }

    private enum Failure: Error { case errorBodyFull }

    @MainActor
    private final class Attempt {
        var status: Int?
        var errorBody = Data()
        var decoder = SSEDecoder()

        func receive(_ chunk: Data, onPayload: @MainActor (String) throws -> Void) throws {
            guard let status, (200..<300).contains(status) else {
                let remaining = 64 * 1024 - errorBody.count
                errorBody.append(chunk.prefix(remaining))
                if chunk.count >= remaining { throw Failure.errorBodyFull }
                return
            }
            for payload in decoder.append(chunk) { try onPayload(payload) }
        }
    }

    static func receive(
        _ request: URLRequest, provider: Provider, transport: any StreamingTransport = AppleStreamingTransport(),
        onPayload: @escaping @MainActor (String) throws -> Void
    ) async throws {
        for index in 0...1 {
            if index > 0, case .gemini = provider { try await Task.sleep(for: .milliseconds(500)) }
            try Task.checkCancellation()
            let attempt = Attempt()
            do {
                try await transport.execute(request, onHead: { head in
                    await MainActor.run { attempt.status = head.status }
                }, onChunk: { chunk in
                    try await attempt.receive(chunk, onPayload: onPayload)
                })
            } catch Failure.errorBodyFull {
                // The transport has cancelled the response. Apply the normal HTTP
                // error/retry policy using only the bounded prefix.
            } catch AppleStreamingTransport.Failure.nonHTTPResponse {
                throw AiClientError.message("\(provider.name) returned an invalid HTTP response.")
            } catch let error as URLError where error.code == .cancelled {
                throw CancellationError()
            } catch {
                try Task.checkCancellation()
                if error is CancellationError || attempt.status != nil || index == 1 { throw error }
                continue
            }
            try Task.checkCancellation()
            guard let status = attempt.status else {
                throw AiClientError.message("\(provider.name) returned an invalid HTTP response.")
            }
            if (200..<300).contains(status) {
                if let last = attempt.decoder.finish() { try onPayload(last) }
                return
            }
            if index == 0, status == 408 || status == 429 || status >= 500 { continue }
            let data = attempt.errorBody
            let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
            let fallback: String
            if case .gemini = provider {
                fallback = String(data: data, encoding: .utf8) ?? ""
            } else {
                fallback = String(decoding: data, as: UTF8.self)
            }
            let message = (json?["error"] as? [String: Any])?["message"] as? String ?? fallback
            throw AiClientError.message(message.isEmpty ? "\(provider.name) request failed with status \(status)." : message)
        }
    }
}
