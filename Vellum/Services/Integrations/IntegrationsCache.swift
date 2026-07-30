import CryptoKit
import Foundation

actor IntegrationsCache {
    struct SnapshotEnvelope: Codable, Sendable { static let currentVersion = 2; let version: Int; var snapshot: ProviderSnapshot }
    struct DownloadManifest: Codable, Hashable, Sendable { let provider: IntegrationProvider; let itemID: String; let revision: String?; let etag: String?; let installedAt: Date }
    struct StagedPath: Sendable { let original: URL; let staged: URL }
    struct DisconnectStaging: Sendable { let directory: URL; let paths: [StagedPath] }
    enum LoadResult: Sendable { case missing, snapshot(ProviderSnapshot), corrupt }

    let root: URL
    private let fileManager: FileManager
    init(root: URL = WebLibrary.appDataDir.appendingPathComponent("integrations", isDirectory: true), fileManager: FileManager = .default) { self.root = root; self.fileManager = fileManager }

    func load(provider: IntegrationProvider) -> LoadResult {
        let primary = snapshotURL(provider), backup = backupURL(provider)
        if let value = decodeSnapshot(at: primary) { return .snapshot(value) }
        if let value = decodeSnapshot(at: backup) { try? Data(contentsOf: backup).write(to: primary, options: .atomic); return .snapshot(value) }
        return fileManager.fileExists(atPath: primary.path) || fileManager.fileExists(atPath: backup.path) ? .corrupt : .missing
    }

    func save(_ snapshot: ProviderSnapshot) throws {
        let directory = providerDirectory(snapshot.provider); try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        let primary = snapshotURL(snapshot.provider), backup = backupURL(snapshot.provider)
        if fileManager.fileExists(atPath: primary.path) { try? fileManager.removeItem(at: backup); try fileManager.copyItem(at: primary, to: backup) }
        try JSONEncoder.integrations.encode(SnapshotEnvelope(version: SnapshotEnvelope.currentVersion, snapshot: snapshot)).write(to: primary, options: .atomic)
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
    func existingDownload(provider: IntegrationProvider, itemID: String) throws -> URL? { let url = try downloadURL(provider: provider, itemID: itemID); return fileManager.fileExists(atPath: url.path) ? url : nil }

    func installDownload(temporaryURL: URL, manifest: DownloadManifest) throws -> URL {
        let destination = try downloadURL(provider: manifest.provider, itemID: manifest.itemID)
        guard !fileManager.fileExists(atPath: destination.path) else { throw IntegrationError.existingDownload }
        try fileManager.moveItem(at: temporaryURL, to: destination)
        do { try JSONEncoder.integrations.encode(manifest).write(to: try manifestURL(provider: manifest.provider, itemID: manifest.itemID), options: .atomic) }
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

    private func decodeSnapshot(at url: URL) -> ProviderSnapshot? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let envelope = try? decoder.decode(SnapshotEnvelope.self, from: data), envelope.version == SnapshotEnvelope.currentVersion else { return nil }
        return envelope.snapshot
    }
    private func providerDirectory(_ provider: IntegrationProvider) -> URL { root.appendingPathComponent(provider.rawValue, isDirectory: true) }
    private func snapshotURL(_ provider: IntegrationProvider) -> URL { providerDirectory(provider).appendingPathComponent("snapshot.json") }
    private func backupURL(_ provider: IntegrationProvider) -> URL { providerDirectory(provider).appendingPathComponent("snapshot.backup.json") }
    static func downloadKey(provider: IntegrationProvider, itemID: String) -> String { SHA256.hash(data: Data("\(provider.rawValue):\(itemID)".utf8)).map { String(format: "%02x", $0) }.joined() }
}
