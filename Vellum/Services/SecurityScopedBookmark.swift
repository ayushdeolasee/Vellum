import Foundation

// Durable, out-of-container file access for PDFs picked in Files, opened from
// another app, or restored from a saved tab.
//
// On iOS this is MANDATORY, not defense-in-depth. The app is sandboxed: a
// UIDocumentPicker URL grants access only for the life of its security scope,
// and the app container's UUID changes across reinstalls and some OS updates,
// so a persisted absolute path can stop resolving for a file that is still
// there. A minted bookmark is the only thing that reliably re-opens a document
// after a relaunch without another trip through the picker.
//
// Every operation is best-effort and never throws: callers always have the raw
// path (and, on iPad, DocumentImport.resolveExistingPath) to fall back to.
enum SecurityScopedBookmark {
    /// Mint a security-scoped bookmark for `url`. Must be called while the app
    /// already has read access (right after a successful open) — minting is
    /// what fails silently for locations that can't be bookmarked (some
    /// network volumes, already-unreachable paths, etc.).
    static func make(for url: URL) -> Data? {
        try? url.bookmarkData(
            options: [],
            includingResourceValuesForKeys: nil,
            relativeTo: nil)
    }

    /// Convenience overload for the raw paths `DocumentInfo`/`AppStore` pass
    /// around.
    static func make(forPath path: String) -> Data? {
        make(for: URL(fileURLWithPath: path))
    }

    struct Resolved {
        let url: URL
        /// True when the bookmark's saved path no longer matches disk (the
        /// file moved/renamed but bookmark resolution could still follow it).
        /// Callers should mint a fresh bookmark from `url` when this is set.
        let isStale: Bool
    }

    /// Resolve a previously stored bookmark back to a URL. Returns nil if the
    /// bookmark can't be resolved at all (deleted file, unreachable volume,
    /// corrupted data) — callers fall back to the last known raw path.
    static func resolve(_ data: Data) -> Resolved? {
        var isStale = false
        guard let url = try? URL(
            resolvingBookmarkData: data,
            options: [],
            relativeTo: nil,
            bookmarkDataIsStale: &isStale
        ) else { return nil }
        return Resolved(url: url, isStale: isStale)
    }
}
