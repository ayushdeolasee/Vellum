import Foundation
import VellumCore

public enum ReaderChatDocument: Sendable {
    case pdf(Data, key: String?, file: URL, title: String, page: Int)
    case article(ManifestHashes, key: String?, title: String, file: URL, store: ReadOnlyLibraryFileStore,
                 visibleText: String)

    public var key: String? {
        switch self {
        case let .pdf(_, key, _, _, _): key
        case let .article(_, key, _, _, _, _): key
        }
    }

    // Unstamped PDFs can chat in memory without inventing a shared identity.
    public var sessionKey: String? {
        if case let .pdf(_, nil, file, _, _) = self { return file.absoluteString }
        return key
    }

    @concurrent
    public func excerpt() async throws -> String {
        let title: String, text: String
        switch self {
        case let .pdf(bytes, _, _, name, page):
            title = "\(name), page \(page + 1)"
            text = try await PdfiumDocument.readText(in: bytes, at: page, priority: .onDemand).text
        case let .article(hashes, _, name, file, store, visibleText):
            title = name
            guard let bytes = try await store.read(file) else { throw CocoaError(.fileNoSuchFile) }
            let indexed = try ArchiveCodec.articleExcerpt(in: bytes, matching: hashes)
            text = indexed.isEmpty ? visibleText : indexed
        }
        try Task.checkCancellation()
        let excerpt = text.prefix(ConversationText.characterLimit).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !excerpt.isEmpty else { throw ChatContextError.noText }
        return "\(title)\n\(excerpt)"
    }

    private enum ChatContextError: LocalizedError {
        case noText
        var errorDescription: String? { "This document has no readable text for chat." }
    }
}
