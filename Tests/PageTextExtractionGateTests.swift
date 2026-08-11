import XCTest
@testable import Vellum

// Unit tests for the process-wide page-text extraction gate
// (Services/Ai/PageTextExtractionGate), which serializes and paces every PDFKit
// text read that can reach Live Text, so concurrent first-time CoreML/ANE model
// compiles can't crash the process.
//
// Each test builds its own gate instead of touching `.shared`, so ordering state
// never leaks between tests. A page that reaches Live Text is simulated by
// returning an empty string — which is exactly what `PDFPage.string` does on an
// image-only page (measured at ~0.02 ms, i.e. the recognition PDFKit starts is
// still running after the call returns).
//
// Cases 1-8 are main's, unchanged — the gate itself needed no iOS adaptation.
// Cases 9-10 are the iPad's, covering the `offMain:` overload the iPad adds for
// its detached 1→N walk (#129 packet 7 §2.1); nothing in main's suite exercises
// it, and getting it wrong is how the walk quietly climbs back onto the main
// actor.

@MainActor
final class PageTextExtractionGateTests: XCTestCase {

    /// Main-actor scratchpad recording the order bodies actually ran in.
    ///
    /// The one adaptation to main's file: `@MainActor` is explicit here. A
    /// nested type does not inherit the enclosing class's global actor, and
    /// case (9) below captures a `Recorder` inside the `offMain:` overload's
    /// `@Sendable` body — which under Swift 6 language mode requires the
    /// captured type to be `Sendable`. Global-actor-isolated classes are
    /// implicitly `Sendable`, so stating the isolation this class already had in
    /// practice is enough; nothing about cases (1)-(8) changes.
    @MainActor
    private final class Recorder {
        private(set) var entries: [String] = []
        func log(_ name: String) -> String {
            entries.append(name)
            return name
        }
    }

    /// Block the main thread for `duration`. Deliberately a busy-wait: the gate's
    /// secondary pacing signal is how long the *synchronous* body took, which
    /// sleeping wouldn't reproduce.
    private static func spin(for duration: Duration) {
        let deadline = ContinuousClock.now + duration
        while ContinuousClock.now < deadline {}
    }

    /// Run one scanned-page extraction so the gate owes a cooldown. The next
    /// acquirer then holds the slot across a real suspension, which is the
    /// window these tests use to queue work behind it.
    private func primeCooldown(on gate: PageTextExtractionGate) async {
        _ = await gate.extractText(priority: .background) { "" }
    }

    // (1) An AI request queued behind the background walk runs first: the walk
    // only ever costs a chat turn the single page already in flight.
    func testOnDemandJumpsAheadOfQueuedBackgroundWork() async {
        let gate = PageTextExtractionGate()
        await primeCooldown(on: gate)
        let recorder = Recorder()

        let holder = Task { await gate.extractText(priority: .background) { recorder.log("holder") } }
        await Task.yield()
        let queuedBackground = Task {
            await gate.extractText(priority: .background) { recorder.log("background") }
        }
        let queuedOnDemand = Task {
            await gate.extractText(priority: .onDemand) { recorder.log("onDemand") }
        }

        _ = await holder.value
        _ = await queuedBackground.value
        _ = await queuedOnDemand.value
        XCTAssertEqual(recorder.entries, ["holder", "onDemand", "background"])
        XCTAssertEqual(gate.queueDepth, 0)
    }

    // (2) Background waiters keep FIFO order among themselves.
    func testBackgroundWaitersStayInQueueOrder() async {
        let gate = PageTextExtractionGate()
        await primeCooldown(on: gate)
        let recorder = Recorder()

        let holder = Task { await gate.extractText(priority: .background) { recorder.log("holder") } }
        await Task.yield()
        let first = Task { await gate.extractText(priority: .background) { recorder.log("first") } }
        await Task.yield()
        let second = Task { await gate.extractText(priority: .background) { recorder.log("second") } }

        _ = await holder.value
        _ = await first.value
        _ = await second.value
        XCTAssertEqual(recorder.entries, ["holder", "first", "second"])
    }

    // (3) A walk cancelled on tab deactivation must leave the queue without
    // running its body and without stranding the slot for everyone behind it.
    func testCancelledWaiterReleasesTheQueue() async {
        let gate = PageTextExtractionGate()
        await primeCooldown(on: gate)
        let recorder = Recorder()

        let holder = Task { await gate.extractText(priority: .background) { recorder.log("holder") } }
        await Task.yield()
        let cancelled = Task {
            await gate.extractText(priority: .background) { recorder.log("cancelled") }
        }
        let follower = Task {
            await gate.extractText(priority: .background) { recorder.log("follower") }
        }
        await Task.yield()
        XCTAssertEqual(gate.queueDepth, 2, "both waiters should be parked behind the holder")

        cancelled.cancel()
        let cancelledResult = await cancelled.value
        XCTAssertNil(cancelledResult, "a cancelled waiter must not run its body")

        _ = await holder.value
        _ = await follower.value
        XCTAssertEqual(recorder.entries, ["holder", "follower"])
        XCTAssertEqual(gate.queueDepth, 0, "the cancelled waiter must not strand the slot")
    }

    // (4) A task cancelled before it ever reaches the gate does no work.
    func testAlreadyCancelledCallerSkipsExtraction() async {
        let gate = PageTextExtractionGate()
        let recorder = Recorder()
        let task = Task {
            // Give the test a chance to cancel before the gate is entered.
            try? await Task.sleep(for: .milliseconds(20))
            return await gate.extractText(priority: .background) { recorder.log("body") }
        }
        task.cancel()
        let result = await task.value
        XCTAssertNil(result)
        XCTAssertTrue(recorder.entries.isEmpty)
    }

    // (5) A page that came back with no text — the shape that reaches Live Text
    // — paces the next extraction, so bursts of scanned pages can't stack ANE
    // model loads.
    func testEmptyPageResultPacesTheNextExtraction() async {
        let gate = PageTextExtractionGate()
        _ = await gate.extractText(priority: .background) { "" }
        let started = ContinuousClock.now
        _ = await gate.extractText(priority: .onDemand) { "page text" }
        let waited = ContinuousClock.now - started
        XCTAssertGreaterThanOrEqual(
            waited, .milliseconds(10), "the page after a scanned one should be paced")
    }

    // (6) So does a read slow enough to have recognized text synchronously,
    // in case PDFKit ever makes `page.string` block on Live Text.
    func testSlowExtractionAlsoPacesTheNextOne() async {
        let gate = PageTextExtractionGate()
        _ = await gate.extractText(priority: .background) {
            Self.spin(for: .milliseconds(30))
            return "recognized text"
        }
        let started = ContinuousClock.now
        _ = await gate.extractText(priority: .onDemand) { "page text" }
        XCTAssertGreaterThanOrEqual(ContinuousClock.now - started, .milliseconds(10))
    }

    // (7) …but a document with a real text layer is not paced at all: those
    // reads never reach Live Text, so whole-document indexing stays as fast as
    // it was before the gate existed.
    func testTextLayerPagesAreNotPaced() async {
        let gate = PageTextExtractionGate()
        let started = ContinuousClock.now
        for page in 0..<40 {
            _ = await gate.extractText(priority: .background) { "text of page \(page)" }
        }
        let elapsed = ContinuousClock.now - started
        XCTAssertLessThan(
            elapsed, .milliseconds(200), "text-layer pages must not inherit the OCR cooldown")
    }

    // (8) A body that declines to read (already cached, wrong document) reports
    // nil and must not be mistaken for a scanned page.
    func testSkippedReadDoesNotPaceTheNextExtraction() async {
        let gate = PageTextExtractionGate()
        _ = await gate.extractText(priority: .background) { nil }
        let started = ContinuousClock.now
        _ = await gate.extractText(priority: .background) { "page text" }
        XCTAssertLessThan(
            ContinuousClock.now - started, .milliseconds(10),
            "skipping a cached page should cost nothing")
    }

    // MARK: - iPad: the off-main-body overload (#129 packet 7 §2.1)

    // (9) iPad: the off-main-body overload holds the same single slot, so a
    // detached walk and a main-actor locator can never both be reading.
    func testOffMainBodiesShareTheSameSlotAsSynchronousOnes() async {
        let gate = PageTextExtractionGate()
        await primeCooldown(on: gate)
        let recorder = Recorder()

        let holder = Task {
            await gate.extractText(priority: .background, offMain: {
                await MainActor.run { recorder.log("holder") }
            })
        }
        await Task.yield()
        let queued = Task { await gate.extractText(priority: .onDemand) { recorder.log("onDemand") } }

        _ = await holder.value
        _ = await queued.value
        XCTAssertEqual(recorder.entries, ["holder", "onDemand"])
        XCTAssertEqual(gate.queueDepth, 0)
    }

    // (10) …and the pacing contract is identical across the two overloads: an
    // empty result from an off-main body still paces the next caller.
    func testOffMainEmptyResultPacesTheNextExtraction() async {
        let gate = PageTextExtractionGate()
        _ = await gate.extractText(priority: .background, offMain: { "" })
        let started = ContinuousClock.now
        _ = await gate.extractText(priority: .onDemand) { "page text" }
        XCTAssertGreaterThanOrEqual(ContinuousClock.now - started, .milliseconds(10))
    }
}
