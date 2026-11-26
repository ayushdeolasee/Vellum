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

    @concurrent
    public static func searchEntries(in store: ReadOnlyLibraryFileStore) async throws
        -> (entries: [LibrarySearchEntry], metadata: ReaderMetadataCatalog?) {
        let files = try await documents(in: store)
        // PDF-only libraries keep the reader's lazy metadata load. Mixed
        // libraries can reuse the snapshot already needed for archive titles.
        let metadata = files.contains(where: isArchive)
            ? try? await ReaderMetadataCatalog.load(in: store)
            : nil
        var entries: [LibrarySearchEntry] = []
        for file in files {
            try Task.checkCancellation()
            var title = file.name
            if isArchive(file),
               let bytes = try? await store.read(file.url),
               let manifest = try? ArchiveCodec.readManifest(data: bytes) {
                // Use the reader's title precedence. Only the manifest is decoded here.
                title = try await metadata?.web(manifest: manifest, fallbackTitle: file.name).displayTitle
                    ?? ReaderMetadataCatalog.title(manifest.title) ?? file.name
            }
            entries.append(LibrarySearchEntry(file: file, title: title, haystack: HomeSearchHaystack(
                title: title, name: file.name, location: "")))
        }
        try Task.checkCancellation()
        return (entries, metadata)
    }

    private static func isArchive(_ file: LibraryFileEntry) -> Bool {
        file.url.pathExtension.lowercased() == "vellumweb"
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
