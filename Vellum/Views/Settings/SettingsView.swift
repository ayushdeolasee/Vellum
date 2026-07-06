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
        #if os(macOS)
        // Fixed-width settings window on macOS; on iPad the sheet fills its
        // presentation and the TabView renders as a bottom tab bar.
        .frame(width: 480)
        #endif
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
                Text(systemFooter)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .scrollDisabled(true)
    }

    private var systemFooter: String {
        #if os(macOS)
        "System follows macOS and updates live when you change appearance in Control Center."
        #else
        "System follows iPadOS and updates live when you change appearance in Control Center."
        #endif
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
    #if os(iOS)
    @AppStorage("twoFingerNoteTap") private var twoFingerNoteTap = true
    @AppStorage(PencilDoubleTapAction.defaultsKey) private var pencilDoubleTap = PencilDoubleTapAction.eraser.rawValue
    @AppStorage(InkController_iOS.autoHideSidebarKey) private var autoHideSidebarWhileInking = true
    #endif

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

            #if os(iOS)
            Section {
                Toggle("Two-finger double-tap adds a note", isOn: $twoFingerNoteTap)
            } header: {
                Text("Gestures")
            } footer: {
                Text("Double-tap the page with two fingers to add a sticky note at that spot.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            Section {
                Picker("Double-tap action", selection: $pencilDoubleTap) {
                    ForEach(PencilDoubleTapAction.allCases, id: \.rawValue) { action in
                        Text(action.label).tag(action.rawValue)
                    }
                }
                .pickerStyle(.segmented)
                Toggle("Auto-hide sidebar while inking", isOn: $autoHideSidebarWhileInking)
            } header: {
                Text("Apple Pencil")
            } footer: {
                Text("What double-tapping a supported Apple Pencil does while inking — toggle the eraser, or switch back to your last tool. Auto-hiding the sidebar collapses the annotation panel so the ink tools get the full page width.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            #endif
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

    var body: some View {
        Form {
            Section {
                Picker("Provider", selection: providerBinding) {
                    Text("Gemini").tag(AiProvider.gemini)
                    Text("OpenAI API").tag(AiProvider.openai)
                    Text("Codex CLI").tag(AiProvider.codex)
                }

                if aiStore.settings.provider != .codex {
                    SecureField(
                        aiStore.settings.provider == .openai ? "OpenAI API key" : "Gemini API key",
                        text: apiKeyBinding,
                        prompt: Text(aiStore.settings.provider == .openai ? "sk-…" : "AIza…")
                    )
                }

                Picker("Model", selection: modelBinding) {
                    ForEach(models, id: \.self) { Text($0).tag($0) }
                }
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
