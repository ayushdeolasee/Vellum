import AppKit
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

            StorageSettingsTab()
                .tabItem { Label("Storage", systemImage: "internaldrive") }
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
    @Environment(WorkspaceStore.self) private var workspace

    var body: some View {
        Form {
            Section {
                Slider(
                    value: fontSizeBinding,
                    in: WorkspaceStore.minSidebarFontSize...WorkspaceStore.maxSidebarFontSize,
                    step: 1
                ) {
                    Text("Sidebar text size")
                } minimumValueLabel: {
                    Text("A").font(.system(size: 10))
                } maximumValueLabel: {
                    Text("A").font(.system(size: 16))
                }
                LabeledContent("Current size") {
                    Text("\(Int(workspace.sidebarFontSize)) pt")
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
            get: { workspace.sidebarFontSize },
            set: { workspace.sidebarFontSize = $0 }
        )
    }
}

// MARK: - Annotations

private struct AnnotationsSettingsTab: View {
    @Environment(WorkspaceStore.self) private var workspace
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
        let selected = workspace.defaultHighlightColor.caseInsensitiveCompare(color.value) == .orderedSame
        return Button {
            workspace.defaultHighlightColor = color.value
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
                Picker("Provider", selection: aiStore.providerBinding) {
                    ForEach(AiProviderOption.all) { option in
                        Text(option.label).tag(option.provider)
                    }
                }

                if aiStore.settings.provider == .chatgpt {
                    LabeledContent("Account") { ChatGPTSignInControl() }
                } else {
                    LabeledContent(aiStore.keyFieldLabel) {
                        RevealableSecureField(placeholder: aiStore.keyFieldPlaceholder, text: aiStore.apiKeyBinding)
                            .id(aiStore.settings.provider)
                    }
                }

                LabeledContent("Model") {
                    AiModelSelectorField()
                }
                capabilityWarnings
                Picker("Thinking", selection: aiStore.reasoningBinding) {
                    ForEach(AiThinkingMode.allCases, id: \.self) { mode in
                        Text(mode.label).tag(mode)
                    }
                }
            } header: {
                Text("Assistant")
            }

            Section {
                Picker("Voice mode", selection: aiStore.voiceBinding()) {
                    Text("Off").tag(VoiceMode.off)
                    Text("Push-to-talk").tag(VoiceMode.pushToTalk)
                }
                Toggle("Speak assistant responses (TTS)", isOn: aiStore.ttsBinding)
            } header: {
                Text("Voice")
            }
        }
        .formStyle(.grouped)
        .scrollDisabled(true)
    }

    @ViewBuilder
    private var capabilityWarnings: some View {
        if let option = aiStore.selectedOption(catalog: openRouterCatalog) {
            if !option.supportsVision {
                Label(AiCapabilityWarning.noVision, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(palette.gold)
            }
            if !option.supportsTools {
                Label(AiCapabilityWarning.noTools, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(palette.gold)
            }
        }
    }
}
