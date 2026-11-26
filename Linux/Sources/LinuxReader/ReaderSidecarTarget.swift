import Foundation
import VellumCore

/// Captured when opening a document. A pending save keeps its own locator
/// across tab changes; it never consults the reader's current selection.
public enum ReaderSidecarTarget: Sendable {
    case pdf(key: String, file: URL)
    case web(key: String)

    public var key: String {
        switch self {
        case .pdf(let key, _), .web(let key): key
        }
    }

    public var positionKey: DocumentKey? {
        switch self {
        case .pdf(let key, _): .pdf(stableIdentifier: key)
        case .web(let key): DocumentKey(rawValue: "web:" + key)
        }
    }

    public struct ChangedPDF: LocalizedError {
        public var errorDescription: String? {
            "PDF identity changed or could not be verified. Restore the original document before retrying."
        }
    }

    @concurrent
    public func validate(in store: ReadOnlyLibraryFileStore) async throws {
        guard case let .pdf(key, file) = self else { return }
        do {
            guard let bytes = try await store.read(file) else { throw ChangedPDF() }
            let info = try await PdfiumDocument.openingInfo(in: bytes)
            let current = try await ReaderMetadataCatalog.resolvePDF(bytes: bytes, file: file,
                                                                    stamp: info.stableIdentifier, store: store)
            guard current.key == key else { throw ChangedPDF() }
        } catch {
            try Task.checkCancellation()
            throw ChangedPDF()
        }
    }
}
