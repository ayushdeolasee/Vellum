import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct ToolbarView: View {
    var sidebarOpen: Bool? = nil
    var onToggleSidebar: (() -> Void)? = nil

    @Environment(AppStore.self) private var appStore
    @Environment(AnnotationStore.self) private var annotationStore
    @Environment(AiStore.self) private var aiStore
    @Environment(\.palette) private var palette

    private enum ExportState: Equatable {
        case idle
        case exporting
        case done(String)
        case failed(String)
    }

    @State private var urlPromptOpen = false
    @State private var urlInput = ""
    @State private var pageInput = "1"
    @State private var pageSaved = false
    @State private var exportState: ExportState = .idle
    @State private var updateChecker = UpdateChecker()
    @FocusState private var urlFieldFocused: Bool
    @FocusState private var pageFieldFocused: Bool

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
        HStack(spacing: 2) {
            IconButton(help: "Open file (⌘O)", action: openFiles) {
                Image(systemName: "folder")
                    .font(.system(size: 16))
            }

            IconButton(
                variant: urlPromptOpen ? .active : .ghost,
                help: "Add webpage (⌘L)",
                action: { urlPromptOpen.toggle() }
            ) {
                Image(systemName: "globe")
                    .font(.system(size: 16))
            }

            if appStore.document != nil, !isWeb {
                IconButton(help: "Save (⌘S)", action: saveDocument) {
                    Image(systemName: "square.and.arrow.down")
                        .font(.system(size: 16))
                }
            }

            if appStore.document != nil, isWeb {
                // Web tabs get in-page history instead of Save.
                IconButton(help: "Back", action: { goWebHistory(-1) }) {
                    Image(systemName: "arrow.left")
                        .font(.system(size: 16))
                }
                IconButton(help: "Forward", action: { goWebHistory(1) }) {
                    Image(systemName: "arrow.right")
                        .font(.system(size: 16))
                }
            }

            if appStore.document != nil {
                Divider()

                IconButton(
                    help: "Previous page",
                    disabled: appStore.currentPage <= 1,
                    action: { appStore.goToPage(appStore.currentPage - 1) }
                ) {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 16))
                }

                HStack(spacing: 6) {
                    TextField("", text: $pageInput)
                        .textFieldStyle(.plain)
                        .font(.system(size: 14))
                        .multilineTextAlignment(.center)
                        .focused($pageFieldFocused)
                        .onSubmit { pageFieldFocused = false }
                        .onChange(of: pageFieldFocused) { _, focused in
                            if !focused { commitPageInput() }
                        }
                        .frame(width: 44, height: 28)
                        .background(palette.surface)
                        .clipShape(RoundedRectangle(cornerRadius: Radius.md))
                        .overlay {
                            RoundedRectangle(cornerRadius: Radius.md)
                                .strokeBorder(palette.border, lineWidth: 1)
                        }
                    Text("/ \(appStore.numPages)")
                        .font(.system(size: 14))
                        .monospacedDigit()
                        .foregroundStyle(palette.mutedForeground)
                }
                .padding(.horizontal, 2)

                IconButton(
                    help: "Next page",
                    disabled: appStore.currentPage >= appStore.numPages,
                    action: { appStore.goToPage(appStore.currentPage + 1) }
                ) {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 16))
                }

                Divider()

                IconButton(help: "Zoom out", action: appStore.zoomOut) {
                    Image(systemName: "minus.magnifyingglass")
                        .font(.system(size: 16))
                }

                Button(action: resetZoom) {
                    Text("\(Int((appStore.zoom * 100).rounded()))%")
                        .font(.system(size: 14))
                        .monospacedDigit()
                        .foregroundStyle(palette.mutedForeground)
                        .frame(minWidth: 52, minHeight: 28)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Reset zoom to 100%")
                .accessibilityLabel("Reset zoom to 100%")

                IconButton(help: "Zoom in", action: appStore.zoomIn) {
                    Image(systemName: "plus.magnifyingglass")
                        .font(.system(size: 16))
                }

                Divider()

                IconButton(
                    help: isBookmarked
                        ? "Remove bookmark"
                        : (isWeb ? "Bookmark this spot" : "Bookmark this page"),
                    action: { Task { await annotationStore.toggleBookmark() } }
                ) {
                    Image(systemName: isBookmarked ? "star.fill" : "star")
                        .font(.system(size: 16))
                        .foregroundStyle(isBookmarked ? palette.gold : palette.mutedForeground)
                }

                IconButton(
                    variant: appStore.mode == .note ? .active : .ghost,
                    help: isWeb
                        ? "Sticky note tool (N) — click in the page to attach a note to the text there"
                        : "Sticky note tool (N) — click on the page to place a note",
                    action: { appStore.setMode(appStore.mode == .note ? .view : .note) }
                ) {
                    Image(systemName: "note.text")
                        .font(.system(size: 16))
                }

                if isWeb {
                    Divider()
                    IconButton(
                        help: pageSaved
                            ? "Saved to library — click to remove"
                            : "Save page to library (keeps an offline snapshot)",
                        action: toggleSavedPage
                    ) {
                        Image(systemName: "archivebox")
                            .font(.system(size: 16))
                            .foregroundStyle(pageSaved ? palette.primary : palette.mutedForeground)
                    }

                    IconButton(
                        help: exportTooltip,
                        disabled: exportState == .exporting,
                        action: exportVellumweb
                    ) {
                        if exportState == .exporting {
                            ProgressView()
                                .controlSize(.small)
                                .frame(width: 16, height: 16)
                        } else {
                            Image(systemName: "square.and.arrow.up")
                                .font(.system(size: 16))
                                .foregroundStyle(exportIconColor)
                        }
                    }

                    Text(displayURL)
                        .font(.system(size: 12))
                        .foregroundStyle(palette.mutedForeground)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .frame(maxWidth: 256)
                        .help(appStore.document?.pdfPath ?? "")
                }
            }

            Spacer(minLength: 4)

            if updateChecker.state == .available,
               let version = updateChecker.availableVersion {
                Button(action: updateChecker.install) {
                    HStack(spacing: 6) {
                        Image(systemName: "arrow.down")
                            .font(.system(size: 12))
                        Text("Update \(version)")
                            .font(.system(size: 12, weight: .medium))
                    }
                    .padding(.horizontal, 10)
                    .frame(height: 28)
                    .foregroundStyle(Color(hex: "#047857"))
                    .background(Color(hex: "#10b981").opacity(0.10))
                    .clipShape(Capsule())
                    .overlay {
                        Capsule().strokeBorder(Color(hex: "#10b981").opacity(0.30), lineWidth: 1)
                    }
                }
                .buttonStyle(.plain)
                .help(updateChecker.tooltip)
                .accessibilityLabel(updateChecker.tooltip)
            }

            IconButton(
                help: updateChecker.tooltip,
                disabled: updateChecker.state == .checking,
                action: { Task { await updateChecker.check() } }
            ) {
                if updateChecker.state == .checking {
                    ProgressView()
                        .controlSize(.small)
                        .frame(width: 16, height: 16)
                } else {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 16))
                }
            }

            ThemeToggle()

            if appStore.document != nil, let onToggleSidebar {
                Divider()
                IconButton(
                    variant: sidebarOpen == true ? .active : .ghost,
                    help: sidebarOpen == true ? "Hide side panel" : "Show side panel",
                    action: onToggleSidebar
                ) {
                    Image(systemName: "sidebar.right")
                        .font(.system(size: 16))
                }
            }
        }
        .padding(.horizontal, 8)
        .frame(height: 44)
        .background(palette.background)
        .overlay(alignment: .bottom) {
            Rectangle().fill(palette.border).frame(height: 1)
        }
        .overlay(alignment: .topLeading) {
            if urlPromptOpen {
                urlPrompt
                    .offset(x: 8, y: 48)
                    .zIndex(100)
            }
        }
        .zIndex(urlPromptOpen ? 100 : 0)
        .onReceive(NotificationCenter.default.publisher(for: .vellumAddWebpage)) { _ in
            urlPromptOpen = true
        }
        .onChange(of: urlPromptOpen) { _, isOpen in
            if isOpen {
                urlInput = ""
                Task {
                    await Task.yield()
                    urlFieldFocused = true
                }
            } else {
                urlFieldFocused = false
            }
        }
        .onChange(of: appStore.currentPage) { _, page in
            pageInput = String(page)
        }
        .task(id: toolbarDocumentIdentity) {
            let identity = toolbarDocumentIdentity
            exportState = .idle
            // Restored sessions start on last_page — the field only synced on
            // page CHANGES, so it showed "1" until the first navigation.
            pageInput = String(appStore.currentPage)
            await loadSavedState(for: identity)
        }
        .task {
            await updateChecker.check(silent: true)
        }
    }

    private var urlPrompt: some View {
        HStack(spacing: 6) {
            TextField("Paste an article URL…", text: $urlInput)
                .textFieldStyle(.plain)
                .font(.system(size: 14))
                .padding(.horizontal, 8)
                .frame(height: 32)
                .background(palette.surface)
                .clipShape(RoundedRectangle(cornerRadius: Radius.md))
                .overlay {
                    RoundedRectangle(cornerRadius: Radius.md)
                        .strokeBorder(palette.border, lineWidth: 1)
                }
                .focused($urlFieldFocused)
                .onSubmit { submitURL() }
                .onExitCommand { urlPromptOpen = false }

            TextButton(size: .sm, action: submitURL) {
                Text("Open")
            }
            .frame(height: 32)
        }
        .padding(8)
        .frame(width: 384)
        .background(palette.background)
        .clipShape(RoundedRectangle(cornerRadius: Radius.lg))
        .overlay {
            RoundedRectangle(cornerRadius: Radius.lg)
                .strokeBorder(palette.border, lineWidth: 1)
        }
        .shadow(color: Color.black.opacity(0.18), radius: 10, y: 4)
    }

    private var exportTooltip: String {
        switch exportState {
        case .idle: return "Export as .vellumweb (portable archive with snapshot + annotations)"
        case .exporting: return "Exporting…"
        case .done(let detail): return detail
        case .failed(let message): return message
        }
    }

    private var exportIconColor: Color {
        switch exportState {
        case .done: return Color(hex: "#059669")
        case .failed: return palette.destructive
        default: return palette.mutedForeground
        }
    }

    /// In-page history for web tabs (window.__webHistory in the original).
    private func goWebHistory(_ delta: Int) {
        NotificationCenter.default.post(
            name: .vellumWebHistory, object: nil, userInfo: ["delta": delta])
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
        let identity = toolbarDocumentIdentity
        exportState = .exporting
        Task {
            do {
                let summary = try await appStore.sessions.exportVellumweb(
                    sessionId: sessionId, destPath: destination.path, pages: pages)
                guard toolbarDocumentIdentity == identity else { return }
                let mb = String(format: "%.2f", Double(summary.bytes) / (1024 * 1024))
                let skipped = summary.assetsSkipped > 0 ? ", \(summary.assetsSkipped) skipped" : ""
                exportState = .done("Exported \(mb) MB (\(summary.assetCount) assets\(skipped))")
            } catch {
                guard toolbarDocumentIdentity == identity else { return }
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

    private var displayURL: String {
        guard let path = appStore.document?.pdfPath else { return "" }
        if path.hasPrefix("https://") { return String(path.dropFirst(8)) }
        if path.hasPrefix("http://") { return String(path.dropFirst(7)) }
        return path
    }

    private var toolbarDocumentIdentity: ToolbarDocumentIdentity {
        ToolbarDocumentIdentity(tabId: appStore.activeTabId, path: appStore.document?.pdfPath)
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

    private func saveDocument() {
        guard let sessionId = appStore.activeTabId else { return }
        Task { try? await appStore.sessions.saveFile(sessionId: sessionId) }
    }

    private func submitURL() {
        let value = urlInput.trimmingCharacters(in: .whitespacesAndNewlines)
        urlPromptOpen = false
        guard !value.isEmpty else { return }
        Task { await appStore.openUrl(value) }
    }

    private func commitPageInput() {
        guard let page = Int(pageInput), (1...appStore.numPages).contains(page) else {
            pageInput = String(appStore.currentPage)
            return
        }
        appStore.goToPage(page)
    }

    private func resetZoom() {
        if let zoomToHandler = appStore.zoomToHandler {
            zoomToHandler(1)
        } else {
            appStore.setZoom(1)
        }
    }

    private func loadSavedState(for identity: ToolbarDocumentIdentity) async {
        pageSaved = false
        guard isWeb, let sessionId = appStore.activeTabId else {
            return
        }
        let saved = (try? await appStore.sessions.getWebpageSaved(sessionId: sessionId)) ?? false
        if toolbarDocumentIdentity == identity {
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
}

private struct ToolbarDocumentIdentity: Hashable {
    var tabId: String?
    var path: String?
}

private struct Divider: View {
    @Environment(\.palette) private var palette

    var body: some View {
        Rectangle()
            .fill(palette.border)
            .frame(width: 1, height: 20)
            .padding(.horizontal, 6)
    }
}
