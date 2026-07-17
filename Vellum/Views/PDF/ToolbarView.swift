import AppKit
import SwiftUI
import UniformTypeIdentifiers

// Native unified-toolbar content (Liquid Glass on macOS 26+). Groups are
// separated with ToolbarSpacer so each cluster reads as its own glass pod.
struct VellumToolbar: ToolbarContent {
    @Environment(AppStore.self) private var appStore

    private var isWeb: Bool { appStore.document?.kind == .web }
    private var hasDocument: Bool { appStore.document != nil }

    // Three stable regions, shared by PDF and web tabs so nothing familiar
    // moves when the tab type changes:
    //   • LEADING (.navigation): the same navigation slot — web back/forward or
    //     PDF page controls — plus PDF-only reading controls (zoom).
    //   • CENTER (.principal): the quiet document title/address. .principal is
    //     genuinely centered by the window, so it never shifts with the leading
    //     cluster's width the way flexible spacers did.
    //   • TRAILING: bookmark, note, inspector, and one overflow Menu that holds
    //     the low-frequency actions (Open, Save, Export, library, updates).
    // Low-use file/library/update actions no longer each claim a glass circle,
    // which is what produced the "pill soup".
    var body: some ToolbarContent {
        // LEADING — navigation. ControlGroup merges related buttons into one
        // shared glass capsule; bare buttons in a group render as zero-gap
        // squished circles on macOS 26.
        ToolbarItemGroup(placement: .navigation) {
            if hasDocument {
                if isWeb {
                    ControlGroup {
                        WebHistoryButtons()
                    }
                } else {
                    PageControls()
                }
            }
        }

        // PDF-only reading controls stay in the leading region so the centered
        // title and the trailing pod never move between modes.
        if hasDocument, !isWeb {
            ToolbarItemGroup(placement: .navigation) {
                ControlGroup {
                    ZoomControls()
                }
            }
        }

        // CENTER — quiet title/address, genuinely centered and not pretending
        // to be an editable pill.
        if hasDocument {
            ToolbarItem(placement: .principal) {
                DocumentTitleField()
            }
        }

        // TRAILING — stable pod. These items sit in the same order for PDF and
        // web tabs.
        if hasDocument {
            ToolbarItemGroup {
                BookmarkButton()
                NoteToolToggle()
            }
            ToolbarSpacer(.fixed)
            ToolbarItem {
                SidebarToggleButton()
            }
        }

        ToolbarItem {
            OverflowMenu()
        }
    }
}

// MARK: - Add webpage sheet

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

/// In-page history for web tabs (window.__webHistory in the original).
private struct WebHistoryButtons: View {
    var body: some View {
        Button {
            go(-1)
        } label: {
            Label("Back", systemImage: "arrow.left")
        }
        .help("Back — go to the previous page in this tab's history")
        .accessibilityIdentifier("toolbar.webBack")

        Button {
            go(1)
        } label: {
            Label("Forward", systemImage: "arrow.right")
        }
        .help("Forward — go to the next page in this tab's history")
        .accessibilityIdentifier("toolbar.webForward")
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
            .accessibilityIdentifier("toolbar.previousPage")

            Button {
                appStore.goToPage(appStore.currentPage + 1)
            } label: {
                Label("Next page", systemImage: "chevron.right")
            }
            .disabled(appStore.currentPage >= appStore.numPages)
            .help("Next page — or type a page number in the field")
            .accessibilityIdentifier("toolbar.nextPage")
        }

        HStack(spacing: 5) {
            TextField("", text: $pageInput)
                .textFieldStyle(.roundedBorder)
                .controlSize(.small)
                .multilineTextAlignment(.center)
                .focused($fieldFocused)
                // Commit directly on Return — FocusState changes are unreliable
                // inside NSToolbar-hosted fields, so blur alone can't be trusted.
                .onSubmit { commitPageInput(); fieldFocused = false }
                .onChange(of: fieldFocused) { _, focused in
                    if !focused { commitPageInput() }
                }
                .frame(width: 44)
                .accessibilityLabel("Page number")
                .accessibilityIdentifier("toolbar.pageField")
            Text("/ \(appStore.numPages)")
                .monospacedDigit()
                .foregroundStyle(.secondary)
        }
        .font(.system(size: 12))
        // Breathing room between the field/count and the glass pod's rounded
        // ends — flush content gets visually clipped by the capsule curvature.
        .padding(.horizontal, 6)
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
        .accessibilityIdentifier("toolbar.zoomOut")

        Button(action: resetZoom) {
            Text("\(Int((appStore.zoom * 100).rounded()))%")
                .font(.system(size: 12))
                .monospacedDigit()
                .frame(minWidth: 40)
        }
        .help("Reset zoom to 100%")
        .accessibilityLabel("Reset zoom to 100%")
        .accessibilityIdentifier("toolbar.resetZoom")

        Button {
            appStore.zoomIn()
        } label: {
            Label("Zoom in", systemImage: "plus.magnifyingglass")
        }
        .help("Zoom in (⌘+)")
        .accessibilityIdentifier("toolbar.zoomIn")
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
        .accessibilityAddTraits(isBookmarked ? .isSelected : [])
        .accessibilityIdentifier("toolbar.bookmark")
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
        .accessibilityAddTraits(appStore.mode == .note ? .isSelected : [])
        .accessibilityIdentifier("toolbar.noteTool")
    }
}

// MARK: - Overflow menu

/// One trailing Menu that collects the low-frequency actions that used to each
/// claim their own toolbar circle: Open, Save, web library + Export, and the
/// updater. Keeping them here is what removes the "pill soup" while leaving the
/// reading controls (nav, zoom, bookmark, note, inspector) permanently visible.
private struct OverflowMenu: View {
    @Environment(AppStore.self) private var appStore
    @Environment(AiStore.self) private var aiStore

    @State private var updateChecker = UpdateChecker()
    @State private var pageSaved = false
    @State private var exporting = false
    /// Separate guard for the "Export with Notes…" flow so it can't double-fire
    /// and doesn't fight the web-only "Export a Copy…" guard above.
    @State private var exportingBundle = false
    /// Serializes save/remove so a rapid Remove can't finish before a slow
    /// Save's archive write and get its deletion undone by it.
    @State private var saveToggleTask: Task<Void, Never>?
    /// Identifies the newest queued toggle, so a superseded one's failure can't
    /// revert the toolbar to a state the user has already toggled away from.
    @State private var saveToggleGeneration = 0

    private var isWeb: Bool { appStore.document?.kind == .web }
    private var hasDocument: Bool { appStore.document != nil }

    var body: some View {
        Menu {
            Section {
                Button(action: openFiles) {
                    Label("Open File…", systemImage: "folder")
                }
                Button {
                    NotificationCenter.default.post(name: .vellumAddWebpage, object: nil)
                } label: {
                    Label("Add Webpage…", systemImage: "globe")
                }
            }

            if hasDocument, !isWeb {
                Section {
                    Button(action: savePdf) {
                        Label("Save", systemImage: "square.and.arrow.down")
                    }
                }
            }

            if hasDocument, isWeb {
                Section {
                    Button(action: toggleSavedPage) {
                        Label(
                            pageSaved ? "Remove Offline Copy" : "Save for Offline Use",
                            systemImage: pageSaved ? "arrow.down.circle.fill" : "arrow.down.circle")
                    }
                    .accessibilityIdentifier("toolbar.saveForOffline")
                    Button(action: exportVellumweb) {
                        Label("Export a Copy…", systemImage: "square.and.arrow.up")
                    }
                    .disabled(exporting)
                }
            }

            if hasDocument {
                Section {
                    Button(action: exportWithNotes) {
                        Label("Export with Notes…", systemImage: "arrow.up.doc")
                    }
                    .disabled(exportingBundle)
                    .accessibilityIdentifier("toolbar.exportWithNotes")
                }
            }

            Section {
                if updateChecker.state == .available,
                   let version = updateChecker.availableVersion {
                    Button(action: updateChecker.install) {
                        Label("Install Update \(version)", systemImage: "arrow.down.circle")
                    }
                }
                Button {
                    Task { await updateChecker.check() }
                } label: {
                    Label("Check for Updates…", systemImage: "arrow.clockwise")
                }
                .disabled(updateChecker.state == .checking)
            }
        } label: {
            Label("More", systemImage: "ellipsis")
                // Icon-only keeps the pod the same circle as the neighboring
                // buttons; a text-bearing Menu label can outgrow the toolbar
                // height and clip against its bottom edge.
                .labelStyle(.iconOnly)
        }
        .menuIndicator(.hidden)
        .help("More — open, save, export, and updates")
        .accessibilityLabel("More actions")
        .accessibilityIdentifier("toolbar.overflowMenu")
        .task {
            await updateChecker.check(silent: true)
        }
        .task(id: DocumentKey(appStore)) {
            await loadSavedState(for: DocumentKey(appStore))
        }
    }

    // MARK: File

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

    private func savePdf() {
        guard let sessionId = appStore.activeTabId else { return }
        Task { try? await appStore.sessions.saveFile(sessionId: sessionId) }
    }

    // MARK: Web library

    private func loadSavedState(for identity: DocumentKey) async {
        pageSaved = false
        guard isWeb, let sessionId = appStore.activeTabId else { return }
        let saved = (try? await appStore.sessions.getWebpageSaved(sessionId: sessionId)) ?? false
        if DocumentKey(appStore) == identity {
            pageSaved = saved
        }
    }

    /// Save = mark the page kept AND make sure its offline copy exists (the
    /// re-archive covers a copy the user deleted from Settings ▸ Storage).
    /// Remove = un-keep and delete the offline copy; the record — highlights,
    /// notes, reading position — always survives.
    private func toggleSavedPage() {
        guard let sessionId = appStore.activeTabId else { return }
        let next = !pageSaved
        pageSaved = next
        let expectedUrl = appStore.document?.pdfPath ?? ""
        let pages = aiStore.pageTexts
            .sorted { $0.key < $1.key }
            .map { WebPageText(number: $0.key, text: $0.value) }
        let prior = saveToggleTask
        saveToggleGeneration += 1
        let generation = saveToggleGeneration
        saveToggleTask = Task {
            await prior?.value
            do {
                try await appStore.sessions.setWebpageSaved(sessionId: sessionId, saved: next)
                if next {
                    // Best-effort: membership is saved even if the archive
                    // write fails (offline, no snapshot yet) — the copy is
                    // rewritten on the next open of the page.
                    _ = try? await appStore.sessions.archiveWebpageDefault(
                        sessionId: sessionId, pages: pages, expectedUrl: expectedUrl)
                }
            } catch {
                // Only the newest toggle owns the button: an older one failing
                // behind a queued newer one must not resurrect its own state.
                if appStore.activeTabId == sessionId, generation == saveToggleGeneration {
                    pageSaved = !next
                }
            }
        }
    }

    /// Export the active webpage as a .vellumweb archive (Toolbar.tsx export flow).
    private func exportVellumweb() {
        guard !exporting,
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
        exporting = true
        Task {
            defer { exporting = false }
            _ = try? await appStore.sessions.exportVellumweb(
                sessionId: sessionId, destPath: destination.path, pages: pages)
        }
    }

    /// Export the active document as a `.vellum` bundle — the document plus its
    /// scratchpad + attachments, and (opt-in checkbox, default OFF) the AI
    /// conversation. Available for BOTH PDF and web tabs.
    private func exportWithNotes() {
        guard !exportingBundle,
              let sessionId = appStore.activeTabId,
              let document = appStore.document else { return }

        let panel = NSSavePanel()
        if let bundleType = UTType(filenameExtension: "vellum") {
            panel.allowedContentTypes = [bundleType]
        }
        panel.nameFieldStringValue = "\(slugifiedTitle()).vellum"
        // Conversations are semi-private (design §5): sharing them is explicit,
        // so the checkbox defaults OFF.
        let checkbox = NSButton(checkboxWithTitle: "Include AI conversation", target: nil, action: nil)
        checkbox.state = .off
        checkbox.setAccessibilityIdentifier("export.includeConversation")
        let accessory = NSView(frame: NSRect(x: 0, y: 0, width: 280, height: 40))
        checkbox.frame = NSRect(x: 18, y: 8, width: 244, height: 24)
        accessory.addSubview(checkbox)
        panel.accessoryView = accessory

        guard panel.runModal() == .OK, let destination = panel.url else { return }
        let includeConversations = checkbox.state == .on
        let pages = aiStore.pageTexts
            .sorted { $0.key < $1.key }
            .map { WebPageText(number: $0.key, text: $0.value) }

        exportingBundle = true
        Task {
            defer { exportingBundle = false }
            try? await buildBundle(
                sessionId: sessionId,
                document: document,
                destination: destination,
                includeConversations: includeConversations,
                pages: pages)
        }
    }

    /// Assemble the bundle content: durable id (lazily stamped), the document
    /// bytes (PDF as-is / a fresh .vellumweb for web), and the class-B sidecar
    /// pulled from DocumentDataStore by storage key.
    private func buildBundle(
        sessionId: String,
        document: DocumentInfo,
        destination: URL,
        includeConversations: Bool,
        pages: [WebPageText]
    ) async throws {
        // The sidecar currently lives under this session's storage key — resolve
        // it BEFORE the stamp changes DocumentInfo.docId.
        let pullKey = DocumentIdentity.storageKey(for: document)
        // Durable id for the manifest (stamps a writable PDF; byte-hash fallback
        // for an unwritable one; URL hash for web).
        let durableId = (try? await appStore.sessions.ensureDocumentId(sessionId: sessionId))
            ?? pullKey
        await appStore.syncDocumentId(sessionId: sessionId)

        let documentData: Data
        let documentFile: String
        if document.kind == .web {
            // Reuse the session's .vellumweb writer rather than duplicating it.
            let tmp = FileManager.default.temporaryDirectory
                .appendingPathComponent("\(UUID().uuidString.lowercased()).vellumweb")
            _ = try await appStore.sessions.exportVellumweb(
                sessionId: sessionId, destPath: tmp.path, pages: pages)
            documentData = try Data(contentsOf: tmp)
            try? FileManager.default.removeItem(at: tmp)
            documentFile = "\(slugifiedTitle()).vellumweb"
        } else {
            // Read AFTER the stamp so the exported PDF carries /VellumDocId.
            documentData = try await appStore.sessions.readPdfBytes(sessionId: sessionId)
            let name = (document.pdfPath as NSString).lastPathComponent
            documentFile = VellumBundle.safeName(name) ?? "document.pdf"
        }

        let scratchpad = DocumentDataStore.loadScratchpad(forKey: pullKey)
        let attachments = loadAttachments(forKey: pullKey)
        let conversations = includeConversations
            ? DocumentDataStore.loadConversationsData(forKey: pullKey)
            : nil

        let content = VellumBundle.Content(
            kind: document.kind,
            docId: durableId,
            documentFile: documentFile,
            documentData: documentData,
            title: document.title,
            scratchpad: scratchpad.isEmpty ? nil : scratchpad,
            attachments: attachments,
            conversations: conversations)
        try VellumBundle.write(content, to: destination)
    }

    /// Read the document's attachments as (bare filename, bytes) pairs.
    private func loadAttachments(forKey key: String) -> [(name: String, data: Data)] {
        let dir = DocumentDataStore.attachmentsDir(forKey: key)
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: dir.path) else {
            return []
        }
        var out: [(name: String, data: Data)] = []
        for name in names.sorted() {
            if let data = try? Data(contentsOf: dir.appendingPathComponent(name)) {
                out.append((name, data))
            }
        }
        return out
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
        // Quiet centered title/address — no capsule, no stacked material. It
        // reads as a label the unified toolbar hosts, not a fake editable pill.
        // Middle-truncation keeps both the site/name head and the tail visible.
        Text(feedback ?? displayText)
            .font(.system(size: 12))
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .truncationMode(.middle)
            .padding(.horizontal, 10)
            .frame(minWidth: 120, idealWidth: isWeb ? 380 : 260, maxWidth: isWeb ? 440 : 320)
            .frame(minHeight: 30)
            .contentShape(Rectangle())
            .help(helpText)
            .onTapGesture(count: 2) { saveAs() }
            .onTapGesture { if isWeb { copyURL() } }
            .accessibilityLabel(feedback ?? displayText)
            .accessibilityIdentifier("toolbar.documentTitle")
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

// MARK: - Sidebar

private struct SidebarToggleButton: View {
    @Environment(WorkspaceStore.self) private var workspace

    var body: some View {
        Button {
            workspace.sidebarOpen.toggle()
        } label: {
            Label(
                workspace.sidebarOpen ? "Hide side panel" : "Show side panel",
                systemImage: "sidebar.trailing")
        }
        .help(
            workspace.sidebarOpen
                ? "Hide side panel (⌘⌥S)"
                : "Show side panel (⌘⌥S) — annotations and AI chat")
        .accessibilityAddTraits(workspace.sidebarOpen ? .isSelected : [])
        .accessibilityIdentifier("toolbar.sidebarToggle")
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
