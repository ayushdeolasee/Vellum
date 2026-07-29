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

        let generationConfig = Self.generationConfig(for: thinkingMode, model: model)

        for _ in 0..<8 {
            let body = Self.requestBody(
                systemPrompt: systemPrompt,
                contents: contents,
                generationConfig: generationConfig
            )
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
            var finishReason: String?
            for try await payload in SSE.dataPayloads(bytes) {
                guard let object = Self.jsonObjectOrNil(payload) else { continue }
                // A 200 stream can carry an in-band error object instead of
                // candidates; surface it rather than finishing with an empty reply.
                if let error = object["error"] as? [String: Any],
                   let message = error["message"] as? String, !message.isEmpty {
                    throw AiClientError.message(message)
                }
                guard let candidates = object["candidates"] as? [[String: Any]],
                      let candidate = candidates.first else {
                    // No candidates at all: a prompt-level safety block.
                    if let feedback = object["promptFeedback"] as? [String: Any],
                       let reason = feedback["blockReason"] as? String {
                        throw AiClientError.message("Gemini blocked the request (\(reason)).")
                    }
                    continue
                }
                if let reason = candidate["finishReason"] as? String, !reason.isEmpty {
                    finishReason = reason
                }
                guard let parts = (candidate["content"] as? [String: Any])?["parts"] as? [[String: Any]]
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
                let reply = try Self.applyFinishReason(finishReason, to: text)
                return AiProviderResult(reply: Self.finalize(reply, actions: actionResults), actionResults: actionResults)
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
                // Brief backoff before the single retry (try? keeps cancellation
                // working: a cancelled sleep just falls through to retry, where
                // the request throws CancellationError).
                try? await Task.sleep(nanoseconds: 500_000_000)
                continue // transient network failure: retry once
            }

            guard let http = response as? HTTPURLResponse else {
                throw AiClientError.message("Gemini returned an invalid HTTP response.")
            }
            if (200..<300).contains(http.statusCode) { return bytes }
            let data = try await Self.drain(bytes)
            let message = Self.providerMessage((try? Self.jsonObject(data)) ?? [:], fallback: String(bytes: data, encoding: .utf8) ?? "")
            let error = AiClientError.message(message.isEmpty ? "Gemini request failed with status \(http.statusCode)." : message)
            if attempt == 0, http.statusCode == 408 || http.statusCode == 429 || http.statusCode >= 500 {
                lastError = error
                // Back off before retrying — immediate retry on 429 usually
                // just re-hits the limit.
                try? await Task.sleep(nanoseconds: 500_000_000)
                continue // transient status: retry once
            }
            throw error // non-retryable status: escapes immediately
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

    /// One tool-loop turn's request body.
    static func requestBody(
        systemPrompt: String,
        contents: [[String: Any]],
        generationConfig: [String: Any]
    ) -> [String: Any] {
        [
            "system_instruction": ["parts": [["text": systemPrompt]]],
            "contents": contents,
            "tools": [["function_declarations": Self.functionDeclarations]],
            "generation_config": generationConfig,
        ]
    }

    /// The `generation_config` for a turn: the thinking level/budget actually
    /// sent, and an output cap sized around it.
    static func generationConfig(for mode: AiThinkingMode, model: String) -> [String: Any] {
        var config: [String: Any] = ["temperature": 0.2]
        if let thinking = resolvedThinkingConfig(for: mode, model: model) {
            config["thinkingConfig"] = thinking
        }
        config["maxOutputTokens"] = maxOutputTokens(for: mode, model: model)
        return config
    }

    /// The thinkingConfig actually sent for `mode`, including the `.auto`
    /// branch that used to sit inline in `generate`.
    ///
    /// `.auto` preserves the prior default byte-for-byte: for the 2.5 flash
    /// family disable extended thinking (0 budget); everything else omits
    /// thinkingConfig and lets the server pick. 2.5 Pro rejects thinkingBudget 0
    /// (its documented minimum is 128); only 2.5 Flash (range 0–24576) and
    /// Flash-Lite (0, then 512–24576) accept 0, so exclude Pro.
    static func resolvedThinkingConfig(for mode: AiThinkingMode, model: String) -> [String: Any]? {
        let lowered = model.lowercased()
        guard mode == .auto else { return thinkingConfig(for: mode, model: model) }
        if lowered.contains("2.5") && !lowered.contains("pro") {
            return ["thinkingBudget": 0]
        }
        return nil
    }

    /// Whether omitting thinkingConfig still leaves the model thinking at a
    /// level the server picks. True for the whole Gemini 3 line (its default
    /// `thinkingLevel` is `high` on the Pro and 3-flash rows, `medium` on
    /// 3.5-flash, `minimal` on 3.1-flash-lite) and for 2.5, whose default is
    /// dynamic thinking. The 2.0 flash models and the retired 1.5 line don't
    /// think at all, so an omitted config really does mean no reasoning tokens —
    /// which matters, because those two families cap output at 8192 total and
    /// must not be handed a larger budget.
    static func thinksWhenUnconfigured(model: String) -> Bool {
        let lowered = model.lowercased()
        if lowered.contains("1.5") { return false }
        if lowered.contains("2.0") { return lowered.contains("thinking") }
        return true
    }

    /// Output-token cap for a turn, sized so thinking can't starve the answer.
    ///
    /// The `.auto` hole this closes (#96): Auto sends no thinkingConfig on every
    /// family except 2.5 flash, so the *server* picks the thinking level — and
    /// the level it picks is not a low one. Google documents the default
    /// `thinkingLevel` as `high` for `gemini-3-pro-preview`,
    /// `gemini-3.1-pro-preview` and `gemini-3-flash-preview`, and 2.5's default
    /// as dynamic thinking. The cap nonetheless stayed at the flat 8192 base, so
    /// on the app's default provider the default thinking mode reserved room for
    /// *no* reasoning while the server did its most expensive kind. That is the
    /// same trade #95 removed from the OpenAI path, and the same truncation.
    ///
    /// So Auto is budgeted at the top of the ladder rather than #95's mid-range:
    /// the mid-range assumption there matched OpenAI's documented default effort
    /// of `medium`, and the equivalent evidence-led answer for Gemini is `high`.
    /// Over-reserving is free — `maxOutputTokens` is a ceiling, not a spend —
    /// while under-reserving truncates a finished answer. The resulting caps stay
    /// well inside the 65536 output limit every 2.5 and 3.x model documents.
    static func maxOutputTokens(for mode: AiThinkingMode, model: String) -> Int {
        let config = resolvedThinkingConfig(for: mode, model: model)
        guard mode == .auto, config == nil, thinksWhenUnconfigured(model: model) else {
            return maxOutputTokens(thinkingConfig: config)
        }
        // Budget the server's own choice as if High had been asked for. A family
        // with no row (a future release) has no level to resolve, so fall back to
        // the same reserve the level ladder's top rung gets.
        guard let topOfLadder = thinkingConfig(for: .high, model: model) else {
            return highThinkingReserve + baseMaxOutputTokens
        }
        return maxOutputTokens(thinkingConfig: topOfLadder)
    }

    /// Output-token cap sized so thinking can't starve the visible answer.
    /// 8192 when thinking is off (nil config or a 0 thinkingBudget) — generous
    /// enough that replies don't clip silently; truncation is surfaced via
    /// finishReason regardless. Otherwise reserves the resolved thinking budget
    /// plus 8192 headroom for the reply. Gemini-3 thinkingLevel has no numeric
    /// budget — Google calls the levels "relative allowances for thinking rather
    /// than strict token guarantees" — so map each level to a generous cap.
    static let baseMaxOutputTokens = 8192
    /// Thinking headroom reserved for the strongest level, and for Auto.
    static let highThinkingReserve = 24576
    static func maxOutputTokens(thinkingConfig config: [String: Any]?) -> Int {
        let base = baseMaxOutputTokens
        guard let config else { return base }
        if let budget = config["thinkingBudget"] as? Int {
            if budget == 0 { return base }                          // thinking disabled
            if budget < 0 { return highThinkingReserve + base }     // dynamic: model decides
            return budget + base                                    // reserve budget + reply headroom
        }
        if let level = config["thinkingLevel"] as? String {
            switch level {
            case "low": return 8192 + base
            case "medium": return 16384 + base
            case "high": return highThinkingReserve + base
            default: return base                    // "minimal" / unknown
            }
        }
        return base
    }

    /// Thinking levels ordered weakest to strongest. Used to fall back to the
    /// nearest level a model actually accepts when the user's choice isn't in
    /// its set.
    private static let thinkingLevelLadder = ["minimal", "low", "medium", "high"]

    /// The `thinkingLevel` values `model` accepts, or `[]` for a family that
    /// doesn't take a level at all (2.x takes numeric budgets, 1.5 takes
    /// nothing).
    ///
    /// Deliberately shaped as "what this family supports" rather than the old
    /// "which one id is special", the same inversion `OpenAIClient
    /// .supportedEfforts` made for #94. The previous form asked
    /// `contains("gemini-3-pro")` and treated everything else on the 3 line as
    /// supporting the full ladder. `gemini-3.1-pro` does not contain that
    /// substring, so it landed in the permissive branch and Instant sent it
    /// `minimal` — a level the 3.1 Pro row does not have, so the request 400s
    /// before streaming. That is #94's failure mode reappearing on a point
    /// release, which is why the shape and not just the string is what changes
    /// here.
    ///
    /// Rows come from the Gemini 3 developer guide plus each model's page under
    /// `ai.google.dev/gemini-api/docs/models`:
    /// - `gemini-3-pro-preview` is the narrow one: `low`/`high` only.
    /// - `gemini-3.1-pro-preview` added `medium` but still has no `minimal`.
    /// - The flash line (`3-flash`, `3.1-flash`/`-flash-lite`, `3.5-flash`)
    ///   takes the full ladder.
    ///
    /// An unrecognized id on the 3 line falls to `low`/`high`: that is the
    /// intersection of every row above, so it can't send a level some future
    /// Pro release rejects. Note the safe branch here is a *narrower set*, not
    /// the empty set `supportedEfforts` uses — omitting the field on Gemini
    /// means the server default, which on this line is `high`, so an omit would
    /// silently turn Instant into the slowest and priciest setting.
    static func supportedThinkingLevels(model: String) -> Set<String> {
        let lowered = model.lowercased()
        guard lowered.contains("gemini-3") else { return [] }
        if lowered.contains("gemini-3-flash")
            || lowered.contains("gemini-3.1-flash")
            || lowered.contains("gemini-3.5-flash") {
            return ["minimal", "low", "medium", "high"]
        }
        if lowered.contains("gemini-3.1-pro") { return ["low", "medium", "high"] }
        if lowered.contains("gemini-3-pro") { return ["low", "high"] }
        return ["low", "high"]
    }

    /// The level to send for `model`, or nil to omit the field.
    ///
    /// When the user's choice isn't in the model's set, fall back to the
    /// nearest rung rather than dropping the choice. Ties round *up* — the
    /// opposite of the OpenAI ladder, because Gemini's level vocabulary has no
    /// "off" rung: every level still thinks, so the cost of rounding up is some
    /// extra thinking, while rounding down on a Pro model that only offers
    /// `low`/`high` would quietly demote a Medium request to the weakest
    /// setting it has.
    static func resolvedThinkingLevel(model: String, requested: String?) -> String? {
        guard let requested else { return nil }
        let supported = supportedThinkingLevels(model: model)
        guard !supported.isEmpty else { return nil }
        if supported.contains(requested) { return requested }
        guard let target = thinkingLevelLadder.firstIndex(of: requested) else { return nil }
        return thinkingLevelLadder.enumerated()
            .filter { supported.contains($0.element) }
            .min { lhs, rhs in
                let left = abs(lhs.offset - target), right = abs(rhs.offset - target)
                return left == right ? lhs.offset > rhs.offset : left < right
            }?
            .element
    }

    /// The `thinkingLevel` a thinking mode asks for, before it is resolved
    /// against what the model actually accepts.
    private static func requestedLevel(for mode: AiThinkingMode) -> String? {
        switch mode {
        case .auto: nil
        case .instant: "minimal"
        case .low: "low"
        case .medium: "medium"
        case .high: "high"
        }
    }

    /// thinkingConfig payload for the given effort, or nil to omit it.
    /// Gemini 3 families take a discrete thinkingLevel — numeric budgets are a
    /// request error there. 2.x keeps numeric budgets (Pro floors at 128, its
    /// minimum — 2.5 Pro cannot disable thinking; -1 means dynamic, the model
    /// decides). 1.5 and unknown families send nothing. `.auto` is
    /// `resolvedThinkingConfig`'s branch and must never be routed here.
    static func thinkingConfig(for mode: AiThinkingMode, model: String) -> [String: Any]? {
        guard mode != .auto else { return nil }
        let lowered = model.lowercased()
        if lowered.contains("1.5") { return nil }
        if lowered.contains("gemini-3") {
            guard let level = resolvedThinkingLevel(
                model: lowered, requested: requestedLevel(for: mode)) else { return nil }
            return ["thinkingLevel": level]
        }
        // 2.5 accepts numeric thinkingBudget across the family. Of the 2.0
        // models only the documented *-thinking variants do — plain
        // gemini-2.0-flash / -flash-lite 400 on thinkingConfig, so omit it.
        let is20Thinking = lowered.contains("2.0") && lowered.contains("thinking")
        guard lowered.contains("2.5") || is20Thinking else { return nil }
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

    /// Surface an abnormal finish instead of silently returning a clipped or
    /// empty reply: MAX_TOKENS appends a visible truncation note (or errors when
    /// nothing streamed); any other non-STOP reason with no text (SAFETY,
    /// RECITATION, …) becomes an error naming the cause.
    private static func applyFinishReason(_ finishReason: String?, to text: String) throws -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if finishReason == "MAX_TOKENS" {
            guard !trimmed.isEmpty else {
                throw AiClientError.message("Gemini hit the output-token limit before producing any text. Try a lower thinking mode.")
            }
            return text + "\n\n_(reply truncated at the output-token limit)_"
        }
        if trimmed.isEmpty, let finishReason, finishReason != "STOP" {
            throw AiClientError.message("Gemini ended the reply without text (\(finishReason)).")
        }
        return text
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
            "name": "getAnnotations",
            "description": "List the user's annotations (notes and highlights) across the WHOLE document, or for a single page when pageNumber is given. The context you receive only includes the current page's annotations — call this when the user asks about their notes or highlights elsewhere.",
            "parameters": [
                "type": "object",
                "properties": ["pageNumber": ["type": "number", "description": "Optional 1-indexed page to filter by. Omit to list every page's annotations."]],
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
