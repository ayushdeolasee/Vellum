import Foundation

// Process-wide serialization for PDFKit page-text extraction.
//
// `PDFPage.string` reads like a cheap property, but on a page with no text layer
// PDFKit falls back to Live Text: it loads — and, the first time, *compiles* — a
// CoreML model for the Apple Neural Engine. Vellum never imports Vision or
// CoreML, which is why the SIGSEGV crash reports (inside ANECompiler/Espresso,
// on com.apple.coreml.MLModelAssetResourceFactory's modelLoadQueue, with
// TextRecognition on the stack) contain no Vellum frame doing anything
// ML-shaped. The trigger is asking for several scanned pages at once:
// overlapping first-time compiles race on shared compiler state and take the
// whole process down.
//
// Vellum had four independent producers of `page.string` bursts — the background
// 1→N walk (one per activated tab, so two in a split), the per-turn AI context
// fill, the `getPageText` tool, and `searchDocument`'s whole-document pass —
// each running as its own Task against the same document, interleaving at their
// suspension points. They all funnel through this gate now.
//
// Measured on macOS 26: `page.string` on an image-only page returns an empty
// string in ~0.02 ms, versus ~1.5 ms for a page with a real text layer. It does
// *not* block on recognition, so the recognition PDFKit kicks off is still
// running after the call returns — which is precisely how our requests end up
// overlapping even though every one of them is issued from the main actor. That
// measurement is why pacing keys off an *empty* result rather than off how long
// the call took: an empty read is the page shape that sends PDFKit to Live Text.
//
// Not covered: `PDFDocument.findString` (⌘F), which scans the whole document in
// one synchronous main-thread call and so can also drive Live Text. Gating it
// would mean making the find handler async all the way up through AppStore, so
// it is left alone for now — it is user-initiated and never concurrent with
// itself, unlike the four extraction loops.

/// Serializes and paces every PDFKit text read that can reach Live Text.
///
/// Main-actor isolated on purpose: PDFKit text extraction on a displayed
/// document has to stay on the main actor anyway, so the gate costs no thread
/// hops and `release` can stay synchronous. What it actually buys is (a) an
/// enforced gap after every page that had no text layer, and (b) an end to
/// main-actor *reentrancy* between the four extraction loops, which previously
/// interleaved into one unpaced burst.
@MainActor
final class PageTextExtractionGate {
    /// The one gate the app runs through. Tests build their own instance.
    static let shared = PageTextExtractionGate()

    /// Queue position. `onDemand` (the AI needs this page to answer *now*) jumps
    /// ahead of every queued `background` page, so a whole-document walk never
    /// makes a chat turn wait for hundreds of pages — it only ever waits out the
    /// single page already in flight.
    enum Priority {
        case background
        case onDemand
    }

    /// Minimum gap between one Live-Text-capable read and the next, giving
    /// PDFKit's recognition — which outlives the `page.string` call — room to
    /// finish before another request stacks another model load on top of it.
    /// Matches the background walk's existing 16 ms idle pacing, and is measured
    /// from the *end* of the previous page, so the walk's own sleep normally
    /// absorbs it rather than adding to it.
    private static let cooldown: Duration = .milliseconds(16)

    /// A read this slow went through recognition synchronously. Kept alongside
    /// the empty-result signal because PDFKit is free to change which of the two
    /// shapes a scanned page takes; either one means "pace the next caller".
    private static let ocrDurationThreshold: Duration = .milliseconds(25)

    private struct Waiter {
        let id: UInt64
        let priority: Priority
        let continuation: CheckedContinuation<Bool, Never>
    }

    private var isBusy = false
    private var waiters: [Waiter] = []
    private var nextWaiterId: UInt64 = 0
    /// When the last Live-Text-suspected read finished; nil when the previous
    /// read came back with real text and no cooldown is owed.
    private var lastSuspectFinish: ContinuousClock.Instant?

    init() {}

    /// Number of tasks queued behind the in-flight extraction. Test seam.
    var queueDepth: Int { waiters.count }

    /// Run one `page.string`-style read with exclusive process-wide access.
    ///
    /// `body` returns the text it extracted, or nil if it decided not to read at
    /// all (already cached, wrong document, and so on). The gate uses that
    /// return value to decide whether the *next* caller has to wait out the
    /// cooldown: text back means a text layer and no pacing, empty back means a
    /// page Live Text is likely still chewing on, nil back means no read
    /// happened and nothing to pace.
    ///
    /// Returns nil without running `body` when the calling task was cancelled
    /// (tab deactivation cancels the background walk mid-flight). The slot is
    /// released on every exit path, cancelled or not.
    func extractText(priority: Priority, _ body: () -> String?) async -> String? {
        guard await acquire(priority: priority) else { return nil }
        var suspectedLiveText = false
        defer { release(pacingNeeded: suspectedLiveText) }
        // Acquiring can suspend for a long time behind a queue of scanned pages;
        // a walk cancelled in that window must not go on to extract anything.
        guard !Task.isCancelled else { return nil }
        let started = ContinuousClock.now
        let text = body()
        if let text {
            suspectedLiveText = text.isEmpty
                || ContinuousClock.now - started >= Self.ocrDurationThreshold
        }
        return text
    }

    /// Takes the slot, waiting in the priority queue if something else holds it.
    /// Returns false only when the caller was cancelled while queued — in which
    /// case it holds nothing and must not release.
    private func acquire(priority: Priority) async -> Bool {
        if Task.isCancelled { return false }
        if isBusy {
            let id = nextWaiterId
            nextWaiterId += 1
            let admitted = await withTaskCancellationHandler {
                await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
                    // Registration is synchronous main-actor work, so the hop
                    // scheduled by `onCancel` below can never observe a
                    // half-registered waiter.
                    waiters.append(Waiter(id: id, priority: priority, continuation: continuation))
                }
            } onCancel: {
                Task { @MainActor in self.dropWaiter(id: id) }
            }
            // `release` hands the slot straight over, so `isBusy` is already
            // true for us when we were admitted.
            guard admitted else { return false }
        } else {
            isBusy = true
        }
        await waitOutCooldown()
        return true
    }

    private func release(pacingNeeded: Bool) {
        lastSuspectFinish = pacingNeeded ? ContinuousClock.now : nil
        guard let index = nextWaiterIndex() else {
            isBusy = false
            return
        }
        let waiter = waiters.remove(at: index)
        // Hand the slot over directly rather than clearing `isBusy`: nothing can
        // slip in between this resume and the waiter actually running.
        waiter.continuation.resume(returning: true)
    }

    /// The first `onDemand` waiter if there is one, else the oldest waiter —
    /// FIFO within a band, with AI requests jumping the background walk.
    ///
    /// A long run of `onDemand` pages (a whole-document `searchDocument`) can
    /// starve the walk for its duration. That is deliberate and harmless: both
    /// fill the same `pageTexts`/`PageTextCache`, so the walk resumes afterwards
    /// and skips everything the search already extracted.
    private func nextWaiterIndex() -> Int? {
        if let urgent = waiters.firstIndex(where: { $0.priority == .onDemand }) { return urgent }
        return waiters.isEmpty ? nil : 0
    }

    /// Cancelled while queued: leave the queue without ever taking the slot.
    /// A waiter that was already admitted is simply not here any more — it will
    /// notice `Task.isCancelled` itself and release normally.
    private func dropWaiter(id: UInt64) {
        guard let index = waiters.firstIndex(where: { $0.id == id }) else { return }
        let waiter = waiters.remove(at: index)
        waiter.continuation.resume(returning: false)
    }

    private func waitOutCooldown() async {
        guard let lastSuspectFinish else { return }
        let remaining = Self.cooldown - (ContinuousClock.now - lastSuspectFinish)
        guard remaining > .zero else { return }
        // Cancellation here is fine to swallow: `extractText` re-checks
        // `Task.isCancelled` before it runs anything.
        try? await Task.sleep(for: remaining)
    }
}

// MARK: - Private-document bodies that run off the main actor
//
// The iPad and Mac 1→N walks parse a PRIVATE `PDFDocument` copy on a detached
// utility task (see each controller's `startTextExtraction(data:)`) because
// walking the live, view-bound document on the main actor starved the run loop
// for minutes on textbook PDFs. The synchronous `extractText` above runs its
// body on the main actor, which would undo that. This overload holds the exact
// same single slot and applies the exact same pacing — only the queue
// bookkeeping stays main-actor isolated; the body runs wherever the caller is.
//
// The pacing contract is unchanged and load-bearing: return the extracted text
// (empty string included) to have the next caller paced, return nil when no
// read happened so nothing is paced.
extension PageTextExtractionGate {
    func extractText(
        priority: Priority,
        offMain body: @Sendable () async -> String?
    ) async -> String? {
        guard await acquire(priority: priority) else { return nil }
        var suspectedLiveText = false
        defer { release(pacingNeeded: suspectedLiveText) }
        guard !Task.isCancelled else { return nil }
        let started = ContinuousClock.now
        let text = await body()
        if let text {
            suspectedLiveText = text.isEmpty
                || ContinuousClock.now - started >= Self.ocrDurationThreshold
        }
        return text
    }
}
