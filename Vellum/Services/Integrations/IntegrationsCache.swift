import CryptoKit
import Foundation

actor IntegrationsCache {
    struct SnapshotEnvelope: Codable, Sendable { static let currentVersion = 3; let version: Int; var snapshot: ProviderSnapshot }
    /// What an installed PDF is a copy *of*. `revision` is the item's server
    /// revision at install time and is read back on every open, so an item the
    /// service has since replaced is re-downloaded instead of reused forever.
    struct DownloadManifest: Codable, Hashable, Sendable { let provider: IntegrationProvider; let itemID: String; let revision: String? }
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
    func downloadURL(provider: IntegrationProvider, itemID: String) throws -> URL { try downloadsDirectory(provider: provider).appendingPathComponent(Self.downloadKey(provider: provider, itemID: itemID) + ".pdf") }
    func manifestURL(provider: IntegrationProvider, itemID: String) throws -> URL { try downloadsDirectory(provider: provider).appendingPathComponent(Self.downloadKey(provider: provider, itemID: itemID) + ".json") }

    /// The installed copy of this item, but only while it still matches
    /// `revision`. A file that exists is not the same as a file that is current:
    /// reusing one on existence alone pins the reader to a version the service
    /// replaced days ago, and no later sync would ever dislodge it.
    func currentDownload(provider: IntegrationProvider, itemID: String, revision: String?) throws -> URL? {
        let url = try downloadURL(provider: provider, itemID: itemID)
        guard fileManager.fileExists(atPath: url.path), manifest(provider: provider, itemID: itemID)?.revision == revision else { return nil }
        return url
    }

    /// Installs a freshly downloaded PDF, replacing a stale copy in place.
    /// An existing copy of the *same* revision means two downloads raced, so
    /// that stays an `existingDownload` error rather than pointless rewriting.
    func installDownload(temporaryURL: URL, manifest newManifest: DownloadManifest) throws -> URL {
        let destination = try downloadURL(provider: newManifest.provider, itemID: newManifest.itemID)
        if fileManager.fileExists(atPath: destination.path) {
            guard manifest(provider: newManifest.provider, itemID: newManifest.itemID)?.revision != newManifest.revision else { throw IntegrationError.existingDownload }
            _ = try fileManager.replaceItemAt(destination, withItemAt: temporaryURL)
        } else {
            try fileManager.moveItem(at: temporaryURL, to: destination)
        }
        do { try JSONEncoder.integrations.encode(newManifest).write(to: try manifestURL(provider: newManifest.provider, itemID: newManifest.itemID), options: .atomic) }
        catch { try? fileManager.removeItem(at: destination); throw error }
        return destination
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
    private func decodeSnapshot(at url: URL) -> DecodeResult {
        guard let data = try? Data(contentsOf: url) else { return .absent }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let envelope = try? decoder.decode(SnapshotEnvelope.self, from: data) else { return .unreadable }
        return envelope.version == SnapshotEnvelope.currentVersion ? .snapshot(envelope.snapshot) : .wrongVersion
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
}
