import SwiftUI

/// App settings window (⌘, / Vellum ▸ Settings…). A durable macOS preferences
/// scene: a toolbar-style TabView whose tabs hold real, already-wired settings —
/// General (appearance), Reading (sidebar text size), Annotations (default
/// highlight color), and AI (provider / key / model / voice). New settings slot
/// into the matching tab instead of accreting in ad-hoc popovers.
struct SettingsView: View {
    var body: some View {
        TabView {
            GeneralSettingsTab()
                .tabItem { Label("General", systemImage: "gearshape") }

            ReadingSettingsTab()
                .tabItem { Label("Reading", systemImage: "text.book.closed") }

            AnnotationsSettingsTab()
                .tabItem { Label("Annotations", systemImage: "highlighter") }

            AiSettingsTab()
                .tabItem { Label("AI", systemImage: "sparkles") }
        }
        .frame(width: 480)
    }
}

// MARK: - General

private struct GeneralSettingsTab: View {
    @Environment(ThemeStore.self) private var themeStore

    var body: some View {
        Form {
            Section {
                Picker("Appearance", selection: themeBinding) {
                    ForEach(AppTheme.allCases, id: \.self) { theme in
                        Text(theme.label).tag(theme)
                    }
                }
                .pickerStyle(.segmented)
            } footer: {
                Text("System follows macOS and updates live when you change appearance in Control Center.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .scrollDisabled(true)
    }

    private var themeBinding: Binding<AppTheme> {
        Binding(
            get: { themeStore.theme },
            set: { themeStore.setTheme($0) }
        )
    }
}

// MARK: - Reading

private struct ReadingSettingsTab: View {
    @Environment(AppStore.self) private var appStore

    var body: some View {
        Form {
            Section {
                Slider(
                    value: fontSizeBinding,
                    in: AppStore.minSidebarFontSize...AppStore.maxSidebarFontSize,
                    step: 1
                ) {
                    Text("Sidebar text size")
                } minimumValueLabel: {
                    Text("A").font(.system(size: 10))
                } maximumValueLabel: {
                    Text("A").font(.system(size: 16))
                }
                LabeledContent("Current size") {
                    Text("\(Int(appStore.sidebarFontSize)) pt")
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
            } header: {
                Text("Sidebar")
            } footer: {
                Text("Sets the text size for annotation and AI panels. Adjust on the fly with ⌘+ / ⌘− while the pointer is over the panel.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .scrollDisabled(true)
    }

    private var fontSizeBinding: Binding<Double> {
        Binding(
            get: { appStore.sidebarFontSize },
            set: { appStore.sidebarFontSize = $0 }
        )
    }
}

// MARK: - Annotations

private struct AnnotationsSettingsTab: View {
    @Environment(AppStore.self) private var appStore
    @Environment(\.palette) private var palette

    var body: some View {
        Form {
            Section {
                LabeledContent("Default highlight") {
                    HStack(spacing: 8) {
                        ForEach(HIGHLIGHT_COLORS) { color in
                            swatch(color)
                        }
                    }
                }
            } header: {
                Text("Highlights")
            } footer: {
                Text("New highlights made without picking a color — including ones the AI assistant and saved webpages create — use this color.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .scrollDisabled(true)
    }

    private func swatch(_ color: HighlightColor) -> some View {
        let selected = appStore.defaultHighlightColor.caseInsensitiveCompare(color.value) == .orderedSame
        return Button {
            appStore.defaultHighlightColor = color.value
        } label: {
            Circle()
                .fill(Color(hex: color.value))
                .frame(width: 22, height: 22)
                .overlay {
                    Circle().strokeBorder(
                        selected ? palette.primary : palette.borderStrong,
                        lineWidth: selected ? 2.5 : 1
                    )
                }
        }
        .buttonStyle(.plain)
        .help(color.name)
        .accessibilityLabel(color.name)
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
    }
}

// MARK: - AI

private struct AiSettingsTab: View {
    @Environment(AiStore.self) private var aiStore
    @Environment(OpenRouterCatalog.self) private var openRouterCatalog
    @Environment(\.palette) private var palette

    var body: some View {
        Form {
            Section {
                Picker("Provider", selection: providerBinding) {
                    Text("Gemini").tag(AiProvider.gemini)
                    Text("OpenAI API").tag(AiProvider.openai)
                    Text("OpenRouter").tag(AiProvider.openrouter)
                    Text("Codex CLI").tag(AiProvider.codex)
                }

                if aiStore.settings.provider != .codex {
                    LabeledContent(keyFieldLabel) {
                        RevealableSecureField(placeholder: keyFieldPlaceholder, text: apiKeyBinding)
                            .id(aiStore.settings.provider)
                    }
                }

                LabeledContent("Model") {
                    ModelSelector(
                        options: modelOptions,
                        selection: modelBinding,
                        pinned: pinnedBinding,
                        isLoading: aiStore.settings.provider == .openrouter && openRouterCatalog.isLoading,
                        onOpen: { if aiStore.settings.provider == .openrouter { Task { await openRouterCatalog.refresh() } } }
                    )
                }
                capabilityWarnings
            } header: {
                Text("Assistant")
            }

            Section {
                Picker("Voice mode", selection: voiceBinding) {
                    Text("Off").tag(VoiceMode.off)
                    Text("Push-to-talk").tag(VoiceMode.pushToTalk)
                }
                Toggle("Speak assistant responses (TTS)", isOn: ttsBinding)
            } header: {
                Text("Voice")
            }
        }
        .formStyle(.grouped)
        .scrollDisabled(true)
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
        case .openai: "sk-…"
        case .openrouter: "sk-or-…"
        default: "AIza…"
        }
    }

    private var selectedOption: AiModelOption? {
        modelOptions.first { $0.id == modelBinding.wrappedValue }
    }

    @ViewBuilder
    private var capabilityWarnings: some View {
        if let option = selectedOption {
            if !option.supportsVision {
                Label("This model can't see the page image — answers about page contents may be less accurate.", systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(palette.gold)
            }
            if !option.supportsTools {
                Label("This model can't run navigation, highlight, or note actions.", systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(palette.gold)
            }
        }
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
