import Darwin
import Foundation

/// Explicit maintenance for one document in the shared folder. An offline
/// peer can still hold a reference that no local scan can see.
enum ScratchpadAttachmentCleanup {
    struct RecoveryBatch: Sendable {
        let directory: URL
        let retainUntil: Date

        var name: String { directory.lastPathComponent }
    }

    struct Inventory: Sendable {
        struct Document: Identifiable, Sendable {
            struct Batch: Identifiable, Sendable {
                let id: String
                let retainUntil: Date
                let files: [String]

                var movedAt: Date { retainUntil.addingTimeInterval(-minimumRetention) }
            }

            let id: String
            let title: String
            let hasAttachments: Bool
            let batches: [Batch]
        }

        let generation: Int
        let root: URL
        let scannedAt: Date
        let documents: [Document]
    }

    struct RestoreResult: Sendable {
        var restored = 0
        var keptInRecovery = 0
    }

    enum CleanupError: Error {
        case sharedFolderRequired
        case invalidStorageKey
        case unsafeItem(URL)
        case incompleteScan(URL)
        case documentOpen
        case staleSelection
        case partialCleanup(RecoveryBatch, cause: any Error)
    }

    // Record the minimum retention in the batch name so it travels with the
    // files. Cleanup itself never expires or overwrites a recovery batch.
    private static let minimumRetention: TimeInterval = 30 * 24 * 60 * 60
    private static let directoryFlags = O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC

    static func moveUnreferencedAttachments(
        forKey key: String, coordinator: StorageCoordinator,
        inventory: Inventory? = nil,
        admissionAllowed: @escaping @Sendable () async -> Bool = { true }
    ) async throws -> RecoveryBatch? {
        if let inventory, !inventory.documents.contains(where: { $0.id == key && $0.hasAttachments }) {
            throw CleanupError.staleSelection
        }
        return try await withSharedFolder(
            forKey: key, coordinator: coordinator,
            expectedGeneration: inventory?.generation, expectedRoot: inventory?.root,
            admissionAllowed: admissionAllowed
        ) { layout in
            try moveUnreferencedAttachments(
                forKey: key, root: layout.rootDir,
                localFallback: WebLibrary.storeDir.deletingLastPathComponent(),
                listedAt: inventory?.scannedAt)
        }
    }

    static func inventory(coordinator: StorageCoordinator) async throws -> Inventory {
        try await coordinator.withStorageContext(expectedGeneration: nil) { context, generation in
            guard context.layout.backend == .syncedFolder else { throw CleanupError.sharedFolderRequired }
            return try await Task.detached(priority: .utility) {
                let scannedAt = Date()
                let root = try Directory(opening: context.layout.rootDir)
                guard let metadata = try root.optionalChild(".vellum") else {
                    return Inventory(generation: generation, root: root.url, scannedAt: scannedAt, documents: [])
                }
                let documents = try metadata.optionalChild("documents")
                let recovery = try metadata.optionalChild("trash")?.optionalChild("scratchpad-attachments")
                let keys = Set(try (documents?.entries() ?? []).map(\.lastPathComponent))
                    .union(try (recovery?.entries() ?? []).map(\.lastPathComponent))
                let rows = try keys.filter(DocumentIdentity.isCanonicalKey).compactMap { key -> Inventory.Document? in
                    let document = try documents?.optionalChild(key)
                    let attachments = try document?.optionalChild("attachments")
                    let hasAttachments = try !(attachments?.attachmentFiles() ?? []).isEmpty
                    let stored = try recovery?.optionalChild(key)
                    let batches = try (stored?.entries() ?? []).compactMap { url -> Inventory.Document.Batch? in
                        let name = url.lastPathComponent
                        guard let retainUntil = batchDeadline(name),
                              let batch = try stored?.optionalChild(name) else { return nil }
                        let files = try batch.attachmentFiles()
                        guard !files.isEmpty else { return nil }
                        return .init(id: name, retainUntil: retainUntil, files: files)
                    }.sorted { $0.retainUntil > $1.retainUntil }
                    guard hasAttachments || !batches.isEmpty else { return nil }
                    let title = (try? document?.readRegularFile("meta.json", limit: 65_536))
                        .flatMap { try? JSONDecoder().decode(DocumentDataStore.Meta.self, from: $0) }?.title
                    return .init(id: key, title: title.flatMap { $0.isEmpty ? nil : $0 } ?? key,
                                 hasAttachments: hasAttachments, batches: batches)
                }.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
                return Inventory(generation: generation, root: root.url, scannedAt: scannedAt, documents: rows)
            }.value
        }
    }

    static func restoreBatch(
        named name: String, forKey key: String, inventory: Inventory, coordinator: StorageCoordinator,
        admissionAllowed: @escaping @Sendable () async -> Bool
    ) async throws -> RestoreResult {
        guard let batch = inventory.documents.first(where: { $0.id == key })?
            .batches.first(where: { $0.id == name }) else { throw CleanupError.staleSelection }
        return try await withSharedFolder(
            forKey: key, coordinator: coordinator,
            expectedGeneration: inventory.generation, expectedRoot: inventory.root,
            admissionAllowed: admissionAllowed
        ) { layout in
            var result = RestoreResult()
            for file in batch.files {
                do {
                    try restoreAttachment(named: file, fromBatch: batch.id, forKey: key, root: layout.rootDir)
                    result.restored += 1
                } catch let error as NSError where error.domain == NSPOSIXErrorDomain && error.code == Int(EEXIST) {
                    result.keptInRecovery += 1
                }
            }
            return result
        }
    }

    /// Return the exact attachment bytes to their original name. A newer
    /// attachment that already occupies that name is never overwritten.
    static func restoreAttachment(
        named name: String, fromBatch batch: String, forKey key: String,
        coordinator: StorageCoordinator
    ) async throws {
        try await withSharedFolder(forKey: key, coordinator: coordinator) { layout in
            try restoreAttachment(named: name, fromBatch: batch, forKey: key, root: layout.rootDir)
        }
    }

    private static func withSharedFolder<T: Sendable>(
        forKey key: String, coordinator: StorageCoordinator,
        expectedGeneration: Int? = nil,
        expectedRoot: URL? = nil,
        admissionAllowed: @escaping @Sendable () async -> Bool = { true },
        _ operation: @escaping @Sendable (WebStorageLayout) throws -> T
    ) async throws -> T {
        guard DocumentIdentity.isCanonicalKey(key) else { throw CleanupError.invalidStorageKey }
        return try await ScratchpadWriteCoordinator.shared.withExclusiveAccess(
            forKeys: [key], invalidatingQueuedWrites: false
        ) {
            try await coordinator.withStorageContext(expectedGeneration: expectedGeneration) { context, _ in
                guard context.layout.backend == .syncedFolder else {
                    throw CleanupError.sharedFolderRequired
                }
                if let expectedRoot, context.layout.rootDir.standardizedFileURL != expectedRoot.standardizedFileURL {
                    throw CleanupError.staleSelection
                }
                guard await admissionAllowed() else { throw CleanupError.documentOpen }
                return try await Task.detached(priority: .utility) {
                    try operation(context.layout)
                }.value
            }
        }
    }

    static func moveUnreferencedAttachments(
        forKey key: String, root: URL, localFallback: URL? = nil, listedAt: Date? = nil
    ) throws -> RecoveryBatch? {
        guard DocumentIdentity.isCanonicalKey(key) else { throw CleanupError.invalidStorageKey }
        let root = try Directory(opening: root)
        guard let internalDir = try root.optionalChild(".vellum"),
              let document = try internalDir.optionalChild("documents")?.optionalChild(key),
              let attachments = try document.optionalChild("attachments")
        else { return nil }

        let fallback: Directory?
        if let localFallback, let local = try Directory.openIfPresent(localFallback) {
            fallback = try local.optionalChild("documents")?.optionalChild(key)
        } else {
            fallback = nil
        }
        let referenced = try protectedIDs(in: document).union(protectedIDs(in: fallback))
        let candidates = try attachments.attachmentFiles().compactMap { name -> (String, FileStamp)? in
            guard let id = attachmentID(name), !referenced.contains(id),
                  let stamp = try attachments.fileStamp(name),
                  listedAt.map({ stamp.latestChange <= $0 }) ?? true else { return nil }
            return (name, stamp)
        }
        guard !candidates.isEmpty else { return nil }

        let retainUntil = Int64(ceil(Date().addingTimeInterval(minimumRetention).timeIntervalSince1970))
        let batchName = "\(retainUntil)-\(UUID().uuidString.lowercased())"
        let trash = try trashDirectory(in: internalDir, forKey: key, create: true)
        let batchDir = try trash.createChild(batchName, exclusively: true)
        let batch = RecoveryBatch(
            directory: batchDir.url, retainUntil: Date(timeIntervalSince1970: Double(retainUntil)))

        // Check again after creating trash, since a peer or the resolver can
        // publish another visible version independently of our write lane.
        let currentReferences = try protectedIDs(in: document).union(protectedIDs(in: fallback))
        var moved = false
        do {
            for (name, stamp) in candidates {
                guard let id = attachmentID(name), !currentReferences.contains(id) else { continue }
                guard try attachments.fileStamp(name) == stamp else { continue }
                try attachments.moveFile(name, to: batchDir)
                moved = true
            }
        } catch {
            // Each rename is atomic and exclusive. Leave the completed moves
            // in the discoverable batch even if a later file cannot be moved.
            if moved { throw CleanupError.partialCleanup(batch, cause: error) }
            throw error
        }
        return moved ? batch : nil
    }

    static func restoreAttachment(
        named name: String, fromBatch batch: String, forKey key: String, root: URL
    ) throws {
        guard DocumentIdentity.isCanonicalKey(key) else { throw CleanupError.invalidStorageKey }
        let root = try Directory(opening: root)
        guard attachmentID(name) != nil, batchDeadline(batch) != nil else {
            throw CleanupError.unsafeItem(root.url)
        }

        let internalDir = try root.child(".vellum")
        let trash = try trashDirectory(in: internalDir, forKey: key, create: false)
        let source = try trash.child(batch)
        guard try source.isRegularFile(name) else {
            throw CleanupError.unsafeItem(source.url.appendingPathComponent(name))
        }
        let attachments = try internalDir.createChild("documents").createChild(key)
            .createChild("attachments")
        try source.moveFile(name, to: attachments)
    }

    private static func batchDeadline(_ name: String) -> Date? {
        let parts = name.split(separator: "-", maxSplits: 1)
        guard parts.count == 2, let deadline = Int64(parts[0]), deadline > 0,
              String(deadline) == parts[0], let id = UUID(uuidString: String(parts[1])),
              id.uuidString.lowercased() == parts[1] else { return nil }
        return Date(timeIntervalSince1970: Double(deadline))
    }

    private static func trashDirectory(
        in internalDir: Directory, forKey key: String, create: Bool
    ) throws -> Directory {
        if create {
            return try internalDir.createChild("trash").createChild("scratchpad-attachments")
                .createChild(key)
        }
        return try internalDir.child("trash").child("scratchpad-attachments").child(key)
    }

    private static func attachmentID(_ name: String) -> String? {
        // Only names understood by the Scratchpad reference format are
        // eligible. Leave unknown files, staging files and conflicts alone.
        guard name.range(of: #"^[0-9a-fA-F]+(?:-[0-9a-fA-F]+)*\.[A-Za-z0-9]+\z"#,
                         options: .regularExpression) != nil,
              !name.lowercased().hasSuffix(".tmp") else { return nil }
        return ScratchpadAttachmentIdentity.canonicalID(forName: name)
    }

    private static func protectedIDs(in document: Directory?) throws -> Set<String> {
        guard let document else { return [] }
        var references: Set<String> = []
        for directory in [document, try document.optionalChild("conflicts")].compactMap({ $0 }) {
            for url in try directory.entries() {
                let name = url.lastPathComponent.lowercased()
                if name.hasPrefix(".syncthing.scratchpad.") ||
                    (name.hasPrefix(".scratchpad.") && name.contains(".tmp")) ||
                    (name.hasPrefix(".scratchpad.") && name.hasSuffix(".md.icloud")) ||
                    (name.hasPrefix("scratchpad.") && name.hasSuffix(".tmp")) {
                    throw CleanupError.incompleteScan(url)
                }
                guard name.hasPrefix("scratchpad."), name.hasSuffix(".md") else { continue }
                let text = try directory.readNote(url.lastPathComponent)
                references.formUnion(ScratchpadAttachmentStore.referencedIds(
                    in: ScratchpadPersistence.relativeToScheme(text)))
                // Escape stray percent signs so they do not stop us from
                // recognizing a valid percent-encoded link elsewhere in the note.
                let escaped = text.replacingOccurrences(
                    of: #"%(?![0-9a-fA-F]{2})"#, with: "%25", options: .regularExpression)
                guard let decoded = escaped.removingPercentEncoding else {
                    throw CleanupError.incompleteScan(url)
                }
                if decoded != text {
                    references.formUnion(ScratchpadAttachmentStore.referencedIds(
                        in: ScratchpadPersistence.relativeToScheme(decoded)))
                }
            }
        }
        return references
    }

    /// Pin each directory and reject symlink components below the selected
    /// root. All reads and moves use those descriptors, including when a peer
    /// changes directory names during the scan.
    private struct FileStamp: Equatable {
        let device: dev_t
        let inode: ino_t
        let size: off_t
        let modified: timespec
        let changed: timespec

        var latestChange: Date {
            let dates = [modified, changed].map {
                Date(timeIntervalSince1970: Double($0.tv_sec) + Double($0.tv_nsec) / 1e9)
            }
            return max(dates[0], dates[1])
        }

        static func == (lhs: Self, rhs: Self) -> Bool {
            lhs.device == rhs.device && lhs.inode == rhs.inode && lhs.size == rhs.size
                && lhs.modified.tv_sec == rhs.modified.tv_sec && lhs.modified.tv_nsec == rhs.modified.tv_nsec
                && lhs.changed.tv_sec == rhs.changed.tv_sec && lhs.changed.tv_nsec == rhs.changed.tv_nsec
        }
    }

    private struct Directory {
        let url: URL
        private let handle: FileHandle
        private var fd: Int32 { handle.fileDescriptor }

        init(opening url: URL) throws {
            guard let directory = try Self.openIfPresent(url) else {
                throw CocoaError(.fileReadNoSuchFile)
            }
            self = directory
        }

        private init(url: URL, fd: Int32) {
            self.url = url
            self.handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        }

        static func openIfPresent(_ url: URL) throws -> Self? {
            guard url.isFileURL else { throw CleanupError.unsafeItem(url) }
            let fd = open(url.path, directoryFlags)
            if fd == -1, errno == ENOENT { return nil }
            guard fd >= 0 else { throw systemError() }
            return Self(url: url, fd: fd)
        }

        func optionalChild(_ name: String) throws -> Self? {
            let childFD = openat(fd, name, directoryFlags)
            if childFD == -1, errno == ENOENT { return nil }
            guard childFD >= 0 else { throw Self.systemError() }
            return Self(url: url.appendingPathComponent(name, isDirectory: true), fd: childFD)
        }

        func child(_ name: String) throws -> Self {
            guard let directory = try optionalChild(name) else {
                throw CocoaError(.fileReadNoSuchFile)
            }
            return directory
        }

        func createChild(_ name: String, exclusively: Bool = false) throws -> Self {
            if mkdirat(fd, name, 0o700) != 0, exclusively || errno != EEXIST {
                throw Self.systemError()
            }
            return try child(name)
        }

        func entries() throws -> [URL] {
            // Open an independent directory stream. Duplicating the original
            // descriptor would share its offset with later enumerations.
            let streamFD = openat(fd, ".", directoryFlags)
            guard streamFD >= 0 else { throw Self.systemError() }
            guard let stream = fdopendir(streamFD) else {
                let error = Self.systemError()
                close(streamFD)
                throw error
            }
            defer { closedir(stream) }
            var entries: [URL] = []
            while true {
                errno = 0
                guard let entry = readdir(stream) else {
                    if errno != 0 { throw Self.systemError() }
                    return entries.sorted { $0.lastPathComponent < $1.lastPathComponent }
                }
                let name = withUnsafeBytes(of: entry.pointee.d_name) { bytes in
                    String(bytes: bytes.prefix(while: { $0 != 0 }), encoding: .utf8)
                }
                guard let name else { throw CleanupError.incompleteScan(url) }
                if name != ".", name != ".." {
                    entries.append(url.appendingPathComponent(name, isDirectory: false))
                }
            }
        }

        func attachmentFiles() throws -> [String] {
            try entries().map(\.lastPathComponent).filter {
                guard attachmentID($0) != nil else { return false }
                return try isRegularFile($0)
            }
        }

        func fileStamp(_ name: String) throws -> FileStamp? {
            var status = stat()
            guard fstatat(fd, name, &status, AT_SYMLINK_NOFOLLOW) == 0 else {
                throw Self.systemError()
            }
            guard status.st_mode & S_IFMT == S_IFREG else { return nil }
            return .init(device: status.st_dev, inode: status.st_ino, size: status.st_size,
                         modified: status.st_mtimespec, changed: status.st_ctimespec)
        }

        func isRegularFile(_ name: String) throws -> Bool {
            try fileStamp(name) != nil
        }

        func readNote(_ name: String) throws -> String {
            guard let text = String(data: try readRegularFile(name), encoding: .utf8) else {
                throw CleanupError.incompleteScan(url.appendingPathComponent(name))
            }
            return text
        }

        func readRegularFile(_ name: String, limit: Int? = nil) throws -> Data {
            let descriptor = openat(fd, name, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
            guard descriptor >= 0 else { throw Self.systemError() }
            let file = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
            var status = stat()
            guard fstat(descriptor, &status) == 0, status.st_mode & S_IFMT == S_IFREG
            else { throw CleanupError.incompleteScan(url.appendingPathComponent(name)) }
            if let limit {
                let data = try file.read(upToCount: limit + 1) ?? Data()
                guard data.count <= limit else { throw CleanupError.incompleteScan(url.appendingPathComponent(name)) }
                return data
            }
            return try file.readToEnd() ?? Data()
        }

        func moveFile(_ name: String, to destination: Self) throws {
            guard try isRegularFile(name) else {
                throw CleanupError.unsafeItem(url.appendingPathComponent(name))
            }
            // RENAME_EXCL prevents replacing recovery bytes or a peer's file.
            // No followed path component can redirect this rename outside the
            // opened directories, and EXDEV leaves the source in place.
            guard renameatx_np(fd, name, destination.fd, name, UInt32(RENAME_EXCL)) == 0
            else { throw Self.systemError() }
        }

        private static func systemError() -> NSError {
            NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
    }
}
