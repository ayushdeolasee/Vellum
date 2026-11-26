import Foundation
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

/// A local write-ahead journal. The private library stays intact. Only the
/// selected PDFs' state is published, under the identity proved by their bytes.
public struct SharedPDFMigration: Sendable {
    public enum Failure: LocalizedError {
        case changed(String), invalid(String)
        public var errorDescription: String? {
            switch self {
            case .changed(let path): "Migration stopped because the contents changed at \(path). Both versions have been kept."
            case .invalid(let path): "Cannot verify the library data at \(path)."
            }
        }
    }

    private struct Change: Codable {
        let relative: String
        let before: String?
        let after: String
    }

    private struct Source: Codable {
        let url: URL
        let digest: String
    }

    private struct Journal: Codable {
        let root: URL
        let local: URL
        let id: UUID
        struct PDF: Codable {
            let source: URL
            let relative: String
            let key: String
        }
        var pdfs: [PDF] = []
        var inputs: [Source] = []
        var directories: [String: [String]] = [:]
        var changes: [Change] = []
        var createdDirectories: [URL] = []
        var completed = 0
        var pending = false
        var reversing = false
    }

    private let location: SharedPDFLocation
    private let local: URL
    private let journalDir: URL
    private var manifest: URL { journalDir.appendingPathComponent("migration.json") }
    private var store: LocalFolderFileStore { LocalFolderFileStore(root: location.root) }
    private var fm: FileManager { .default }

    public init(root: URL, localData: URL, journals: URL) throws {
        location = SharedPDFLocation(root: root)
        local = localData.standardizedFileURL.resolvingSymlinksInPath()
        journalDir = journals.standardizedFileURL.resolvingSymlinksInPath()
            .appendingPathComponent(DocumentIdentity.sha256Hex(location.root.path), isDirectory: true)
        let base = location.root.pathComponents
        guard !local.pathComponents.starts(with: base), !base.starts(with: local.pathComponents),
              !journalDir.pathComponents.starts(with: base), !base.starts(with: journalDir.pathComponents)
        else { throw Failure.invalid("overlapping library roots") }
    }

    /// The lock lives outside the transaction directory so retiring a completed
    /// rollback cannot admit a second process while the first still holds it.
    private func lockJournal() throws -> FileHandle {
        let parent = journalDir.deletingLastPathComponent()
        try fm.createDirectory(at: parent, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let fd = open(journalDir.path + ".lock", O_RDWR | O_CREAT | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw Failure.invalid(parent.path) }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else { throw Failure.changed("another migration is running") }
        return handle
    }

    private func persist(_ data: Data, to url: URL) throws {
        try data.write(to: url, options: .atomic)
        let file = try FileHandle(forWritingTo: url)
        try file.synchronize()
        try file.close()
        let dir = open(url.deletingLastPathComponent().path, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard dir >= 0 else { throw Failure.invalid(url.path) }
        defer { close(dir) }
        guard fsync(dir) == 0 else { throw Failure.invalid(url.path) }
    }

    private func save(_ journal: Journal) throws {
        try persist(JSONEncoder().encode(journal), to: manifest)
    }

    private func blob(_ digest: String) -> URL { journalDir.appendingPathComponent(digest) }

    private func snapshot(_ data: Data) throws -> String {
        let digest = DocumentIdentity.byteHash(data)
        let url = blob(digest)
        if !fm.fileExists(atPath: url.path) { try persist(data, to: url) }
        guard try Data(contentsOf: url) == data else { throw Failure.changed(url.path) }
        return digest
    }

    private func contents(_ digest: String) throws -> Data {
        guard digest.count == 64, DocumentIdentity.isCanonicalKey(digest) else { throw Failure.invalid("journal blob") }
        let data = try Data(contentsOf: blob(digest))
        guard DocumentIdentity.byteHash(data) == digest else { throw Failure.changed(blob(digest).path) }
        return data
    }

    private func journal() throws -> Journal? {
        let data: Data
        do { data = try Data(contentsOf: manifest) }
        catch let error as CocoaError where error.code == .fileReadNoSuchFile { return nil }
        let j = try JSONDecoder().decode(Journal.self, from: data)
        guard j.root.path == location.root.path, j.local.path == local.path, (0...j.changes.count).contains(j.completed),
              !j.pending || j.completed < j.changes.count else { throw Failure.invalid(manifest.path) }
        return j
    }

    /// Enumerate every regular sidecar, including unrecognized filenames. Refuse
    /// symbolic links and special files rather than silently omitting user data.
    private func files(in dir: URL) throws -> [String] {
        func walk(_ url: URL, prefix: String) throws -> [String] {
            let children: [URL]
            do { children = try fm.contentsOfDirectory(at: url, includingPropertiesForKeys: nil) }
            catch let error as CocoaError where error.code == .fileReadNoSuchFile && prefix.isEmpty { return [] }
            var result = [String]()
            for child in children {
                let key = prefix + child.lastPathComponent
                switch try fm.attributesOfItem(atPath: child.path)[.type] as? FileAttributeType {
                case .typeRegular: result.append(key)
                case .typeDirectory: result += try walk(child, prefix: key + "/")
                default: throw Failure.invalid(child.path)
                }
            }
            return result.sorted()
        }
        guard dir.resolvingSymlinksInPath().standardizedFileURL.path == dir.standardizedFileURL.path,
              (try? fm.destinationOfSymbolicLink(atPath: dir.path)) == nil else { throw Failure.invalid(dir.path) }
        return try walk(dir, prefix: "")
    }

    private func change(_ data: Data, relative: String, before: Data? = nil, journal: inout Journal) throws {
        guard !journal.changes.contains(where: { $0.relative == relative }) else { throw Failure.invalid(relative) }
        journal.changes.append(Change(relative: relative, before: try before.map(snapshot), after: try snapshot(data)))
    }

    /// Finish an interrupted transaction before accepting another selection.
    /// Calling migrate with no sources resumes the recorded batch after a crash.
    public func migrate(_ sources: [URL], readID: (Data) -> String?,
                        checkpoint: (Int) throws -> Void = { _ in }) async throws {
        let lock = try lockJournal()
        defer { try? lock.close() }
        if var prior = try journal() {
            guard !prior.reversing else { throw Failure.invalid("rollback in progress") }
            guard sources.isEmpty || Set(sources.map(\.standardizedFileURL.path)) ==
                    Set(prior.pdfs.map(\.source.path)) else {
                throw Failure.invalid("a previous batch is recorded; finish or undo that migration first")
            }
            try await apply(&prior, checkpoint: checkpoint)
            return
        }
        guard !sources.isEmpty else { throw Failure.invalid("no pending migration") }
        try fm.createDirectory(at: journalDir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        var j = Journal(root: location.root, local: local, id: UUID())
        var positions = [DocumentKey: DocumentKey]()
        for url in sources {
            try await plan(url.standardizedFileURL, readID: readID, journal: &j, positions: &positions)
        }
        let payloads = j.changes.filter { $0.relative.hasPrefix("PDFs/") }
        j.changes.removeAll { $0.relative.hasPrefix("PDFs/") }
        try await planPositions(positions, journal: &j)
        j.changes += payloads
        var absent = Set<URL>()
        for step in j.changes {
            var parent = location.root.appendingPathComponent(step.relative).deletingLastPathComponent()
            while parent.path != location.root.path && !fm.fileExists(atPath: parent.path) {
                absent.insert(parent)
                parent.deleteLastPathComponent()
            }
        }
        j.createdDirectories = absent.sorted { $0.pathComponents.count > $1.pathComponents.count }
        try save(j) // every byte and inverse is durable before the first shared mutation
        try await apply(&j, checkpoint: checkpoint)
    }

    /// A device-local recent still names the original. Resolve only after the
    /// entire transaction commits, and prove the destination's identity again.
    public func migratedURL(for source: URL, readID: (Data) -> String?) async throws -> URL? {
        guard let j = try journal(),
              let pdf = j.pdfs.first(where: { $0.source.standardizedFileURL.path == source.standardizedFileURL.path })
        else { return nil }
        guard !j.reversing, j.completed == j.changes.count,
              let url = location.resolve(pdf.relative), let bytes = try await store.read(url),
              SharedPDFIdentity.storageKey(in: bytes, readerID: readID(bytes)) == pdf.key else {
            throw Failure.changed(source.path)
        }
        return url
    }

    private func plan(_ source: URL, readID: (Data) -> String?, journal j: inout Journal,
                      positions: inout [DocumentKey: DocumentKey]) async throws {
        guard source.pathExtension.lowercased() == "pdf", location.relativePath(for: source) == nil,
              !source.resolvingSymlinksInPath().pathComponents.starts(with: location.root.pathComponents)
        else { throw Failure.invalid(source.path) }
        let original = try Data(contentsOf: source)
        guard original.starts(with: "%PDF-".utf8) else { throw Failure.invalid(source.path) }
        j.inputs.append(Source(url: source, digest: try snapshot(original)))
        let prepared = SharedPDFIdentity.prepare(original, writable: fm.isWritableFile(atPath: source.path), readID: readID)
        let oldID = readID(original).flatMap { DocumentIdentity.isCanonicalKey($0) ? $0 : nil }
        let stable = DocumentKey.pdf(stableIdentifier: prepared.key)
        let urlPaths = Set([source.path, source.resolvingSymlinksInPath().path])
        var keys = Set(urlPaths.map(DocumentIdentity.sha256Hex))
        keys.insert(DocumentIdentity.byteHash(original))
        if let oldID { keys.insert(oldID) }
        for key in keys {
            let sourceKey = DocumentKey.pdf(stableIdentifier: key)
            if let prior = positions[sourceKey], prior != stable { throw Failure.invalid(source.path) }
            positions[sourceKey] = stable
        }
        for path in urlPaths { positions[.pdfPath(path)] = stable }
        let base = source.deletingPathExtension().lastPathComponent
        var relative = "PDFs/" + source.lastPathComponent
        var number = 1
        while true {
            guard let dest = location.resolve(relative) else { throw Failure.invalid(relative) }
            if try await store.read(dest) == nil, !j.changes.contains(where: { $0.relative == relative }) { break }
            number += 1
            relative = "PDFs/\(base) \(number).pdf"
        }
        j.pdfs.append(.init(source: source, relative: relative, key: prepared.key))
        let prefix = ".vellum/documents/" + prepared.key + "/"
        guard try files(in: location.root.appendingPathComponent(prefix)).isEmpty else { throw Failure.changed(prefix) }
        var metadata: [String: Any] = ["version": 1, "kind": "pdf", "last_opened": ISO8601DateFormatter().string(from: Date())]
        var foundMeta = false
        for key in keys.sorted() {
            let dir = local.appendingPathComponent("documents/" + key)
            let names = try files(in: dir)
            j.directories[dir.path] = names
            for name in names {
                let input = dir.appendingPathComponent(name)
                let data = try Data(contentsOf: input)
                j.inputs.append(Source(url: input, digest: try snapshot(data)))
                if name == "meta.json" {
                    guard !foundMeta, let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                          object["kind"] as? String == "pdf", object["version"] as? Int == 1,
                          let path = object["last_known_path"] as? String, object["last_opened"] is String,
                          key == oldID || urlPaths.contains(path) || key == DocumentIdentity.byteHash(original)
                    else { throw Failure.invalid(input.path) }
                    metadata = object
                    foundMeta = true
                } else {
                    try change(data, relative: prefix + name, journal: &j)
                }
            }
        }
        metadata["last_known_path"] = relative
        try change(try JSONSerialization.data(withJSONObject: metadata, options: [.sortedKeys]),
                   relative: prefix + "meta.json", journal: &j)
        // Publish the visible PDF only after its class-B files have been installed.
        try change(prepared.bytes, relative: relative, journal: &j)
    }

    private func planPositions(_ keys: [DocumentKey: DocumentKey], journal j: inout Journal) async throws {
        let dir = local.appendingPathComponent("positions")
        let names = try files(in: dir)
        j.directories[dir.path] = names
        for name in names where !name.contains("/") {
            guard let parsed = PositionLayout.parseFileName(name) else { continue }
            let source = dir.appendingPathComponent(name)
            let data = try Data(contentsOf: source)
            let record = try parsed.decode(data)
            guard record.deviceID == parsed.device, PositionMerge.isUsable(record) else { throw Failure.invalid(name) }
            j.inputs.append(Source(url: source, digest: try snapshot(data)))
            let selected = record.documents.filter { keys[$0.key] != nil }
            guard !selected.isEmpty else { continue }
            let relative = ".vellum/positions/" + name
            let before = try await store.read(location.root.appendingPathComponent(relative))
            var after = record
            if let before {
                after = try parsed.decode(before)
                guard after.deviceID == record.deviceID, PositionMerge.isUsable(after) else { throw Failure.invalid(name) }
                for (field, value) in record.unknownFields {
                    if let other = after.unknownFields[field], other != value { throw Failure.changed(name) }
                    after.unknownFields[field] = value
                }
            } else { after.documents = [:] }
            for (old, value) in selected {
                guard let new = keys[old] else { throw Failure.invalid(name) }
                if old != new, let previous = after.documents.removeValue(forKey: old), previous != value {
                    throw Failure.changed(name)
                }
                if let previous = after.documents[new], previous != value { throw Failure.changed(name) }
                after.documents[new] = value
            }
            let bytes = try PositionCoding.encoder.encode(after)
            guard try parsed.decode(bytes) == after else { throw Failure.invalid(name) }
            try change(bytes, relative: relative, before: before, journal: &j)
        }
    }

    private func verifySources(_ j: Journal) throws {
        for (path, expected) in j.directories {
            guard try files(in: URL(fileURLWithPath: path)) == expected else { throw Failure.changed(path) }
        }
        for input in j.inputs {
            guard try DocumentIdentity.byteHash(Data(contentsOf: input.url)) == input.digest else {
                throw Failure.changed(input.url.path)
            }
        }
    }

    private func apply(_ j: inout Journal, checkpoint: (Int) throws -> Void) async throws {
        try verifySources(j)
        for i in j.changes.indices {
            let step = j.changes[i]
            let url = location.root.appendingPathComponent(step.relative)
            let after = try contents(step.after)
            let current = try await store.read(url)
            if i < j.completed {
                guard current == after else { throw Failure.changed(url.path) }
                continue
            }
            let before = try step.before.map(contents)
            if current != before && !(j.pending && current == after) { throw Failure.changed(url.path) }
            j.pending = true
            try save(j)
            if current != after {
                guard try await store.replace(url, with: after, ifCurrent: before) else { throw Failure.changed(url.path) }
            }
            try checkpoint(i) // simulates interruption after publication, before acknowledgment
            guard try await store.read(url) == after else { throw Failure.changed(url.path) }
            j.completed += 1
            j.pending = false
            try save(j)
        }
    }

    public func rollback() async throws {
        let lock = try lockJournal()
        defer { try? lock.close() }
        guard var j = try journal() else { return }
        try verifySources(j)
        if j.pending {
            let step = j.changes[j.completed]
            let current = try await store.read(location.root.appendingPathComponent(step.relative))
            if current == (try contents(step.after)) { j.completed += 1 }
            else if current != (try step.before.map(contents)) { throw Failure.changed(step.relative) }
            j.pending = false
        }
        for pdf in j.pdfs {
            let prefix = ".vellum/documents/" + pdf.key + "/"
            let known = Set(j.changes.filter { $0.relative.hasPrefix(prefix) }.map { String($0.relative.dropFirst(prefix.count)) })
            guard try Set(files(in: location.root.appendingPathComponent(prefix))).isSubset(of: known)
            else { throw Failure.changed(prefix) }
        }
        for step in j.changes.prefix(j.completed) {
            let bytes = try await store.read(location.root.appendingPathComponent(step.relative))
            let before = try step.before.map(contents)
            if bytes != (try contents(step.after)), !(j.reversing && bytes == before) {
                throw Failure.changed(step.relative)
            }
        }
        j.reversing = true
        try save(j)
        while j.completed > 0 {
            let step = j.changes[j.completed - 1]
            let url = location.root.appendingPathComponent(step.relative)
            let after = try contents(step.after)
            let before = try step.before.map(contents)
            let current = try await store.read(url)
            if current != before {
                guard current == after else { throw Failure.changed(step.relative) }
                if let before {
                    guard try await store.replace(url, with: before, ifCurrent: after) else { throw Failure.changed(step.relative) }
                } else {
                    let trash = location.root.appendingPathComponent(".vellum/trash/pdf-migration/")
                        .appendingPathComponent(j.id.uuidString).appendingPathComponent(step.relative)
                    guard try await store.archiveSibling(url, expected: after, to: trash) != nil else {
                        throw Failure.changed(step.relative)
                    }
                }
            }
            guard try await store.read(url) == before else { throw Failure.changed(step.relative) }
            j.completed -= 1
            try save(j)
        }
        // rmdir only removes empty directories this batch created. Never
        // recursively remove a folder that may contain a new peer attachment.
        for dir in j.createdDirectories where dir.pathComponents.starts(with: location.root.pathComponents) {
            guard dir.resolvingSymlinksInPath().standardizedFileURL.path == dir.standardizedFileURL.path else {
                throw Failure.changed(dir.path)
            }
            if rmdir(dir.path) != 0 && errno != ENOENT && errno != ENOTEMPTY { throw Failure.changed(dir.path) }
        }
        // Retire the entire local journal atomically. A crash during cleanup
        // cannot leave a live manifest pointing to missing blobs.
        let retired = journalDir.deletingLastPathComponent().appendingPathComponent(j.id.uuidString)
        try fm.moveItem(at: journalDir, to: retired)
        try? fm.removeItem(at: retired)
    }
}
