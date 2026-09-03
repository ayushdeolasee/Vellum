import Foundation
import Observation

/// Models available to the user's OpenAI API key. OpenAI's model-list response
/// only exposes identifiers and basic availability, so Vellum keeps capability
/// handling separate and filters out product-specific model families that its
/// Responses API client cannot use.
@MainActor
@Observable
final class OpenAIModelCatalog {
    private(set) var models: [String] = []
    private(set) var isLoading = false
    private(set) var error: String?

    private static let endpoint = URL(string: "https://api.openai.com/v1/models")!

    func refresh(apiKey: String, session: URLSession = .shared) async {
        let key = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty, !isLoading else { return }

        models = []
        isLoading = true
        error = nil
        defer { isLoading = false }

        var request = URLRequest(url: Self.endpoint)
        request.timeoutInterval = 15
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")

        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                error = "OpenAI returned an invalid response."
                return
            }
            guard (200..<300).contains(http.statusCode) else {
                error = http.statusCode == 401 || http.statusCode == 403
                    ? "OpenAI rejected the API key."
                    : "OpenAI returned HTTP \(http.statusCode)."
                return
            }

            let parsed = Self.parse(data)
            guard !parsed.isEmpty else {
                error = "OpenAI returned no compatible models."
                return
            }
            models = parsed
        } catch {
            self.error = "Couldn't load OpenAI models."
        }
    }

    nonisolated static func parse(_ data: Data) -> [String] {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let list = root["data"] as? [[String: Any]] else { return [] }

        return Array(Set(list.compactMap { raw in
            guard let id = raw["id"] as? String, supportsVellum(id) else { return nil }
            return id
        })).sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    /// Vellum sends text, images, and function tools through `/v1/responses`.
    /// `/v1/models` does not expose endpoint or modality support, so keep the
    /// general-purpose GPT and o-series families and reject specialized model
    /// ids whose APIs or payload shapes are incompatible with that request.
    nonisolated private static func supportsVellum(_ id: String) -> Bool {
        let value = id.lowercased()
        let isCompatibleFamily = value.hasPrefix("gpt-4.1")
            || value.hasPrefix("gpt-4o")
            || value.range(
                of: #"^gpt-(?:[5-9]|[1-9][0-9]+)(?:\D|$)"#,
                options: .regularExpression
            ) != nil
            || value.range(
                of: #"^o(?:[3-9]|[1-9][0-9]+)(?:\D|$)"#,
                options: .regularExpression
            ) != nil
        guard isCompatibleFamily else {
            return false
        }
        let incompatibleMarkers = [
            "audio", "realtime", "transcribe", "tts", "image", "search",
            "deep-research",
        ]
        return !incompatibleMarkers.contains { value.contains($0) }
    }
}
