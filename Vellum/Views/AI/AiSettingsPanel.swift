import SwiftUI

/// Model catalogs shared between the in-panel AI settings and the Settings
/// window's AI tab so the two never drift.
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
    static let codex = ["gpt-5.5", "gpt-5.4-mini", "gpt-5.3-codex-spark"]

    static func models(for provider: AiProvider) -> [String] {
        switch provider {
        case .gemini: gemini
        case .openai: openAI
        case .codex: codex
        case .openrouter: []
        }
    }

    /// Unified options for the model selector. Built-in provider models are all
    /// vision- and tool-capable; OpenRouter models come from the live catalog.
    @MainActor
    static func options(for provider: AiProvider, catalog: OpenRouterCatalog) -> [AiModelOption] {
        if provider == .openrouter {
            return catalog.models.map {
                AiModelOption(
                    id: $0.id,
                    name: $0.name,
                    supportsVision: $0.supportsVision,
                    supportsTools: $0.supportsTools,
                    contextLength: $0.contextLength,
                    promptPrice: $0.promptPrice,
                    created: $0.created
                )
            }
        }
        return models(for: provider).map {
            AiModelOption(id: $0, name: $0, supportsVision: true, supportsTools: true,
                          contextLength: nil, promptPrice: nil, created: nil)
        }
    }
}

struct AiSettingsPanel: View {
    var onStopRecognition: () -> Void = {}

    @Environment(AiStore.self) private var aiStore
    @Environment(OpenRouterCatalog.self) private var openRouterCatalog
    @Environment(\.palette) private var palette

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            field("Provider") {
                Picker("", selection: providerBinding) {
                    Text("Gemini").tag(AiProvider.gemini)
                    Text("OpenAI API").tag(AiProvider.openai)
                    Text("OpenRouter").tag(AiProvider.openrouter)
                    Text("Codex CLI").tag(AiProvider.codex)
                }
                .labelsHidden()
            }

            if aiStore.settings.provider != .codex {
                field(keyFieldLabel) {
                    RevealableSecureField(placeholder: keyFieldPlaceholder, text: apiKeyBinding)
                        .id(aiStore.settings.provider)
                }
            }

            field("Model") {
                ModelSelector(
                    options: modelOptions,
                    selection: modelBinding,
                    pinned: pinnedBinding,
                    isLoading: aiStore.settings.provider == .openrouter && openRouterCatalog.isLoading,
                    onOpen: { if aiStore.settings.provider == .openrouter { Task { await openRouterCatalog.refresh() } } }
                )
                capabilityWarnings
            }

            field("Voice mode") {
                Picker("", selection: voiceBinding) {
                    Text("Off").tag(VoiceMode.off)
                    Text("Push-to-talk").tag(VoiceMode.pushToTalk)
                }
                .labelsHidden()
            }

            Toggle("Speak assistant responses (TTS)", isOn: ttsBinding)
                .toggleStyle(.checkbox)
                .foregroundStyle(palette.mutedForeground)
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

    private var modelOptions: [AiModelOption] {
        AiModelCatalog.options(for: aiStore.settings.provider, catalog: openRouterCatalog)
    }

    private var keyFieldLabel: String {
        switch aiStore.settings.provider {
        case .openai: "OpenAI API key"
        case .openrouter: "OpenRouter API key"
        default: "Gemini API key"
        }
    }

    private var keyFieldPlaceholder: String {
        switch aiStore.settings.provider {
        case .openai: "sk-..."
        case .openrouter: "sk-or-..."
        default: "AIza..."
        }
    }

    private var selectedOption: AiModelOption? {
        modelOptions.first { $0.id == modelBinding.wrappedValue }
    }

    @ViewBuilder
    private var capabilityWarnings: some View {
        if let option = selectedOption {
            if !option.supportsVision {
                warning("This model can't see the page image — answers about page contents may be less accurate.")
            }
            if !option.supportsTools {
                warning("This model can't run navigation, highlight, or note actions.")
            }
        }
    }

    private func warning(_ text: String) -> some View {
        HStack(alignment: .top, spacing: 4) {
            Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 9))
            Text(text)
        }
        .font(.system(size: 10))
        .foregroundStyle(palette.gold)
        .fixedSize(horizontal: false, vertical: true)
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
            get: {
                switch aiStore.settings.provider {
                case .openai: aiStore.settings.openaiApiKey
                case .openrouter: aiStore.settings.openrouterApiKey
                default: aiStore.settings.apiKey
                }
            },
            set: { value in
                var settings = aiStore.settings
                switch settings.provider {
                case .openai: settings.openaiApiKey = value
                case .openrouter: settings.openrouterApiKey = value
                default: settings.apiKey = value
                }
                aiStore.setSettings(settings)
            }
        )
    }

    private var modelBinding: Binding<String> {
        Binding(
            get: {
                switch aiStore.settings.provider {
                case .gemini: aiStore.settings.model
                case .openai: aiStore.settings.openaiModel
                case .codex: aiStore.settings.codexModel
                case .openrouter: aiStore.settings.openrouterModel
                }
            },
            set: { value in
                var settings = aiStore.settings
                switch settings.provider {
                case .gemini: settings.model = value
                case .openai: settings.openaiModel = value
                case .codex: settings.codexModel = value
                case .openrouter: settings.openrouterModel = value
                }
                aiStore.setSettings(settings)
            }
        )
    }

    private var pinnedBinding: Binding<[String]> {
        Binding(
            get: { aiStore.settings.pinnedModels },
            set: { value in
                var settings = aiStore.settings
                settings.pinnedModels = value
                aiStore.setSettings(settings)
            }
        )
    }

    private var voiceBinding: Binding<VoiceMode> {
        Binding(get: { aiStore.settings.voiceMode }, set: { value in
            if value != .pushToTalk { onStopRecognition() }
            var settings = aiStore.settings
            settings.voiceMode = value
            aiStore.setSettings(settings)
        })
    }

    private var ttsBinding: Binding<Bool> {
        Binding(get: { aiStore.settings.ttsEnabled }, set: { value in
            var settings = aiStore.settings
            settings.ttsEnabled = value
            aiStore.setSettings(settings)
        })
    }
}
