import AppKit
import SwiftUI

/// Settings ▸ Storage — the "nothing invisible" pane (design §8). Four data
/// classes in one place: summary tiles for the three totals, a per-document
/// drill-down that unions the notes/chat folders, the extracted-text cache and
/// the web archives by storage key, an orphans/relink section for documents
/// whose source moved or whose data predates migration, and a housekeeping
/// section owning the retention TTL that the launch sweep and "Run Cleanup Now"
/// both apply. Unlike its sibling tabs this one scrolls (unbounded document
/// list), so it is height-bounded and deliberately NOT `.scrollDisabled`.
struct StorageSettingsTab: View {
    @Environment(\.palette) private var palette
    @Environment(WorkspaceStore.self) private var workspace

    // Joined-list sources (each listed off-main in `reload`).
    @State private var docEntries: [DocumentDataStore.DocumentDataEntry] = []
    @State private var cacheEntries: [PageTextCacheEntry] = []
    @State private var webEntries: [WebLibrary.SnapshotStorageEntry] = []
    @State private var webRecordBytes: Int64 = 0
    @State private var legacyScratchpad: [LegacyRow] = []
    @State private var legacyAi: [LegacyRow] = []
    @State private var isLoading = true

    @State private var sortOrder: StorageInventory.SortOrder = .size
    @State private var expandedKeys: Set<String> = []

    // Storage-location + housekeeping controls.
    @State private var storageMode: WebStorageMode = .local
    @State private var autoSavePages = false
    @State private var retentionMonths: Int? = StorageHousekeeping.defaultMonths
    @State private var isCleaningUp = false

    // Pending destructive confirmations (user data confirms with the title).
    @State private var pendingDeleteAll: StorageInventory.DocumentRow?
    @State private var pendingDeleteNotes: StorageInventory.DocumentRow?
    @State private var pendingDeleteChat: StorageInventory.DocumentRow?
    @State private var pendingOrphanDelete: StorageInventory.DocumentRow?
    @State private var pendingLegacyDelete: LegacyRow?
    @State private var relinkFailureTitle: String?

    /// The unified per-document rows for the current sort.
    private var rows: [StorageInventory.DocumentRow] {
        StorageInventory.joinRows(
            documents: docEntries, cacheEntries: cacheEntries,
            webEntries: webEntries, sort: sortOrder)
    }

    private var linkedRows: [StorageInventory.DocumentRow] { rows.filter(\.sourceExists) }
    private var orphanRows: [StorageInventory.DocumentRow] { rows.filter { !$0.sourceExists } }
    private var hasOrphanSection: Bool {
        !orphanRows.isEmpty || !legacyScratchpad.isEmpty || !legacyAi.isEmpty
    }

    var body: some View {
        applyDialogs(formContent)
    }

    private var formContent: some View {
        Form {
            storageLocationSection
            summaryTilesSection
            documentsSection
            if hasOrphanSection { orphansSection }
            housekeepingSection
        }
        .formStyle(.grouped)
        .frame(height: 520)
        .task {
            refreshSettings()
            await reload()
        }
    }

    // MARK: - Summary tiles

    private var yourDataBytes: Int64 {
        docEntries.reduce(0) { $0 + $1.notesBytes + $1.conversationBytes } + webRecordBytes
    }
    private var webArchiveBytes: Int64 { webEntries.reduce(0) { $0 + $1.byteSize } }
    private var cacheBytes: Int64 { cacheEntries.reduce(0) { $0 + $1.byteSize } }

    @ViewBuilder
    private var summaryTilesSection: some View {
        Section {
            tile(
                "Your data", bytes: yourDataBytes,
                caption: "Notes, highlights, reading positions and chat. Irreplaceable — never deleted automatically.")
            tile(
                "Web archives", bytes: webArchiveBytes,
                caption: "Offline copies of pages you've opened. Re-downloaded when you reopen a page.")
            Button("Remove all…", role: .destructive) { confirmingWebRemoveAll = true }
                .disabled(webEntries.isEmpty)
                .accessibilityIdentifier("storage.webRemoveAll")
            tile(
                "Caches", bytes: cacheBytes,
                caption: "Extracted text that makes AI and search start instantly. Rebuilt the next time you open a document.")
            Button("Clear all caches") { clearCaches() }
                .disabled(cacheEntries.isEmpty)
                .accessibilityIdentifier("storage.eraseAll")
        } header: {
            Text("Overview")
        }
    }

    @State private var confirmingWebRemoveAll = false

    private func tile(_ title: String, bytes: Int64, caption: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(title)
                Spacer()
                Text(bytes.formatted(.byteCount(style: .file)))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            Text(caption)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Per-document list

    @ViewBuilder
    private var documentsSection: some View {
        Section {
            Picker("Sort by", selection: $sortOrder) {
                ForEach(StorageInventory.SortOrder.allCases, id: \.self) { order in
                    Text(order.label).tag(order)
                }
            }
            .accessibilityIdentifier("storage.sortPicker")

            if isLoading {
                ProgressView().frame(maxWidth: .infinity, alignment: .center)
            } else if linkedRows.isEmpty {
                Text("No stored documents")
                    .foregroundStyle(.secondary)
                    .id("storage.empty")
            } else {
                ForEach(linkedRows) { row in
                    documentRow(row)
                }
            }
        } header: {
            Text("Documents")
        }
    }

    @ViewBuilder
    private func documentRow(_ row: StorageInventory.DocumentRow) -> some View {
        DisclosureGroup(isExpanded: expansionBinding(row.key)) {
            breakdown(row)
        } label: {
            DocumentRowHeader(row: row)
        }
        .accessibilityIdentifier("storageDoc.\(row.key)")
    }

    @ViewBuilder
    private func breakdown(_ row: StorageInventory.DocumentRow) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            if row.hasNotes {
                BreakdownLine(
                    label: "Notes & attachments", bytes: row.notesBytes,
                    idSuffix: "deleteNotes.\(row.key)", help: "Delete notes",
                    action: { pendingDeleteNotes = row })
            }
            if row.hasConversation {
                BreakdownLine(
                    label: "AI chat", bytes: row.conversationBytes,
                    idSuffix: "deleteChat.\(row.key)", help: "Delete chat",
                    action: { pendingDeleteChat = row })
            }
            if row.hasCache {
                BreakdownLine(
                    label: "Extracted-text cache", bytes: row.cacheBytes,
                    idSuffix: "deleteCache.\(row.key)", help: "Delete cached text",
                    action: { deleteCache(row) })
            }
            if row.hasArchive {
                BreakdownLine(
                    label: "Web archive", bytes: row.archiveBytes,
                    idSuffix: "deleteArchive.\(row.key)", help: "Remove archive",
                    action: { deleteArchive(row) })
            }
            Button("Delete everything for this document", role: .destructive) {
                pendingDeleteAll = row
            }
            .buttonStyle(.borderless)
            .padding(.top, 2)
            .accessibilityIdentifier("storageDoc.deleteAll.\(row.key)")
        }
        .padding(.leading, 4)
    }

    // MARK: - Orphans & unlinked

    @ViewBuilder
    private var orphansSection: some View {
        Section {
            ForEach(orphanRows) { row in
                OrphanRow(
                    row: row,
                    onRelink: { relink(row) },
                    onDelete: { pendingOrphanDelete = row })
            }
            ForEach(legacyScratchpad + legacyAi) { legacy in
                LegacyRowView(row: legacy, onDelete: { pendingLegacyDelete = legacy })
            }
        } header: {
            Text("Orphans & unlinked")
        } footer: {
            Text("Documents whose file has moved (relink to reconnect notes and chat) and data left by an older version that hasn't been migrated yet. Nothing here is ever deleted automatically — a missing file may just be on an unplugged drive.")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Housekeeping

    @ViewBuilder
    private var housekeepingSection: some View {
        Section {
            Toggle("Automatically save every page for offline use", isOn: autoSaveBinding)
                .accessibilityIdentifier("storage.autoSavePages")
            Picker("Keep unused caches for", selection: retentionBinding) {
                ForEach(StorageHousekeeping.monthOptions, id: \.self) { months in
                    Text(months == 12 ? "1 year" : "\(months) months").tag(Int?.some(months))
                }
                Text("Never").tag(Int?.none)
            }
            .accessibilityIdentifier("storage.retentionPicker")
            Button {
                runCleanupNow()
            } label: {
                if isCleaningUp {
                    ProgressView().controlSize(.small)
                } else {
                    Text("Run Cleanup Now")
                }
            }
            .disabled(isCleaningUp || StorageHousekeeping.evictionCutoff() == nil)
            .accessibilityIdentifier("storage.runCleanup")
        } header: {
            Text("Housekeeping")
        } footer: {
            Text("Cleanup removes only re-creatable data — cached text and offline copies of pages you never saved or annotated — for documents you haven't opened in this long. Your notes, highlights and chat are never touched. Open documents are always kept.")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Storage location (unchanged from v1)

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
                    refreshSettings()
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
            return "Everything — offline copies, highlights, notes, AI conversations, and reading positions — lives in iCloud Drive ▸ Vellum and syncs across your Macs."
        case .custom:
            return "Offline copies live in your folder. iCloud syncing is not available for a custom folder: highlights, notes, AI conversations, and reading positions stay on this Mac."
        case .local:
            return "Everything stays in Vellum's private app folder on this Mac. No syncing."
        }
    }

    // MARK: - Bindings

    private var locationBinding: Binding<WebStorageMode> {
        Binding(
            get: { storageMode },
            set: { newMode in
                guard newMode != storageMode else { return }
                switch newMode {
                case .custom:
                    guard let path = WebStorageRelocator.pickCustomFolder() else { return }
                    WebStorageRelocator.apply(mode: .custom, customPath: path)
                case .icloud:
                    guard WebStorageSettings.icloudVellumRoot != nil else { return }
                    WebStorageRelocator.apply(mode: .icloud)
                case .local:
                    WebStorageRelocator.apply(mode: .local)
                }
                refreshSettings()
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

    private var retentionBinding: Binding<Int?> {
        Binding(
            get: { retentionMonths },
            set: { months in
                retentionMonths = months
                StorageHousekeeping.setRetentionMonths(months)
            }
        )
    }

    private func expansionBinding(_ key: String) -> Binding<Bool> {
        Binding(
            get: { expandedKeys.contains(key) },
            set: { expanded in
                if expanded { expandedKeys.insert(key) } else { expandedKeys.remove(key) }
            }
        )
    }

    private func refreshSettings() {
        storageMode = WebStorageSettings.chosenMode ?? .local
        autoSavePages = WebStorageSettings.autoSavePages
        retentionMonths = StorageHousekeeping.retentionMonths
    }

    // MARK: - Open-document exclusion

    private var openDocuments: [DocumentInfo] {
        workspace.root.allLeaves().flatMap { $0.app.tabs }.compactMap(\.document)
    }
    private var openPdfKeys: Set<String> {
        Set(openDocuments.filter { $0.kind == .pdf }.map { DocumentIdentity.storageKey(for: $0) })
    }
    private var openWebUrls: Set<String> {
        Set(openDocuments.filter { $0.kind == .web }.map(\.pdfPath))
    }

    // MARK: - Loading

    private struct Listing: Sendable {
        var documents: [DocumentDataStore.DocumentDataEntry]
        var web: [WebLibrary.SnapshotStorageEntry]
        var webRecordBytes: Int64
        var legacyScratchpad: [LegacyRow]
        var legacyAi: [LegacyRow]
    }

    private func reload() async {
        isLoading = true
        let listing = await Task.detached(priority: .userInitiated) { () -> Listing in
            Listing(
                documents: DocumentDataStore.listDocuments(),
                web: WebLibrary.listSnapshotStorage(),
                webRecordBytes: WebLibrary.totalRecordBytes(),
                legacyScratchpad: ScratchpadPersistence.listLegacyEntries().map {
                    LegacyRow(source: .scratchpad, key: $0.key, bytes: $0.bytes)
                },
                legacyAi: AiPersistence.listLegacyEntries().map {
                    LegacyRow(source: .ai, key: $0.key, bytes: $0.bytes)
                })
        }.value
        let cache = await PageTextCache.shared.listEntries()
        docEntries = listing.documents
        webEntries = listing.web
        webRecordBytes = listing.webRecordBytes
        legacyScratchpad = listing.legacyScratchpad
        legacyAi = listing.legacyAi
        cacheEntries = cache
        isLoading = false
    }

    // MARK: - Destructive actions

    private func mutateDoc(_ key: String, _ transform: (inout DocumentDataStore.DocumentDataEntry) -> Void) {
        if let index = docEntries.firstIndex(where: { $0.key == key }) {
            transform(&docEntries[index])
        }
    }

    private func deleteNotes(_ row: StorageInventory.DocumentRow) {
        mutateDoc(row.key) { $0.notesBytes = 0 }
        let keys = [row.key] + row.adoptedKeys
        Task {
            await Task.detached { DocumentDataStore.deleteNotes(forKey: row.key) }.value
            // A pane showing this document must drop its live note WITHOUT saving,
            // or its quit-flush would rewrite the just-deleted markdown.
            postDataDeleted(keys: keys, notes: true, chat: false)
            await reload()
        }
    }

    private func deleteChat(_ row: StorageInventory.DocumentRow) {
        mutateDoc(row.key) { $0.conversationBytes = 0 }
        let keys = [row.key] + row.adoptedKeys
        Task {
            await Task.detached { DocumentDataStore.deleteConversation(forKey: row.key) }.value
            // A pane showing this document must drop its cached chat, or the
            // AiPersistence write-behind cache would recreate the history.
            postDataDeleted(keys: keys, notes: false, chat: true)
            await reload()
        }
    }

    private func deleteCache(_ row: StorageInventory.DocumentRow) {
        // Include any path-hash sibling adopted into this docId row so the stale
        // pre-stamp cache entry is deleted too, not just the docId-keyed one.
        let keys = [row.key] + row.adoptedKeys
        cacheEntries.removeAll { keys.contains($0.pathKey) }
        Task {
            for key in keys { await PageTextCache.shared.delete(key: key) }
            await reload()
        }
    }

    private func deleteArchive(_ row: StorageInventory.DocumentRow) {
        let keys = [row.key] + row.adoptedKeys
        webEntries.removeAll { keys.contains($0.key) }
        Task {
            for key in keys {
                await Task.detached { WebLibrary.removeLocalSnapshots(forKey: key) }.value
            }
            await reload()
        }
    }

    private func deleteEverything(_ row: StorageInventory.DocumentRow) {
        let keys = [row.key] + row.adoptedKeys
        docEntries.removeAll { $0.key == row.key }
        cacheEntries.removeAll { keys.contains($0.pathKey) }
        webEntries.removeAll { keys.contains($0.key) }
        Task {
            await Task.detached { DocumentDataStore.deleteAll(forKey: row.key) }.value
            // Both notes and chat are gone — a pane showing this document must
            // drop its live scratchpad + AI state so neither writer resurrects it.
            postDataDeleted(keys: keys, notes: true, chat: true)
            for key in keys {
                await PageTextCache.shared.delete(key: key)
                await Task.detached { WebLibrary.removeLocalSnapshots(forKey: key) }.value
            }
            await reload()
        }
    }

    /// Tell any open pane that the Storage pane deleted this document's data so
    /// it drops the matching in-memory state WITHOUT saving (§8 delete-means-delete
    /// even for a document open in another pane).
    @MainActor
    private func postDataDeleted(keys: [String], notes: Bool, chat: Bool) {
        // The AI cache is process-wide (not per-pane), so invalidate it here up
        // front — a pane not currently showing the doc still holds no live view,
        // but a queued flush from any AiStore must not clobber the delete.
        if chat {
            for key in keys { AiPersistence.invalidateCachedConversation(forKey: key) }
        }
        NotificationCenter.default.post(
            name: .vellumDocumentDataDeleted, object: nil,
            userInfo: ["keys": keys, "notes": notes, "chat": chat])
    }

    private func deleteLegacy(_ legacy: LegacyRow) {
        switch legacy.source {
        case .scratchpad: legacyScratchpad.removeAll { $0.id == legacy.id }
        case .ai: legacyAi.removeAll { $0.id == legacy.id }
        }
        let source = legacy.source
        let key = legacy.key
        Task {
            await Task.detached {
                switch source {
                case .scratchpad: ScratchpadPersistence.removeLegacyEntry(key: key)
                case .ai: AiPersistence.removeLegacyEntry(key: key)
                }
            }.value
            await reload()
        }
    }

    private func clearCaches() {
        cacheEntries = []
        Task {
            await PageTextCache.shared.deleteAll()
            await reload()
        }
    }

    private func removeAllWeb() {
        webEntries = []
        Task {
            await Task.detached { WebLibrary.removeAllSnapshotArtifacts() }.value
            await reload()
        }
    }

    private func runCleanupNow() {
        isCleaningUp = true
        let pdfKeys = openPdfKeys
        let webUrls = openWebUrls
        Task {
            await StorageHousekeeping.runCleanup(openPdfKeys: pdfKeys, openWebUrls: webUrls)
            await reload()
            isCleaningUp = false
        }
    }

    private func relink(_ row: StorageInventory.DocumentRow) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.pdf]
        panel.prompt = "Relink"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let path = url.path
        let key = row.key
        let docIdKeyed = row.isDocIdKeyed
        let title = row.title
        Task {
            let verified = await Task.detached { () -> Bool in
                // A docId-keyed entry can be proven: the picked PDF must carry
                // the same embedded /VellumDocId. A path-hash fallback entry has
                // no embedded id, so the user's pick is accepted as-is.
                if docIdKeyed { return PdfMetadata.documentId(atPath: path) == key }
                return true
            }.value
            guard verified else {
                relinkFailureTitle = title
                return
            }
            await Task.detached { DocumentDataStore.relink(forKey: key, newPath: path) }.value
            await reload()
        }
    }

    // MARK: - Confirmation dialogs

    private func applyDialogs<Content: View>(_ content: Content) -> some View {
        content
            .confirmationDialog(
                pendingDeleteNotes.map { "Delete notes for \"\($0.title)\"?" } ?? "",
                isPresented: bindingFor($pendingDeleteNotes), presenting: pendingDeleteNotes
            ) { row in
                Button("Delete Notes", role: .destructive) { deleteNotes(row) }
                    .accessibilityIdentifier("storage.confirmDeleteNotes")
                Button("Cancel", role: .cancel) {}
            } message: { _ in
                Text("This permanently deletes this document's scratchpad notes and every image in them. Highlights in the document itself, and your AI chat, are not affected. This cannot be undone.")
            }
            .confirmationDialog(
                pendingDeleteChat.map { "Delete AI chat for \"\($0.title)\"?" } ?? "",
                isPresented: bindingFor($pendingDeleteChat), presenting: pendingDeleteChat
            ) { row in
                Button("Delete Chat", role: .destructive) { deleteChat(row) }
                    .accessibilityIdentifier("storage.confirmDeleteChat")
                Button("Cancel", role: .cancel) {}
            } message: { _ in
                Text("This permanently deletes this document's AI conversation history. Your notes and highlights are not affected. This cannot be undone.")
            }
            .confirmationDialog(
                pendingDeleteAll.map { "Delete everything for \"\($0.title)\"?" } ?? "",
                isPresented: bindingFor($pendingDeleteAll), presenting: pendingDeleteAll
            ) { row in
                Button("Delete Everything", role: .destructive) { deleteEverything(row) }
                    .accessibilityIdentifier("storage.confirmDeleteAll")
                Button("Cancel", role: .cancel) {}
            } message: { _ in
                Text("This permanently deletes this document's notes, attachments and AI chat, along with its cached text and offline copy. Highlights saved inside the document file itself are not affected. This cannot be undone.")
            }
            .confirmationDialog(
                pendingOrphanDelete.map { "Delete data for \"\($0.title)\"?" } ?? "",
                isPresented: bindingFor($pendingOrphanDelete), presenting: pendingOrphanDelete
            ) { row in
                Button("Delete Data", role: .destructive) { deleteEverything(row) }
                    .accessibilityIdentifier("storage.confirmOrphanDelete")
                Button("Cancel", role: .cancel) {}
            } message: { _ in
                Text("The original file couldn't be found, so this can't be reconnected. Deleting removes its notes, attachments and AI chat permanently. If the file is only on an unplugged drive or offloaded from iCloud, relink it instead. This cannot be undone.")
            }
            .confirmationDialog(
                pendingLegacyDelete.map { "Delete \($0.kindLabel.lowercased()) for \"\($0.displayLabel)\"?" } ?? "",
                isPresented: bindingFor($pendingLegacyDelete), presenting: pendingLegacyDelete
            ) { legacy in
                Button("Delete", role: .destructive) { deleteLegacy(legacy) }
                    .accessibilityIdentifier("storage.confirmLegacyDelete")
                Button("Cancel", role: .cancel) {}
            } message: { _ in
                Text("This is data from an older version that hasn't been migrated to a document yet. Deleting it is permanent and cannot be undone.")
            }
            .confirmationDialog(
                "Remove all offline copies?", isPresented: $confirmingWebRemoveAll
            ) {
                Button("Remove All Offline Copies", role: .destructive) { removeAllWeb() }
                    .accessibilityIdentifier("storage.confirmWebRemoveAll")
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("This removes the downloaded copy of every web page. Your saved-pages list, highlights, and notes are not affected — pages just load from the network (and re-download) the next time you open them.")
            }
            .alert(
                "Couldn't relink",
                isPresented: Binding(
                    get: { relinkFailureTitle != nil },
                    set: { if !$0 { relinkFailureTitle = nil } })
            ) {
                Button("OK", role: .cancel) {}
            } message: {
                Text("That PDF isn't the same document as “\(relinkFailureTitle ?? "")” — its identity stamp doesn't match. Pick the original file, or delete the orphaned data instead.")
            }
    }

    private func bindingFor<T>(_ pending: Binding<T?>) -> Binding<Bool> {
        Binding(get: { pending.wrappedValue != nil }, set: { if !$0 { pending.wrappedValue = nil } })
    }
}

// MARK: - Row views

private struct DocumentRowHeader: View {
    let row: StorageInventory.DocumentRow

    var body: some View {
        HStack {
            Image(systemName: row.kind == .web ? "globe" : "doc.text")
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(row.title)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(recency)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Text(row.totalBytes.formatted(.byteCount(style: .file)))
                .font(.callout)
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .accessibilityIdentifier("storageDoc.size.\(row.key)")
        }
    }

    private var recency: String {
        guard let opened = row.lastOpened else { return "Never opened" }
        return "Last opened \(opened.formatted(.relative(presentation: .named)))"
    }
}

/// One size bucket inside a document's disclosure: label, size, and a delete
/// button. `.contain` (not `.combine`) keeps the button reachable for VoiceOver
/// and UI tests (same reason as the v1 rows).
private struct BreakdownLine: View {
    let label: String
    let bytes: Int64
    let idSuffix: String
    let help: String
    let action: () -> Void

    var body: some View {
        HStack {
            Text(label)
                .font(.callout)
            Spacer()
            Text(bytes.formatted(.byteCount(style: .file)))
                .font(.callout)
                .monospacedDigit()
                .foregroundStyle(.secondary)
            Button(role: .destructive, action: action) {
                Image(systemName: "trash")
            }
            .buttonStyle(.borderless)
            .help(help)
            .accessibilityLabel(help)
            .accessibilityIdentifier("storageDoc.\(idSuffix)")
        }
        .accessibilityElement(children: .contain)
    }
}

private struct OrphanRow: View {
    @Environment(\.palette) private var palette
    let row: StorageInventory.DocumentRow
    let onRelink: () -> Void
    let onDelete: () -> Void

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(row.title)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Label("Original file not found", systemImage: "questionmark.circle")
                    .font(.caption)
                    .foregroundStyle(palette.gold)
            }
            Spacer()
            Text(row.totalBytes.formatted(.byteCount(style: .file)))
                .font(.callout)
                .monospacedDigit()
                .foregroundStyle(.secondary)
            Button("Relink…", action: onRelink)
                .buttonStyle(.borderless)
                .accessibilityIdentifier("storageOrphan.relink.\(row.key)")
            Button(role: .destructive, action: onDelete) {
                Image(systemName: "trash")
            }
            .buttonStyle(.borderless)
            .help("Delete data")
            .accessibilityLabel("Delete data for \(row.title)")
            .accessibilityIdentifier("storageOrphan.delete.\(row.key)")
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("storageOrphan.\(row.key)")
    }
}

private struct LegacyRowView: View {
    let row: LegacyRow
    let onDelete: () -> Void

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(row.displayLabel)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text("Not yet migrated · \(row.kindLabel)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Text(Int64(row.bytes).formatted(.byteCount(style: .file)))
                .font(.callout)
                .monospacedDigit()
                .foregroundStyle(.secondary)
            Button(role: .destructive, action: onDelete) {
                Image(systemName: "trash")
            }
            .buttonStyle(.borderless)
            .help("Delete")
            .accessibilityLabel("Delete \(row.kindLabel) for \(row.displayLabel)")
            .accessibilityIdentifier("storageLegacy.delete.\(row.id)")
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("storageLegacy.\(row.id)")
    }
}

/// A leftover path-keyed blob entry (pre-migration notes or chat) for the
/// orphans section.
struct LegacyRow: Identifiable, Sendable, Equatable {
    enum Source: Sendable { case scratchpad, ai }
    var source: Source
    var key: String
    var bytes: Int

    var id: String { "\(source == .scratchpad ? "sp" : "ai")-\(key)" }
    var kindLabel: String { source == .scratchpad ? "Notes" : "Chat" }
    var displayLabel: String {
        RecentFilesService.fileName(for: key)
    }
}
