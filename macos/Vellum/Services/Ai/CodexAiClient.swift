import Foundation

// STUB — replaced by the AI module (see macos/specs/SPECS-ai.md, "run_codex_ai").
// Shells out to the local `codex` CLI with an output schema and optional page
// image, exactly mirroring the Rust run_codex_ai command.

@MainActor
final class CodexAiClient {
    func run(prompt: String, model: String, image: CodexAiImageInput?) async throws -> String {
        throw SessionServiceError.invalidDocument("CodexAiClient not implemented yet")
    }
}
