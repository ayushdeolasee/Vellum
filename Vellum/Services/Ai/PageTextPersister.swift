import Foundation

// Per-document coordinator that debounces persistence of extracted page text to
// PageTextCache. Owned by PdfViewerController. It keeps its OWN authoritative
// page dict (seeded from the cache at open) so a flush never depends on
// AiStore.pageTexts, which is wiped from two lifecycle sites (clearDocument
// context on tab/doc change). Web documents never install one — only PDFs
// persist.

@MainActor
final class PageTextPersister {
    let path: String
    let title: String?
    let pageCount: Int
    private let cache: PageTextCache

    /// The authoritative page set this persister flushes, independent of
    /// AiStore.pageTexts. Seeded from the cache so a resumed walk that skips
    /// already-cached pages still flushes the full document.
    private var pages: [Int: String]
    private var dirty = false
    private var newSinceFlush = 0
    /// Flush every N newly extracted pages (≈ one write per 0.8s at the walk's
    /// 16ms/page pacing).
    private let flushThreshold = 50

    init(
        path: String, title: String?, pageCount: Int,
        seeded: [Int: String], cache: PageTextCache = .shared
    ) {
        self.path = path
        self.title = title
        self.pageCount = pageCount
        pages = seeded
        self.cache = cache
    }

    /// Record a newly extracted page (text already whitespace-normalized by
    /// AiStore.setPageText). No-op when unchanged; fires a debounced flush every
    /// `flushThreshold` new pages.
    func noteExtracted(page: Int, text: String) {
        guard pages[page] != text else { return }
        pages[page] = text
        dirty = true
        newSinceFlush += 1
        if newSinceFlush >= flushThreshold {
            newSinceFlush = 0
            Task { await self.flush() }
        }
    }

    /// Persist the current page set if anything changed since the last flush.
    /// Idempotent and a no-op when clean. `complete` is full 1…N key coverage.
    func flush() async {
        guard dirty else { return }
        // Clear dirty before the await so a concurrent noteExtracted re-dirties
        // us and its page still lands in the next flush.
        dirty = false
        let complete = pageCount >= 1 && (1...pageCount).allSatisfy { pages[$0] != nil }
        await cache.write(
            path: path, title: title, pageCount: pageCount, pages: pages, complete: complete)
    }
}
