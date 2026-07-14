import Foundation
import Observation

/// One model exposed by OpenRouter's `/api/v1/models` endpoint, reduced to the
/// fields the selector and send pipeline care about.
struct OpenRouterModel: Identifiable, Sendable, Equatable {
    var id: String
    var name: String
    var contextLength: Int?
    var promptPrice: Double?
    var completionPrice: Double?
    var created: Int?
    /// True when the model accepts image input ("image" in input_modalities).
    var supportsVision: Bool
    /// True when the model supports function/tool calling ("tools" in supported_parameters).
    var supportsTools: Bool
}

/// Fetches and caches OpenRouter's model catalog. The list endpoint needs no
/// API key. Cached to UserDefaults so the selector opens instantly and works
/// offline; refreshed at most daily unless forced.
@MainActor
@Observable
final class OpenRouterCatalog {
    private(set) var models: [OpenRouterModel] = []
    private(set) var isLoading = false
    private(set) var error: String?

    private static let cacheKey = "openrouter-models-cache-v1"
    private static let cacheStampKey = "openrouter-models-cache-stamp-v1"
    private static let maxCacheAge: TimeInterval = 24 * 60 * 60
    private static let endpoint = "https://openrouter.ai/api/v1/models"

    init() {
        models = Self.loadCache()
    }

    /// Refreshes the catalog from the network. Skips the fetch when a recent
    /// cache exists unless `force` is set.
    func refresh(force: Bool = false) async {
        if !force, !models.isEmpty, !Self.cacheIsStale() { return }
        if isLoading { return }
        isLoading = true
        error = nil
        defer { isLoading = false }

        guard let url = URL(string: Self.endpoint) else {
            error = "Invalid OpenRouter endpoint."
            return
        }
        do {
            let (data, response) = try await URLSession.shared.data(from: url)
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                error = "Couldn't load OpenRouter models."
                return
            }
            let parsed = Self.parse(data)
            if parsed.isEmpty {
                error = "OpenRouter returned no models."
                return
            }
            models = parsed
            Self.saveCache(data)
        } catch {
            self.error = "Couldn't load OpenRouter models: \(error.localizedDescription)"
        }
    }

    /// Capability lookup used by the send pipeline. Unknown ids default to
    /// permissive (assume both supported) so a stale cache never silently
    /// strips a capability the model actually has.
    func model(for id: String) -> OpenRouterModel? {
        models.first { $0.id == id }
    }

    // MARK: - Parsing

    private static func parse(_ data: Data) -> [OpenRouterModel] {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let list = root["data"] as? [[String: Any]] else { return [] }
        return list.compactMap(parseModel)
    }

    private static func parseModel(_ raw: [String: Any]) -> OpenRouterModel? {
        guard let id = raw["id"] as? String, !id.isEmpty else { return nil }
        let name = (raw["name"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? id
        let architecture = raw["architecture"] as? [String: Any]
        let inputModalities = architecture?["input_modalities"] as? [String] ?? []
        let supportedParameters = raw["supported_parameters"] as? [String] ?? []
        let pricing = raw["pricing"] as? [String: Any]
        return OpenRouterModel(
            id: id,
            name: name,
            contextLength: (raw["context_length"] as? NSNumber)?.intValue,
            promptPrice: price(pricing?["prompt"]),
            completionPrice: price(pricing?["completion"]),
            created: (raw["created"] as? NSNumber)?.intValue,
            supportsVision: inputModalities.contains("image"),
            supportsTools: supportedParameters.contains("tools")
        )
    }

    /// OpenRouter encodes per-token prices as strings ("0", "0.000003").
    private static func price(_ value: Any?) -> Double? {
        if let string = value as? String { return Double(string) }
        if let number = value as? NSNumber { return number.doubleValue }
        return nil
    }

    // MARK: - Cache

    private static func loadCache() -> [OpenRouterModel] {
        guard let data = UserDefaults.standard.data(forKey: cacheKey) else { return [] }
        return parse(data)
    }

    private static func saveCache(_ data: Data) {
        UserDefaults.standard.set(data, forKey: cacheKey)
        UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: cacheStampKey)
    }

    private static func cacheIsStale() -> Bool {
        let stamp = UserDefaults.standard.double(forKey: cacheStampKey)
        guard stamp > 0 else { return true }
        return Date().timeIntervalSince1970 - stamp > maxCacheAge
    }
}
