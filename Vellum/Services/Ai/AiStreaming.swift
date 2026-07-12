import Foundation

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

/// Minimal Server-Sent-Events line splitter over an async byte stream. Yields
/// each complete `data:` payload (SSE frames are newline-delimited; a blank line
/// terminates an event, but every provider we target emits one JSON object per
/// `data:` line, so we surface payloads line-by-line).
enum SSE {
    static func dataPayloads(
        _ bytes: URLSession.AsyncBytes
    ) -> AsyncCompactMapSequence<AsyncLineSequence<URLSession.AsyncBytes>, String> {
        bytes.lines.compactMap { line -> String? in
            guard line.hasPrefix("data:") else { return nil }
            let payload = line.dropFirst("data:".count)
                .trimmingCharacters(in: .whitespaces)
            if payload.isEmpty || payload == "[DONE]" { return nil }
            return payload
        }
    }
}
