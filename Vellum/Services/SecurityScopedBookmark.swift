import Foundation

// Durable, out-of-container file access for PDFs opened via the panel, a
// Finder drop/double-click, or restored from a saved tab. This app is not
// sandboxed (ENABLE_APP_SANDBOX: NO), so these bookmarks are defense-in-depth
// rather than a hard requirement: the primary fix for repeated "Vellum wants
// access to your Documents folder" prompts is a stable code-signing identity
// (see project.yml), since TCC grants persist per identity across relaunches.
// Bookmarks add resilience — if the app is ever sandboxed, or a TCC grant is
// ever revoked, a resolved bookmark can still regain access to a restored
// tab without a fresh picker round-trip. Every operation here is best-effort
// and never throws: callers always have the raw path to fall back to.
enum SecurityScopedBookmark {
    /// Mint a security-scoped bookmark for `url`. Must be called while the app
    /// already has read access (right after a successful open) — minting is
    /// what fails silently for locations that can't be bookmarked (some
    /// network volumes, already-unreachable paths, etc.).
    static func make(for url: URL) -> Data? {
        try? url.bookmarkData(
            options: [.withSecurityScope],
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
            options: [.withSecurityScope],
            relativeTo: nil,
            bookmarkDataIsStale: &isStale
        ) else { return nil }
        return Resolved(url: url, isStale: isStale)
    }
}
