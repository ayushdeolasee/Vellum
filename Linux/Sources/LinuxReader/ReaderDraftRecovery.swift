import Foundation
import VellumCore

/// Device-local, immutable draft versions. A reader removes only a version it
/// loaded or published. Other processes can recover their own version later.
public actor ReaderDraftRecovery {
    private let base: URL
    private var known: [URL: URL] = [:]
    private static let limit = 64 * 1024 * 1024

    public init(root: RootDirectory) {
        let env = ProcessInfo.processInfo.environment
        let state = env["XDG_STATE_HOME"].flatMap { $0.hasPrefix("/") ? URL(fileURLWithPath: $0) : nil }
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".local/state")
        let library = DocumentIdentity.sha256Hex(root.identity + "\n" + root.url.path)
        base = state.appendingPathComponent("vellum/recovery/" + library, isDirectory: true)
    }

    private func directory(_ document: String, _ kind: String) -> URL {
        base.appendingPathComponent(DocumentIdentity.sha256Hex(kind + "\n" + document), isDirectory: true)
    }

    public func save(_ data: Data, document: String, kind: String) throws {
        guard data.count <= Self.limit else { throw ReaderFileError.fileTooLarge }
        let dir = directory(document, kind)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true,
                                               attributes: [.posixPermissions: 0o700])
        let file = dir.appendingPathComponent(UUID().uuidString + ".draft")
        try data.write(to: file, options: .atomic)
        if let old = known.updateValue(file, forKey: dir) { try? FileManager.default.removeItem(at: old) }
    }

    public func load(document: String, kind: String) throws -> Data? {
        let dir = directory(document, kind)
        let files: [URL]
        do { files = try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) }
        catch let error as CocoaError where error.code == .fileReadNoSuchFile { return nil }
        let candidates = try files.filter { $0.pathExtension == "draft" }.compactMap { file -> (URL, Date)? in
            let values = try file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .contentModificationDateKey])
            guard values.isRegularFile == true, values.isSymbolicLink != true else { return nil }
            return (file, values.contentModificationDate ?? .distantPast)
        }
        guard let file = candidates.max(by: { $0.1 < $1.1 })?.0 else { return nil }
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        let bytes = try handle.read(upToCount: Self.limit + 1) ?? Data()
        guard bytes.count <= Self.limit else { throw ReaderFileError.fileTooLarge }
        known[dir] = file
        return bytes
    }

    public func remove(document: String, kind: String) throws {
        let dir = directory(document, kind)
        guard let file = known[dir] else { return }
        do { try FileManager.default.removeItem(at: file) }
        catch let error as CocoaError where error.code == .fileNoSuchFile { }
        known[dir] = nil
    }
}
