import Foundation

/// Permission to send document content to an AI provider.
///
/// The disclosure version is part of the key so a future material change can
/// ask again without treating an older grant as current consent.
enum AiSharingConsent {
    static let providers: [AiProvider] = [
        .gemini, .openai, .openrouter, .opencode, .opencodeGo,
    ]

    private static let disclosureVersion = 1

    static func needsConsent(for provider: AiProvider) -> Bool {
        providers.contains(provider) && !isGranted(for: provider)
    }

    static func isGranted(for provider: AiProvider) -> Bool {
        AppDefaults.current.bool(forKey: key(for: provider))
    }

    static func grant(for provider: AiProvider) {
        guard providers.contains(provider) else { return }
        AppDefaults.current.set(true, forKey: key(for: provider))
    }

    static func revoke(for provider: AiProvider) {
        AppDefaults.current.removeObject(forKey: key(for: provider))
    }

    private static func key(for provider: AiProvider) -> String {
        "vellum.ai-sharing-consent.v\(disclosureVersion).\(provider.rawValue)"
    }
}

extension AiProvider {
    var consentDisplayName: String {
        switch self {
        case .gemini: "Google Gemini"
        case .openai: "OpenAI API"
        case .openrouter: "OpenRouter"
        case .chatgpt: "ChatGPT"
        case .opencode: "OpenCode Zen"
        case .opencodeGo: "OpenCode Go"
        }
    }
}
