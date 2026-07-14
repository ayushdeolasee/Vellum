import SwiftUI

/// Model catalogs shared between the in-panel AI settings and the Settings
/// window's AI tab so the two never drift.
///
/// The catalog *data* + `supportsVision` (used by the AI send path) is complete
/// for every provider. The Phase-1 settings UI only surfaces the two API-key
/// providers (Gemini, OpenAI) in its pickers; the OpenRouter / ChatGPT /
/// OpenCode selectors and `options(for:catalog:)` (which needs `AiModelOption`)
/// ship with the AI-UI rewrite (ModelSelector) in Phase 2.
enum AiModelCatalog {
    static let gemini = [
        "gemini-3.1-flash-lite-preview", "gemini-3-pro-preview", "gemini-3-flash-preview",
        "gemini-2.5-pro", "gemini-2.5-flash", "gemini-2.5-flash-lite",
        "gemini-2.0-flash", "gemini-2.0-flash-lite", "gemini-1.5-pro", "gemini-1.5-flash",
    ]
    static let openAI = [
        "gpt-5.5", "gpt-5.5-2026-04-23", "gpt-5.4-mini", "gpt-5.4",
        "gpt-5", "gpt-5-mini", "gpt-4.1", "gpt-4.1-mini",
    ]
    /// Slugs valid on the ChatGPT-subscription Codex backend.
    static let chatgpt = ["gpt-5.5", "gpt-5.4", "gpt-5.4-mini", "gpt-5.3-codex", "gpt-5.2"]
    /// Models on the OpenCode **Zen** gateway: proprietary flagships plus the
    /// open-weight and free models Zen also hosts. See `opencodeGo` for the
    /// separate Go gateway.
    static let opencode = [
        "claude-opus-4-8", "claude-sonnet-5", "claude-haiku-4-5",
        "gpt-5.5", "gpt-5.4", "gpt-5.4-mini",
        "gemini-3.1-pro", "gemini-3.5-flash", "gemini-3-flash",
        "deepseek-v4-pro", "deepseek-v4-flash",
        "glm-5.2", "glm-5.1", "glm-5",
        "kimi-k2.7-code", "kimi-k2.6", "kimi-k2.5",
        "minimax-m3", "minimax-m2.7", "minimax-m2.5",
        "qwen3.6-plus", "qwen3.5-plus",
        "big-pickle", "deepseek-v4-flash-free", "mimo-v2.5-free",
        "hy3-free", "nemotron-3-ultra-free", "north-mini-code-free",
    ]
    /// Models on the OpenCode **Go** gateway — low-cost open coding models,
    /// authenticated with a Go-specific API key that is separate from Zen's.
    static let opencodeGo = [
        "glm-5.2", "glm-5.1", "glm-5",
        "kimi-k2.7-code", "kimi-k2.6", "kimi-k2.5",
        "deepseek-v4-pro", "deepseek-v4-flash",
        "qwen3.7-max", "qwen3.7-plus", "qwen3.6-plus", "qwen3.5-plus",
        "minimax-m3", "minimax-m2.7", "minimax-m2.5",
        "mimo-v2-pro", "mimo-v2-omni", "mimo-v2.5-pro", "mimo-v2.5",
        "hy3-preview",
    ]

    /// Vision-capable model ids across both OpenCode gateways. Everything else is
    /// treated as text-only, so the page image is withheld.
    private static let opencodeVisionModels: Set<String> = [
        "claude-opus-4-8", "claude-sonnet-5", "claude-haiku-4-5",
        "gpt-5.5", "gpt-5.4", "gpt-5.4-mini",
        "gemini-3.1-pro", "gemini-3.5-flash", "gemini-3-flash",
        "mimo-v2-omni",
    ]

    /// Whether an OpenCode (Zen or Go) model can accept the page image.
    static func opencodeSupportsVision(_ model: String) -> Bool {
        opencodeVisionModels.contains(model)
    }

    /// Whether `model` on `provider` accepts image inputs. Single source of truth
    /// for the send path (which withholds images from text-only models) and for
    /// the composer's image-attach affordances. Unknown OpenRouter ids (catalog
    /// still loading, or a stale pick) stay permissive.
    @MainActor
    static func supportsVision(provider: AiProvider, model: String, catalog: OpenRouterCatalog?) -> Bool {
        switch provider {
        case .openrouter: catalog?.model(for: model)?.supportsVision ?? true
        case .opencode, .opencodeGo: opencodeSupportsVision(model)
        case .gemini, .openai, .chatgpt: true
        }
    }

    static func models(for provider: AiProvider) -> [String] {
        switch provider {
        case .gemini: gemini
        case .openai: openAI
        case .chatgpt: chatgpt
        case .opencode: opencode
        case .opencodeGo: opencodeGo
        case .openrouter: []
        }
    }
}

struct AiSettingsPanel: View {
    @Environment(AiStore.self) private var aiStore
    @Environment(\.palette) private var palette

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            field("Provider") {
                Picker("", selection: providerBinding) {
                    Text("Gemini").tag(AiProvider.gemini)
                    Text("OpenAI API").tag(AiProvider.openai)
                }
                .labelsHidden()
            }

            field(aiStore.settings.provider == .openai ? "OpenAI API key" : "Gemini API key") {
                SecureField(
                    aiStore.settings.provider == .openai ? "sk-..." : "AIza...",
                    text: apiKeyBinding
                )
                .textFieldStyle(.roundedBorder)
                .controlSize(.small)
            }

            field("Model") {
                Picker("", selection: modelBinding) {
                    ForEach(models, id: \.self) { Text($0).tag($0) }
                }
                .labelsHidden()
            }
        }
        .font(.system(size: 12))
        .padding(12)
        .background(palette.surfaceMuted)
        .overlay(alignment: .bottom) { Rectangle().fill(palette.border).frame(height: 1) }
    }

    private func field<Content: View>(_ label: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label).foregroundStyle(palette.mutedForeground)
            content().frame(maxWidth: .infinity)
        }
    }

    private var models: [String] {
        AiModelCatalog.models(for: aiStore.settings.provider)
    }

    private var providerBinding: Binding<AiProvider> {
        Binding(get: { aiStore.settings.provider }, set: { value in
            var settings = aiStore.settings
            settings.provider = value
            aiStore.setSettings(settings)
        })
    }

    private var apiKeyBinding: Binding<String> {
        Binding(
            get: { aiStore.settings.provider == .openai ? aiStore.settings.openaiApiKey : aiStore.settings.apiKey },
            set: { value in
                var settings = aiStore.settings
                if settings.provider == .openai { settings.openaiApiKey = value } else { settings.apiKey = value }
                aiStore.setSettings(settings)
            }
        )
    }

    private var modelBinding: Binding<String> {
        Binding(
            get: {
                switch aiStore.settings.provider {
                case .gemini: aiStore.settings.model
                default: aiStore.settings.openaiModel
                }
            },
            set: { value in
                var settings = aiStore.settings
                switch settings.provider {
                case .gemini: settings.model = value
                default: settings.openaiModel = value
                }
                aiStore.setSettings(settings)
            }
        )
    }
}
