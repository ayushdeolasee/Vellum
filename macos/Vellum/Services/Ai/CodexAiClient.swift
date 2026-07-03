import Foundation

// Runs the codex CLI off the main actor (the original executes it inside
// spawn_blocking + wait_with_output). Stateless, so safely Sendable.
final class CodexAiClient: Sendable {
    nonisolated func run(prompt: String, model: String, image: CodexAiImageInput?) async throws -> String {
        let manager = FileManager.default
        let tempDirectory = manager.temporaryDirectory
            .appendingPathComponent(UUID().uuidString.lowercased(), isDirectory: true)
        do {
            try manager.createDirectory(at: tempDirectory, withIntermediateDirectories: false)
        } catch {
            throw CodexAiError.message("Failed to create temp dir: \(error.localizedDescription)")
        }
        defer { try? manager.removeItem(at: tempDirectory) }

        let schemaURL = tempDirectory.appendingPathComponent("codex-output-schema.json")
        let outputURL = tempDirectory.appendingPathComponent("codex-response.json")
        let schemaData: Data
        do {
            schemaData = try JSONSerialization.data(withJSONObject: Self.outputSchema, options: [.prettyPrinted])
        } catch {
            throw CodexAiError.message("Failed to serialize Codex schema: \(error.localizedDescription)")
        }
        do {
            try schemaData.write(to: schemaURL)
        } catch {
            throw CodexAiError.message("Failed to write Codex schema: \(error.localizedDescription)")
        }

        var imageURL: URL?
        if let image {
            guard let data = Data(base64Encoded: image.base64Data.trimmingCharacters(in: .whitespacesAndNewlines)) else {
                throw CodexAiError.message("Failed to decode page image: Invalid Base64 input")
            }
            let ext = image.mediaType == "image/png" ? "png" : (image.mediaType == "image/webp" ? "webp" : "jpg")
            let url = tempDirectory.appendingPathComponent("current-page.\(ext)")
            do {
                try data.write(to: url)
            } catch {
                throw CodexAiError.message("Failed to write page image: \(error.localizedDescription)")
            }
            imageURL = url
        }

        let selectedModel = model.trimmingCharacters(in: .whitespacesAndNewlines)
        var arguments = [
            "codex", "exec",
            "--model", selectedModel.isEmpty ? "gpt-5.5" : selectedModel,
            "--sandbox", "read-only",
            "--skip-git-repo-check",
            "--ephemeral",
            "--cd", tempDirectory.path,
            "--output-schema", schemaURL.path,
            "--output-last-message", outputURL.path,
        ]
        if let imageURL { arguments += ["--image", imageURL.path] }
        arguments.append("-")

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = arguments
        let stdin = Pipe()
        let stdout = Pipe()
        let stderr = Pipe()
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = stderr

        // Drain stdout and stderr concurrently via readability handlers so a
        // child filling one pipe while we read the other can never deadlock,
        // and wait for exit via a termination handler instead of blocking.
        let stdoutCollector = CodexPipeCollector()
        let stderrCollector = CodexPipeCollector()
        stdout.fileHandleForReading.readabilityHandler = { handle in
            let chunk = handle.availableData
            if chunk.isEmpty {
                handle.readabilityHandler = nil
                stdoutCollector.finish()
            } else {
                stdoutCollector.append(chunk)
            }
        }
        stderr.fileHandleForReading.readabilityHandler = { handle in
            let chunk = handle.availableData
            if chunk.isEmpty {
                handle.readabilityHandler = nil
                stderrCollector.finish()
            } else {
                stderrCollector.append(chunk)
            }
        }
        let exitLatch = CodexExitLatch()
        process.terminationHandler = { _ in exitLatch.signal() }

        do {
            try process.run()
        } catch {
            stdout.fileHandleForReading.readabilityHandler = nil
            stderr.fileHandleForReading.readabilityHandler = nil
            throw CodexAiError.message("Failed to start Codex CLI. Is `codex` installed? \(error.localizedDescription)")
        }
        do {
            // run() is nonisolated, so this executes off the main actor; both
            // output pipes are already being drained, so the child keeps
            // making progress while it consumes the (possibly large) prompt.
            try stdin.fileHandleForWriting.write(contentsOf: Data(prompt.utf8))
            try stdin.fileHandleForWriting.close()
        } catch {
            process.terminate()
            throw CodexAiError.message("Failed to write prompt to Codex: \(error.localizedDescription)")
        }

        await exitLatch.wait()
        let outputData = await stdoutCollector.collect()
        let errorData = await stderrCollector.collect()
        let outputText = String(decoding: outputData, as: UTF8.self)
        let errorText = String(decoding: errorData, as: UTF8.self)
        guard process.terminationStatus == 0 else {
            let rawDetails = errorText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? outputText.trimmingCharacters(in: .whitespacesAndNewlines)
                : errorText.trimmingCharacters(in: .whitespacesAndNewlines)
            let details = rawDetails.count > 1_200
                ? String(rawDetails.prefix(1_200)) + "..."
                : rawDetails
            throw CodexAiError.message("Codex CLI exited with status exit status: \(process.terminationStatus): \(details)")
        }

        let response: String
        do {
            response = try String(contentsOf: outputURL, encoding: .utf8)
        } catch {
            if !outputText.isEmpty {
                response = outputText
            } else {
                throw CodexAiError.message("Failed to read Codex final response: \(error.localizedDescription)")
            }
        }
        let trimmed = response.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw CodexAiError.message("Codex returned an empty response.") }
        return trimmed
    }

    // Computed (not stored) so the non-Sendable dictionary carries no shared
    // state now that the class is nonisolated.
    private static var outputSchema: [String: Any] { [
        "type": "object",
        "additionalProperties": false,
        "properties": [
            "reply": ["type": "string"],
            "actions": [
                "type": "array",
                "items": [
                    "type": "object",
                    "additionalProperties": false,
                    "properties": [
                        "tool": ["type": "string", "enum": ["goToPage", "addNote", "addHighlight"]],
                        "args": [
                            "type": "object",
                            "additionalProperties": false,
                            "properties": [
                                "pageNumber": ["type": "number"],
                                "text": ["type": ["string", "null"]],
                                "color": ["type": ["string", "null"]],
                                "x": ["type": ["number", "null"]],
                                "y": ["type": ["number", "null"]],
                            ],
                            "required": ["pageNumber", "text", "color", "x", "y"],
                        ],
                    ],
                    "required": ["tool", "args"],
                ],
            ],
        ],
        "required": ["reply", "actions"],
    ] }
}

private enum CodexAiError: LocalizedError {
    case message(String)
    var errorDescription: String? {
        if case .message(let message) = self { return message }
        return nil
    }
}

/// Accumulates one pipe's bytes from a readabilityHandler (GCD thread) and
/// hands the full contents to an awaiting task once EOF is seen.
private final class CodexPipeCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()
    private var finished = false
    private var continuation: CheckedContinuation<Data, Never>?

    func append(_ chunk: Data) {
        lock.lock()
        data.append(chunk)
        lock.unlock()
    }

    func finish() {
        lock.lock()
        finished = true
        let continuation = self.continuation
        self.continuation = nil
        let collected = data
        lock.unlock()
        continuation?.resume(returning: collected)
    }

    func collect() async -> Data {
        await withCheckedContinuation { continuation in
            lock.lock()
            if finished {
                let collected = data
                lock.unlock()
                continuation.resume(returning: collected)
            } else {
                self.continuation = continuation
                lock.unlock()
            }
        }
    }
}

/// Bridges Process.terminationHandler to async/await without blocking a
/// thread (waitUntilExit) and without racing handler installation.
private final class CodexExitLatch: @unchecked Sendable {
    private let lock = NSLock()
    private var signaled = false
    private var continuation: CheckedContinuation<Void, Never>?

    func signal() {
        lock.lock()
        signaled = true
        let continuation = self.continuation
        self.continuation = nil
        lock.unlock()
        continuation?.resume()
    }

    func wait() async {
        await withCheckedContinuation { continuation in
            lock.lock()
            if signaled {
                lock.unlock()
                continuation.resume()
            } else {
                self.continuation = continuation
                lock.unlock()
            }
        }
    }
}
