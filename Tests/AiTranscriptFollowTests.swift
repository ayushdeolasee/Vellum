import XCTest
import SwiftUI
@testable import Vellum

/// The AI transcript's stick-to-bottom rule (`AiPanel.follows`).
///
/// Issue #57: the transcript re-ran `scrollToBottom` on every streamed token, so
/// scrolling up to re-read part of an answer yanked you straight back down. The
/// replacement follows the tail only while the reader is parked at it — and that
/// rule is fiddly precisely because content growth and reader scrolling arrive
/// through the same `onScrollGeometryChange` signal.
///
/// In the app every one of these scenarios needs a live streamed reply to
/// reproduce, so the rule was extracted as a pure function to get it under test
/// here instead.
@MainActor
final class AiTranscriptFollowTests: XCTestCase {

    /// A viewport shorter than the content, i.e. a transcript long enough to
    /// scroll. `offset` is the scroll position; `content` the laid-out height.
    private func metrics(offset: CGFloat, content: CGFloat, viewport: CGFloat = 500) -> AiPanel.ScrollMetrics {
        AiPanel.ScrollMetrics(offsetY: offset, contentHeight: content, viewportHeight: viewport)
    }

    /// Scroll position that puts the end of the content at the bottom edge.
    private func atEnd(content: CGFloat, viewport: CGFloat = 500) -> CGFloat {
        content - viewport
    }

    // MARK: - Streaming under a stationary reader

    /// The core trap: a token grows the content, which moves the end away from a
    /// reader who has not touched the scroller. A naive "am I at the end?" test
    /// unsticks them here, on the very first token.
    func testAStreamedTokenDoesNotUnstickAStationaryReader() {
        let before = metrics(offset: atEnd(content: 2000), content: 2000)
        // 300pt of new text arrives; the offset has not moved yet.
        let after = metrics(offset: before.offsetY, content: 2300)
        XCTAssertGreaterThan(
            after.distanceFromBottom, AiPanel.bottomSlack,
            "precondition: the token must push the end out of slack range")
        XCTAssertTrue(AiPanel.follows(was: true, from: before, to: after))
    }

    /// The very first token of a reply, arriving into an empty-ish transcript.
    func testTheFirstTokenKeepsFollowing() {
        let before = metrics(offset: 0, content: 120)
        let after = metrics(offset: 0, content: 900)
        XCTAssertTrue(AiPanel.follows(was: true, from: before, to: after))
    }

    /// Following means the programmatic `scrollToBottom` lands next. It only ever
    /// moves the offset DOWN, so it must not read as a reader scroll — otherwise
    /// the fix feeds back on itself and unsticks on every token.
    func testTheProgrammaticCatchUpScrollDoesNotUnstick() {
        let before = metrics(offset: atEnd(content: 2000), content: 2300)
        // scrollToBottom aligns the 1pt anchor with the viewport edge, leaving
        // the transcript's 12pt bottom padding below it.
        let after = metrics(offset: atEnd(content: 2300) - 12, content: 2300)
        XCTAssertTrue(AiPanel.follows(was: true, from: before, to: after))
        XCTAssertLessThan(
            after.distanceFromBottom, AiPanel.bottomSlack,
            "the slack must cover the transcript's bottom padding or following can never settle")
    }

    // MARK: - The reader

    func testScrollingUpMidStreamStopsFollowing() {
        let before = metrics(offset: atEnd(content: 2000), content: 2000)
        // The reader drags up 400pt while a token happens to land in the same
        // geometry update — growth plus a DECREASED offset is unambiguously them.
        let after = metrics(offset: before.offsetY - 400, content: 2100)
        XCTAssertFalse(AiPanel.follows(was: true, from: before, to: after))
    }

    func testScrollingUpAfterTheStreamEndsStopsFollowing() {
        let before = metrics(offset: atEnd(content: 2000), content: 2000)
        let after = metrics(offset: before.offsetY - 400, content: 2000)
        XCTAssertFalse(AiPanel.follows(was: true, from: before, to: after))
    }

    /// Content that keeps growing under a reader who has already scrolled away
    /// must not drag them back — this is the whole point of the issue.
    func testTokensArrivingWhileScrolledUpDoNotReArmFollowing() {
        var state = false
        var previous = metrics(offset: 600, content: 2000)
        for growth in stride(from: 2100, through: 3000, by: 100) {
            let next = metrics(offset: 600, content: CGFloat(growth))
            state = AiPanel.follows(was: state, from: previous, to: next)
            XCTAssertFalse(state, "a streamed token re-armed following at content height \(growth)")
            previous = next
        }
    }

    func testScrollingBackToTheBottomReArmsFollowing() {
        let before = metrics(offset: 600, content: 2000)
        let after = metrics(offset: atEnd(content: 2000), content: 2000)
        XCTAssertTrue(AiPanel.follows(was: false, from: before, to: after))
    }

    /// Rubber-band overscroll past the end reads as "at the bottom", not as a
    /// wildly wrong distance.
    func testOverscrollingPastTheEndStillCountsAsFollowing() {
        let before = metrics(offset: atEnd(content: 2000), content: 2000)
        let after = metrics(offset: before.offsetY + 80, content: 2000)
        XCTAssertEqual(after.distanceFromBottom, 0)
        XCTAssertTrue(AiPanel.follows(was: true, from: before, to: after))
    }

    // MARK: - The panel resizing under the transcript

    /// The defect this rule originally shipped with. Nothing about the transcript
    /// changed — the panel's own chrome grew and stole viewport height — but the
    /// end moved away, so a contentHeight-only test concluded the reader had
    /// scrolled off and stopped following mid-reply.
    func testTheComposerGrowingUnderTheTranscriptDoesNotUnstickAReader() {
        let before = metrics(offset: atEnd(content: 2000, viewport: 500), content: 2000, viewport: 500)
        // ComposerTextView grows 36pt -> 120pt as the user types a multi-line
        // question; the transcript below the header loses exactly that height.
        let after = metrics(offset: before.offsetY, content: 2000, viewport: 500 - 84)
        XCTAssertGreaterThan(
            after.distanceFromBottom, AiPanel.bottomSlack,
            "precondition: the shrink must push the end out of slack range")
        XCTAssertTrue(
            AiPanel.follows(was: true, from: before, to: after),
            "a viewport shrink is not a reader scroll")
    }

    /// Same shape, from the settings section expanding above the transcript.
    func testOpeningTheSettingsSectionDoesNotUnstickAReader() {
        let before = metrics(offset: atEnd(content: 3000, viewport: 600), content: 3000, viewport: 600)
        let after = metrics(offset: before.offsetY, content: 3000, viewport: 380)
        XCTAssertTrue(AiPanel.follows(was: true, from: before, to: after))
    }

    /// A reader who had already scrolled away stays away across a resize.
    func testAResizeDoesNotReArmAReaderWhoScrolledAway() {
        let before = metrics(offset: 600, content: 3000, viewport: 500)
        let after = metrics(offset: 600, content: 3000, viewport: 420)
        XCTAssertFalse(AiPanel.follows(was: false, from: before, to: after))
    }

    /// Growing the viewport back can clamp the offset down. That looks like an
    /// upward scroll, but it only happens to a reader already at the end — who
    /// the at-the-bottom check catches first.
    func testGrowingTheViewportBackKeepsFollowing() {
        let before = metrics(offset: atEnd(content: 2000, viewport: 416), content: 2000, viewport: 416)
        let after = metrics(offset: atEnd(content: 2000, viewport: 500), content: 2000, viewport: 500)
        XCTAssertLessThan(after.offsetY, before.offsetY, "precondition: the offset clamps down")
        XCTAssertTrue(AiPanel.follows(was: true, from: before, to: after))
    }

    // MARK: - Degenerate content

    /// A reply shorter than the viewport has no tail to scroll away from, so the
    /// Jump to latest pill must never be offered for one.
    func testContentShorterThanTheViewportAlwaysFollows() {
        let before = metrics(offset: 0, content: 120, viewport: 500)
        for content in [CGFloat(150), 300, 499] {
            let after = metrics(offset: 0, content: content, viewport: 500)
            XCTAssertEqual(after.distanceFromBottom, 0)
            XCTAssertTrue(AiPanel.follows(was: true, from: before, to: after))
        }
    }
}
