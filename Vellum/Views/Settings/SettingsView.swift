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

// MARK: - Storage

/// Manages the on-disk extracted-text cache (`PageTextCache`): shows total size,
/// a per-document breakdown sorted by size, and destructive controls to clear
/// one document's cached text or all of it. Unlike its sibling tabs this one
/// scrolls — the document list can grow unbounded — so it is height-bounded and
/// deliberately does NOT set `.scrollDisabled(true)`.
private struct StorageSettingsTab: View {
    @Environment(\.palette) private var palette

    @State private var entries: [PageTextCacheEntry] = []
    @State private var isLoading = true
    @State private var pendingDelete: PageTextCacheEntry?
    @State private var confirmingEraseAll = false

    var body: some View {
        Form {
            Section {
                LabeledContent("Total cache size") {
                    Text(totalBytes.formatted(.byteCount(style: .file)))
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
                Button("Erase all…", role: .destructive) {
                    confirmingEraseAll = true
                }
                .disabled(entries.isEmpty)
                .accessibilityIdentifier("storage.eraseAll")
            } header: {
                Text("Extracted-text cache")
            } footer: {
                Text("Vellum caches each PDF's extracted text so the AI assistant and search start instantly. It's rebuilt automatically the next time you open a document.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            Section {
                if isLoading {
                    ProgressView()
                        .frame(maxWidth: .infinity, alignment: .center)
                } else if entries.isEmpty {
                    Text("No cached documents")
                        .foregroundStyle(.secondary)
                        .id("storage.empty")
                } else {
                    ForEach(entries) { entry in
                        StorageCacheRow(entry: entry) { pendingDelete = entry }
                    }
                }
            } header: {
                Text("Cached documents")
            }
        }
        .formStyle(.grouped)
        .frame(height: 460)
        .task { await reload() }
        .confirmationDialog(
            pendingDelete.map { "Delete cached text for \"\($0.displayTitle)\"?" } ?? "",
            isPresented: deleteDialogBinding,
            presenting: pendingDelete
        ) { entry in
            Button("Delete Cached Text", role: .destructive) {
                delete(entry)
            }
            .accessibilityIdentifier("storage.confirmDelete")
            Button("Cancel", role: .cancel) {}
        } message: { _ in
            Text("This removes only the extracted-text cache Vellum uses to speed up AI and search. Your notes, highlights, and AI conversations are not affected. The text is rebuilt automatically the next time you open this document.")
        }
        .confirmationDialog(
            "Erase all cached text?",
            isPresented: $confirmingEraseAll
        ) {
            Button("Erase All Cached Text", role: .destructive) {
                eraseAll()
            }
            .accessibilityIdentifier("storage.confirmEraseAll")
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This clears the extracted-text cache for every document. Your notes, highlights, and AI conversations are not affected — only cached text is removed, and it's rebuilt automatically the next time you open each document.")
        }
    }

    private var totalBytes: Int64 {
        entries.reduce(0) { $0 + $1.byteSize }
    }

    /// Drive the per-row dialog off `pendingDelete`: dismiss clears the pending
    /// entry so a re-tap re-presents it.
    private var deleteDialogBinding: Binding<Bool> {
        Binding(
            get: { pendingDelete != nil },
            set: { if !$0 { pendingDelete = nil } }
        )
    }

    private func reload() async {
        isLoading = true
        entries = await PageTextCache.shared.listEntries()
        isLoading = false
    }

    // Optimistic local removal for immediate feedback, then a reload once the
    // actor finishes — reconciling with disk in case a still-open document's
    // persister recreated its entry (allowed; it re-persists harmlessly).
    private func delete(_ entry: PageTextCacheEntry) {
        entries.removeAll { $0.pathKey == entry.pathKey }
        Task {
            await PageTextCache.shared.delete(pathKey: entry.pathKey)
            entries = await PageTextCache.shared.listEntries()
        }
    }

    private func eraseAll() {
        entries = []
        Task {
            await PageTextCache.shared.deleteAll()
            entries = await PageTextCache.shared.listEntries()
        }
    }
}

/// One cached document: title, when it was last opened, completeness (or a
/// "source missing" hint that never triggers deletion), cache size, and a
/// destructive per-row delete.
private struct StorageCacheRow: View {
    @Environment(\.palette) private var palette

    let entry: PageTextCacheEntry
    let onDelete: () -> Void

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(entry.displayTitle)
                    .lineLimit(1)
                    .truncationMode(.middle)
                statusLine
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Text(entry.byteSize.formatted(.byteCount(style: .file)))
                .font(.callout)
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .accessibilityIdentifier("storageRow.size.\(entry.pathKey)")

            Button(role: .destructive, action: onDelete) {
                Image(systemName: "trash")
            }
            .buttonStyle(.borderless)
            .help("Delete cached text")
            .accessibilityLabel("Delete cached text for \(entry.displayTitle)")
            .accessibilityIdentifier("storageRow.delete.\(entry.pathKey)")
        }
        // .contain (not .combine): merging would swallow the delete button
        // into one opaque element, unreachable for VoiceOver and UI tests.
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("storageRow.\(entry.pathKey)")
    }

    @ViewBuilder
    private var statusLine: some View {
        let opened = entry.lastOpened.formatted(.relative(presentation: .named))
        if entry.sourceExists {
            Text("\(opened) · \(entry.isComplete ? "Complete" : "Partial")")
        } else {
            HStack(spacing: 4) {
                Text("\(opened) · ")
                Label("Original file not found", systemImage: "questionmark.circle")
                    .foregroundStyle(palette.gold)
            }
        }
    }
}
