#if os(iOS)
import SwiftUI

/// Root shell for the iPad app. Empty state shows the full-screen library;
/// once documents are open it becomes a tabbed reader with a Liquid Glass
/// toolbar, tab strip, find bar, and an adaptive inspector sidebar.
struct ContentView_iOS: View {
    @Environment(AppStore.self) private var appStore
    @Environment(AnnotationStore.self) private var annotationStore
    @Environment(AiStore.self) private var aiStore
    @Environment(ThemeStore.self) private var themeStore
    @Environment(\.palette) private var palette
    @Environment(\.colorScheme) private var colorScheme

    @State private var addWebpagePresented = false

    var body: some View {
        Group {
            if appStore.tabs.isEmpty {
                WelcomeLibrary_iOS(
                    onOpen: { presentImporter() },
                    onAddWebpage: { addWebpagePresented = true }
                )
            } else {
                TabbedShell_iOS(
                    onOpenFile: { presentImporter() },
                    onAddWebpage: { addWebpagePresented = true }
                )
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(palette.background.ignoresSafeArea())
        // Warm the document-picker subsystem shortly after launch so the first
        // "Open a PDF" tap doesn't pay the multi-second service-discovery cost.
        .task {
            try? await Task.sleep(for: .seconds(1))
            DocumentPickerCoordinator_iOS.shared.prewarm()
        }
        .sheet(isPresented: $addWebpagePresented) {
            AddWebpageSheet_iOS { url in
                Task { await appStore.openUrl(url) }
            }
        }
        // Reload annotations + AI context on document identity change, mirroring
        // the macOS ContentView.
        .task(id: documentIdentity) {
            annotationStore.clearAnnotations()
            aiStore.clearDocumentContext()
            guard appStore.document?.pdfPath != nil else { return }
            await annotationStore.loadAnnotations()
            guard !Task.isCancelled else { return }
            aiStore.loadConversationForDocument(appStore.document)
        }
        .onReceive(NotificationCenter.default.publisher(for: .vellumAnnotationsUpdated)) { _ in
            guard appStore.document != nil else { return }
            Task { await annotationStore.loadAnnotations() }
        }
        // Keyboard-shortcut routing (VellumCommands_iOS): ⌘O opens the file
        // importer, ⌘L presents the add-webpage sheet — both reach the shell
        // here since a Commands struct can't drive this view's presentation.
        .onReceive(NotificationCenter.default.publisher(for: .vellumOpenFile)) { _ in
            presentImporter()
        }
        .onReceive(NotificationCenter.default.publisher(for: .vellumAddWebpage)) { _ in
            addWebpagePresented = true
        }
        .onChange(of: colorScheme, initial: true) { _, scheme in
            themeStore.systemAppearanceChanged(isDark: scheme == .dark)
        }
        #if DEBUG
        .task { await autoOpenForTesting() }
        #endif
    }

    private func presentImporter() {
        DocumentPickerCoordinator_iOS.shared.present { urls in
            let paths = DocumentImport.importPicked(urls)
            guard !paths.isEmpty else { return }
            Task { await appStore.openFiles(paths: paths) }
        }
    }

    private var documentIdentity: String {
        "\(appStore.activeTabId ?? "none")|\(appStore.document?.pdfPath ?? "none")"
    }

    #if DEBUG
    private func autoOpenForTesting() async {
        guard appStore.document == nil, appStore.tabs.isEmpty else { return }
        if let url = ProcessInfo.processInfo.environment["VELLUM_AUTOOPEN_URL"] {
            await appStore.openUrl(url)
            return
        }
        guard let path = ProcessInfo.processInfo.environment["VELLUM_AUTOOPEN_PDF"],
              FileManager.default.fileExists(atPath: path) else { return }
        let paths = DocumentImport.importPicked([URL(fileURLWithPath: path)])
        guard !paths.isEmpty else { return }
        await appStore.openFiles(paths: paths)
    }
    #endif
}

// MARK: - Tabbed reader shell

private struct TabbedShell_iOS: View {
    var onOpenFile: () -> Void
    var onAddWebpage: () -> Void

    @Environment(AppStore.self) private var appStore
    @Environment(\.palette) private var palette
    @State private var ink = InkController_iOS()

    var body: some View {
        VStack(spacing: 0) {
            TabStrip_iOS(onNewTab: { appStore.newStartTab() })

            if appStore.document == nil {
                // Active start tab: the library, inside the tabbed shell.
                WelcomeLibrary_iOS(onOpen: onOpenFile, onAddWebpage: onAddWebpage, compact: true)
            } else {
                PdfToolbar_iOS(ink: ink, onOpenFile: onOpenFile, onAddWebpage: onAddWebpage)

                if appStore.findVisible {
                    FindBar()
                }

                documentViewer
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .ignoresSafeArea(edges: .bottom)
            }
        }
        .inspector(isPresented: inspectorPresented) {
            SidebarContent_iOS(ink: ink)
                .inspectorColumnWidth(min: 280, ideal: 360, max: 560)
        }
        #if DEBUG
        .task(id: appStore.activeTabId) {
            if ProcessInfo.processInfo.environment["VELLUM_AUTOINK"] != nil,
               appStore.document?.kind == .pdf {
                // Wait for the viewer's load() to adopt the document (it resets
                // ink.isActive = false when it finishes, so a fixed delay races
                // a slow cold launch), then activate past that reset.
                for _ in 0..<40 where ink.pdfController?.document == nil {
                    try? await Task.sleep(for: .milliseconds(250))
                }
                try? await Task.sleep(for: .milliseconds(500))
                guard !Task.isCancelled else { return }
                ink.isActive = true
            }
        }
        #endif
    }

    @ViewBuilder
    private var documentViewer: some View {
        if appStore.document?.kind == .web {
            WebViewerView_iOS()
                .id(appStore.activeTabId)
        } else {
            PdfViewerView_iOS(ink: ink)
                .id(appStore.activeTabId)
        }
    }

    private var inspectorPresented: Binding<Bool> {
        Binding(
            get: { appStore.document != nil && appStore.sidebarOpen },
            set: { appStore.sidebarOpen = $0 }
        )
    }
}

// MARK: - Add webpage sheet

struct AddWebpageSheet_iOS: View {
    var onSubmit: (String) -> Void

    @Environment(\.dismiss) private var dismiss
    @Environment(\.palette) private var palette
    @State private var url = ""
    @FocusState private var focused: Bool

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 14) {
                Text("Enter a URL to read it in Vellum. The page is captured for offline reading and annotation.")
                    .font(.subheadline)
                    .foregroundStyle(palette.mutedForeground)
                TextField("https://example.com", text: $url)
                    .textFieldStyle(.roundedBorder)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .keyboardType(.URL)
                    .font(.system(size: 17))
                    .focused($focused)
                    .onSubmit(submit)
                Spacer()
            }
            .padding(20)
            .navigationTitle("Add Webpage")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Open", action: submit)
                        .disabled(url.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            .onAppear { focused = true }
        }
        .presentationDetents([.medium])
    }

    private func submit() {
        let trimmed = url.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        onSubmit(trimmed)
        dismiss()
    }
}
#endif
