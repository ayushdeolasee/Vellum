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
    /// The in-flight threshold flush, kept so `flush()` is a real completion
    /// barrier: without it, a quit right after page 50 would see `dirty ==
    /// false` and return while the cache write is still pending.
    private var flushTask: Task<Void, Never>?

    /// Detached flushes from dropped persisters (tab switch / teardown), so the
    /// quit path can await writes whose owning controller is already gone.
    private static var inFlightFlushes: [UUID: Task<Void, Never>] = [:]

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
            let previous = flushTask
            flushTask = Task {
                await previous?.value
                await self.performFlush()
            }
        }
    }

    /// Completion barrier: waits out any in-flight threshold flush, then writes
    /// whatever changed since. Idempotent and a no-op when clean.
    func flush() async {
        let pending = flushTask
        flushTask = nil
        await pending?.value
        await performFlush()
    }

    /// Fire-and-forget flush for a persister being dropped (its controller is
    /// resetting). Registered so `awaitInFlightFlushes` can act as the quit
    /// barrier for writes no controller owns anymore.
    func flushDetached() {
        let id = UUID()
        Self.inFlightFlushes[id] = Task {
            await self.flush()
            Self.inFlightFlushes[id] = nil
        }
    }

    /// Awaited by the quit path after the active controller's own flush, so a
    /// tab switched away from moments before ⌘Q still lands its cache write.
    static func awaitInFlightFlushes() async {
        while let task = inFlightFlushes.values.first {
            await task.value
        }
    }

    /// `complete` is full 1…N key coverage.
    private func performFlush() async {
        guard dirty else { return }
        // Clear dirty before the await so a concurrent noteExtracted re-dirties
        // us and its page still lands in the next flush.
        dirty = false
        let complete = pageCount >= 1 && (1...pageCount).allSatisfy { pages[$0] != nil }
        await cache.write(
            path: path, title: title, pageCount: pageCount, pages: pages, complete: complete)
    }
}
