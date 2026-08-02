import SwiftUI

/// App settings window (⌘, / Vellum ▸ Settings…). A durable macOS preferences
/// scene: a toolbar-style TabView whose tabs hold real, already-wired settings —
/// General (appearance), Reading (sidebar text size), Annotations (default
/// highlight color), and AI (provider / key / model / voice). New settings slot
/// into the matching tab instead of accreting in ad-hoc popovers.
struct SettingsView: View {
    /// #70: the selected tab is workspace state, not view state, so a caller
    /// that presents Settings for a *reason* — Home's gear button, "Configure
    /// AI…", a Storage warning — can route to the right tab instead of dumping
    /// the reader on General and making them find it.
    @Environment(WorkspaceStore.self) private var workspace

    var body: some View {
        @Bindable var workspace = workspace
        TabView(selection: $workspace.settingsSection) {
            GeneralSettingsTab()
                .tabItem { Label("General", systemImage: "gearshape") }
                .tag(WorkspaceStore.SettingsSection.general)

            ReadingSettingsTab()
                .tabItem { Label("Reading", systemImage: "text.book.closed") }
                .tag(WorkspaceStore.SettingsSection.reading)

            AnnotationsSettingsTab()
                .tabItem { Label("Annotations", systemImage: "highlighter") }
                .tag(WorkspaceStore.SettingsSection.annotations)

            AiSettingsTab()
                .tabItem { Label("AI", systemImage: "sparkles") }
                .tag(WorkspaceStore.SettingsSection.ai)

            StorageSettingsTab()
                .tabItem { Label("Storage", systemImage: "internaldrive") }
                .tag(WorkspaceStore.SettingsSection.storage)

            IntegrationsSettingsTab()
                .tabItem { Label("Integrations", systemImage: "link") }
                .tag(WorkspaceStore.SettingsSection.integrations)
        }
        .accessibilityIdentifier("settings.content")
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
    @Environment(WorkspaceStore.self) private var workspace
    #if os(iOS)
    @AppStorage("twoFingerNoteTap") private var twoFingerNoteTap = true
    @AppStorage(PencilDoubleTapAction.defaultsKey) private var pencilDoubleTap = PencilDoubleTapAction.eraser.rawValue
    @AppStorage(InkController_iOS.autoHideSidebarKey) private var autoHideSidebarWhileInking = true
    @AppStorage(InkController_iOS.scratchOutToEraseKey) private var scratchOutToErase = true
    #endif

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
                Toggle("Scribble to erase", isOn: $scratchOutToErase)
            } header: {
                Text("Apple Pencil")
            } footer: {
                Text("What double-tapping a supported Apple Pencil does while inking — toggle the eraser, or switch back to your last tool. Auto-hiding the sidebar collapses the annotation panel so the ink tools get the full page width. Scribbling back and forth over your own handwriting with the pen deletes it, without switching to the eraser.")
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
    @Environment(ChatGPTAuth.self) private var chatGPTAuth
    @State private var validationState: AiConnectionValidationState = .idle

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
                        RevealableSecureField(
                            accessibilityLabel: aiStore.keyFieldLabel,
                            placeholder: aiStore.keyFieldPlaceholder,
                            text: aiStore.apiKeyBinding
                        )
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
                LabeledContent("Configuration") {
                    Text(configurationSummary)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.trailing)
                        .accessibilityIdentifier("ai.configurationSummary")
                }
                HStack {
                    Button("Validate Connection") {
                        validationState = .checking
                        let settings = aiStore.settings
                        let signedIn = chatGPTAuth.isSignedIn
                        let provider = settings.provider
                        let model = aiStore.activeModelName
                        let credential = aiStore.apiKeyBinding.wrappedValue
                        Task {
                            let result = await AiConnectionValidator.validate(
                                settings: settings,
                                chatGPTSignedIn: signedIn
                            )
                            guard aiStore.settings.provider == provider,
                                  aiStore.activeModelName == model,
                                  aiStore.apiKeyBinding.wrappedValue == credential,
                                  chatGPTAuth.isSignedIn == signedIn else { return }
                            validationState = result
                        }
                    }
                    .disabled(validationState == .checking || !canValidate)
                    .accessibilityIdentifier("ai.validateConnection")
                    validationLabel
                }
            } header: {
                Text("Assistant")
            }
        }
        .formStyle(.grouped)
        .scrollDisabled(true)
        .onChange(of: aiStore.settings.provider) { _, _ in validationState = .idle }
        .onChange(of: aiStore.activeModelName) { _, _ in validationState = .idle }
        .onChange(of: aiStore.apiKeyBinding.wrappedValue) { _, _ in validationState = .idle }
        .onChange(of: chatGPTAuth.isSignedIn) { _, _ in validationState = .idle }
    }

    private var canValidate: Bool {
        aiStore.settings.provider == .chatgpt ? chatGPTAuth.isSignedIn : !aiStore.apiKeyBinding.wrappedValue.isEmpty
    }

    private var configurationSummary: String {
        let provider = AiProviderOption.all.first { $0.provider == aiStore.settings.provider }?.label
            ?? aiStore.settings.provider.rawValue
        let credential = aiStore.settings.provider == .chatgpt
            ? (chatGPTAuth.isSignedIn ? "signed in" : "not signed in")
            : (aiStore.apiKeyBinding.wrappedValue.isEmpty ? "credential missing" : "credential saved")
        return "\(provider) · \(aiStore.activeModelName) · \(credential)"
    }

    @ViewBuilder
    private var validationLabel: some View {
        switch validationState {
        case .idle:
            if !canValidate {
                Text(aiStore.settings.provider == .chatgpt ? "Sign in to validate" : "Add a credential to validate")
                    .foregroundStyle(.secondary)
            }
        case .checking:
            ProgressView("Checking…").controlSize(.small)
        case .valid:
            Label("Connection verified", systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
        case .invalid(let message):
            Label(message, systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(palette.gold)
        }
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

enum AiConnectionValidationState: Equatable {
    case idle
    case checking
    case valid
    case invalid(String)
}

enum AiConnectionValidator {
    static func request(settings: AiSettings) -> URLRequest? {
        let key: String
        let urlString: String
        switch settings.provider {
        case .gemini:
            key = settings.apiKey
            urlString = "https://generativelanguage.googleapis.com/v1beta/models?pageSize=1"
        case .openai:
            key = settings.openaiApiKey
            urlString = "https://api.openai.com/v1/models"
        case .openrouter:
            key = settings.openrouterApiKey
            urlString = "https://openrouter.ai/api/v1/auth/key"
        case .opencode:
            key = settings.opencodeApiKey
            urlString = "https://opencode.ai/zen/v1/models"
        case .opencodeGo:
            key = settings.opencodeGoApiKey
            urlString = "https://opencode.ai/zen/go/v1/models"
        case .chatgpt:
            return nil
        }
        guard !key.isEmpty, let url = URL(string: urlString) else { return nil }
        var request = URLRequest(url: url)
        request.timeoutInterval = 15
        if settings.provider == .gemini {
            request.setValue(key, forHTTPHeaderField: "x-goog-api-key")
        } else {
            request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        }
        return request
    }

    static func validate(
        settings: AiSettings,
        chatGPTSignedIn: Bool,
        session: URLSession = .shared
    ) async -> AiConnectionValidationState {
        if settings.provider == .chatgpt {
            return chatGPTSignedIn ? .valid : .invalid("ChatGPT is not signed in")
        }
        guard let request = request(settings: settings) else {
            return .invalid("Credential is missing")
        }
        do {
            let (_, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                return .invalid("The provider returned an invalid response")
            }
            switch http.statusCode {
            case 200..<300: return .valid
            case 401, 403: return .invalid("Credential was rejected")
            case 429: return .invalid("Provider is reachable but rate limited")
            default: return .invalid("Provider returned HTTP \(http.statusCode)")
            }
        } catch {
            return .invalid("Couldn’t reach the provider")
        }
    }
}
