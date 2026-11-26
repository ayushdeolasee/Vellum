import Foundation
import VellumCore

public enum LibraryCatalog {
    /// PDFs/ is the portable fixture convention. Recents, bookmarks and
    /// lastKnownPath may point outside the library and are never consulted.
    @concurrent
    public static func pdfs(in store: ReadOnlyLibraryFileStore) async throws -> [LibraryFileEntry] {
        let directory = store.root.url.appendingPathComponent("PDFs", isDirectory: true)
        var directories = [directory]
        var files = [LibraryFileEntry]()
        while let next = directories.popLast() {
            try Task.checkCancellation()
            for entry in try await store.list(next, suffix: nil) {
                if entry.url.hasDirectoryPath { directories.append(entry.url) }
                else if entry.url.pathExtension.lowercased() == "pdf" { files.append(entry) }
            }
        }
        return files.sorted { $0.url.path < $1.url.path }
    }

    @concurrent
    public static func documents(in store: ReadOnlyLibraryFileStore) async throws -> [LibraryFileEntry] {
        let pdfs = try await pdfs(in: store)
        let directory = store.root.url.appendingPathComponent("Web Pages", isDirectory: true)
        let archives = try await store.list(directory, suffix: nil).filter {
            !$0.url.hasDirectoryPath && $0.url.pathExtension.lowercased() == "vellumweb"
        }
        return pdfs + archives
    }
}
