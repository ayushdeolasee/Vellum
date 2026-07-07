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
    /// Slugs valid on the ChatGPT-subscription Codex backend.
    static let chatgpt = ["gpt-5.5", "gpt-5.4", "gpt-5.4-mini", "gpt-5.3-codex", "gpt-5.2"]
    /// Curated vision- and tool-capable models on the OpenCode Zen gateway.
    static let opencode = [
        "claude-opus-4-8", "claude-sonnet-5", "claude-haiku-4-5",
        "gpt-5.5", "gpt-5.4", "gpt-5.4-mini",
        "gemini-3.1-pro", "gemini-3.5-flash", "gemini-3-flash",
    ]

    static func models(for provider: AiProvider) -> [String] {
        switch provider {
        case .gemini: gemini
        case .openai: openAI
        case .chatgpt: chatgpt
        case .opencode: opencode
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
                    completionPrice: $0.completionPrice,
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
                Picker("", selection: aiStore.providerBinding) {
                    ForEach(AiProviderOption.all) { option in
                        Text(option.label).tag(option.provider)
                    }
                }
                .labelsHidden()
            }

            if aiStore.settings.provider == .chatgpt {
                field("Account") { ChatGPTSignInControl() }
            } else {
                field(aiStore.keyFieldLabel) {
                    RevealableSecureField(placeholder: aiStore.keyFieldPlaceholder, text: aiStore.apiKeyBinding)
                        .id(aiStore.settings.provider)
                }
            }

            field("Model") {
                AiModelSelectorField()
                capabilityWarnings
            }

            field("Voice mode") {
                Picker("", selection: aiStore.voiceBinding(onStop: onStopRecognition)) {
                    Text("Off").tag(VoiceMode.off)
                    Text("Push-to-talk").tag(VoiceMode.pushToTalk)
                }
                .labelsHidden()
            }

            Toggle("Speak assistant responses (TTS)", isOn: aiStore.ttsBinding)
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

    @ViewBuilder
    private var capabilityWarnings: some View {
        if let option = aiStore.selectedOption(catalog: openRouterCatalog) {
            if !option.supportsVision {
                warning(AiCapabilityWarning.noVision)
            }
            if !option.supportsTools {
                warning(AiCapabilityWarning.noTools)
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
}

/// Shared model-row content embedded by both AI settings hosts (the in-panel
/// `AiSettingsPanel` and the Settings window's `AiSettingsTab`). Each host wraps
/// it in its own label container so the surrounding layout stays distinct.
struct AiModelSelectorField: View {
    @Environment(AiStore.self) private var aiStore
    @Environment(OpenRouterCatalog.self) private var openRouterCatalog

    var body: some View {
        ModelSelector(
            options: aiStore.modelOptions(catalog: openRouterCatalog),
            selection: aiStore.modelBinding,
            pinned: aiStore.pinnedBinding,
            isLoading: aiStore.settings.provider == .openrouter && openRouterCatalog.isLoading,
            onOpen: { if aiStore.settings.provider == .openrouter { Task { await openRouterCatalog.refresh() } } }
        )
    }
}

/// Capability-warning strings shared by both hosts so the copy never drifts.
/// Each host renders them with its own styling (custom HStack vs `Label`).
enum AiCapabilityWarning {
    static let noVision = "This model can't see the page image — answers about page contents may be less accurate."
    static let noTools = "This model can't run navigation, highlight, or note actions."
}

/// The provider list shared by both AI settings hosts so the picker never
/// drifts between the in-panel view and the Settings window.
struct AiProviderOption: Identifiable {
    let provider: AiProvider
    let label: String
    var id: String { provider.rawValue }

    static let all: [AiProviderOption] = [
        .init(provider: .gemini, label: "Gemini"),
        .init(provider: .openai, label: "OpenAI API"),
        .init(provider: .openrouter, label: "OpenRouter"),
        .init(provider: .chatgpt, label: "ChatGPT (Codex)"),
        .init(provider: .opencode, label: "OpenCode Zen"),
    ]
}

/// Sign-in / signed-in / sign-out control for the ChatGPT-subscription OAuth
/// provider, shared by both AI settings hosts. Replaces the API-key field, since
/// this provider authenticates via the browser rather than a pasted key.
struct ChatGPTSignInControl: View {
    @Environment(ChatGPTAuth.self) private var auth
    @Environment(\.palette) private var palette
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if auth.isSignedIn {
                HStack(spacing: 8) {
                    Image(systemName: "checkmark.seal.fill").foregroundStyle(.green)
                    Text(auth.accountLabel ?? "Signed in").lineLimit(1).truncationMode(.middle)
                    Spacer(minLength: 8)
                    Button("Sign out") { auth.signOut() }
                        .buttonStyle(.borderless)
                }
            } else {
                Button {
                    error = nil
                    Task {
                        do { try await auth.signIn() }
                        catch { self.error = error.localizedDescription }
                    }
                } label: {
                    HStack(spacing: 6) {
                        if auth.isAuthorizing { ProgressView().controlSize(.small) }
                        Text(auth.isAuthorizing ? "Waiting for browser…" : "Sign in with ChatGPT")
                    }
                }
                .disabled(auth.isAuthorizing)
            }
            if let error {
                Text(error)
                    .font(.system(size: 10))
                    .foregroundStyle(palette.gold)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

// MARK: - Shared AI settings plumbing

/// Bindings, labels, and model-option helpers shared by both AI settings hosts.
/// Kept on `AiStore` (rather than duplicated per view) so the two hosts can't
/// drift. All provider-dependent helpers read `settings.provider`.
extension AiStore {
    var providerBinding: Binding<AiProvider> {
        Binding(get: { self.settings.provider }, set: { value in
            var settings = self.settings
            settings.provider = value
            self.setSettings(settings)
        })
    }

    var apiKeyBinding: Binding<String> {
        Binding(
            get: {
                switch self.settings.provider {
                case .openai: self.settings.openaiApiKey
                case .openrouter: self.settings.openrouterApiKey
                case .opencode: self.settings.opencodeApiKey
                default: self.settings.apiKey
                }
            },
            set: { value in
                var settings = self.settings
                switch settings.provider {
                case .openai: settings.openaiApiKey = value
                case .openrouter: settings.openrouterApiKey = value
                case .opencode: settings.opencodeApiKey = value
                default: settings.apiKey = value
                }
                self.setSettings(settings)
            }
        )
    }

    var modelBinding: Binding<String> {
        Binding(
            get: {
                switch self.settings.provider {
                case .gemini: self.settings.model
                case .openai: self.settings.openaiModel
                case .openrouter: self.settings.openrouterModel
                case .chatgpt: self.settings.chatgptModel
                case .opencode: self.settings.opencodeModel
                }
            },
            set: { value in
                var settings = self.settings
                switch settings.provider {
                case .gemini: settings.model = value
                case .openai: settings.openaiModel = value
                case .openrouter: settings.openrouterModel = value
                case .chatgpt: settings.chatgptModel = value
                case .opencode: settings.opencodeModel = value
                }
                self.setSettings(settings)
            }
        )
    }

    var pinnedBinding: Binding<[String]> {
        Binding(
            get: { self.settings.pinnedModels },
            set: { value in
                var settings = self.settings
                settings.pinnedModels = value
                self.setSettings(settings)
            }
        )
    }

    /// Voice-mode binding. `onStop` fires when the mode leaves push-to-talk so
    /// the in-panel host can tear down an active recognition session; the
    /// Settings host passes the default no-op.
    func voiceBinding(onStop: @escaping () -> Void = {}) -> Binding<VoiceMode> {
        Binding(get: { self.settings.voiceMode }, set: { value in
            if value != .pushToTalk { onStop() }
            var settings = self.settings
            settings.voiceMode = value
            self.setSettings(settings)
        })
    }

    var ttsBinding: Binding<Bool> {
        Binding(get: { self.settings.ttsEnabled }, set: { value in
            var settings = self.settings
            settings.ttsEnabled = value
            self.setSettings(settings)
        })
    }

    var keyFieldLabel: String {
        switch settings.provider {
        case .openai: "OpenAI API key"
        case .openrouter: "OpenRouter API key"
        case .opencode: "OpenCode Zen API key"
        default: "Gemini API key"
        }
    }

    var keyFieldPlaceholder: String {
        switch settings.provider {
        case .openai: "sk-…"
        case .openrouter: "sk-or-…"
        case .opencode: "sk-…"
        default: "AIza…"
        }
    }

    func modelOptions(catalog: OpenRouterCatalog) -> [AiModelOption] {
        AiModelCatalog.options(for: settings.provider, catalog: catalog)
    }

    func selectedOption(catalog: OpenRouterCatalog) -> AiModelOption? {
        modelOptions(catalog: catalog).first { $0.id == modelBinding.wrappedValue }
    }
}
