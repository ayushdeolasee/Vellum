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

    @State private var webEntries: [WebLibrary.SnapshotStorageEntry] = []
    @State private var isLoadingWeb = true
    @State private var pendingWebDelete: WebLibrary.SnapshotStorageEntry?
    @State private var confirmingWebRemoveAll = false

    @State private var storageMode: WebStorageMode = .local
    @State private var autoSavePages = false

    var body: some View {
        Form {
            storageLocationSection

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

            Section {
                Toggle("Automatically save every page for offline use", isOn: autoSaveBinding)
                    .accessibilityIdentifier("storage.autoSavePages")
                LabeledContent("Total size") {
                    Text(webTotalBytes.formatted(.byteCount(style: .file)))
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
                Button("Remove all…", role: .destructive) {
                    confirmingWebRemoveAll = true
                }
                .disabled(webEntries.isEmpty)
                .accessibilityIdentifier("storage.webRemoveAll")
            } header: {
                Text("Downloaded web pages")
            } footer: {
                Text("Vellum keeps an offline copy of each web page you open so it loads without a connection and the AI can read it. Copies of pages you never saved or annotated are removed automatically after six months — with automatic saving on, every page you open is kept until you remove it. Removing a copy never affects your saved-pages list, highlights, or notes.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            Section {
                if isLoadingWeb {
                    ProgressView()
                        .frame(maxWidth: .infinity, alignment: .center)
                } else if webEntries.isEmpty {
                    Text("No downloaded pages")
                        .foregroundStyle(.secondary)
                        .id("storage.webEmpty")
                } else {
                    ForEach(webEntries) { entry in
                        WebStorageRow(entry: entry) { pendingWebDelete = entry }
                    }
                }
            } header: {
                Text("Pages with offline copies")
            }
        }
        .formStyle(.grouped)
        .frame(height: 460)
        .task {
            refreshStorageSettings()
            await reload()
        }
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
        .confirmationDialog(
            pendingWebDelete.map { "Remove the offline copy of \"\($0.displayTitle)\"?" } ?? "",
            isPresented: webDeleteDialogBinding,
            presenting: pendingWebDelete
        ) { entry in
            Button("Remove Offline Copy", role: .destructive) {
                deleteWeb(entry)
            }
            .accessibilityIdentifier("storage.confirmWebDelete")
            Button("Cancel", role: .cancel) {}
        } message: { _ in
            Text("This removes only the downloaded offline copy — your saved-pages list, highlights, and notes are not affected. Vellum downloads a fresh copy the next time you open this page.")
        }
        .confirmationDialog(
            "Remove all offline copies?",
            isPresented: $confirmingWebRemoveAll
        ) {
            Button("Remove All Offline Copies", role: .destructive) {
                removeAllWeb()
            }
            .accessibilityIdentifier("storage.confirmWebRemoveAll")
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This removes the downloaded copy of every web page. Your saved-pages list, highlights, and notes are not affected — pages just load from the network (and re-download) the next time you open them.")
        }
    }

    // MARK: - Storage location

    @ViewBuilder
    private var storageLocationSection: some View {
        Section {
            Picker("Location", selection: locationBinding) {
                Text("iCloud Drive").tag(WebStorageMode.icloud)
                Text("Custom Folder").tag(WebStorageMode.custom)
                Text("This Mac").tag(WebStorageMode.local)
            }
            .accessibilityIdentifier("storage.locationPicker")

            if storageMode != .local, let path = currentLocationPath {
                LabeledContent("Folder") {
                    Text(path)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Button("Show in Finder") {
                    NSWorkspace.shared.activateFileViewerSelecting(
                        [URL(fileURLWithPath: path, isDirectory: true)])
                }
                .accessibilityIdentifier("storage.showInFinder")
            }
            if storageMode == .custom {
                Button("Change Folder…") {
                    guard let path = WebStorageRelocator.pickCustomFolder() else { return }
                    WebStorageRelocator.apply(mode: .custom, customPath: path)
                    refreshStorageSettings()
                }
                .accessibilityIdentifier("storage.changeFolder")
            }
        } header: {
            Text("Storage location")
        } footer: {
            Text(locationFooterText)
                .font(.footnote)
                .foregroundStyle(WebStorageSettings.modeIsDegraded ? .orange : Color.secondary)
        }
    }

    private var currentLocationPath: String? {
        switch storageMode {
        case .icloud: return WebStorageSettings.icloudVellumRoot?.path
        case .custom: return UserDefaults.standard.string(forKey: WebStorageSettings.customPathKey)
        case .local: return nil
        }
    }

    private var locationFooterText: String {
        if WebStorageSettings.modeIsDegraded {
            switch storageMode {
            case .icloud:
                return "iCloud Drive isn't available right now (signed out, or iCloud Drive is off). Vellum is storing everything on this Mac until it comes back."
            case .custom:
                return "The chosen folder can't be found. Vellum is storing everything on this Mac until you pick a folder again."
            case .local:
                return ""
            }
        }
        switch storageMode {
        case .icloud:
            return "Everything — offline copies, highlights, notes, and reading positions — lives in iCloud Drive ▸ Vellum and syncs across your Macs."
        case .custom:
            return "Offline copies live in your folder. iCloud syncing is not available for a custom folder: highlights, notes, and reading positions stay on this Mac."
        case .local:
            return "Everything stays in Vellum's private app folder on this Mac. No syncing."
        }
    }

    private var locationBinding: Binding<WebStorageMode> {
        Binding(
            get: { storageMode },
            set: { newMode in
                guard newMode != storageMode else { return }
                switch newMode {
                case .custom:
                    // Cancelling the folder picker leaves the mode unchanged.
                    guard let path = WebStorageRelocator.pickCustomFolder() else { return }
                    WebStorageRelocator.apply(mode: .custom, customPath: path)
                case .icloud:
                    guard WebStorageSettings.icloudVellumRoot != nil else { return }
                    WebStorageRelocator.apply(mode: .icloud)
                case .local:
                    WebStorageRelocator.apply(mode: .local)
                }
                refreshStorageSettings()
                // The move runs in the background; refresh the listings once
                // it has had a moment to relocate the artifacts.
                Task {
                    try? await Task.sleep(for: .seconds(1))
                    await reload()
                }
            }
        )
    }

    private var autoSaveBinding: Binding<Bool> {
        Binding(
            get: { autoSavePages },
            set: { on in
                autoSavePages = on
                WebStorageSettings.setAutoSavePages(on)
            }
        )
    }

    private func refreshStorageSettings() {
        storageMode = WebStorageSettings.chosenMode ?? .local
        autoSavePages = WebStorageSettings.autoSavePages
    }

    private var totalBytes: Int64 {
        entries.reduce(0) { $0 + $1.byteSize }
    }

    private var webTotalBytes: Int64 {
        webEntries.reduce(0) { $0 + $1.byteSize }
    }

    /// Drive the per-row dialog off `pendingDelete`: dismiss clears the pending
    /// entry so a re-tap re-presents it.
    private var deleteDialogBinding: Binding<Bool> {
        Binding(
            get: { pendingDelete != nil },
            set: { if !$0 { pendingDelete = nil } }
        )
    }

    private var webDeleteDialogBinding: Binding<Bool> {
        Binding(
            get: { pendingWebDelete != nil },
            set: { if !$0 { pendingWebDelete = nil } }
        )
    }

    private func reload() async {
        isLoading = true
        entries = await PageTextCache.shared.listEntries()
        isLoading = false
        isLoadingWeb = true
        webEntries = await Self.listWebStorage()
        isLoadingWeb = false
    }

    /// WebLibrary's listing walks the store directory and stats archive dirs —
    /// keep it off the main thread (same reason PageTextCache is an actor).
    private static func listWebStorage() async -> [WebLibrary.SnapshotStorageEntry] {
        await Task.detached(priority: .userInitiated) {
            WebLibrary.listSnapshotStorage()
        }.value
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

    private func deleteWeb(_ entry: WebLibrary.SnapshotStorageEntry) {
        webEntries.removeAll { $0.key == entry.key }
        Task {
            await Task.detached(priority: .userInitiated) {
                WebLibrary.removeLocalSnapshots(forKey: entry.key)
            }.value
            webEntries = await Self.listWebStorage()
        }
    }

    private func removeAllWeb() {
        webEntries = []
        Task {
            await Task.detached(priority: .userInitiated) {
                WebLibrary.removeAllSnapshotArtifacts()
            }.value
            webEntries = await Self.listWebStorage()
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

/// One downloaded web page: title (or URL), last-opened recency, whether the
/// user saved it, artifact size, and a destructive per-row remove. Mirrors
/// `StorageCacheRow` so the Storage tab reads as one system.
private struct WebStorageRow: View {
    let entry: WebLibrary.SnapshotStorageEntry
    let onDelete: () -> Void

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(entry.displayTitle)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(statusText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Text(entry.byteSize.formatted(.byteCount(style: .file)))
                .font(.callout)
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .accessibilityIdentifier("webStorageRow.size.\(entry.key)")

            Button(role: .destructive, action: onDelete) {
                Image(systemName: "trash")
            }
            .buttonStyle(.borderless)
            .help("Remove offline copy")
            .accessibilityLabel("Remove offline copy of \(entry.displayTitle)")
            .accessibilityIdentifier("webStorageRow.delete.\(entry.key)")
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("webStorageRow.\(entry.key)")
    }

    private var statusText: String {
        let opened = entry.lastOpened?.formatted(.relative(presentation: .named)) ?? "—"
        return "\(opened) · \(entry.saved ? "Saved" : "Not saved")"
    }
}
