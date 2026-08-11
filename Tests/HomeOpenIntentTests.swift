import Foundation
import Testing

@testable import Vellum

// `HomeOpenResolver` — the rule that turns a chosen Home row into something
// `AppStore` can open (#153 P4).
//
// Both Home screens (the iPad's `WelcomeLibrary_iOS` and the phone's
// `PhoneHome_iOS`) route through this, which is the whole reason it exists as a
// value-level seam: its two clauses are individually invisible until they
// misfire — one shows a document twice in Recents, the other makes a
// pre-reinstall recent look like a missing file — so neither is something to
// re-derive per screen.
//
// Path resolution is injected, so nothing here touches the filesystem.

/// Resolver that knows about a fixed set of paths that "exist".
private func existing(_ paths: String...) -> (String) -> String? {
    let known = Set(paths)
    return { known.contains($0) ? $0 : nil }
}

/// Resolver that relocates any path into a new container, the way
/// `DocumentImport.resolveExistingPath` does after a reinstall.
private func relocating(to directory: String) -> (String) -> String? {
    { path in "\(directory)/\((path as NSString).lastPathComponent)" }
}

@Suite("Home open intent")
struct HomeOpenIntentTests {
    @Test("A web target passes straight through, untouched by path resolution")
    func urlPassesThrough() {
        var resolverCalls = 0
        let intent = HomeOpenResolver.intent(for: .url("https://example.test/a")) { _ in
            resolverCalls += 1
            return nil
        }

        #expect(intent == .url("https://example.test/a"))
        // A URL has no path to re-resolve; asking would be a filesystem hit per
        // opened link.
        #expect(resolverCalls == 0)
    }

    @Test("A file whose recorded path still matches drops no recents entry")
    func matchingRecordedPathIsNotStale() {
        let path = "/library/paper.pdf"
        let intent = HomeOpenResolver.intent(for: .file(path: path, recordedPath: path),
                                             resolveExisting: existing(path))

        #expect(intent == .file(path: path, staleRecentPath: nil))
    }

    @Test("A moved file drops exactly the one stale recents entry it replaced")
    func movedFileReportsStaleRecent() {
        // The corpus re-resolved this PDF through its stamped docId, so the
        // row's path and the path recents stored have diverged.
        let intent = HomeOpenResolver.intent(
            for: .file(path: "/library/moved/paper.pdf", recordedPath: "/library/old/paper.pdf"),
            resolveExisting: existing("/library/moved/paper.pdf"))

        #expect(intent == .file(path: "/library/moved/paper.pdf",
                                staleRecentPath: "/library/old/paper.pdf"))
    }

    @Test("Re-resolution rewrites the path without touching what counts as stale")
    func relocatedContainerRewritesPath() {
        // A recent recorded before a reinstall carries the previous container's
        // UUID; the resolver finds the same file under the current one.
        let intent = HomeOpenResolver.intent(
            for: .file(path: "/old-container/paper.pdf", recordedPath: "/old-container/paper.pdf"),
            resolveExisting: relocating(to: "/new-container"))

        // Staleness is decided by the corpus (path vs recordedPath), never by
        // the container rewrite — the recents entry still names this document.
        #expect(intent == .file(path: "/new-container/paper.pdf", staleRecentPath: nil))
    }

    @Test("An unresolvable path falls back to the recorded one rather than refusing")
    func unresolvablePathFallsBack() {
        let intent = HomeOpenResolver.intent(
            for: .file(path: "/gone/paper.pdf", recordedPath: "/gone/paper.pdf"),
            resolveExisting: { _ in nil })

        // `AppStore` owns missing-file reporting, and it names the path the
        // user's row is showing — which is only true if we hand it that path.
        #expect(intent == .file(path: "/gone/paper.pdf", staleRecentPath: nil))
    }

    @Test("A moved file that then vanishes still drops its stale entry")
    func movedAndUnresolvableStillReportsStale() {
        let intent = HomeOpenResolver.intent(
            for: .file(path: "/library/moved/paper.pdf", recordedPath: "/library/old/paper.pdf"),
            resolveExisting: { _ in nil })

        #expect(intent == .file(path: "/library/moved/paper.pdf",
                                staleRecentPath: "/library/old/paper.pdf"))
    }
}
