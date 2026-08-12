import CryptoKit
import Foundation

actor IntegrationsCache {
    struct SnapshotEnvelope: Codable, Sendable { static let currentVersion = 3; let version: Int; var snapshot: ProviderSnapshot }
    struct PreservedRevision: Codable, Hashable, Sendable {
        let revision: String?
        let fileName: String
    }
    /// What an installed PDF is a copy *of*. `revision` is the item's server
    /// revision at install time and is read back on every open, so an item the
    /// service has since replaced is re-downloaded instead of reused forever.
    /// Optional fields keep manifests written by older builds readable: those
    /// builds always stored the active bytes at the legacy `<item-key>.pdf`.
    struct DownloadManifest: Codable, Hashable, Sendable {
        let provider: IntegrationProvider
        let itemID: String
        let revision: String?
        var fileName: String?
        var preservedRevisions: [PreservedRevision]?
        var revisionWarningPending: Bool?

        init(
            provider: IntegrationProvider, itemID: String, revision: String?,
            fileName: String? = nil, preservedRevisions: [PreservedRevision]? = nil,
            revisionWarningPending: Bool? = nil
        ) {
            self.provider = provider
            self.itemID = itemID
            self.revision = revision
            self.fileName = fileName
            self.preservedRevisions = preservedRevisions
            self.revisionWarningPending = revisionWarningPending
        }
    }
    struct DownloadInstallation: Hashable, Sendable {
        let currentURL: URL
        let preservedRevisionURL: URL?
    }
    struct StagedPath: Sendable { let original: URL; let staged: URL }
    struct DisconnectStaging: Sendable { let directory: URL; let paths: [StagedPath] }
    enum LoadResult: Sendable { case missing, snapshot(ProviderSnapshot), corrupt }
    private enum DecodeResult { case absent, wrongVersion, unreadable, snapshot(ProviderSnapshot) }

    let root: URL
    private let fileManager: FileManager
    init(root: URL = WebLibrary.appDataDir.appendingPathComponent("integrations", isDirectory: true), fileManager: FileManager = .default) { self.root = root; self.fileManager = fileManager }

    /// A snapshot written by another schema version is not damage — it is state
    /// this build cannot read — so it loads as `.missing` and re-syncs silently.
    /// Reporting it as `.corrupt` would show "the local cache is damaged" to
    /// every user on the next schema bump. Only genuinely undecodable bytes
    /// (a truncated or overwritten file) are `.corrupt`.
    func load(provider: IntegrationProvider) -> LoadResult {
        let primary = snapshotURL(provider), backup = backupURL(provider)
        let primaryResult = decodeSnapshot(at: primary)
        if case .snapshot(let value) = primaryResult { return .snapshot(value) }
        let backupResult = decodeSnapshot(at: backup)
        if case .snapshot(let value) = backupResult { try? Data(contentsOf: backup).write(to: primary, options: .atomic); return .snapshot(value) }
        for result in [primaryResult, backupResult] { if case .unreadable = result { return .corrupt } }
        return .missing
    }

    func save(_ snapshot: ProviderSnapshot) throws {
        let directory = providerDirectory(snapshot.provider); try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        let primary = snapshotURL(snapshot.provider), backup = backupURL(snapshot.provider)
        if fileManager.fileExists(atPath: primary.path) { try? fileManager.removeItem(at: backup); try fileManager.copyItem(at: primary, to: backup) }
        try Self.snapshotEncoder.encode(SnapshotEnvelope(version: SnapshotEnvelope.currentVersion, snapshot: snapshot)).write(to: primary, options: .atomic)
    }

    func deleteSnapshot(provider: IntegrationProvider) throws { for url in [snapshotURL(provider), backupURL(provider)] where fileManager.fileExists(atPath: url.path) { try fileManager.removeItem(at: url) } }

    /// Refiles one cached item under a new collection as a single actor-isolated
    /// read-modify-write, so a concurrent patch or disconnect can never interleave
    /// between the load and the save (which also prevents a move from resurrecting
    /// a snapshot a disconnect just deleted). No-op when the snapshot is missing
    /// or belongs to another connection generation/account.
    func patchItemCollection(provider: IntegrationProvider, itemID: ReadLaterItem.ID, collectionID: String, updatedAt: Date, expectedGeneration: Int, expectedFingerprint: String) throws {
        guard case .snapshot(var snapshot) = load(provider: provider),
              snapshot.connectionGeneration == expectedGeneration,
              snapshot.accountFingerprint == expectedFingerprint else { return }
        snapshot.items = snapshot.items
            .map { $0.id == itemID ? $0.movingToCollection(collectionID, updatedAt: updatedAt) : $0 }
            .sorted { $0.updatedAt == $1.updatedAt ? $0.id < $1.id : $0.updatedAt > $1.updatedAt }
        try save(snapshot)
    }
    func downloadsDirectory(provider: IntegrationProvider) throws -> URL { let url = providerDirectory(provider).appendingPathComponent("downloads", isDirectory: true); try fileManager.createDirectory(at: url, withIntermediateDirectories: true); return url }
    /// The path used by manifests written before revision preservation. Kept as
    /// an internal compatibility seam and for tests that stage legacy state.
    func downloadURL(provider: IntegrationProvider, itemID: String) throws -> URL { try downloadsDirectory(provider: provider).appendingPathComponent(Self.downloadKey(provider: provider, itemID: itemID) + ".pdf") }
    func manifestURL(provider: IntegrationProvider, itemID: String) throws -> URL { try downloadsDirectory(provider: provider).appendingPathComponent(Self.downloadKey(provider: provider, itemID: itemID) + ".json") }

    /// The installed copy of this item, but only while it still matches
    /// `revision`. A file that exists is not the same as a file that is current:
    /// reusing one on existence alone pins the reader to a version the service
    /// replaced days ago, and no later sync would ever dislodge it.
    func currentDownload(provider: IntegrationProvider, itemID: String, revision: String?) throws -> URL? {
        guard let manifest = manifest(provider: provider, itemID: itemID),
              manifest.revision == revision else { return nil }
        let url = try downloadURL(for: manifest)
        guard fileManager.fileExists(atPath: url.path) else { return nil }
        return url
    }

    /// Installs every server revision at an immutable path, then atomically
    /// advances the manifest. The old path is never rewritten or removed, so a
    /// user's embedded annotations remain recoverable and an already-open tab
    /// cannot have its backing file changed underneath PDFKit.
    func installDownload(temporaryURL: URL, manifest requested: DownloadManifest) throws -> DownloadInstallation {
        let oldManifest = manifest(provider: requested.provider, itemID: requested.itemID)
        if let oldManifest, oldManifest.revision == requested.revision,
           fileManager.fileExists(atPath: try downloadURL(for: oldManifest).path) {
            throw IntegrationError.existingDownload
        }

        let directory = try downloadsDirectory(provider: requested.provider)
        let destination = directory.appendingPathComponent(
            Self.revisionFileName(
                provider: requested.provider, itemID: requested.itemID,
                revision: requested.revision))
        try fileManager.moveItem(at: temporaryURL, to: destination)

        var preserved = oldManifest?.preservedRevisions ?? []
        var preservedURL: URL?
        if let oldManifest {
            let oldURL = try downloadURL(for: oldManifest)
            if fileManager.fileExists(atPath: oldURL.path), oldURL != destination {
                let record = PreservedRevision(
                    revision: oldManifest.revision, fileName: oldURL.lastPathComponent)
                preserved.removeAll { $0.fileName == record.fileName }
                preserved.append(record)
                preservedURL = oldURL
            }
        }

        let installedManifest = DownloadManifest(
            provider: requested.provider,
            itemID: requested.itemID,
            revision: requested.revision,
            fileName: destination.lastPathComponent,
            preservedRevisions: preserved.isEmpty ? nil : preserved,
            revisionWarningPending: preservedURL == nil ? nil : true)
        do {
            try writeManifest(installedManifest)
        } catch {
            // The old manifest and every old revision are still intact. Remove
            // only the uncommitted new bytes so a failed metadata write cannot
            // turn into either data loss or an ambiguous active revision.
            try? fileManager.removeItem(at: destination)
            throw error
        }
        return DownloadInstallation(
            currentURL: destination, preservedRevisionURL: preservedURL)
    }

    func pendingPreviousRevisionURL(provider: IntegrationProvider, itemID: String) throws -> URL? {
        guard let manifest = manifest(provider: provider, itemID: itemID),
              manifest.revisionWarningPending == true,
              let previous = manifest.preservedRevisions?.last else { return nil }
        let url = try revisionURL(
            fileName: previous.fileName, provider: provider, itemID: itemID)
        return fileManager.fileExists(atPath: url.path) ? url : nil
    }

    func acknowledgeRevisionWarning(
        provider: IntegrationProvider, itemID: String, previousRevisionURL: URL
    ) throws {
        guard var manifest = manifest(provider: provider, itemID: itemID),
              manifest.revisionWarningPending == true,
              manifest.preservedRevisions?.last?.fileName == previousRevisionURL.lastPathComponent
        else { return }
        manifest.revisionWarningPending = false
        try writeManifest(manifest)
    }

    /// Whether an id names real download artifacts. The id-only retention path
    /// uses this to distinguish a vanished PDF (reclaimable by provider/id)
    /// from an article whose URL-keyed archive cannot be reconstructed.
    func existingDownloadURL(provider: IntegrationProvider, itemID: String) -> URL? {
        guard let manifest = manifest(provider: provider, itemID: itemID),
            let pdf = try? downloadURL(for: manifest),
            fileManager.fileExists(atPath: pdf.path)
        else { return nil }
        return pdf
    }

    func hasDownloadArtifacts(provider: IntegrationProvider, itemID: String) -> Bool {
        let manifestExists = (try? manifestURL(provider: provider, itemID: itemID))
            .map { fileManager.fileExists(atPath: $0.path) } ?? false
        return manifestExists || !downloadURLs(provider: provider, itemID: itemID).isEmpty
    }

    /// Deletes one installed copy and its manifest — the retention sweep's
    /// counterpart to `installDownload`. Reports whether anything is gone from
    /// disk afterwards: a copy that never existed is already "deleted" as far
    /// as the caller is concerned, while a file that refused to go keeps the
    /// item tracked for the next sweep.
    func deleteDownload(provider: IntegrationProvider, itemID: String) -> Bool {
        let downloads = downloadURLs(provider: provider, itemID: itemID)
        for pdf in downloads { try? fileManager.removeItem(at: pdf) }
        if let manifest = try? manifestURL(provider: provider, itemID: itemID),
            fileManager.fileExists(atPath: manifest.path)
        {
            try? fileManager.removeItem(at: manifest)
        }
        return downloadURLs(provider: provider, itemID: itemID).isEmpty
    }

    func downloadByteSize(provider: IntegrationProvider, itemID: String) -> Int {
        downloadURLs(provider: provider, itemID: itemID).reduce(0) { total, url in
            let attributes = try? fileManager.attributesOfItem(atPath: url.path)
            return total + ((attributes?[.size] as? NSNumber)?.intValue ?? 0)
        }
    }

    func downloadURLs(provider: IntegrationProvider, itemID: String) -> [URL] {
        guard let directory = try? downloadsDirectory(provider: provider) else { return [] }
        let key = Self.downloadKey(provider: provider, itemID: itemID)
        return contents(of: directory).filter {
            $0.pathExtension.lowercased() == "pdf"
                && ($0.lastPathComponent == key + ".pdf"
                    || $0.lastPathComponent.hasPrefix(key + "-"))
        }
    }

    func managedDownloadURLs(provider: IntegrationProvider) -> [URL] {
        let directory = providerDirectory(provider).appendingPathComponent("downloads", isDirectory: true)
        return (try? fileManager.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil).filter { $0.pathExtension.lowercased() == "pdf" }) ?? []
    }
    func deleteDownloads(provider: IntegrationProvider) throws { let directory = providerDirectory(provider).appendingPathComponent("downloads", isDirectory: true); if fileManager.fileExists(atPath: directory.path) { try fileManager.removeItem(at: directory) } }
    func stageDisconnect(provider: IntegrationProvider, deleteDownloads: Bool) throws -> DisconnectStaging {
        let stagingDirectory = providerDirectory(provider).appendingPathComponent(".disconnect-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: stagingDirectory, withIntermediateDirectories: true)
        let downloads = providerDirectory(provider).appendingPathComponent("downloads", isDirectory: true)
        let candidates = [snapshotURL(provider), backupURL(provider)] + (deleteDownloads ? [downloads] : [])
        var paths: [StagedPath] = []
        do {
            for original in candidates where fileManager.fileExists(atPath: original.path) {
                let staged = stagingDirectory.appendingPathComponent(original.lastPathComponent, isDirectory: original.hasDirectoryPath)
                try fileManager.moveItem(at: original, to: staged)
                paths.append(.init(original: original, staged: staged))
            }
            return .init(directory: stagingDirectory, paths: paths)
        } catch {
            for path in paths.reversed() where fileManager.fileExists(atPath: path.staged.path) { try? fileManager.moveItem(at: path.staged, to: path.original) }
            try? fileManager.removeItem(at: stagingDirectory)
            throw error
        }
    }
    func rollbackDisconnect(_ staging: DisconnectStaging) throws {
        for path in staging.paths.reversed() where fileManager.fileExists(atPath: path.staged.path) { try fileManager.moveItem(at: path.staged, to: path.original) }
        if fileManager.fileExists(atPath: staging.directory.path) { try fileManager.removeItem(at: staging.directory) }
    }
    func commitDisconnect(_ staging: DisconnectStaging) throws { if fileManager.fileExists(atPath: staging.directory.path) { try fileManager.removeItem(at: staging.directory) } }
    func temporaryDownloadURL(provider: IntegrationProvider, itemID: String) throws -> URL { try downloadsDirectory(provider: provider).appendingPathComponent(".\(Self.downloadKey(provider: provider, itemID: itemID)).\(UUID().uuidString).download") }

    /// Deletes what interrupted work leaves behind: `.disconnect-<uuid>` staging
    /// directories whose commit or rollback never ran (a crash mid-disconnect
    /// leaks a full copy of the snapshot and downloads forever) and `.download`
    /// part files from transfers that never finished. Only artifacts older than
    /// `maximumAge` are touched, so a sweep can never delete work in flight.
    func sweepStaleArtifacts(now: Date, maximumAge: TimeInterval = 3600) {
        let cutoff = now.addingTimeInterval(-maximumAge)
        for provider in IntegrationProvider.allCases {
            let directory = providerDirectory(provider)
            for url in contents(of: directory) where url.lastPathComponent.hasPrefix(".disconnect-") { removeIfCreated(url, before: cutoff) }
            for url in contents(of: directory.appendingPathComponent("downloads", isDirectory: true)) where url.pathExtension == "download" { removeIfCreated(url, before: cutoff) }
        }
    }

    private func contents(of directory: URL) -> [URL] { (try? fileManager.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.creationDateKey, .contentModificationDateKey], options: [])) ?? [] }
    private func removeIfCreated(_ url: URL, before cutoff: Date) {
        let values = try? url.resourceValues(forKeys: [.creationDateKey, .contentModificationDateKey])
        guard let stamp = values?.creationDate ?? values?.contentModificationDate, stamp < cutoff else { return }
        try? fileManager.removeItem(at: url)
    }
    private func manifest(provider: IntegrationProvider, itemID: String) -> DownloadManifest? {
        guard let url = try? manifestURL(provider: provider, itemID: itemID), let data = try? Data(contentsOf: url) else { return nil }
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(DownloadManifest.self, from: data)
    }
    private func downloadURL(for manifest: DownloadManifest) throws -> URL {
        guard let fileName = manifest.fileName else {
            return try downloadURL(provider: manifest.provider, itemID: manifest.itemID)
        }
        return try revisionURL(
            fileName: fileName, provider: manifest.provider, itemID: manifest.itemID)
    }
    private func revisionURL(
        fileName: String, provider: IntegrationProvider, itemID: String
    ) throws -> URL {
        let key = Self.downloadKey(provider: provider, itemID: itemID)
        guard fileName == (fileName as NSString).lastPathComponent,
              fileName.hasPrefix(key + "-"),
              fileName.lowercased().hasSuffix(".pdf")
        else { throw IntegrationError.invalidResponse }
        return try downloadsDirectory(provider: provider).appendingPathComponent(fileName)
    }
    private func writeManifest(_ manifest: DownloadManifest) throws {
        try JSONEncoder.integrations.encode(manifest).write(
            to: try manifestURL(provider: manifest.provider, itemID: manifest.itemID),
            options: .atomic)
    }
    private func decodeSnapshot(at url: URL) -> DecodeResult {
        guard let data = try? Data(contentsOf: url) else { return .absent }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        // Probe the version FIRST, alone. Decoding the whole envelope in one
        // shot means a payload from any future schema fails decoding before the
        // version comparison runs — reported as corruption ("cache is damaged")
        // instead of the silent re-sync `.wrongVersion` exists to provide.
        struct VersionProbe: Decodable { let version: Int }
        guard let probe = try? decoder.decode(VersionProbe.self, from: data) else { return .unreadable }
        guard probe.version == SnapshotEnvelope.currentVersion else { return .wrongVersion }
        guard let envelope = try? decoder.decode(SnapshotEnvelope.self, from: data) else { return .unreadable }
        return .snapshot(envelope.snapshot)
    }
    private func providerDirectory(_ provider: IntegrationProvider) -> URL { root.appendingPathComponent(provider.rawValue, isDirectory: true) }
    private func snapshotURL(_ provider: IntegrationProvider) -> URL { providerDirectory(provider).appendingPathComponent("snapshot.json") }
    private func backupURL(_ provider: IntegrationProvider) -> URL { providerDirectory(provider).appendingPathComponent("snapshot.backup.json") }
    /// Snapshots are machine-read only and are rewritten on every walk
    /// checkpoint, so they skip the key sorting `JSONEncoder.integrations` does
    /// for the small payloads people read — a full library runs to megabytes and
    /// nothing here benefits from a stable key order.
    private static var snapshotEncoder: JSONEncoder { let value = JSONEncoder(); value.dateEncodingStrategy = .iso8601; value.outputFormatting = [.withoutEscapingSlashes]; return value }
    static func downloadKey(provider: IntegrationProvider, itemID: String) -> String { SHA256.hash(data: Data("\(provider.rawValue):\(itemID)".utf8)).map { String(format: "%02x", $0) }.joined() }
    private static func revisionFileName(provider: IntegrationProvider, itemID: String, revision: String?) -> String {
        let key = downloadKey(provider: provider, itemID: itemID)
        let revisionKey = SHA256.hash(data: Data((revision ?? "unknown").utf8))
            .prefix(8).map { String(format: "%02x", $0) }.joined()
        return "\(key)-\(revisionKey)-\(UUID().uuidString.lowercased()).pdf"
    }
}
