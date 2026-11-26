import Foundation

/// The only PDF locator persisted in a shared library is relative to its PDFs directory.
public struct SharedPDFLocation: Sendable {
    public let root: URL

    public init(root: URL) {
        self.root = root.standardizedFileURL.resolvingSymlinksInPath()
    }

    public func resolve(_ relative: String) -> URL? {
        let components = relative.split(separator: "/", omittingEmptySubsequences: false)
        guard components.count > 1, components.first == "PDFs",
              components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }),
              !relative.contains("\\"), !relative.utf8.contains(0),
              (relative as NSString).pathExtension.lowercased() == "pdf" else { return nil }
        var url = root
        for component in components {
            url.appendPathComponent(String(component))
            if (try? FileManager.default.destinationOfSymbolicLink(atPath: url.path)) != nil { return nil }
        }
        return url
    }

    public func relativePath(for url: URL) -> String? {
        guard url.isFileURL else { return nil }
        let parts = url.standardizedFileURL.pathComponents
        // macOS may hand the same file to different callers under /var and /private/var.
        let resolved = url.resolvingSymlinksInPath().standardizedFileURL.pathComponents
        let base = root.pathComponents
        let path = parts.starts(with: base) ? parts : resolved
        guard path.starts(with: base) else { return nil }
        let relative = path.dropFirst(base.count).joined(separator: "/")
        guard resolve(relative)?.standardizedFileURL.pathComponents == resolved else { return nil }
        return relative
    }
}

public enum SharedPDFIdentity {
    /// Both platforms require their engine's value and the typed witness in the
    /// original xref to agree. Keep resume's intentionally bounded parser as the authority.
    public static func stamp(in bytes: Data, readerID: String?) -> String? {
        guard let readerID, DocumentIdentity.isCanonicalKey(readerID),
              ClassicPdfFile.currentInfoText(forKey: "VellumDocId", in: bytes) == readerID else { return nil }
        return readerID
    }

    public static func storageKey(in bytes: Data, readerID: String?) -> String {
        stamp(in: bytes, readerID: readerID) ?? DocumentIdentity.byteHash(bytes)
    }

    /// Build and read back a single Info increment in memory before publishing any bytes.
    public static func prepare(_ original: Data, preferredID: String? = nil, writable: Bool = true,
                               readID: (Data) -> String?) -> (bytes: Data, key: String) {
        let observed = readID(original)
        if let existing = stamp(in: original, readerID: observed) { return (original, existing) }
        let id = preferredID ?? UUID().uuidString.lowercased()
        if writable, observed == nil, DocumentIdentity.isCanonicalKey(id),
           PdfEditEligibility.classify(original) == .editable,
           let bytes = try? PdfInfoIncrement.setMetadataIncrement(normalizedData: original, entries: [("doc_id", id)],
                                                                 requiringAbsentKey: "VellumDocId"),
           bytes.count > original.count, bytes.starts(with: original),
           (try? PdfEditEligibility.inspect(bytes, reservingRevision: false)) != nil,
           stamp(in: bytes, readerID: readID(bytes)) == id {
            return (bytes, id)
        }
        return (original, DocumentIdentity.byteHash(original))
    }
}
