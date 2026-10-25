import Foundation

// The managed copy of every opened book. An EPUB is validated before it is
// admitted, then copied atomically to `Books/<docId>/<name>.epub`, so the
// original stays available offline and reimporting identical bytes reuses
// the existing copy instead of duplicating it.
enum EpubLibrary {
    nonisolated(unsafe) static var directoryOverride: URL?

    static var directory: URL {
        directoryOverride ?? defaultDocumentLibraryDirectory().appendingPathComponent("Books", isDirectory: true)
    }

    /// Validates and admits `source`, returning the managed path. Blocking:
    /// call off the main actor.
    static func importBook(
        at source: URL,
        preferredName: String? = nil,
        into library: URL = directory,
        limits: EpubContainer.Limits = .standard
    ) throws -> URL {
        EpubLibraryCatalog.lock.lock()
        defer { EpubLibraryCatalog.lock.unlock() }
        let source = source.standardizedFileURL
        guard !EpubLibraryCatalog.isSymbolicLink(source) else {
            throw SessionServiceError.io("Import the original EPUB file, not a symbolic link.")
        }
        let accessing = source.startAccessingSecurityScopedResource()
        defer { if accessing { source.stopAccessingSecurityScopedResource() } }

        let fileManager = FileManager.default
        do {
            try fileManager.createDirectory(at: library, withIntermediateDirectories: true)
        } catch {
            throw SessionServiceError.io("Failed to prepare the book library: \(error.localizedDescription)")
        }
        // Resolve once so managed paths compare equal however they are reached.
        let library = EpubLibraryCatalog.canonicalURL(library)
        let book = try EpubBook.load(path: source.path, limits: limits)
        try Task.checkCancellation()
        let folder = library.appendingPathComponent(book.docId, isDirectory: true)
        guard !EpubLibraryCatalog.isSymbolicLink(folder) else {
            throw SessionServiceError.io("The managed book folder is not safe.")
        }
        if let existing = existingBook(in: folder) {
            guard try EpubIdentity.contentDocId(fileAt: existing) == book.docId else {
                throw SessionServiceError.io("The managed book no longer matches its content identity.")
            }
            try EpubLibraryCatalog.record(book, managedURL: existing)
            return EpubLibraryCatalog.canonicalURL(existing)
        }
        let count = try fileManager.contentsOfDirectory(atPath: library.path).count
        guard count < EpubLibraryCatalog.maxBooks else {
            throw SessionServiceError.io("The book library exceeds the supported catalog size.")
        }

        do {
            try fileManager.createDirectory(at: folder, withIntermediateDirectories: true)
        } catch {
            throw SessionServiceError.io("Failed to prepare the book library: \(error.localizedDescription)")
        }
        let destination = folder.appendingPathComponent(
            filename(preferred: preferredName ?? source.lastPathComponent,
                     title: book.publication.metadata.title))
        let staging = folder.appendingPathComponent(".import-\(UUID().uuidString.lowercased())")
        do {
            try fileManager.copyItem(at: source, to: staging)
            try Task.checkCancellation()
            guard try EpubIdentity.contentDocId(fileAt: staging) == book.docId else {
                throw SessionServiceError.io("The source book changed during import.")
            }
            guard rename(staging.path, destination.path) == 0 else {
                throw CocoaError(.fileWriteUnknown)
            }
        } catch {
            try? fileManager.removeItem(at: staging)
            if error is CancellationError { throw error }
            throw SessionServiceError.io("Failed to copy the book into the library: \(error.localizedDescription)")
        }
        try EpubLibraryCatalog.record(book, managedURL: destination)
        return EpubLibraryCatalog.canonicalURL(destination)
    }

    private static func existingBook(in folder: URL) -> URL? {
        let contents = (try? FileManager.default.contentsOfDirectory(
            at: folder, includingPropertiesForKeys: nil)) ?? []
        return contents.sorted { $0.path < $1.path }.first {
            $0.pathExtension.lowercased() == "epub"
                && !EpubLibraryCatalog.isSymbolicLink($0)
        }
    }

    /// A safe single path component ending in `.epub`.
    static func filename(preferred: String?, title: String?) -> String {
        func sanitized(_ raw: String?) -> String? {
            guard let raw else { return nil }
            var name = (raw as NSString).lastPathComponent
            if (name as NSString).pathExtension.lowercased() == "epub" {
                name = (name as NSString).deletingPathExtension
            }
            name = name.components(separatedBy: CharacterSet(charactersIn: "/:\\\0").union(.controlCharacters))
                .joined(separator: " ")
                .trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: ".")))
            return name.isEmpty ? nil : String(name.prefix(120))
        }
        return (sanitized(preferred) ?? sanitized(title) ?? "Book") + ".epub"
    }
}

/// Device-local publication metadata, never a notes/conversation store. All
/// methods are blocking and must be called off the main actor. A listing reads
/// bounded JSON and stats; only legacy discovery or a changed file hashes bytes.
enum EpubLibraryCatalog {
    static let maxCoverBytes = 2 * 1024 * 1024
    static let maxRecordBytes = 64 * 1024
    static let maxBooks = 10_000
    static let recordFilename = "publication.json"
    static let coverFilename = "cover.image"
    static let lock = NSRecursiveLock()

    struct Record: Codable, Equatable, Sendable {
        var version = 1
        var docId: String
        var filename: String
        var title: String?
        var customTitle: String? = nil
        var authors: [String]
        var importedAt: Date
        var originalBytes: Int64
        var modificationDate: Date
        var coverFilename: String?
    }

    struct Entry: Equatable, Sendable {
        var record: Record
        var fileURL: URL
        var available: Bool
        var coverURL: URL?
        var originalBytes: Int64
        var coverBytes: Int64
        var metadataBytes: Int64
        var totalBytes: Int64 { originalBytes + coverBytes + metadataBytes }
    }

    static func isDocId(_ value: String) -> Bool {
        value.count == 64 && value.allSatisfy { ("0"..."9").contains($0) || ("a"..."f").contains($0) }
    }

    static func record(_ book: EpubBook, managedURL: URL) throws {
        let folder = managedURL.deletingLastPathComponent()
        let old = readRecord(in: folder)
        let attributes = try managedURL.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
        var record = Record(
            docId: book.docId, filename: managedURL.lastPathComponent,
            title: book.publication.metadata.title.map { String($0.prefix(1024)) },
            customTitle: old?.customTitle,
            authors: book.publication.metadata.creators.prefix(32).map { String($0.prefix(256)) },
            importedAt: old?.importedAt ?? Date(),
            originalBytes: Int64(attributes.fileSize ?? 0),
            modificationDate: attributes.contentModificationDate ?? .distantPast)
        if let path = book.publication.coverPath,
           let type = book.publication.manifestItem(path: path)?.mediaType,
           ["image/jpeg", "image/png", "image/gif", "image/webp"].contains(type),
           let data = try? book.container.data(at: path, maxSize: UInt64(maxCoverBytes)), !data.isEmpty {
            let cover = folder.appendingPathComponent(coverFilename)
            guard !isSymbolicLink(cover) else {
                throw SessionServiceError.io("The managed book cover is not safe.")
            }
            try data.write(to: cover, options: .atomic)
            record.coverFilename = coverFilename
        }
        try write(record, in: folder)
    }

    static func list(in library: URL = EpubLibrary.directory) throws -> [Entry] {
        lock.lock()
        defer { lock.unlock() }
        let library = canonicalURL(library)
        guard FileManager.default.fileExists(atPath: library.path) else { return [] }
        let folders = try FileManager.default.contentsOfDirectory(
            at: library, includingPropertiesForKeys: [.isDirectoryKey], options: .skipsHiddenFiles)
        guard folders.count <= maxBooks else {
            throw SessionServiceError.io("The book library exceeds the supported catalog size.")
        }
        var entries: [Entry] = []
        for folder in folders.sorted(by: { $0.path < $1.path }) {
            try Task.checkCancellation()
            guard isDocId(folder.lastPathComponent),
                  !isSymbolicLink(folder),
                  (try? folder.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else { continue }
            var record = readRecord(in: folder)
            if record == nil, !FileManager.default.fileExists(atPath: folder.appendingPathComponent(recordFilename).path) {
                // Stage 2 admitted originals without a catalog. Discover only
                // direct, non-symlink EPUBs whose bytes match the folder id.
                let files = try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
                guard files.count <= 32 else { continue }
                for file in files.sorted(by: { $0.path < $1.path })
                where file.pathExtension.lowercased() == "epub" && !isSymbolicLink(file) {
                    do {
                        let book = try EpubBook.load(path: file.path)
                        guard book.docId == folder.lastPathComponent else { continue }
                        try Task.checkCancellation()
                        try self.record(book, managedURL: file)
                        record = readRecord(in: folder)
                        break
                    } catch is CancellationError { throw CancellationError() }
                    catch { continue }
                }
            }
            guard var record else { continue }
            let file = folder.appendingPathComponent(record.filename)
            let safe = !isSymbolicLink(file)
            let attributes = safe ? try? file.resourceValues(
                forKeys: [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey]) : nil
            let bytes = Int64(attributes?.fileSize ?? 0)
            var available = attributes?.isRegularFile == true
            if available, bytes != record.originalBytes || attributes?.contentModificationDate != record.modificationDate {
                available = (try? EpubIdentity.contentDocId(fileAt: file)) == record.docId
                if available {
                    record.originalBytes = bytes
                    record.modificationDate = attributes?.contentModificationDate ?? .distantPast
                    try Task.checkCancellation()
                    try write(record, in: folder)
                }
            }
            let cover = record.coverFilename.map { folder.appendingPathComponent($0) }
            let coverSize = cover.flatMap { boundedSize($0, cap: Int.max) } ?? 0
            entries.append(Entry(
                record: record, fileURL: safe ? canonicalURL(file) : file, available: available,
                coverURL: coverSize > 0 && coverSize <= maxCoverBytes ? cover : nil,
                originalBytes: bytes, coverBytes: Int64(coverSize),
                metadataBytes: Int64(boundedSize(folder.appendingPathComponent(recordFilename), cap: maxRecordBytes) ?? 0)))
        }
        return entries
    }

    static func resolve(docId: String, in library: URL = EpubLibrary.directory) -> URL? {
        guard isDocId(docId) else { return nil }
        // Restrict discovery to this book, not a whole-library walk.
        lock.lock()
        defer { lock.unlock() }
        let folder = canonicalURL(library).appendingPathComponent(docId)
        guard !isSymbolicLink(folder), let record = readRecord(in: folder) else { return nil }
        let file = folder.appendingPathComponent(record.filename)
        guard !isSymbolicLink(file),
              let values = try? file.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey]),
              values.isRegularFile == true else { return nil }
        if Int64(values.fileSize ?? 0) == record.originalBytes, values.contentModificationDate == record.modificationDate {
            return canonicalURL(file)
        }
        return (try? EpubIdentity.contentDocId(fileAt: file)) == docId ? canonicalURL(file) : nil
    }

    static func boundedSize(_ file: URL, cap: Int) -> Int? {
        guard !isSymbolicLink(file), !isSymbolicLink(file.deletingLastPathComponent()),
              let values = try? file.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]),
              values.isRegularFile == true, let size = values.fileSize, size <= cap else { return nil }
        return size
    }

    static func isSymbolicLink(_ file: URL) -> Bool {
        let attributes = try? FileManager.default.attributesOfItem(atPath: file.path)
        return attributes?[.type] as? FileAttributeType == .typeSymbolicLink
    }

    static func canonicalURL(_ file: URL) -> URL {
        guard let path = realpath(file.path, nil) else { return file.standardizedFileURL }
        defer { free(path) }
        return URL(fileURLWithPath: String(cString: path))
    }

    static func boundedData(_ file: URL, cap: Int) -> Data? {
        guard boundedSize(file, cap: cap) != nil,
              let handle = try? FileHandle(forReadingFrom: file) else { return nil }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: cap + 1), data.count <= cap else { return nil }
        return data
    }

    @discardableResult
    static func setTitle(docId: String, title: String?, in library: URL = EpubLibrary.directory) throws -> Bool {
        guard isDocId(docId) else { return false }
        lock.lock()
        defer { lock.unlock() }
        let folder = canonicalURL(library).appendingPathComponent(docId)
        guard !isSymbolicLink(folder), var record = readRecord(in: folder) else { return false }
        record.customTitle = title
        try write(record, in: folder)
        return true
    }

    static func customTitle(docId: String, in library: URL = EpubLibrary.directory) -> String? {
        guard isDocId(docId) else { return nil }
        lock.lock()
        defer { lock.unlock() }
        let folder = canonicalURL(library).appendingPathComponent(docId)
        guard !isSymbolicLink(folder) else { return nil }
        return readRecord(in: folder)?.customTitle
    }

    private static func readRecord(in folder: URL) -> Record? {
        let url = folder.appendingPathComponent(recordFilename)
        guard let data = boundedData(url, cap: maxRecordBytes),
              let record = try? JSONDecoder().decode(Record.self, from: data),
              record.version == 1, record.docId == folder.lastPathComponent, isDocId(record.docId),
              record.filename == (record.filename as NSString).lastPathComponent,
              !record.filename.contains("\\"), !record.filename.contains("\0"),
              (record.filename as NSString).pathExtension.lowercased() == "epub",
              record.originalBytes > 0,
              record.coverFilename == nil || record.coverFilename == coverFilename else { return nil }
        return record
    }

    private static func write(_ record: Record, in folder: URL) throws {
        let url = folder.appendingPathComponent(recordFilename)
        guard !isSymbolicLink(url), !isSymbolicLink(folder) else {
            throw SessionServiceError.io("The managed book catalog is not safe.")
        }
        let data = try JSONEncoder().encode(record)
        guard data.count <= maxRecordBytes else { throw SessionServiceError.io("The book metadata is too large.") }
        try data.write(to: url, options: .atomic)
    }
}
