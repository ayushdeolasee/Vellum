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

    enum CleanupError: Error {
        case sharedFolderRequired
        case invalidStorageKey
        case unsafeItem(URL)
        case incompleteScan(URL)
        case partialCleanup(RecoveryBatch, cause: any Error)
    }

    // Record the minimum retention in the batch name so it travels with the
    // files. Cleanup itself never expires or overwrites a recovery batch.
    private static let minimumRetention: TimeInterval = 30 * 24 * 60 * 60
    private static let directoryFlags = O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC

    static func moveUnreferencedAttachments(
        forKey key: String, coordinator: StorageCoordinator
    ) async throws -> RecoveryBatch? {
        try await withSharedFolder(forKey: key, coordinator: coordinator) { layout in
            try moveUnreferencedAttachments(
                forKey: key, root: layout.rootDir,
                localFallback: WebLibrary.storeDir.deletingLastPathComponent())
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
        _ operation: @escaping @Sendable (WebStorageLayout) throws -> T
    ) async throws -> T {
        guard DocumentIdentity.isCanonicalKey(key) else { throw CleanupError.invalidStorageKey }
        return try await ScratchpadWriteCoordinator.shared.withExclusiveAccess(
            forKeys: [key], invalidatingQueuedWrites: false
        ) {
            try await coordinator.withStorageContext { context in
                guard context.layout.backend == .syncedFolder else {
                    throw CleanupError.sharedFolderRequired
                }
                return try await Task.detached(priority: .utility) {
                    try operation(context.layout)
                }.value
            }
        }
    }

    static func moveUnreferencedAttachments(
        forKey key: String, root: URL, localFallback: URL? = nil
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
        let candidates = try attachments.entries().filter { url in
            guard let id = attachmentID(url.lastPathComponent), !referenced.contains(id) else {
                return false
            }
            return try attachments.isRegularFile(url.lastPathComponent)
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
            for url in candidates {
                let name = url.lastPathComponent
                guard let id = attachmentID(name), !currentReferences.contains(id) else { continue }
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
        let nameParts = batch.split(separator: "-", maxSplits: 1)
        guard attachmentID(name) != nil, nameParts.count == 2,
              let deadline = Int64(nameParts[0]), deadline > 0,
              String(deadline) == nameParts[0],
              let id = UUID(uuidString: String(nameParts[1])),
              id.uuidString.lowercased() == nameParts[1]
        else { throw CleanupError.unsafeItem(root.url) }

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

        func isRegularFile(_ name: String) throws -> Bool {
            var status = stat()
            guard fstatat(fd, name, &status, AT_SYMLINK_NOFOLLOW) == 0 else {
                throw Self.systemError()
            }
            return status.st_mode & S_IFMT == S_IFREG
        }

        func readNote(_ name: String) throws -> String {
            let descriptor = openat(fd, name, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
            guard descriptor >= 0 else { throw Self.systemError() }
            let file = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
            var status = stat()
            guard fstat(descriptor, &status) == 0, status.st_mode & S_IFMT == S_IFREG,
                  let text = String(data: try file.readToEnd() ?? Data(), encoding: .utf8)
            else { throw CleanupError.incompleteScan(url.appendingPathComponent(name)) }
            return text
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
