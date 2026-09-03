import Foundation

/// Device-local storage for security-scoped PDF bookmarks.
///
/// This store deliberately lives outside `DocumentDataStore`: `documents/<key>/`
/// may sync, be bundled, or be exported beside user data, while bookmark bytes
/// are device credentials that are only meaningful on the device that minted
/// them. The legacy `DocumentInfo.bookmarkData` field remains decodable for old
/// workspace JSON, but new durable access recovery is written here.
final class DocumentAccessBookmarkStore: @unchecked Sendable {
    static let shared = DocumentAccessBookmarkStore()

    nonisolated(unsafe) static var rootDirectoryOverride: URL?

    struct Entry: Codable, Equatable, Sendable {
        var key: String
        var lastKnownPath: String
        var bookmarkData: Data
        var updatedAt: String

        enum CodingKeys: String, CodingKey {
            case key
            case lastKnownPath = "last_known_path"
            case bookmarkData = "bookmark_data"
            case updatedAt = "updated_at"
        }
    }

    private struct Payload: Codable {
        var version: Int
        var entries: [String: Entry]
    }

    private let directoryOverride: URL?
    private let lock = NSLock()

    init(directory: URL? = nil) {
        self.directoryOverride = directory
    }

    var directory: URL {
        if let directoryOverride { return directoryOverride }
        if let root = Self.rootDirectoryOverride { return root }
        let appSupport = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        )[0]
        return appSupport
            .appendingPathComponent(RuntimeProfile.current.localStorageDirectoryName, isDirectory: true)
            .appendingPathComponent("DocumentAccess", isDirectory: true)
    }

    var fileURL: URL {
        directory.appendingPathComponent("bookmarks.json")
    }

    var corruptFileURL: URL {
        directory.appendingPathComponent("bookmarks.json.corrupt")
    }

    static func key(for document: DocumentInfo) -> String {
        if let docId = document.docId, docId.isEmpty == false {
            return docId
        }
        return DocumentIdentity.sha256Hex(document.pdfPath)
    }

    func entry(forKey key: String) -> Entry? {
        lock.withLock {
            loadEntriesLocked()[key]
        }
    }

    func bookmarkData(forKey key: String) -> Data? {
        entry(forKey: key)?.bookmarkData
    }

    func upsert(key: String, lastKnownPath: String, bookmarkData: Data) throws {
        try lock.withLock {
            var entries = loadEntriesLocked()
            entries[key] = Entry(
                key: key,
                lastKnownPath: lastKnownPath,
                bookmarkData: bookmarkData,
                updatedAt: WebLibrary.rfc3339Now())
            try saveEntriesLocked(entries)
        }
    }

    func remove(key: String) throws {
        try lock.withLock {
            var entries = loadEntriesLocked()
            entries[key] = nil
            try saveEntriesLocked(entries)
        }
    }

    func removeAll() throws {
        lock.withLock {
            try? FileManager.default.removeItem(at: fileURL)
            try? FileManager.default.removeItem(at: corruptFileURL)
        }
    }

    private func loadEntriesLocked() -> [String: Entry] {
        let url = fileURL
        guard let data = try? Data(contentsOf: url), data.isEmpty == false else {
            return [:]
        }
        do {
            let payload = try JSONDecoder().decode(Payload.self, from: data)
            guard payload.version == 1 else { return [:] }
            return payload.entries
        } catch {
            quarantineCorruptStoreLocked()
            return [:]
        }
    }

    private func saveEntriesLocked(_ entries: [String: Entry]) throws {
        let dir = directory
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        } catch {
            throw DocumentAccessError.storeUnavailable(
                "Failed to create bookmark directory: \(error.localizedDescription)")
        }

        let payload = Payload(version: 1, entries: entries)
        let data: Data
        do {
            data = try JSONEncoder().encode(payload)
        } catch {
            throw DocumentAccessError.storeUnavailable(
                "Failed to encode bookmark store: \(error.localizedDescription)")
        }

        let tmp = dir.appendingPathComponent(".bookmarks-\(UUID().uuidString.lowercased()).tmp")
        do {
            try data.write(to: tmp)
            guard rename(tmp.path, fileURL.path) == 0 else {
                throw DocumentAccessError.storeUnavailable("rename failed")
            }
        } catch {
            try? FileManager.default.removeItem(at: tmp)
            throw DocumentAccessError.storeUnavailable(
                "Failed to save bookmark store: \(error.localizedDescription)")
        }
    }

    private func quarantineCorruptStoreLocked() {
        let fm = FileManager.default
        try? fm.createDirectory(at: directory, withIntermediateDirectories: true)
        try? fm.removeItem(at: corruptFileURL)
        if fm.fileExists(atPath: fileURL.path) {
            try? fm.moveItem(at: fileURL, to: corruptFileURL)
        }
    }
}

private extension NSLock {
    func withLock<R>(_ body: () throws -> R) rethrows -> R {
        lock()
        defer { unlock() }
        return try body()
    }
}
