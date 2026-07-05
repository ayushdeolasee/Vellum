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
        }
    }
}

struct AiSettingsPanel: View {
    var onStopRecognition: () -> Void = {}

    @Environment(AiStore.self) private var aiStore
    @Environment(\.palette) private var palette

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            field("Provider") {
                Picker("", selection: providerBinding) {
                    Text("Gemini").tag(AiProvider.gemini)
                    Text("OpenAI API").tag(AiProvider.openai)
                    Text("Codex CLI").tag(AiProvider.codex)
                }
                .labelsHidden()
            }

            if aiStore.settings.provider != .codex {
                field(aiStore.settings.provider == .openai ? "OpenAI API key" : "Gemini API key") {
                    SecureField(
                        aiStore.settings.provider == .openai ? "sk-..." : "AIza...",
                        text: apiKeyBinding
                    )
                    .textFieldStyle(.roundedBorder)
                    .controlSize(.small)
                }
            }

            field("Model") {
                Picker("", selection: modelBinding) {
                    ForEach(models, id: \.self) { Text($0).tag($0) }
                }
                .labelsHidden()
            }

            field("Voice mode") {
                Picker("", selection: voiceBinding) {
                    Text("Off").tag(VoiceMode.off)
                    Text("Push-to-talk").tag(VoiceMode.pushToTalk)
                }
                .labelsHidden()
            }

            Toggle("Speak assistant responses (TTS)", isOn: ttsBinding)
                #if os(macOS)
                .toggleStyle(.checkbox)
                #else
                .toggleStyle(.switch)
                #endif
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
                case .openai: aiStore.settings.openaiModel
                case .codex: aiStore.settings.codexModel
                }
            },
            set: { value in
                var settings = aiStore.settings
                switch settings.provider {
                case .gemini: settings.model = value
                case .openai: settings.openaiModel = value
                case .codex: settings.codexModel = value
                }
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
