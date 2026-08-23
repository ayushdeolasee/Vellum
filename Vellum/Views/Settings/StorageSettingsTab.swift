#if os(iOS)
import SwiftUI

/// Settings ▸ Storage — the "nothing invisible" pane (design §8). Four data
/// classes in one place: summary tiles for the three totals, a per-document
/// drill-down that unions the notes/chat folders, the extracted-text cache and
/// the web archives by storage key, an orphans/relink section for documents
/// whose source moved or whose data predates migration, and a housekeeping
/// section owning the retention TTL that the launch sweep and "Run Cleanup Now"
/// both apply. Unlike its sibling tabs this one scrolls (unbounded document
/// list), so it is deliberately NOT `.scrollDisabled`.
///
/// iOS adaptation: no `.frame(height:)` (the Settings sheet fills its
/// presentation and the tabs render in a bottom tab bar), no `.help(...)`
/// tooltips, no "Show in Finder", and relink/change-folder go through the
/// asynchronous `UIDocumentPickerViewController` instead of a modal
/// `NSOpenPanel`. Every accessibility label/identifier is kept verbatim — they
/// are the only handle tests and VoiceOver have.
struct StorageSettingsTab: View {
    @Environment(\.palette) private var palette
    @Environment(WorkspaceStore.self) private var workspace
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    // Joined-list sources (each listed off-main in `reload`).
    @State private var docEntries: [DocumentDataStore.DocumentDataEntry] = []
    @State private var cacheEntries: [PageTextCacheEntry] = []
    @State private var webEntries: [WebLibrary.SnapshotStorageEntry] = []
    @State private var positionWebLastOpened: [String: Date] = [:]
    @State private var webRecordBytes: Int64 = 0
    @State private var legacyScratchpad: [LegacyRow] = []
    @State private var legacyAi: [LegacyRow] = []
    @State private var archivedConflicts: [StorageCoordinator.ArchivedConflict] = []
    @State private var isLoading = true
    @State private var showsOrphansSheet = false
    @State private var showsConflictsSheet = false

    @State private var sortOrder: StorageInventory.SortOrder = .size
    @State private var searchText = ""
    @State private var expandedKeys: Set<String> = []

    // Storage-location + housekeeping controls.
    @State private var storageMode: WebStorageMode = .local
    @State private var autoSavePages = false
    @State private var retentionMonths: Int? = StorageHousekeeping.defaultMonths
    @State private var isCleaningUp = false
    @State private var cleanupResult: String?
    @State private var dataRemovalResult: String?
    @State private var relocationStatus = WebStorageRelocator.status
    @State private var relocationReloadTask: Task<Void, Never>?
    @State private var pendingLocation: PendingLocation?

    // Pending destructive confirmations (user data confirms with the title).
    @State private var pendingDeleteAll: StorageInventory.DocumentRow?
    @State private var pendingDeleteNotes: StorageInventory.DocumentRow?
    @State private var pendingDeleteChat: StorageInventory.DocumentRow?
    @State private var pendingOrphanDelete: StorageInventory.DocumentRow?
    @State private var pendingLegacyDelete: LegacyRow?
    @State private var relinkFailures: [String: String] = [:]

    /// The unified per-document rows for the current sort.
    private var rows: [StorageInventory.DocumentRow] {
        StorageInventory.joinRows(
            documents: docEntries, cacheEntries: cacheEntries,
            webEntries: webEntries,
            positionLastOpened: positionWebLastOpened,
            sort: sortOrder)
    }

    private var linkedRows: [StorageInventory.DocumentRow] {
        rows.filter(\.sourceExists).filter { StorageInventory.matches($0, searchText: searchText) }
    }
    private var orphanRows: [StorageInventory.DocumentRow] { rows.filter { !$0.sourceExists } }
    private var hasOrphanSection: Bool {
        !orphanRows.isEmpty || !legacyScratchpad.isEmpty || !legacyAi.isEmpty
    }
    private var usesRecoverySheets: Bool {
        StorageCompactRouting.usesRecoverySheets(
            idiom: ShellIdiom_iOS.current,
            horizontalSizeClass: horizontalSizeClass)
    }

    var body: some View {
        applyDialogs(formContent)
    }

    private var formContent: some View {
        Form {
            storageLocationSection
            if !archivedConflicts.isEmpty { syncConflictsSection }
            summaryTilesSection
            documentsSection
            if hasOrphanSection {
                if usesRecoverySheets { orphansSheetLinkSection } else { orphansSection }
            }
            housekeepingSection
            removeStoredDataSection
        }
        .formStyle(.grouped)
        #if os(iOS)
        .contentMargins(.bottom, 32, for: .scrollContent)
        #endif
        .task {
            refreshSettings()
            await reload()
        }
        .onReceive(NotificationCenter.default.publisher(for: .vellumStorageRelocationChanged)) { _ in
            handleRelocationStatusChange()
        }
        .onReceive(NotificationCenter.default.publisher(
            for: .vellumStorageConflictArchivesChanged)
        ) { _ in
            Task {
                archivedConflicts = await workspace.storageCoordinator.archivedConflicts()
            }
        }
        .onDisappear {
            relocationReloadTask?.cancel()
        }
        .sheet(isPresented: $showsOrphansSheet) {
            StorageOrphansSheet_iOS(
                orphanRows: orphanRows,
                legacyRows: legacyScratchpad + legacyAi,
                relinkFailures: relinkFailures,
                onRelink: relink,
                onDeleteOrphan: deleteEverything,
                onDeleteLegacy: deleteLegacy)
        }
        .sheet(isPresented: $showsConflictsSheet) {
            StorageConflictsSheet_iOS(conflicts: $archivedConflicts)
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
            tile(
                "Caches", bytes: cacheBytes,
                caption: "Extracted text that makes AI and search start instantly. Rebuilt the next time you open a document.")
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
            TextField("Search documents", text: $searchText)
                .textFieldStyle(.roundedBorder)
                .accessibilityLabel("Search stored documents")
                .accessibilityIdentifier("storage.search")
            Picker("Sort by", selection: $sortOrder) {
                ForEach(StorageInventory.SortOrder.allCases, id: \.self) { order in
                    Text(order.label).tag(order)
                }
            }
            .accessibilityIdentifier("storage.sortPicker")

            if isLoading {
                ProgressView().frame(maxWidth: .infinity, alignment: .center)
            } else if linkedRows.isEmpty {
                Text(searchText.isEmpty ? "No stored documents" : "No matching documents")
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
    private var removeStoredDataSection: some View {
        Section {
            Button("Remove All Offline Copies…", role: .destructive) {
                confirmingWebRemoveAll = true
            }
            .disabled(webEntries.isEmpty)
            .accessibilityIdentifier("storage.webRemoveAll")
            Button("Clear All Extracted-Text Caches", role: .destructive) {
                clearCaches()
            }
            .disabled(cacheEntries.isEmpty)
            .accessibilityIdentifier("storage.eraseAll")
            if let dataRemovalResult {
                Label(dataRemovalResult, systemImage: "checkmark.circle")
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("storage.reclaimed")
            }
        } header: {
            Text("Remove stored data")
        } footer: {
            Text("These actions remove only downloadable or rebuildable data. Document notes, highlights, reading positions, and AI conversations are never removed here.")
                .font(.footnote)
                .foregroundStyle(.secondary)
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

    private var orphansSheetLinkSection: some View {
        Section {
            Button {
                showsOrphansSheet = true
            } label: {
                HStack {
                    Label("Orphans & unlinked", systemImage: "link.badge.plus")
                    Spacer()
                    Text("\(orphanRows.count + legacyScratchpad.count + legacyAi.count)")
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.tertiary)
                        .accessibilityHidden(true)
                }
            }
            .accessibilityIdentifier("storage.orphans")
        } footer: {
            Text("Review moved files and data left by older versions.")
        }
    }

    @ViewBuilder
    private var orphansSection: some View {
        Section {
            ForEach(orphanRows) { row in
                StorageOrphanRow_iOS(
                    row: row,
                    failureMessage: relinkFailures[row.key],
                    onRelink: { relink(row) },
                    onDelete: { pendingOrphanDelete = row })
            }
            ForEach(legacyScratchpad + legacyAi) { legacy in
                StorageLegacyRow_iOS(
                    row: legacy,
                    onDelete: { pendingLegacyDelete = legacy })
            }
        } header: {
            Text("Orphans & unlinked")
        } footer: {
            Text("Documents whose file has moved (relink to reconnect notes and chat) and data left by an older version that hasn't been migrated yet. Nothing here is ever deleted automatically — a missing file may just be on an unplugged drive.")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Preserved sync conflicts

    private var syncConflictsSection: some View {
        Section {
            Button {
                showsConflictsSheet = true
            } label: {
                HStack {
                    Label("Sync conflicts", systemImage: "arrow.triangle.branch")
                    Spacer()
                    Text("\(archivedConflicts.count)")
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.tertiary)
                        .accessibilityHidden(true)
                }
            }
            .accessibilityIdentifier("storage.conflicts")
        } footer: {
            Text("Vellum preserved losing versions that could not be merged safely.")
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
            .accessibilityLabel("Run Cleanup Now")
            .accessibilityIdentifier("storage.runCleanup")
            if let cleanupResult {
                Text(cleanupResult)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("storage.cleanupResult")
            }
        } header: {
            Text("Housekeeping")
        } footer: {
            Text("Cleanup removes only re-creatable data — cached text and offline copies of pages you never saved or annotated — for documents you haven't opened in this long. Your notes, highlights and chat are never touched. Open documents are always kept.")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Storage location

    @ViewBuilder
    private var storageLocationSection: some View {
        Section {
            Picker("Location", selection: locationBinding) {
                Text("iCloud Drive").tag(WebStorageMode.icloud)
                Text("Custom Folder").tag(WebStorageMode.custom)
                Text("This \(ShellIdiom_iOS.current.deviceName)").tag(WebStorageMode.local)
            }
            .accessibilityIdentifier("storage.locationPicker")

            if relocationStatus.isInProgress {
                ProgressView(relocationStatus.message)
                    .controlSize(.small)
                    .accessibilityIdentifier("storage.migrationProgress")
            } else if !relocationStatus.message.isEmpty {
                Label(relocationStatus.message, systemImage: relocationStatus.needsRecovery ? "exclamationmark.triangle" : "checkmark.circle")
                    .font(.footnote)
                    .foregroundStyle(relocationStatus.needsRecovery ? .orange : .secondary)
                    .accessibilityIdentifier("storage.migrationStatus")
            }

            // No "Show in Finder" counterpart on iPadOS — the folder row is the
            // whole affordance.
            if storageMode != .local, let path = currentLocationPath {
                LabeledContent("Folder") {
                    Text(path)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            if storageMode == .custom {
                Button("Change Folder…") {
                    chooseCustomFolder()
                }
                .accessibilityIdentifier("storage.changeFolder")
            }
        } header: {
            Text("Storage location")
        } footer: {
            Text(locationFooterText)
                .font(.footnote)
                .foregroundStyle(WebStorageSettings.modeIsDegraded ? Color.orange : Color.secondary)
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
        StorageLocationCopy.settingsFooter(
            for: storageMode,
            isDegraded: WebStorageSettings.modeIsDegraded,
            deviceName: ShellIdiom_iOS.current.deviceName)
    }

    /// The custom-folder flow is asynchronous on iPadOS: the picker's callback
    /// mints the bookmark, persists the mode and starts the move itself, so it
    /// never flows through `pendingLocation`/the confirmation dialog the way the
    /// two instant modes do.
    private func chooseCustomFolder() {
        WebStorageRelocator.chooseCustomFolder(
            coordinator: workspace.storageCoordinator) {
            refreshSettings()
            relocationStatus = WebStorageRelocator.status
            // The move runs in the background; refresh the listings once it has
            // had a moment to relocate the artifacts.
            Task {
                try? await Task.sleep(for: .seconds(1))
                await reload()
            }
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
                    chooseCustomFolder()
                case .icloud:
                    guard WebStorageSettings.icloudVellumRoot != nil else { return }
                    pendingLocation = PendingLocation(mode: .icloud, customPath: nil)
                case .local:
                    pendingLocation = PendingLocation(mode: .local, customPath: nil)
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

    /// A relocation notification is also used for progress, so only its
    /// terminal states may refresh the inventory. The terminal notification is
    /// posted after a successful move, an interrupted move, or an unavailable
    /// source has settled on its recovery state.
    private func handleRelocationStatusChange() {
        relocationStatus = WebStorageRelocator.status
        guard StorageRelocationInventoryReloadPolicy.shouldReload(for: relocationStatus) else {
            relocationReloadTask?.cancel()
            relocationReloadTask = nil
            return
        }

        // Several state changes can arrive in one main-loop turn (for example,
        // a recovered launch move followed by a location change). Yield once so
        // they collapse to one inventory read, and cancel any superseded read
        // before it starts.
        relocationReloadTask?.cancel()
        relocationReloadTask = Task {
            await Task.yield()
            guard !Task.isCancelled else { return }
            await reload()
        }
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
        var legacyScratchpad: [LegacyRow]
        var legacyAi: [LegacyRow]
    }

    private func reload() async {
        isLoading = true
        async let coordinatedWeb = workspace.webLibraryStorage.listSnapshotStorage()
        async let coordinatedWebRecordBytes = workspace.webLibraryStorage.totalRecordBytes()
        async let coordinatedDocuments = DocumentDataStore.listDocuments(
            coordinator: workspace.storageCoordinator)
        let legacy = await Task.detached(priority: .userInitiated) {
            (
                legacyScratchpad: ScratchpadPersistence.listLegacyEntries().map {
                    LegacyRow(source: .scratchpad, key: $0.key, bytes: $0.bytes)
                },
                legacyAi: AiPersistence.listLegacyEntries().map {
                    LegacyRow(source: .ai, key: $0.key, bytes: $0.bytes)
                }
            )
        }.value
        let listing = Listing(
            documents: await coordinatedDocuments,
            legacyScratchpad: legacy.legacyScratchpad,
            legacyAi: legacy.legacyAi)
        let web = await coordinatedWeb
        let recordBytes = await coordinatedWebRecordBytes
        let cache = await PageTextCache.shared.listEntries()
        let positionWeb = await workspace.positions.lastOpenedByWebKey()
        let conflicts = await workspace.storageCoordinator.archivedConflicts()
        docEntries = listing.documents
        webEntries = web
        positionWebLastOpened = positionWeb
        webRecordBytes = recordBytes
        legacyScratchpad = listing.legacyScratchpad
        legacyAi = listing.legacyAi
        cacheEntries = cache
        archivedConflicts = conflicts
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
        var deleteTokens: [(ScratchpadStore, ScratchpadExternalDeleteToken)] = []
        for pane in workspace.root.allLeaves() {
            for key in keys {
                if let token = pane.scratchpad.prepareForExternalDelete(matchingKey: key) {
                    deleteTokens.append((pane.scratchpad, token))
                }
            }
        }
        Task {
            let deleted = await ScratchpadWriteCoordinator.shared.withExclusiveAccess(
                forKeys: keys
            ) {
                do {
                    for key in keys {
                        try await DocumentDataStore.deleteNotesSafely(
                            forKey: key, coordinator: workspace.storageCoordinator)
                    }
                    return true
                } catch {
                    return false
                }
            }
            guard deleted else {
                for (store, token) in deleteTokens {
                    await store.finishExternalDelete(token, succeeded: false)
                }
                await reload()
                return
            }
            // A pane showing this document must drop its live note WITHOUT saving,
            // or its quit-flush would rewrite the just-deleted markdown.
            postDataDeleted(keys: keys, notes: true, chat: false)
            for (store, token) in deleteTokens {
                await store.finishExternalDelete(token, succeeded: true)
            }
            await reload()
        }
    }

    private func deleteChat(_ row: StorageInventory.DocumentRow) {
        mutateDoc(row.key) { $0.conversationBytes = 0 }
        let keys = [row.key] + row.adoptedKeys
        Task {
            await DocumentDataStore.deleteConversation(
                forKey: row.key, coordinator: workspace.storageCoordinator)
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
                await workspace.webLibraryStorage.removeLocalSnapshots(forKey: key)
            }
            await reload()
        }
    }

    private func deleteEverything(_ row: StorageInventory.DocumentRow) {
        let keys = [row.key] + row.adoptedKeys
        docEntries.removeAll { $0.key == row.key }
        cacheEntries.removeAll { keys.contains($0.pathKey) }
        webEntries.removeAll { keys.contains($0.key) }
        var deleteTokens: [(ScratchpadStore, ScratchpadExternalDeleteToken)] = []
        for pane in workspace.root.allLeaves() {
            for key in keys {
                if let token = pane.scratchpad.prepareForExternalDelete(matchingKey: key) {
                    deleteTokens.append((pane.scratchpad, token))
                }
            }
        }
        Task {
            let deleted = await ScratchpadWriteCoordinator.shared.withExclusiveAccess(
                forKeys: keys
            ) {
                do {
                    for key in keys {
                        try await DocumentDataStore.deleteAllSafely(
                            forKey: key, coordinator: workspace.storageCoordinator)
                    }
                    return true
                } catch {
                    return false
                }
            }
            guard deleted else {
                for (store, token) in deleteTokens {
                    await store.finishExternalDelete(token, succeeded: false)
                }
                await reload()
                return
            }
            // Both notes and chat are gone — a pane showing this document must
            // drop its live scratchpad + AI state so neither writer resurrects it.
            postDataDeleted(keys: keys, notes: true, chat: true)
            for (store, token) in deleteTokens {
                await store.finishExternalDelete(token, succeeded: true)
            }
            for key in keys {
                await PageTextCache.shared.delete(key: key)
                await workspace.webLibraryStorage.removeLocalSnapshots(forKey: key)
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
            switch source {
            case .scratchpad:
                await ScratchpadPersistence.removeLegacyEntry(key: key)
            case .ai:
                await Task.detached {
                    AiPersistence.removeLegacyEntry(key: key)
                }.value
            }
            await reload()
        }
    }

    private func clearCaches() {
        let before = cacheBytes
        // Drop the previous run's number so the label can't report a stale
        // reclaimed total while this one is still working.
        dataRemovalResult = nil
        cacheEntries = []
        Task {
            await PageTextCache.shared.deleteAll()
            await reload()
            dataRemovalResult = reclaimedMessage(max(0, before - cacheBytes))
        }
    }

    private func removeAllWeb() {
        let before = webArchiveBytes
        dataRemovalResult = nil
        webEntries = []
        Task {
            await workspace.webLibraryStorage.removeAllSnapshotArtifacts()
            await reload()
            dataRemovalResult = reclaimedMessage(max(0, before - webArchiveBytes))
        }
    }

    private func runCleanupNow() {
        isCleaningUp = true
        cleanupResult = nil
        let pdfKeys = openPdfKeys
        let webUrls = openWebUrls
        let positions = workspace.positions
        Task {
            let reclaimed = await StorageHousekeeping.runCleanup(
                openPdfKeys: pdfKeys,
                openWebUrls: webUrls,
                measuringReclaimedBytes: true,
                webLastOpened: { await positions.lastOpenedForWebURL($0) },
                webStorage: workspace.webLibraryStorage)
            await reload()
            cleanupResult = reclaimedMessage(reclaimed)
            isCleaningUp = false
        }
    }

    private func reclaimedMessage(_ bytes: Int64) -> String {
        bytes == 0
            ? "No space needed reclaiming."
            : "Reclaimed \(bytes.formatted(.byteCount(style: .file)))."
    }

    private struct PendingLocation: Identifiable {
        let mode: WebStorageMode
        let customPath: String?
        var id: String { "\(mode.rawValue):\(customPath ?? "")" }
        @MainActor var label: String {
            switch mode {
            case .icloud: "iCloud Drive"
            case .custom: "the selected folder"
            case .local: ShellIdiom_iOS.current.thisDevice
            }
        }
    }

    private func applyPendingLocation(_ choice: PendingLocation) {
        WebStorageRelocator.apply(
            mode: choice.mode,
            customPath: choice.customPath,
            coordinator: workspace.storageCoordinator)
        refreshSettings()
        relocationStatus = WebStorageRelocator.status
    }

    private func relink(_ row: StorageInventory.DocumentRow) {
        let key = row.key
        // The iPad picker is asynchronous (no modal `runModal()`), so the whole
        // verify-and-relink runs from its callback.
        DocumentPickerCoordinator_iOS.shared.presentPdfPicker { url in
            Task {
                let result = await DocumentAccessResolver.live.relink(
                    key: key,
                    isDocIdKeyed: row.isDocIdKeyed,
                    to: url,
                    coordinator: workspace.storageCoordinator)
                switch result {
                case .success:
                    relinkFailures[key] = nil
                    await reload()
                case .failure(let error):
                    relinkFailures[key] = relinkFailureMessage(error, title: row.title)
                }
            }
        }
    }

    private func relinkFailureMessage(_ error: DocumentAccessError, title: String) -> String {
        switch error {
        case .identityMismatch:
            return "That PDF is not \(title). Pick the original file, or delete this stored data."
        case .unavailable:
            return "That PDF is unavailable. If it is in iCloud or on an external drive, download or reconnect it, then try again."
        case .missingMetadata:
            return "The stored metadata for this row is missing. Refresh Storage and try again."
        case .storeUnavailable(let message):
            return message
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
            .confirmationDialog(
                pendingLocation.map { "Move Vellum storage to \($0.label)?" } ?? "",
                isPresented: bindingFor($pendingLocation),
                presenting: pendingLocation
            ) { choice in
                Button("Move Storage") { applyPendingLocation(choice) }
                    .accessibilityIdentifier("storage.confirmMigration")
                Button("Cancel", role: .cancel) { refreshSettings() }
            } message: { _ in
                Text(StorageLocationCopy.relocationConfirmation(
                    on: ShellIdiom_iOS.current.deviceName))
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
            .accessibilityLabel(help)
            .accessibilityIdentifier("storageDoc.\(idSuffix)")
        }
        .accessibilityElement(children: .contain)
    }
}

/// A leftover path-keyed blob entry (pre-migration notes or chat) for the
/// orphans section.
struct LegacyRow: Identifiable, Sendable, Equatable {
    enum Source: Sendable, Equatable { case scratchpad, ai }
    var source: Source
    var key: String
    var bytes: Int

    var id: String { "\(source == .scratchpad ? "sp" : "ai")-\(key)" }
    var kindLabel: String { source == .scratchpad ? "Notes" : "Chat" }
    var displayLabel: String {
        RecentFilesService.fileName(for: key)
    }
}
#endif
