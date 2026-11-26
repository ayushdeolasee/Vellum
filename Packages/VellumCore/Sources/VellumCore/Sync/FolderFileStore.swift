import Foundation
import CFolderSync

/// Extra primitives a folder backend needs. A filtered library listing can
/// never be used for discovery, and a separate read + write cannot implement CAS.
public protocol FolderFileStore: LibraryFileStore {
    func occupiedNames(in directory: URL) throws -> [String]
    func contents(of directory: URL) throws -> [FolderEntry]
    func replace(_ url: URL, with data: Data, ifCurrent expected: Data?) async throws -> Bool
    func archiveSibling(_ sibling: URL, expected: Data, to archive: URL) async throws -> URL?
}

public extension FolderFileStore {
    func occupiedNames(in directory: URL) throws -> [String] {
        try contents(of: directory).map { $0.url.lastPathComponent }
    }
}

public struct FolderEntry: Sendable {
    public let url: URL
    public let isDirectory: Bool
    public init(url: URL, isDirectory: Bool) {
        self.url = url
        self.isDirectory = isDirectory
    }
}

public struct LocalFolderFileStore: FolderFileStore {
    public let isCoordinated = false
    private let root: URL
    private var fm: FileManager { .default }
    // Shared across instances, bounded even for a long-running library.
    private static let locks = (0..<64).map { _ in NSLock() }

    public init(root: URL) {
        self.root = root.standardizedFileURL
    }

    private func checked(_ url: URL, allowRoot: Bool = false) throws -> URL {
        let candidate = url.standardizedFileURL
        let parts = candidate.pathComponents
        let base = root.pathComponents
        guard url.isFileURL, parts.starts(with: base), allowRoot || parts.count > base.count else {
            throw LibraryFileError.outsideAllowedRoot(url)
        }
        var cursor = root
        for component in [""] + Array(parts.dropFirst(base.count)) {
            if !component.isEmpty { cursor.appendPathComponent(component) }
            if (try? fm.destinationOfSymbolicLink(atPath: cursor.path)) != nil {
                throw LibraryFileError.symbolicLink(cursor)
            }
        }
        return candidate
    }

    private func lock(for url: URL) -> NSLock {
        Self.locks[Int(UInt(bitPattern: url.path.lowercased().hashValue) % UInt(Self.locks.count))]
    }

    private func bytes(_ url: URL) throws -> Data? {
        do { return try Data(contentsOf: url) }
        catch let error as CocoaError where error.code == .fileReadNoSuchFile { return nil }
    }

    public func read(_ url: URL) async throws -> Data? { try bytes(checked(url)) }

    // Include directories, broken symlinks and special files as occupied names
    // without following or opening them during archive placement.
    public func occupiedNames(in directory: URL) throws -> [String] {
        let path = try checked(directory, allowRoot: true)
        do { return try fm.contentsOfDirectory(atPath: path.path) }
        catch let error as CocoaError where error.code == .fileReadNoSuchFile { return [] }
    }

    public func contents(of directory: URL) throws -> [FolderEntry] {
        let dir = try checked(directory, allowRoot: true)
        let keys: Set<URLResourceKey> = [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey]
        do {
            return try fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: Array(keys))
                .compactMap { item in
                    let values = try item.resourceValues(forKeys: keys)
                    guard values.isSymbolicLink != true,
                          values.isDirectory == true || values.isRegularFile == true else { return nil }
                    // Foundation may enumerate /var through /private/var. Keep
                    // descendants in the selected root's URL namespace even
                    // when a later archive destination does not yet exist.
                    let isDirectory = values.isDirectory == true
                    let child = dir.appendingPathComponent(item.lastPathComponent, isDirectory: isDirectory)
                    return FolderEntry(url: child, isDirectory: isDirectory)
                }
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            return []
        }
    }

    public func list(_ directory: URL, suffix: String?) async throws -> [LibraryFileEntry] {
        try contents(of: directory).compactMap { entry in
            let name = entry.url.lastPathComponent
            guard !name.hasPrefix("."), !SyncArtifact.matches(name),
                  suffix.map(name.hasSuffix) ?? true else { return nil }
            let values = try entry.url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
            return LibraryFileEntry(url: entry.url, name: name, readiness: .current,
                                    byteSize: values.fileSize.map(Int64.init),
                                    contentModifiedAt: values.contentModificationDate)
        }.sorted { $0.name < $1.name }
    }

    private func stage(_ data: Data, for url: URL) throws -> URL {
        let parent = url.deletingLastPathComponent()
        try fm.createDirectory(at: parent, withIntermediateDirectories: true)
        let temp = parent.appendingPathComponent(".vellum.tmp-\(UUID().uuidString)")
        try data.write(to: temp, options: .withoutOverwriting)
        return temp
    }

    public func replace(_ url: URL, with data: Data) async throws {
        let path = try checked(url)
        try lock(for: path).withLock {
            let temp = try stage(data, for: path)
            defer { try? fm.removeItem(at: temp) }
            guard rename(temp.path, path.path) == 0 else { throw POSIXError(.init(rawValue: errno) ?? .EIO) }
        }
    }

    public func remove(_ url: URL) async throws {
        let path = try checked(url)
        try lock(for: path).withLock {
            // unlink cannot recursively delete a directory.
            guard unlink(path.path) == 0 || errno == ENOENT else {
                throw POSIXError(.init(rawValue: errno) ?? .EIO)
            }
        }
    }

    public func replace(_ url: URL, with data: Data, ifCurrent expected: Data?) async throws -> Bool {
        let path = try checked(url)
        return try lock(for: path).withLock {
            guard try bytes(path) == expected else { return false }
            let temp = try stage(data, for: path)
            let result = vellum_rename(temp.path, path.path, expected == nil ? 0 : 1)
            guard result == 0 else {
                try fm.removeItem(at: temp)
                if [EEXIST, ENOENT, EOPNOTSUPP, ENOSYS, EINVAL].contains(result) { return false }
                throw POSIXError(.init(rawValue: result) ?? .EIO)
            }
            guard expected != nil else { return true }

            // A sync daemon does not take our lock. Exchange, then inspect the
            // actual displaced inode. If it raced, restore it without unlinking
            // anything an uncoordinated writer may have put at either path.
            do {
                if try bytes(temp) == expected {
                    try fm.removeItem(at: temp)
                    return true
                }
            } catch {
                // A non-regular or unreadable replacement is still user data.
                try exclusiveMove(temp, to: recoveryURL(for: path))
                throw error
            }
            if try bytes(path) == data { _ = vellum_rename(temp.path, path.path, 1) }
            let recovery = try recoveryURL(for: path)
            try exclusiveMove(temp, to: recovery)
            throw LibraryFileError.retryable
        }
    }

    private func exclusiveMove(_ source: URL, to destination: URL) throws {
        let result = vellum_rename(source.path, destination.path, 0)
        guard result == 0 else { throw POSIXError(.init(rawValue: result) ?? .EIO) }
    }

    private func recoveryURL(for url: URL) throws -> URL {
        let recovery = PreserveLosersConflictResolver.archiveURL(
            for: url, version: ConflictVersion(id: UUID().uuidString))
        _ = try checked(recovery)
        try fm.createDirectory(at: recovery.deletingLastPathComponent(), withIntermediateDirectories: true)
        return recovery
    }

    /// Move the actual sibling inode into recovery. Comparing and then
    /// unlinking the live filename could destroy a newer Syncthing version.
    public func archiveSibling(_ sibling: URL, expected: Data, to archive: URL) async throws -> URL? {
        let path = try checked(sibling)
        var destination = try checked(archive)
        return try lock(for: path).withLock {
            guard try bytes(path) == expected else { return nil }
            try fm.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            do { try exclusiveMove(path, to: destination) }
            catch let error as POSIXError where error.code == .EEXIST {
                // The same peer/timestamp may recur. Never overwrite an archive.
                destination = destination.deletingPathExtension().appendingPathExtension(UUID().uuidString)
                    .appendingPathExtension(destination.pathExtension)
                try exclusiveMove(path, to: destination)
            }
            guard try bytes(destination) == expected else {
                // Leave the captured version in recovery if a new sibling
                // already occupies its old name.
                _ = vellum_rename(destination.path, path.path, 0)
                return nil
            }
            return destination
        }
    }
}
