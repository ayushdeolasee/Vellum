import Foundation
import VellumCore

/// One immutable selection. The snapshot's relative __VELLUM_ASSET__/ links
/// resolve under its token without rewriting or expanding the bounded HTML.
public struct ArchiveResourceMap: Sendable {
    public let documentURL: URL
    public let hasHandwriting: Bool
    private let snapshot: Data
    private let assets: [String: Data]

    public init(archive: DecodedWebArchive, documentToken: UUID, hasInkSidecar: Bool = false) {
        documentURL = URL(string: "vellum-web://archive/\(documentToken.uuidString)/index.html")!
        hasHandwriting = archive.inkJSON != nil || hasInkSidecar
        snapshot = Data(archive.snapshotHtml.utf8)
        assets = Dictionary(archive.assets, uniquingKeysWith: { first, _ in first })
    }

    public func response(for uri: URL) throws -> (mime: String, bytes: Data) {
        if uri.absoluteString == documentURL.absoluteString {
            return ("text/html; charset=utf-8", snapshot)
        }
        let base = documentURL.deletingLastPathComponent().absoluteString + "__VELLUM_ASSET__/"
        let raw = uri.absoluteString
        guard raw.hasPrefix(base) else { throw URLError(.resourceUnavailable) }
        let component = raw.dropFirst(base.count)
        guard !component.contains("?"), !component.contains("#"),
              let name = component.removingPercentEncoding,
              ArchiveCodec.safeAssetName(name) != nil, let data = assets[name] else {
            throw URLError(.resourceUnavailable)
        }
        // As on Apple, derive media types from flat archive filenames.
        return (Self.mediaTypes[(name as NSString).pathExtension.lowercased()] ?? "application/octet-stream", data)
    }

    private static let mediaTypes = [
        "png": "image/png", "jpg": "image/jpeg", "jpeg": "image/jpeg", "gif": "image/gif",
        "webp": "image/webp", "avif": "image/avif", "svg": "image/svg+xml", "ico": "image/x-icon",
        "css": "text/css", "woff": "font/woff", "woff2": "font/woff2", "ttf": "font/ttf", "otf": "font/otf"
    ]

    @concurrent
    public static func load(from store: ReadOnlyLibraryFileStore, file: URL,
                            catalog: ReaderMetadataCatalog) async throws -> (Self, ReaderDocumentMetadata) {
        guard let data = try await store.read(file) else { throw CocoaError(.fileNoSuchFile) }
        try Task.checkCancellation()
        let archive = try ArchiveCodec.decode(data)
        let metadata = try await catalog.web(manifest: archive.manifest, fallbackTitle: file.lastPathComponent)
        try Task.checkCancellation()
        return (Self(archive: archive, documentToken: UUID(), hasInkSidecar: metadata.hasInkSidecar), metadata)
    }
}
