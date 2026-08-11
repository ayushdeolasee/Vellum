import Foundation

// What "open this home-screen result" actually means, decided away from any
// view.
//
// Two Home screens now share this: the iPad's `WelcomeLibrary_iOS` and the
// phone's `PhoneHome_iOS`. Before the split there was one screen, so the rule
// below could live inline in its `open(_:)`; with two, an inline copy in each
// is a rule that drifts — and this particular rule is the one nobody
// re-derives correctly, because both of its halves are invisible until they
// misfire (a duplicated recents row; a document that "doesn't open" after a
// reinstall).
//
// Deliberately free of SwiftUI *and* of `DocumentImport`: the container-aware
// path resolution is injected, which is what lets the rule be tested without a
// filesystem and keeps this file platform-neutral.

/// The concrete thing to hand `AppStore` for a chosen result.
enum HomeOpenIntent: Equatable, Sendable {
    /// Open a web address — `AppStore.openUrl`.
    case url(String)
    /// Open a file — `AppStore.openFiles(paths: [path])`.
    ///
    /// `staleRecentPath` is a recents entry that must be dropped FIRST, and is
    /// non-nil only when the corpus re-resolved a moved PDF through its docId.
    /// Opening re-records the document under the path it actually opened from,
    /// so leaving the old entry behind would show the same document twice in
    /// Recents — one row of which no longer points at anything (design §7).
    case file(path: String, staleRecentPath: String?)
}

/// Turns a corpus target into a `HomeOpenIntent`.
enum HomeOpenResolver {
    /// - Parameters:
    ///   - target: the chosen row's target, exactly as the corpus recorded it.
    ///   - resolveExisting: maps a recorded path to a path that exists now, or
    ///     nil when nothing does. On iOS this is
    ///     `DocumentImport.resolveExistingPath`, which also looks in the current
    ///     app container's library folder — a recent recorded before a reinstall
    ///     carries a *different container UUID* in its absolute path, so without
    ///     this step every pre-reinstall recent would open to "file not found"
    ///     while the file sits right there.
    ///
    /// When nothing resolves, the recorded path is used unchanged rather than
    /// refusing to open: `AppStore` has its own missing-file reporting, and it
    /// names the path the user's row is showing.
    static func intent(
        for target: HomeSearchTarget,
        resolveExisting: (String) -> String?
    ) -> HomeOpenIntent {
        switch target {
        case .url(let url):
            return .url(url)
        case .file(let path, let recordedPath):
            // Only a genuine re-resolution leaves a stale entry. When the two
            // agree — the overwhelmingly common case — the open simply refreshes
            // the row that is already there, and removing it first would be a
            // pointless write.
            let stale = path == recordedPath ? nil : recordedPath
            return .file(path: resolveExisting(path) ?? path, staleRecentPath: stale)
        }
    }
}
