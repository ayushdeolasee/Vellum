import Foundation

/// Async storage boundary for web sidecars, the pretty-name index, and managed
/// `.vellumweb` archives. Callers name domain items (record key, index, managed
/// archive) instead of constructing iCloud URLs themselves.
actor WebLibraryStorage {
    struct Metadata: Sendable, Equatable {
        var name: String
        var readiness: ItemReadiness
        var byteSize: Int64?
        var contentModifiedAt: Date?
    }

    private let coordinator: StorageCoordinator?
    private var heldRecordKeys: Set<String> = []
    private var recordWaiters: [String: [CheckedContinuation<Void, Never>]] = [:]
    private var heldIndex = false
    private var indexWaiters: [CheckedContinuation<Void, Never>] = []

    init(coordinator: StorageCoordinator? = nil) {
        self.coordinator = coordinator
    }

    // MARK: - Records

    func loadRecord(
        forKey key: String,
        materializing: Materialization = .downloadIfNeeded(timeout: 10)
    ) async -> WebPageRecord? {
        try? await loadRecordStrict(forKey: key, materializing: materializing)
    }

    func loadRecordStrict(
        forKey key: String,
        materializing: Materialization = .downloadIfNeeded(timeout: 10)
    ) async throws -> WebPageRecord? {
        try await withStorageContext { context in
            switch context {
            case .direct(let layout):
                return Self.loadRecordDirect(forKey: key, layout: layout)
            case .coordinated(let container, let layout):
                return try await Self.loadRecordCoordinated(
                    forKey: key,
                    layout: layout,
                    container: container,
                    materializing: materializing)
            }
        }
    }

    @discardableResult
    func mutateRecord<T: Sendable>(
        url: String,
        key: String,
        materializing: Materialization = .downloadIfNeeded(timeout: 10),
        _ mutate: @Sendable (inout WebPageRecord) -> T
    ) async throws -> T {
        await acquireRecord(key)
        defer { releaseRecord(key) }

        return try await withStorageContext { context in
            switch context {
            case .direct(let layout):
                let path = layout.recordsDir.appendingPathComponent("\(key).json")
                return try WebLibrary.withRecord(url: url, recordPath: path, mutate)

            case .coordinated(let container, let layout):
                let recordURL = layout.recordsDir.appendingPathComponent("\(key).json")
                var record = try await Self.loadRecordCoordinated(
                    forKey: key,
                    layout: layout,
                    container: container,
                    materializing: materializing)
                    ?? WebPageRecord(url: url)
                let value = mutate(&record)
                let data = try Self.encodeRecord(record)
                try await container.replace(recordURL, with: data)
                return value
            }
        }
    }

    func listSaved() async throws -> [WebLibraryEntry] {
        try await withStorageContext { context in
            switch context {
            case .direct(let layout):
                return Self.listSavedDirect(layout: layout)
            case .coordinated(let container, let layout):
                return try await Self.listSavedCoordinated(layout: layout, container: container)
            }
        }
    }

    func setTitle(rawUrl: String, title: String?) async throws {
        let url = try WebUrl.normalize(rawUrl)
        let key = WebLibrary.pageKey(url)
        let trimmed = title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        try await mutateRecord(url: url, key: key) { record in
            record.title = trimmed.isEmpty ? nil : trimmed
        }
    }

    // MARK: - Managed archives

    func hasLocalSnapshot(forKey key: String) async -> Bool {
        await acquireIndex()
        defer { releaseIndex() }

        return (try? await withStorageContext { context in
            switch context {
            case .direct(let layout):
                return Self.hasDerivedLocalSnapshot(forKey: key)
                    || Self.existingManagedArchiveURLDirect(forKey: key, layout: layout) != nil
            case .coordinated(let container, let layout):
                if Self.hasDerivedLocalSnapshot(forKey: key) { return true }
                guard let archive = try await Self.existingManagedArchiveMetadata(
                    forKey: key,
                    layout: layout,
                    container: container,
                    readyOnly: true)
                else { return false }
                return archive.readiness.isReady
            }
        }) ?? false
    }

    func snapshotArtifactsSize(forKey key: String) async -> Int64 {
        await acquireIndex()
        defer { releaseIndex() }

        return (try? await withStorageContext { context in
            switch context {
            case .direct:
                return WebLibrary.snapshotArtifactsSize(forKey: key)
            case .coordinated(let container, let layout):
                let managed = try await Self.existingManagedArchiveMetadata(
                    forKey: key,
                    layout: layout,
                    container: container,
                    readyOnly: false)
                return Self.derivedSnapshotBytes(forKey: key) + (managed?.byteSize ?? 0)
            }
        }) ?? Self.derivedSnapshotBytes(forKey: key)
    }

    func removeLocalSnapshots(forKey key: String) async {
        await acquireIndex()
        defer { releaseIndex() }

        try? await withStorageContext { context in
            switch context {
            case .direct(let layout):
                try? FileManager.default.removeItem(at: WebLibrary.snapshotPath(forKey: key))
                if let managed = Self.existingManagedArchiveURLDirect(forKey: key, layout: layout) {
                    WebICloud.removeItem(at: managed)
                }
                try? FileManager.default.removeItem(
                    at: layout.recordsDir.appendingPathComponent("\(key).vellumweb"))
                if let indexPath = layout.indexPath {
                    WebArchiveIndex.removeEntry(forKey: key, at: indexPath)
                }
                try? FileManager.default.removeItem(at: WebLibrary.archiveDir(forKey: key))
            case .coordinated(let container, let layout):
                try? FileManager.default.removeItem(at: WebLibrary.snapshotPath(forKey: key))
                try? FileManager.default.removeItem(at: WebLibrary.managedArchivePath(forKey: key))
                try? FileManager.default.removeItem(at: WebLibrary.archiveDir(forKey: key))
                if let name = try await Self.indexFileName(
                    forKey: key,
                    layout: layout,
                    container: container,
                    materializing: .requireCurrent) {
                    let archiveURL = layout.archivesDir.appendingPathComponent(name)
                    try? await container.remove(archiveURL)
                }
                try await Self.removeIndexEntry(forKey: key, layout: layout, container: container)
            }
        }
    }

    func reserveManagedArchiveName(forKey key: String) async throws -> String {
        await acquireIndex()
        defer { releaseIndex() }

        return try await withStorageContext {
            try await Self.managedArchiveName(forKey: key, context: $0)
        }
    }

    func writeManagedArchive(
        forKey key: String,
        manifest: ArchiveManifest,
        snapshotHtml: String,
        assets: [CapturedAsset],
        pagesJson: Data,
        annotations: [Annotation]
    ) async throws -> (path: String, bytes: Int) {
        let data = try WebArchive.encodeArchive(
            manifest: manifest,
            snapshotHtml: snapshotHtml,
            assets: assets,
            pagesJson: pagesJson,
            annotations: annotations)

        await acquireIndex()
        defer { releaseIndex() }

        return try await withStorageContext { context in
            let name = try await Self.managedArchiveName(forKey: key, context: context)
            switch context {
            case .direct(let layout):
                let dest = layout.pretty
                    ? layout.archivesDir.appendingPathComponent(name)
                    : layout.archivesDir.appendingPathComponent("\(key).vellumweb")
                try WebArchive.writeArchiveBytes(data, to: dest)
                return (dest.path, data.count)

            case .coordinated(let container, let layout):
                let dest = layout.archivesDir.appendingPathComponent(name)
                try await container.replace(dest, with: data)
                return (dest.path, data.count)
            }
        }
    }

    func readManagedArchive(forKey key: String) async throws -> Data? {
        await acquireIndex()
        defer { releaseIndex() }

        return try await withStorageContext { context in
            switch context {
            case .direct(let layout):
                guard let url = Self.existingManagedArchiveURLDirect(
                    forKey: key, layout: layout) else { return nil }
                return try Data(contentsOf: url)
            case .coordinated(let container, let layout):
                guard let name = try await Self.indexFileName(
                    forKey: key,
                    layout: layout,
                    container: container,
                    materializing: .downloadIfNeeded(timeout: 10))
                else { return nil }
                let url = layout.archivesDir.appendingPathComponent(name)
                return try await container.data(
                    at: url,
                    materializing: .downloadIfNeeded(timeout: 10))
            }
        }
    }

    func listRecordMetadata(readyOnly: Bool = true) async throws -> [Metadata] {
        try await withStorageContext { context in
            switch context {
            case .direct(let layout):
                return WebLibrary.recordFileNames(inDir: layout.recordsDir).map {
                    Metadata(name: $0, readiness: .current, byteSize: nil, contentModifiedAt: nil)
                }
            case .coordinated(let container, let layout):
                return try await container.list(
                    layout.recordsDir,
                    matching: SyncedItemFilter(fileExtension: "json", readyOnly: readyOnly)
                ).map(Self.metadata)
            }
        }
    }

    func listSnapshotStorage() async -> [WebLibrary.SnapshotStorageEntry] {
        let metadata = (try? await listRecordMetadata(readyOnly: false)) ?? []
        let activeNames = Set(metadata.map(\.name))
        let legacyNames = WebLibrary.recordFileNames(inDir: WebLibrary.storeDir)
            .filter { !activeNames.contains($0) }
        var entries: [WebLibrary.SnapshotStorageEntry] = []
        let names = metadata.filter { $0.readiness.isReady }.map(\.name) + legacyNames
        for name in names {
            let key = (name as NSString).deletingPathExtension
            guard let record = await loadRecord(forKey: key) else { continue }
            let bytes = await snapshotArtifactsSize(forKey: key)
            guard bytes > 0 else { continue }
            entries.append(Self.snapshotEntry(record: record, key: key, bytes: bytes))
        }
        entries.sort { $0.byteSize > $1.byteSize }
        return entries
    }

    func totalRecordBytes() async -> Int64 {
        let metadata = (try? await listRecordMetadata(readyOnly: false)) ?? []
        let activeNames = Set(metadata.map(\.name))
        let coordinatedBytes = metadata.reduce(Int64(0)) { $0 + ($1.byteSize ?? 0) }
        let legacyBytes = WebLibrary.recordFileNames(inDir: WebLibrary.storeDir)
            .filter { !activeNames.contains($0) }
            .reduce(Int64(0)) { total, name in
                total + WebICloud.size(
                    ofItemAt: WebLibrary.storeDir.appendingPathComponent(name))
            }
        if metadata.allSatisfy({ $0.byteSize == nil }) {
            return WebLibrary.totalRecordBytes()
        }
        return coordinatedBytes + legacyBytes
    }

    func evictStaleUnsavedSnapshots(
        olderThan cutoff: Date,
        excludingUrls: Set<String>,
        lastOpened: (@Sendable (String) async -> Date?)? = nil
    ) async {
        let metadata = (try? await listRecordMetadata(readyOnly: false)) ?? []
        let activeNames = Set(metadata.map(\.name))
        let names = metadata.filter { $0.readiness.isReady }.map(\.name)
            + WebLibrary.recordFileNames(inDir: WebLibrary.storeDir)
                .filter { !activeNames.contains($0) }
        for name in names {
            let key = (name as NSString).deletingPathExtension
            guard let record = await loadRecord(forKey: key),
                  !record.saved,
                  record.annotations.isEmpty,
                  !excludingUrls.contains(record.url),
                  let opened = await lastOpened?(record.url)
                    ?? WebLibrary.parseRfc3339(record.openedAt)
                    ?? WebLibrary.parseRfc3339(record.savedAt),
                  opened < cutoff
            else { continue }
            await removeLocalSnapshots(forKey: key)
        }
    }

    func removeAllSnapshotArtifacts() async {
        await acquireIndex()
        defer { releaseIndex() }

        try? await withStorageContext { context in
            switch context {
            case .direct:
                WebLibrary.removeAllSnapshotArtifacts()
            case .coordinated(let container, let layout):
                Self.removeDerivedLocalArtifacts()
                let archives = try await container.list(
                    layout.archivesDir,
                    matching: SyncedItemFilter(fileExtension: "vellumweb", readyOnly: false))
                for archive in archives {
                    try? await container.remove(archive.url)
                }
                if let indexPath = layout.indexPath {
                    try? await container.remove(indexPath)
                }
            }
        }
    }

    // MARK: - Locking

    private func acquireRecord(_ key: String) async {
        if !heldRecordKeys.contains(key) {
            heldRecordKeys.insert(key)
            return
        }
        await withCheckedContinuation { continuation in
            recordWaiters[key, default: []].append(continuation)
        }
    }

    private func releaseRecord(_ key: String) {
        if var waiters = recordWaiters[key], !waiters.isEmpty {
            let next = waiters.removeFirst()
            recordWaiters[key] = waiters.isEmpty ? nil : waiters
            next.resume()
        } else {
            heldRecordKeys.remove(key)
        }
    }

    private func acquireIndex() async {
        if !heldIndex {
            heldIndex = true
            return
        }
        await withCheckedContinuation { continuation in
            indexWaiters.append(continuation)
        }
    }

    private func releaseIndex() {
        if indexWaiters.isEmpty {
            heldIndex = false
        } else {
            indexWaiters.removeFirst().resume()
        }
    }

    private func withStorageContext<T: Sendable>(
        _ operation: @Sendable (StorageCoordinator.StorageContext) async throws -> T
    ) async throws -> T {
        if let coordinator {
            return try await coordinator.withStorageContext(operation)
        }
        return try await operation(.direct(layout: WebLibrary.activeLayout))
    }

    // MARK: - Coordinated helpers

    private static func loadRecordCoordinated(
        forKey key: String,
        layout: WebStorageLayout,
        container: any SyncedContainer,
        materializing: Materialization
    ) async throws -> WebPageRecord? {
        let primary = layout.recordsDir.appendingPathComponent("\(key).json")
        let items = try await container.list(
            layout.recordsDir,
            matching: SyncedItemFilter(fileExtension: "json", namePrefix: primary.lastPathComponent))
        guard items.contains(where: { $0.name == primary.lastPathComponent }) else {
            if let legacy = WebLibrary.loadRecord(
                at: WebLibrary.storeDir.appendingPathComponent("\(key).json")) {
                return legacy
            }
            return nil
        }
        return try await container.read(primary, materializing: materializing) { data in
            try JSONDecoder().decode(WebPageRecord.self, from: data)
        }
    }

    private static func managedArchiveName(
        forKey key: String,
        context: StorageCoordinator.StorageContext
    ) async throws -> String {
        switch context {
        case .direct(let layout):
            guard layout.pretty, let indexPath = layout.indexPath else {
                return "\(key).vellumweb"
            }
            let record = loadRecordDirect(forKey: key, layout: layout)
            return WebArchiveIndex.assignFileName(
                forKey: key,
                title: record?.title,
                url: record?.url ?? "",
                at: indexPath,
                archivesDir: layout.archivesDir)

        case .coordinated(let container, let layout):
            let record = try await loadRecordCoordinated(
                forKey: key,
                layout: layout,
                container: container,
                materializing: .downloadIfNeeded(timeout: 10))
            return try await reserveManagedArchiveNameCoordinated(
                forKey: key,
                title: record?.title,
                url: record?.url ?? "",
                layout: layout,
                container: container)
        }
    }

    private static func listSavedCoordinated(
        layout: WebStorageLayout,
        container: any SyncedContainer
    ) async throws -> [WebLibraryEntry] {
        let items = try await container.list(
            layout.recordsDir,
            matching: SyncedItemFilter(fileExtension: "json", readyOnly: false))
        var out: [WebLibraryEntry] = []
        for item in items where item.readiness.isReady {
            guard let record = try? await container.read(
                item.url,
                materializing: .requireCurrent,
                { try JSONDecoder().decode(WebPageRecord.self, from: $0) }
            ), record.saved else { continue }
            let key = WebLibrary.pageKey(record.url)
            let hasDerivedSnapshot = Self.hasDerivedLocalSnapshot(forKey: key)
            let hasManagedArchive = (try? await existingManagedArchiveMetadata(
                forKey: key,
                layout: layout,
                container: container,
                readyOnly: true)) != nil
            let hasSnapshot = hasDerivedSnapshot || hasManagedArchive
            out.append(WebLibraryEntry(
                url: record.url,
                title: record.title,
                pageCount: record.pageCount,
                savedAt: record.savedAt,
                hasSnapshot: hasSnapshot))
        }
        let seenNames = Set(items.map(\.name))
        for name in WebLibrary.recordFileNames(inDir: WebLibrary.storeDir)
            where !seenNames.contains(name) {
            let file = WebLibrary.storeDir.appendingPathComponent(name)
            guard let record = WebLibrary.loadRecord(at: file), record.saved else { continue }
            let key = WebLibrary.pageKey(record.url)
            let hasManagedArchive = (try? await existingManagedArchiveMetadata(
                forKey: key,
                layout: layout,
                container: container,
                readyOnly: true)) != nil
            out.append(WebLibraryEntry(
                url: record.url,
                title: record.title,
                pageCount: record.pageCount,
                savedAt: record.savedAt,
                hasSnapshot: hasDerivedLocalSnapshot(forKey: key) || hasManagedArchive))
        }
        out.sort { a, b in
            switch (a.savedAt, b.savedAt) {
            case (nil, nil): return false
            case (nil, _): return false
            case (_, nil): return true
            case (let x?, let y?): return x > y
            }
        }
        return out
    }

    private static func reserveManagedArchiveNameCoordinated(
        forKey key: String,
        title: String?,
        url: String,
        layout: WebStorageLayout,
        container: any SyncedContainer
    ) async throws -> String {
        guard let indexPath = layout.indexPath else { return "\(key).vellumweb" }
        var contents = try await loadIndexCoordinated(
            at: indexPath,
            container: container,
            materializing: .downloadIfNeeded(timeout: 10))
        if let existing = contents.entries[key] { return existing }

        let base = WebArchiveIndex.sanitizedBaseName(title: title, url: url)
        let archiveItems = try await container.list(
            layout.archivesDir,
            matching: SyncedItemFilter(fileExtension: "vellumweb", readyOnly: false))
        let occupied = Set(contents.entries.values).union(archiveItems.map(\.name))
        var candidate = "\(base).vellumweb"
        var counter = 2
        while occupied.contains(candidate) {
            candidate = "\(base) \(counter).vellumweb"
            counter += 1
        }
        contents.entries[key] = candidate
        let data = try WebLibrary.jsonEncoderPretty.encode(contents)
        try await container.replace(indexPath, with: data)
        return candidate
    }

    private static func removeIndexEntry(
        forKey key: String,
        layout: WebStorageLayout,
        container: any SyncedContainer
    ) async throws {
        guard let indexPath = layout.indexPath else { return }
        var contents = try await Self.loadIndexCoordinated(
            at: indexPath,
            container: container,
            materializing: .requireCurrent)
        guard contents.entries.removeValue(forKey: key) != nil else { return }
        let data = try WebLibrary.jsonEncoderPretty.encode(contents)
        try await container.replace(indexPath, with: data)
    }

    private static func indexFileName(
        forKey key: String,
        layout: WebStorageLayout,
        container: any SyncedContainer,
        materializing: Materialization
    ) async throws -> String? {
        guard let indexPath = layout.indexPath else { return nil }
        let contents = try await loadIndexCoordinated(
            at: indexPath,
            container: container,
            materializing: materializing)
        return contents.entries[key]
    }

    private static func loadIndexCoordinated(
        at indexPath: URL,
        container: any SyncedContainer,
        materializing: Materialization
    ) async throws -> WebArchiveIndex.Contents {
        let items = try await container.list(
            indexPath.deletingLastPathComponent(),
            matching: SyncedItemFilter(fileExtension: "json", namePrefix: indexPath.lastPathComponent))
        guard items.contains(where: { $0.name == indexPath.lastPathComponent }) else {
            return WebArchiveIndex.Contents()
        }
        return try await container.read(indexPath, materializing: materializing) { data in
            try JSONDecoder().decode(WebArchiveIndex.Contents.self, from: data)
        }
    }

    private static func existingManagedArchiveMetadata(
        forKey key: String,
        layout: WebStorageLayout,
        container: any SyncedContainer,
        readyOnly: Bool
    ) async throws -> Metadata? {
        guard let name = try await indexFileName(
            forKey: key,
            layout: layout,
            container: container,
            materializing: .requireCurrent)
        else { return nil }
        let items = try await container.list(
            layout.archivesDir,
            matching: SyncedItemFilter(fileExtension: "vellumweb", readyOnly: readyOnly))
        return items.first(where: { $0.name == name }).map(metadata)
    }

    private static func metadata(_ item: SyncedItem) -> Metadata {
        Metadata(
            name: item.name,
            readiness: item.readiness,
            byteSize: item.byteSize,
            contentModifiedAt: item.contentModifiedAt)
    }

    // MARK: - Direct helpers

    private static func loadRecordDirect(forKey key: String, layout: WebStorageLayout) -> WebPageRecord? {
        let primary = layout.recordsDir.appendingPathComponent("\(key).json")
        return WebLibrary.loadRecord(at: primary)
            ?? WebLibrary.loadRecord(at: WebLibrary.storeDir.appendingPathComponent("\(key).json"))
    }

    private static func listSavedDirect(layout: WebStorageLayout) -> [WebLibraryEntry] {
        var entries: [WebLibraryEntry] = []
        for name in WebLibrary.recordFileNames(inDir: layout.recordsDir) {
            let file = layout.recordsDir.appendingPathComponent(name)
            guard let record = WebLibrary.loadRecord(at: file) else {
                WebICloud.requestDownload(at: file)
                continue
            }
            guard record.saved else { continue }
            let key = WebLibrary.pageKey(record.url)
            entries.append(WebLibraryEntry(
                url: record.url,
                title: record.title,
                pageCount: record.pageCount,
                savedAt: record.savedAt,
                hasSnapshot: hasDerivedLocalSnapshot(forKey: key)
                    || existingManagedArchiveURLDirect(forKey: key, layout: layout) != nil))
        }
        entries.sort { lhs, rhs in
            switch (lhs.savedAt, rhs.savedAt) {
            case (nil, nil): return false
            case (nil, _): return false
            case (_, nil): return true
            case (let lhs?, let rhs?): return lhs > rhs
            }
        }
        return entries
    }

    private static func existingManagedArchiveURLDirect(
        forKey key: String,
        layout: WebStorageLayout
    ) -> URL? {
        if let indexPath = layout.indexPath,
           let name = WebArchiveIndex.fileName(forKey: key, at: indexPath) {
            let url = layout.archivesDir.appendingPathComponent(name)
            if WebICloud.itemExists(at: url) { return url }
        }
        let legacy = layout.recordsDir.appendingPathComponent("\(key).vellumweb")
        var isDirectory: ObjCBool = false
        if FileManager.default.fileExists(atPath: legacy.path, isDirectory: &isDirectory),
           !isDirectory.boolValue {
            return legacy
        }
        return nil
    }

    private static func hasDerivedLocalSnapshot(forKey key: String) -> Bool {
        let fm = FileManager.default
        var isDir: ObjCBool = false
        if fm.fileExists(atPath: WebLibrary.snapshotPath(forKey: key).path, isDirectory: &isDir),
           !isDir.boolValue {
            return true
        }
        let installed = WebLibrary.archiveDir(forKey: key).appendingPathComponent("snapshot.html")
        return fm.fileExists(atPath: installed.path, isDirectory: &isDir) && !isDir.boolValue
    }

    private static func derivedSnapshotBytes(forKey key: String) -> Int64 {
        let fm = FileManager.default
        var total = ((try? fm.attributesOfItem(
            atPath: WebLibrary.snapshotPath(forKey: key).path)[.size]) as? NSNumber)?.int64Value ?? 0
        guard let enumerator = fm.enumerator(
            at: WebLibrary.archiveDir(forKey: key),
            includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey],
            options: [],
            errorHandler: nil)
        else { return total }
        for case let file as URL in enumerator {
            guard let values = try? file.resourceValues(
                forKeys: [.fileSizeKey, .isRegularFileKey]),
                values.isRegularFile == true
            else { continue }
            total += Int64(values.fileSize ?? 0)
        }
        return total
    }

    private static func snapshotEntry(
        record: WebPageRecord,
        key: String,
        bytes: Int64
    ) -> WebLibrary.SnapshotStorageEntry {
        WebLibrary.SnapshotStorageEntry(
            key: key,
            url: record.url,
            title: record.title,
            saved: record.saved,
            hasAnnotations: !record.annotations.isEmpty,
            lastOpened: WebLibrary.parseRfc3339(record.openedAt)
                ?? WebLibrary.parseRfc3339(record.savedAt),
            byteSize: bytes)
    }

    private static func removeDerivedLocalArtifacts() {
        let fm = FileManager.default
        try? fm.removeItem(
            at: WebLibrary.storeDir.appendingPathComponent("archives", isDirectory: true))
        guard let names = try? fm.contentsOfDirectory(atPath: WebLibrary.storeDir.path) else {
            return
        }
        for name in names where name.hasSuffix(".snapshot.html") || name.hasSuffix(".vellumweb") {
            try? fm.removeItem(at: WebLibrary.storeDir.appendingPathComponent(name))
        }
    }

    private static func encodeRecord(_ record: WebPageRecord) throws -> Data {
        do {
            return try WebLibrary.jsonEncoderPretty.encode(record)
        } catch {
            throw SessionServiceError.io(
                "Failed to serialize webpage record: \(error.localizedDescription)")
        }
    }
}
