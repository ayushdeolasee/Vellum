import Foundation

@MainActor
final class CodexAiClient {
    func run(prompt: String, model: String, image: CodexAiImageInput?) async throws -> String {
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

        do {
            try process.run()
        } catch {
            throw CodexAiError.message("Failed to start Codex CLI. Is `codex` installed? \(error.localizedDescription)")
        }
        do {
            try stdin.fileHandleForWriting.write(contentsOf: Data(prompt.utf8))
            try stdin.fileHandleForWriting.close()
        } catch {
            process.terminate()
            throw CodexAiError.message("Failed to write prompt to Codex: \(error.localizedDescription)")
        }

        let outputData = stdout.fileHandleForReading.readDataToEndOfFile()
        let errorData = stderr.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
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

    private static let outputSchema: [String: Any] = [
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
    ]
}

private enum CodexAiError: LocalizedError {
    case message(String)
    var errorDescription: String? {
        if case .message(let message) = self { return message }
        return nil
    }
}
