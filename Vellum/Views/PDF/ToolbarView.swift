import AppKit
import SwiftUI
import UniformTypeIdentifiers

// Native unified-toolbar content (Liquid Glass on macOS 26+). Groups are
// separated with ToolbarSpacer so each cluster reads as its own glass pod.
struct VellumToolbar: ToolbarContent {
    @Environment(AppStore.self) private var appStore

    private var isWeb: Bool { appStore.document?.kind == .web }
    private var hasDocument: Bool { appStore.document != nil }

    var body: some ToolbarContent {
        // ControlGroup merges related buttons into one shared glass capsule —
        // left to their own devices, macOS 26 gives every button its own
        // circle with no gap, which reads as a squished blob.
        ToolbarItemGroup(placement: .navigation) {
            ControlGroup {
                OpenFileButton()
                AddWebpageButton()
                if hasDocument, !isWeb {
                    SaveButton()
                }
            }
            if hasDocument, isWeb {
                ControlGroup {
                    WebHistoryButtons()
                }
            }
        }

        if hasDocument {
            // Web pages scroll continuously — page numbers are meaningless
            // there, so the page cluster is PDF-only.
            if !isWeb {
                ToolbarItemGroup {
                    PageControls()
                }
                ToolbarSpacer(.fixed)
            }

            ToolbarItemGroup {
                ControlGroup {
                    ZoomControls()
                }
            }

            // Flexible spacers center the address pod in the free space,
            // Safari-style, instead of leaving one dead gap at the trailing
            // edge. Everything stays in .automatic placement — mixing in
            // .primaryAction scatters items mid-bar on macOS 26.
            ToolbarSpacer(.flexible)

            // The address pill is its own item: nesting a hand-drawn capsule
            // inside the icon pod produced capsule-in-capsule seams and left
            // the trailing button with mismatched corner rounding.
            ToolbarItem {
                DocumentTitleField()
            }
            ToolbarSpacer(.fixed)
            ToolbarItemGroup {
                BookmarkButton()
                NoteToolToggle()
                if isWeb {
                    WebLibraryControls()
                }
            }

            ToolbarSpacer(.flexible)
        } else {
            ToolbarSpacer(.flexible)
        }

        ToolbarItemGroup {
            UpdateControls()
        }

        if hasDocument {
            ToolbarSpacer(.fixed)
            ToolbarItem {
                SidebarToggleButton()
            }
        }
    }
}

// MARK: - File / web entry points

private struct OpenFileButton: View {
    @Environment(AppStore.self) private var appStore

    var body: some View {
        Button(action: openFiles) {
            Label("Open file", systemImage: "folder")
        }
        .help("Open file (⌘O) — open a PDF or .vellumweb archive in a new tab")
    }

    private func openFiles() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        var types: [UTType] = [.pdf]
        if let archive = UTType(filenameExtension: "vellumweb") { types.append(archive) }
        panel.allowedContentTypes = types
        guard panel.runModal() == .OK else { return }
        Task { await appStore.openFiles(paths: panel.urls.map(\.path)) }
    }
}

private struct AddWebpageButton: View {
    var body: some View {
        Button {
            NotificationCenter.default.post(name: .vellumAddWebpage, object: nil)
        } label: {
            Label("Add webpage", systemImage: "globe")
        }
        .help("Add webpage (⌘L) — open an article URL in reading mode")
    }
}

/// Sheet for the Add Webpage flow (⌘L). A popover anchored to the toolbar
/// button could detach and land at the edge of another display — see the
/// audit's P0 "Add Webpage popover" finding. A sheet is always centered over
/// the owning window, so it can't escape onto another screen. It also sidesteps
/// the @FocusState-in-NSToolbar gotcha since the field now lives in a normal
/// window-hosted view instead of a toolbar item.
struct AddWebpageSheet: View {
    @Environment(AppStore.self) private var appStore
    @Environment(\.dismiss) private var dismiss

    @State private var urlInput = ""
    @FocusState private var fieldFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Add Webpage")
                .font(.headline)
            Text("Paste an article URL to open it in reading mode.")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
            TextField("https://…", text: $urlInput)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 13))
                .focused($fieldFocused)
                .onSubmit(submit)
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Open", action: submit)
                    .buttonStyle(.glassProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(urlInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 380)
        .onAppear {
            urlInput = ""
            fieldFocused = true
        }
    }

    private func submit() {
        let value = urlInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return }
        dismiss()
        Task { await appStore.openUrl(value) }
    }
}

private struct SaveButton: View {
    @Environment(AppStore.self) private var appStore

    var body: some View {
        Button {
            guard let sessionId = appStore.activeTabId else { return }
            Task { try? await appStore.sessions.saveFile(sessionId: sessionId) }
        } label: {
            Label("Save", systemImage: "square.and.arrow.down")
        }
        .help("Save (⌘S) — write annotations into the PDF file")
    }
}

/// In-page history for web tabs (window.__webHistory in the original).
private struct WebHistoryButtons: View {
    var body: some View {
        Button {
            go(-1)
        } label: {
            Label("Back", systemImage: "arrow.left")
        }
        .help("Back — go to the previous page in this tab's history")

        Button {
            go(1)
        } label: {
            Label("Forward", systemImage: "arrow.right")
        }
        .help("Forward — go to the next page in this tab's history")
    }

    private func go(_ delta: Int) {
        NotificationCenter.default.post(
            name: .vellumWebHistory, object: nil, userInfo: ["delta": delta])
    }
}

// MARK: - Page navigation

private struct PageControls: View {
    @Environment(AppStore.self) private var appStore

    @State private var pageInput = "1"
    @FocusState private var fieldFocused: Bool

    var body: some View {
        ControlGroup {
            Button {
                appStore.goToPage(appStore.currentPage - 1)
            } label: {
                Label("Previous page", systemImage: "chevron.left")
            }
            .disabled(appStore.currentPage <= 1)
            .help("Previous page — or type a page number in the field")

            Button {
                appStore.goToPage(appStore.currentPage + 1)
            } label: {
                Label("Next page", systemImage: "chevron.right")
            }
            .disabled(appStore.currentPage >= appStore.numPages)
            .help("Next page — or type a page number in the field")
        }

        HStack(spacing: 5) {
            TextField("", text: $pageInput)
                .textFieldStyle(.roundedBorder)
                .multilineTextAlignment(.center)
                .focused($fieldFocused)
                // Commit directly on Return — FocusState changes are unreliable
                // inside NSToolbar-hosted fields, so blur alone can't be trusted.
                .onSubmit { commitPageInput(); fieldFocused = false }
                .onChange(of: fieldFocused) { _, focused in
                    if !focused { commitPageInput() }
                }
                .frame(width: 44)
            Text("/ \(appStore.numPages)")
                .monospacedDigit()
                .foregroundStyle(.secondary)
        }
        .font(.system(size: 12))
        .onChange(of: appStore.currentPage) { _, page in
            pageInput = String(page)
        }
        // Restored sessions start on last_page — sync on tab/doc switch too.
        .task(id: DocumentKey(appStore)) {
            pageInput = String(appStore.currentPage)
        }
    }

    private func commitPageInput() {
        guard let page = Int(pageInput), (1...appStore.numPages).contains(page) else {
            pageInput = String(appStore.currentPage)
            return
        }
        appStore.goToPage(page)
    }
}

// MARK: - Zoom

private struct ZoomControls: View {
    @Environment(AppStore.self) private var appStore

    var body: some View {
        Button {
            appStore.zoomOut()
        } label: {
            Label("Zoom out", systemImage: "minus.magnifyingglass")
        }
        .help("Zoom out (⌘−)")

        Button(action: resetZoom) {
            Text("\(Int((appStore.zoom * 100).rounded()))%")
                .font(.system(size: 12))
                .monospacedDigit()
                .frame(minWidth: 40)
        }
        .help("Reset zoom to 100%")
        .accessibilityLabel("Reset zoom to 100%")

        Button {
            appStore.zoomIn()
        } label: {
            Label("Zoom in", systemImage: "plus.magnifyingglass")
        }
        .help("Zoom in (⌘+)")
    }

    private func resetZoom() {
        if let zoomToHandler = appStore.zoomToHandler {
            zoomToHandler(1)
        } else {
            appStore.setZoom(1)
        }
    }
}

// MARK: - Annotation tools

private struct BookmarkButton: View {
    @Environment(AppStore.self) private var appStore
    @Environment(AnnotationStore.self) private var annotationStore
    @Environment(\.palette) private var palette

    private var isWeb: Bool { appStore.document?.kind == .web }
    private var isBookmarked: Bool {
        findCurrentBookmark(
            annotations: annotationStore.annotations,
            docKind: appStore.document?.kind,
            currentPage: appStore.currentPage,
            webVisibleBookmarks: appStore.webVisibleBookmarks
        ) != nil
    }

    var body: some View {
        Button {
            Task { await annotationStore.toggleBookmark() }
        } label: {
            Label(
                isBookmarked ? "Remove bookmark" : "Bookmark",
                systemImage: isBookmarked ? "bookmark.fill" : "bookmark"
            )
            .foregroundStyle(isBookmarked ? AnyShapeStyle(palette.gold) : AnyShapeStyle(.primary))
        }
        .help(
            isBookmarked
                ? "Remove bookmark (⌘D)"
                : (isWeb
                    ? "Bookmark this spot (⌘D) — saves your reading position"
                    : "Bookmark this page (⌘D) — saves it in the annotations panel"))
    }
}

private struct NoteToolToggle: View {
    @Environment(AppStore.self) private var appStore

    private var isWeb: Bool { appStore.document?.kind == .web }

    var body: some View {
        Toggle(
            isOn: Binding(
                get: { appStore.mode == .note },
                set: { appStore.setMode($0 ? .note : .view) }
            )
        ) {
            Label("Sticky note tool", systemImage: "note.text")
        }
        .toggleStyle(.button)
        .help(
            isWeb
                ? "Sticky note tool (N) — click in the page to attach a note to the text there"
                : "Sticky note tool (N) — click on the page to place a note")
    }
}

// MARK: - Web library / export

private struct WebLibraryControls: View {
    @Environment(AppStore.self) private var appStore
    @Environment(AiStore.self) private var aiStore
    @Environment(\.palette) private var palette

    private enum ExportState: Equatable {
        case idle
        case exporting
        case done(String)
        case failed(String)
    }

    @State private var pageSaved = false
    @State private var exportState: ExportState = .idle

    var body: some View {
        Button(action: toggleSavedPage) {
            Label(
                pageSaved ? "Saved to library" : "Save page to library",
                systemImage: "archivebox"
            )
            .foregroundStyle(pageSaved ? AnyShapeStyle(palette.primary) : AnyShapeStyle(.primary))
        }
        .help(
            pageSaved
                ? "Saved to library — click to remove"
                : "Save page to library (keeps an offline snapshot)")

        Button(action: exportVellumweb) {
            if exportState == .exporting {
                ProgressView()
                    .controlSize(.small)
            } else {
                Label("Export", systemImage: "square.and.arrow.up")
                    .foregroundStyle(exportIconStyle)
            }
        }
        .disabled(exportState == .exporting)
        .help(exportTooltip)
        .task(id: DocumentKey(appStore)) {
            exportState = .idle
            await loadSavedState(for: DocumentKey(appStore))
        }
    }

    private var exportTooltip: String {
        switch exportState {
        case .idle: return "Export as .vellumweb (portable archive with snapshot + annotations)"
        case .exporting: return "Exporting…"
        case .done(let detail): return detail
        case .failed(let message): return message
        }
    }

    private var exportIconStyle: AnyShapeStyle {
        switch exportState {
        case .done: return AnyShapeStyle(.green)
        case .failed: return AnyShapeStyle(palette.destructive)
        default: return AnyShapeStyle(.primary)
        }
    }

    private func loadSavedState(for identity: DocumentKey) async {
        pageSaved = false
        guard let sessionId = appStore.activeTabId else { return }
        let saved = (try? await appStore.sessions.getWebpageSaved(sessionId: sessionId)) ?? false
        if DocumentKey(appStore) == identity {
            pageSaved = saved
        }
    }

    private func toggleSavedPage() {
        guard let sessionId = appStore.activeTabId else { return }
        let next = !pageSaved
        pageSaved = next
        Task {
            do {
                try await appStore.sessions.setWebpageSaved(sessionId: sessionId, saved: next)
            } catch {
                if appStore.activeTabId == sessionId { pageSaved = !next }
            }
        }
    }

    /// Export the active webpage as a .vellumweb archive (Toolbar.tsx export flow).
    private func exportVellumweb() {
        guard exportState != .exporting,
              let sessionId = appStore.activeTabId,
              appStore.document?.kind == .web else { return }

        let slug = slugifiedTitle()
        let panel = NSSavePanel()
        if let archive = UTType(filenameExtension: "vellumweb") {
            panel.allowedContentTypes = [archive]
        }
        panel.nameFieldStringValue = "\(slug).vellumweb"
        guard panel.runModal() == .OK, let destination = panel.url else { return }

        let pages = aiStore.pageTexts
            .sorted { $0.key < $1.key }
            .map { WebPageText(number: $0.key, text: $0.value) }
        let identity = DocumentKey(appStore)
        exportState = .exporting
        Task {
            do {
                let summary = try await appStore.sessions.exportVellumweb(
                    sessionId: sessionId, destPath: destination.path, pages: pages)
                guard DocumentKey(appStore) == identity else { return }
                let mb = String(format: "%.2f", Double(summary.bytes) / (1024 * 1024))
                let skipped = summary.assetsSkipped > 0 ? ", \(summary.assetsSkipped) skipped" : ""
                exportState = .done("Exported \(mb) MB (\(summary.assetCount) assets\(skipped))")
            } catch {
                guard DocumentKey(appStore) == identity else { return }
                exportState = .failed(error.localizedDescription)
            }
        }
    }

    /// Slug for the export default filename: lowercased title, non-alphanumeric
    /// runs collapsed to "-", trimmed, max 60 chars, fallback "article".
    private func slugifiedTitle() -> String {
        let title = appStore.document?.title ?? ""
        var slug = ""
        var lastWasDash = false
        for scalar in title.lowercased().unicodeScalars {
            if (scalar.value >= 97 && scalar.value <= 122)
                || (scalar.value >= 48 && scalar.value <= 57) {
                slug.unicodeScalars.append(scalar)
                lastWasDash = false
            } else if !lastWasDash, !slug.isEmpty {
                slug.append("-")
                lastWasDash = true
            }
        }
        while slug.hasSuffix("-") { slug.removeLast() }
        if slug.count > 60 {
            slug = String(slug.prefix(60))
            while slug.hasSuffix("-") { slug.removeLast() }
        }
        return slug.isEmpty ? "article" : slug
    }
}

/// Safari-style address field: shows the page URL for web tabs (click copies
/// it, double-click exports the archive) or the file name for PDFs
/// (double-click = Save As, retargeting the tab to the new location).
private struct DocumentTitleField: View {
    @Environment(AppStore.self) private var appStore
    @Environment(AiStore.self) private var aiStore

    /// Transient status text shown in place of the title (e.g. "URL copied").
    @State private var feedback: String?
    @State private var feedbackTask: Task<Void, Never>?

    private var isWeb: Bool { appStore.document?.kind == .web }

    var body: some View {
        Text(feedback ?? displayText)
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .truncationMode(.tail)
            .padding(.horizontal, 12)
            .frame(maxWidth: .infinity, minHeight: 30, alignment: .center)
            .background(.quaternary.opacity(0.5), in: Capsule())
            .contentShape(Capsule())
            .frame(minWidth: 200, idealWidth: isWeb ? 420 : 300, maxWidth: isWeb ? 420 : 300)
            .help(helpText)
            .onTapGesture(count: 2) { saveAs() }
            .onTapGesture { if isWeb { copyURL() } }
    }

    private var displayText: String {
        guard let path = appStore.document?.pdfPath else { return "" }
        if isWeb {
            if path.hasPrefix("https://") { return String(path.dropFirst(8)) }
            if path.hasPrefix("http://") { return String(path.dropFirst(7)) }
            return path
        }
        return (path as NSString).lastPathComponent
    }

    private var helpText: String {
        let path = appStore.document?.pdfPath ?? ""
        return isWeb
            ? "\(path) — click to copy, double-click to export a copy"
            : "\(path) — double-click to change where the file is saved"
    }

    private func showFeedback(_ text: String) {
        feedbackTask?.cancel()
        feedback = text
        feedbackTask = Task {
            try? await Task.sleep(for: .seconds(1.4))
            guard !Task.isCancelled else { return }
            feedback = nil
        }
    }

    private func copyURL() {
        guard let path = appStore.document?.pdfPath else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(path, forType: .string)
        showFeedback("URL copied")
    }

    private func saveAs() {
        if isWeb {
            exportWebArchive()
        } else {
            savePdfAs()
        }
    }

    /// Save As for PDFs: flush annotations, copy the file, retarget the tab.
    private func savePdfAs() {
        guard let sessionId = appStore.activeTabId,
              let sourcePath = appStore.document?.pdfPath else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.pdf]
        panel.nameFieldStringValue = (sourcePath as NSString).lastPathComponent
        guard panel.runModal() == .OK, let destination = panel.url else { return }
        let destPath = destination.path
        guard destPath != sourcePath else { return }
        Task {
            do {
                try await appStore.sessions.saveFile(sessionId: sessionId)
                if FileManager.default.fileExists(atPath: destPath) {
                    try FileManager.default.removeItem(atPath: destPath)
                }
                try FileManager.default.copyItem(atPath: sourcePath, toPath: destPath)
                await appStore.closeTab(sessionId)
                await appStore.openFile(path: destPath)
            } catch {
                showFeedback("Save failed")
            }
        }
    }

    /// Double-click on a web tab: export the snapshot archive to a chosen spot.
    private func exportWebArchive() {
        guard let sessionId = appStore.activeTabId else { return }
        let panel = NSSavePanel()
        if let archive = UTType(filenameExtension: "vellumweb") {
            panel.allowedContentTypes = [archive]
        }
        panel.nameFieldStringValue = "article.vellumweb"
        guard panel.runModal() == .OK, let destination = panel.url else { return }
        let pages = aiStore.pageTexts
            .sorted { $0.key < $1.key }
            .map { WebPageText(number: $0.key, text: $0.value) }
        Task {
            do {
                _ = try await appStore.sessions.exportVellumweb(
                    sessionId: sessionId, destPath: destination.path, pages: pages)
                showFeedback("Exported")
            } catch {
                showFeedback("Export failed")
            }
        }
    }
}

// MARK: - Updates / theme / sidebar

private struct UpdateControls: View {
    @State private var updateChecker = UpdateChecker()

    var body: some View {
        if updateChecker.state == .available,
           let version = updateChecker.availableVersion {
            Button(action: updateChecker.install) {
                Label("Update \(version)", systemImage: "arrow.down")
                    .font(.system(size: 12, weight: .medium))
            }
            .buttonStyle(.glassProminent)
            .tint(.green)
            .help(updateChecker.tooltip)
            .accessibilityLabel(updateChecker.tooltip)
        }

        Button {
            Task { await updateChecker.check() }
        } label: {
            if updateChecker.state == .checking {
                ProgressView()
                    .controlSize(.small)
            } else {
                Label("Check for updates", systemImage: "arrow.clockwise")
            }
        }
        .disabled(updateChecker.state == .checking)
        .help("Check for updates — \(updateChecker.tooltip)")
        .task {
            await updateChecker.check(silent: true)
        }
    }
}

private struct SidebarToggleButton: View {
    @Environment(AppStore.self) private var appStore

    var body: some View {
        Button {
            appStore.sidebarOpen.toggle()
        } label: {
            Label(
                appStore.sidebarOpen ? "Hide side panel" : "Show side panel",
                systemImage: "sidebar.trailing")
        }
        .help(
            appStore.sidebarOpen
                ? "Hide side panel (⌘⌥S)"
                : "Show side panel (⌘⌥S) — annotations and AI chat")
    }
}

/// Identity of the active document — toolbar state (page field, export, saved
/// flag) resets whenever the tab or backing file changes.
private struct DocumentKey: Hashable {
    var tabId: String?
    var path: String?

    @MainActor
    init(_ appStore: AppStore) {
        tabId = appStore.activeTabId
        path = appStore.document?.pdfPath
    }
}
