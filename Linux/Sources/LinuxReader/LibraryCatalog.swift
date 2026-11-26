import Foundation
import VellumCore

public struct LibrarySearchEntry: Sendable {
    public let file: LibraryFileEntry
    public let title: String
    fileprivate let haystack: HomeSearchHaystack
}

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

    @concurrent
    public static func documents(in store: ReadOnlyLibraryFileStore) async throws -> [LibraryFileEntry] {
        let pdfs = try await pdfs(in: store)
        let directory = store.root.url.appendingPathComponent("Web Pages", isDirectory: true)
        let archives = try await store.list(directory, suffix: nil).filter {
            !$0.url.hasDirectoryPath && $0.url.pathExtension.lowercased() == "vellumweb"
        }
        return pdfs + archives
    }

    @concurrent
    public static func searchEntries(in store: ReadOnlyLibraryFileStore,
                                     metadata: ReaderMetadataCatalog) async throws -> [LibrarySearchEntry] {
        var entries: [LibrarySearchEntry] = []
        for file in try await documents(in: store) {
            try Task.checkCancellation()
            var title = file.name
            if file.url.pathExtension.lowercased() == "vellumweb",
               let bytes = try? await store.read(file.url),
               let manifest = try? ArchiveCodec.readManifest(data: bytes) {
                // Use the reader's title precedence. Only the manifest is decoded here.
                title = try await metadata.web(manifest: manifest, fallbackTitle: file.name).displayTitle
            }
            entries.append(LibrarySearchEntry(file: file, title: title, haystack: HomeSearchHaystack(
                title: title, name: file.name, location: "")))
        }
        try Task.checkCancellation()
        return entries
    }

    /// Return indexes into the original catalog, which remain stable across query changes.
    @concurrent
    public static func matches(in entries: [LibrarySearchEntry], query: String) async throws -> [Int] {
        let tokens = HomeSearchText.tokens(in: query)
        guard !tokens.isEmpty else { return [] }
        let matches: [(index: Int, score: Int)] = try entries.enumerated().compactMap { index, entry in
            try Task.checkCancellation()
            return HomeSearchRanker.score(entry.haystack, tokens: tokens).map { (index, $0) }
        }
        return matches.sorted { lhs, rhs in
            if lhs.score != rhs.score { return lhs.score > rhs.score }
            let leftTitle = entries[lhs.index].haystack.title
            let rightTitle = entries[rhs.index].haystack.title
            if leftTitle != rightTitle { return leftTitle < rightTitle }
            return lhs.index < rhs.index
        }.map(\.index)
    }
}
