import Foundation

// The managed copy of every opened book. An EPUB is validated before it is
// admitted, then copied atomically to `Books/<docId>/<name>.epub`, so the
// original stays available offline and reimporting identical bytes reuses
// the existing copy instead of duplicating it.
enum EpubLibrary {
    static var directory: URL {
        defaultDocumentLibraryDirectory().appendingPathComponent("Books", isDirectory: true)
    }

    /// Validates and admits `source`, returning the managed path. Blocking:
    /// call off the main actor.
    static func importBook(
        at source: URL,
        preferredName: String? = nil,
        into library: URL = directory,
        limits: EpubContainer.Limits = .standard
    ) throws -> URL {
        let source = source.standardizedFileURL
        let accessing = source.startAccessingSecurityScopedResource()
        defer { if accessing { source.stopAccessingSecurityScopedResource() } }

        let fileManager = FileManager.default
        do {
            try fileManager.createDirectory(at: library, withIntermediateDirectories: true)
        } catch {
            throw SessionServiceError.io("Failed to prepare the book library: \(error.localizedDescription)")
        }
        // Resolve once so managed paths compare equal however they are reached.
        let library = library.standardizedFileURL.resolvingSymlinksInPath()
        if source.resolvingSymlinksInPath().path.hasPrefix(library.path + "/") { return source }

        let book = try EpubBook.load(path: source.path, limits: limits)
        try Task.checkCancellation()
        let folder = library.appendingPathComponent(book.docId, isDirectory: true)
        if let existing = existingBook(in: folder) { return existing }

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
            guard rename(staging.path, destination.path) == 0 else {
                throw CocoaError(.fileWriteUnknown)
            }
        } catch {
            try? fileManager.removeItem(at: staging)
            if error is CancellationError { throw error }
            throw SessionServiceError.io("Failed to copy the book into the library: \(error.localizedDescription)")
        }
        return destination
    }

    private static func existingBook(in folder: URL) -> URL? {
        let contents = (try? FileManager.default.contentsOfDirectory(
            at: folder, includingPropertiesForKeys: nil)) ?? []
        return contents.first { $0.pathExtension.lowercased() == "epub" }
            .map { URL(fileURLWithPath: $0.resolvingSymlinksInPath().path) }
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
