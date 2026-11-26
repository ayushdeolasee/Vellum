import Foundation
import VellumCore

public enum LibraryCatalog {
    /// PDFs/ is the portable fixture convention. Recents, bookmarks and
    /// lastKnownPath may point outside the library and are never consulted.
    @concurrent
    public static func pdfs(in store: ReadOnlyLibraryFileStore) async throws -> [LibraryFileEntry] {
        let directory = store.root.url.appendingPathComponent("PDFs", isDirectory: true)
        return try await store.list(directory, suffix: nil).filter {
            !$0.url.hasDirectoryPath && $0.url.pathExtension.lowercased() == "pdf"
        }
    }
}
