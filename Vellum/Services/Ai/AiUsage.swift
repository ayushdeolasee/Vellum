import Foundation

/// Provider-neutral token usage for one request, summed across every streamed
/// response in the request's tool loop. Records token counts and provider-
/// reported cost only — never prompt contents. Used to measure real cache
/// economics (issue #37 review §4) instead of guessing at hit rates.
struct AiUsage: Codable, Equatable, Sendable {
    /// Total prompt tokens billed (includes the cached portion).
    var inputTokens = 0
    /// Portion of `inputTokens` served from the provider's prompt cache.
    var cachedInputTokens = 0
    /// Tokens written to the cache (Anthropic-style cache creation; 0 where
    /// the provider doesn't report it).
    var cacheWriteTokens = 0
    /// Reasoning/thinking tokens (billed as output on every provider).
    var reasoningTokens = 0
    /// Visible output tokens (includes `reasoningTokens` where the provider
    /// folds them into the output count).
    var outputTokens = 0
    /// Provider-reported cost in USD. Only OpenRouter reports one today.
    var costUSD: Double?

    var isEmpty: Bool {
        inputTokens == 0 && cachedInputTokens == 0 && cacheWriteTokens == 0
            && reasoningTokens == 0 && outputTokens == 0 && costUSD == nil
    }

    /// Fraction of prompt tokens served from cache (nil before any input).
    var cacheHitRatio: Double? {
        guard inputTokens > 0 else { return nil }
        return Double(cachedInputTokens) / Double(inputTokens)
    }

    mutating func accumulate(_ other: AiUsage) {
        inputTokens += other.inputTokens
        cachedInputTokens += other.cachedInputTokens
        cacheWriteTokens += other.cacheWriteTokens
        reasoningTokens += other.reasoningTokens
        outputTokens += other.outputTokens
        if let cost = other.costUSD {
            costUSD = (costUSD ?? 0) + cost
        }
    }

    // MARK: - Provider parsers (defensive: absent fields read as 0)

    /// Chat Completions `usage` object (OpenRouter, OpenCode gateways).
    static func fromChatCompletions(_ usage: [String: Any]) -> AiUsage {
        let promptDetails = usage["prompt_tokens_details"] as? [String: Any] ?? [:]
        let completionDetails = usage["completion_tokens_details"] as? [String: Any] ?? [:]
        var parsed = AiUsage(
            inputTokens: int(usage["prompt_tokens"]),
            cachedInputTokens: int(promptDetails["cached_tokens"]),
            cacheWriteTokens: int(promptDetails["cache_write_tokens"])
                + int(usage["cache_creation_input_tokens"]),
            reasoningTokens: int(completionDetails["reasoning_tokens"]),
            outputTokens: int(usage["completion_tokens"])
        )
        if let cost = (usage["cost"] as? NSNumber)?.doubleValue, cost > 0 {
            parsed.costUSD = cost
        }
        return parsed
    }

    /// Responses API `response.usage` object (OpenAI, ChatGPT Codex backend).
    static func fromResponses(_ usage: [String: Any]) -> AiUsage {
        let inputDetails = usage["input_tokens_details"] as? [String: Any] ?? [:]
        let outputDetails = usage["output_tokens_details"] as? [String: Any] ?? [:]
        return AiUsage(
            inputTokens: int(usage["input_tokens"]),
            cachedInputTokens: int(inputDetails["cached_tokens"]),
            reasoningTokens: int(outputDetails["reasoning_tokens"]),
            outputTokens: int(usage["output_tokens"])
        )
    }

    /// Gemini `usageMetadata` (cumulative per response — pass the last seen).
    static func fromGemini(_ metadata: [String: Any]) -> AiUsage {
        AiUsage(
            inputTokens: int(metadata["promptTokenCount"]),
            cachedInputTokens: int(metadata["cachedContentTokenCount"]),
            reasoningTokens: int(metadata["thoughtsTokenCount"]),
            outputTokens: int(metadata["candidatesTokenCount"])
        )
    }

    private static func int(_ value: Any?) -> Int {
        (value as? NSNumber)?.intValue ?? 0
    }
}

// MARK: - Display

extension AiUsage {
    /// Compact one-line indicator rendered under an assistant reply, e.g.
    /// "12.3k in (62% cached) · 1.2k out · $0.0042".
    var summaryLine: String {
        var input = "\(Self.compact(inputTokens)) in"
        if let ratio = cacheHitRatio, cachedInputTokens > 0 {
            input += " (\(Int((ratio * 100).rounded()))% cached)"
        }
        var parts = [input, "\(Self.compact(outputTokens)) out"]
        if let costUSD {
            parts.append(String(format: "$%.4f", costUSD))
        }
        return parts.joined(separator: " · ")
    }

    static func compact(_ tokens: Int) -> String {
        guard tokens >= 1000 else { return "\(tokens)" }
        let thousands = Double(tokens) / 1000
        return thousands >= 100
            ? "\(Int(thousands.rounded()))k"
            : String(format: "%.1fk", thousands)
    }
}

// MARK: - Aggregate ledger

/// Running totals per "provider/model", persisted in UserDefaults, so cache
/// retention and breakpoint policy can be tuned from measured hit rates.
/// Token counts and cost only — no prompt contents, no timestamps.
enum AiUsageLedger {
    static let key = "vellum-ai-usage-ledger-v1"

    struct Entry: Codable, Equatable, Sendable {
        var requests = 0
        var usage = AiUsage()

        var cacheHitRatio: Double? { usage.cacheHitRatio }
    }

    static func record(provider: String, model: String, usage: AiUsage) {
        guard !usage.isEmpty else { return }
        var entries = load()
        var entry = entries[ledgerKey(provider: provider, model: model)] ?? Entry()
        entry.requests += 1
        entry.usage.accumulate(usage)
        entries[ledgerKey(provider: provider, model: model)] = entry
        save(entries)
    }

    static func entry(provider: String, model: String) -> Entry? {
        load()[ledgerKey(provider: provider, model: model)]
    }

    private static func ledgerKey(provider: String, model: String) -> String {
        "\(provider)/\(model)"
    }

    private static func load() -> [String: Entry] {
        guard let data = UserDefaults.standard.data(forKey: key),
              let entries = try? JSONDecoder().decode([String: Entry].self, from: data)
        else { return [:] }
        return entries
    }

    private static func save(_ entries: [String: Entry]) {
        guard let data = try? JSONEncoder().encode(entries) else { return }
        UserDefaults.standard.set(data, forKey: key)
    }
}
