import Foundation

enum VellumPrivacyPolicy {
    static let url = URL(string: "https://ayushdeolasee.github.io/Vellum/privacy.html")!
}

/// Permission to send document content to an AI provider.
///
/// The version is part of the key so a future material change to the purpose or
/// data categories asks again without trying to migrate an older permission.
enum AiSharingConsent {
    static let disclosureVersion = 1

    static func isGranted(for provider: AiProvider) -> Bool {
        AppDefaults.current.bool(forKey: key(for: provider))
    }

    static func grant(for provider: AiProvider) {
        AppDefaults.current.set(true, forKey: key(for: provider))
    }

    static func revoke(for provider: AiProvider) {
        AppDefaults.current.removeObject(forKey: key(for: provider))
    }

    static func revokeAll() {
        for provider in AiProvider.allCases {
            revoke(for: provider)
        }
    }

    static var hasAnyGranted: Bool {
        AiProvider.allCases.contains(where: isGranted)
    }

    private static func key(for provider: AiProvider) -> String {
        "vellum.ai-sharing-consent.v\(disclosureVersion).\(provider.rawValue)"
    }
}

extension AiProvider {
    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .gemini: "Google Gemini"
        case .openai: "OpenAI API"
        case .openrouter: "OpenRouter"
        case .opencode: "OpenCode Zen"
        case .opencodeGo: "OpenCode Go"
        }
    }

    var privacyPolicyURL: URL {
        switch self {
        case .gemini: URL(string: "https://ai.google.dev/gemini-api/terms")!
        case .openai: URL(string: "https://openai.com/policies/privacy-policy/")!
        case .openrouter: URL(string: "https://openrouter.ai/privacy")!
        case .opencode, .opencodeGo:
            URL(string: "https://opencode.ai/legal/privacy-policy")!
        }
    }

    var currentDataRulesURL: URL? {
        switch self {
        case .opencode: URL(string: "https://opencode.ai/docs/zen/")!
        case .opencodeGo: URL(string: "https://opencode.ai/docs/go/")!
        default: nil
        }
    }

    func dataHandlingSummary(model: String) -> String {
        switch self {
        case .gemini:
            "Google says unpaid Gemini API content outside the EEA, Switzerland, and the UK may be reviewed by people and used to improve Google products and models. Paid-project content is not used for product improvement, but Google may retain it for abuse prevention and legal duties."
        case .openai:
            "OpenAI says API content is not used to train its models by default. Its default abuse-monitoring logs may keep prompts, responses, and related metadata for up to 30 days, with documented legal and safety exceptions."
        case .openrouter:
            "OpenRouter forwards the request to the provider for \(model). OpenRouter says prompt logging and product-improvement use are off by default, but it stores request metadata. The selected model provider may have different retention and training rules."
        case .opencode:
            "OpenCode routes \(model) through its Zen gateway to a model provider in the United States. Retention and training rules vary by model. Some free models may use content for improvement, and OpenCode's general privacy policy also applies."
        case .opencodeGo:
            "OpenCode routes \(model) through its Go gateway to a model provider. Its current model table says Go content is not used for training, but retention varies by model from zero to 30 days. OpenCode's general privacy policy also applies."
        }
    }
}
