#if os(iOS)
import CoreGraphics
import PencilKit
import UIKit
import XCTest
@testable import Vellum

/// Unit tests for "scribble to erase". Two halves:
///
/// * the **recognizer** — synthesized scratch-outs must be recognized, and
///   synthesized handwriting / underlines / circles must not be. These are the
///   false-positive guards; the feature is destructive, so every "must NOT fire"
///   case here is load-bearing.
/// * the **overlap selection** — which existing strokes a recognized scribble
///   takes with it, including the case where it takes nothing (blank paper) and
///   so must not fire at all.
///
/// All coordinates are page (zoom-1) points, the space strokes are stored in.
final class ScratchOutRecognizerTests: XCTestCase {
    // MARK: - Shape synthesis

    /// Densely samples a polyline through `vertices` at `spacing`, the way a
    /// pencil sampling at 240 Hz would.
    private func polyline(_ vertices: [CGPoint], spacing: CGFloat = 2) -> [CGPoint] {
        guard let first = vertices.first else { return [] }
        var points: [CGPoint] = [first]
        for index in 1..<vertices.count {
            let a = vertices[index - 1]
            let b = vertices[index]
            let length = hypot(b.x - a.x, b.y - a.y)
            let steps = max(1, Int((length / spacing).rounded()))
            for step in 1...steps {
                let t = CGFloat(step) / CGFloat(steps)
                points.append(CGPoint(x: a.x + (b.x - a.x) * t, y: a.y + (b.y - a.y) * t))
            }
        }
        return points
    }

    /// A back-and-forth scrub: `passes` horizontal sweeps of `length`, each one
    /// `drift` points below the last. `passes - 1` reversals.
    private func scratchOut(
        passes: Int = 6,
        length: CGFloat = 100,
        drift: CGFloat = 3,
        origin: CGPoint = .zero
    ) -> [CGPoint] {
        var vertices: [CGPoint] = []
        for index in 0...passes {
            vertices.append(CGPoint(
                x: origin.x + (index.isMultiple(of: 2) ? 0 : length),
                y: origin.y + CGFloat(index) * drift))
        }
        return polyline(vertices)
    }

    private func rotated(_ points: [CGPoint], degrees: CGFloat) -> [CGPoint] {
        let transform = CGAffineTransform(rotationAngle: degrees * .pi / 180)
        return points.map { $0.applying(transform) }
    }

    private func circle(radius: CGFloat, center: CGPoint = .zero, samples: Int = 120) -> [CGPoint] {
        (0...samples).map { index in
            let angle = 2 * CGFloat.pi * CGFloat(index) / CGFloat(samples)
            return CGPoint(x: center.x + radius * cos(angle), y: center.y + radius * sin(angle))
        }
    }

    /// A cursive-looking wave — the archetypal false positive. Lots of sharp
    /// turns, but the pen never travels backwards along its principal axis.
    private func cursiveWave(
        width: CGFloat = 200,
        amplitude: CGFloat = 14,
        humps: Int = 5,
        samples: Int = 300
    ) -> [CGPoint] {
        (0...samples).map { index in
            let t = CGFloat(index) / CGFloat(samples)
            return CGPoint(
                x: width * t,
                y: amplitude * sin(2 * .pi * CGFloat(humps) * t))
        }
    }

    // MARK: - Recognized

    func testHorizontalScratchOutIsRecognized() {
        let points = scratchOut()
        let metrics = ScratchOutRecognizer.metrics(for: points)
        XCTAssertEqual(metrics.reversals, 5, "six passes means five confirmed reversals")
        XCTAssertGreaterThan(metrics.density, 2.5)
        XCTAssertTrue(ScratchOutRecognizer.isScratchOut(points))
    }

    func testVerticalScratchOutIsRecognized() {
        // Same gesture rotated onto the other axis: PCA must follow the ink, not
        // assume horizontal.
        let points = rotated(scratchOut(), degrees: 90)
        XCTAssertTrue(ScratchOutRecognizer.isScratchOut(points))
    }

    func testDiagonalScratchOutIsRecognized() {
        // The case a bounding-box major axis would get wrong: at 30° the box is
        // much squarer than the gesture, so only PCA finds the scrub direction.
        let points = rotated(scratchOut(), degrees: 30)
        XCTAssertTrue(ScratchOutRecognizer.isScratchOut(points))
    }

    func testTightScratchOutOverASingleWordIsRecognized() {
        // A realistic "cross out one word" scrub: 40 pt wide, 14 pt tall.
        let points = scratchOut(passes: 7, length: 40, drift: 2)
        XCTAssertTrue(ScratchOutRecognizer.isScratchOut(points))
    }

    // MARK: - NOT recognized (false-positive guards)

    func testStraightUnderlineIsNotRecognized() {
        let points = polyline([CGPoint(x: 0, y: 0), CGPoint(x: 220, y: 0)])
        let metrics = ScratchOutRecognizer.metrics(for: points)
        XCTAssertEqual(metrics.reversals, 0)
        XCTAssertEqual(metrics.density, 1, accuracy: 0.01, "a line is exactly its own diagonal")
        XCTAssertFalse(ScratchOutRecognizer.isScratchOut(points))
    }

    func testCircleIsNotRecognized() {
        let points = circle(radius: 45)
        let metrics = ScratchOutRecognizer.metrics(for: points)
        XCTAssertLessThan(metrics.reversals, 4, "a closed loop turns back at most twice")
        XCTAssertLessThan(metrics.density, 2.5, "a circle travels once around its own box")
        XCTAssertFalse(ScratchOutRecognizer.isScratchOut(points))
    }

    func testCursiveHandwritingIsNotRecognized() {
        let points = cursiveWave()
        let metrics = ScratchOutRecognizer.metrics(for: points)
        XCTAssertEqual(
            metrics.reversals, 0,
            "cursive oscillates across its principal axis but never doubles back along it")
        XCTAssertFalse(ScratchOutRecognizer.isScratchOut(points))
    }

    func testPrintedLetterMIsNotRecognized() {
        // The busiest single Latin letterform: four strokes of the pen, three
        // reversals along its (vertical) principal axis. This is precisely why
        // `minimumReversals` is 4 and not 3.
        let points = polyline([
            CGPoint(x: 0, y: 50), CGPoint(x: 0, y: 0),
            CGPoint(x: 20, y: 30), CGPoint(x: 40, y: 0), CGPoint(x: 40, y: 50),
        ])
        XCTAssertLessThanOrEqual(ScratchOutRecognizer.metrics(for: points).reversals, 3)
        XCTAssertFalse(ScratchOutRecognizer.isScratchOut(points))
    }

    func testZigZagLetterZIsNotRecognized() {
        let points = polyline([
            CGPoint(x: 0, y: 0), CGPoint(x: 60, y: 0),
            CGPoint(x: 0, y: 50), CGPoint(x: 60, y: 50),
        ])
        XCTAssertLessThanOrEqual(ScratchOutRecognizer.metrics(for: points).reversals, 2)
        XCTAssertFalse(ScratchOutRecognizer.isScratchOut(points))
    }

    func testShortTickIsNotRecognized() {
        // A `t` crossbar or an accent: scribble-shaped statistics are meaningless
        // this small, so the length floor rejects it outright.
        let points = polyline([CGPoint(x: 0, y: 0), CGPoint(x: 9, y: 2)])
        XCTAssertFalse(ScratchOutRecognizer.isScratchOut(points))
    }

    func testThreePassScribbleIsNotRecognized() {
        // Deliberately conservative: three passes (two reversals) is well short
        // of the bar, so a sloppy retrace can't delete the user's work.
        let points = scratchOut(passes: 3, length: 100, drift: 3)
        XCTAssertEqual(ScratchOutRecognizer.metrics(for: points).reversals, 2)
        XCTAssertFalse(ScratchOutRecognizer.isScratchOut(points))
    }

    // MARK: - Reversal counting

    func testTremorDoesNotCountAsReversals() {
        // A "straight" line drawn by a human hand: sign-of-difference counting
        // would report dozens of reversals here; hysteresis reports none.
        var points: [CGPoint] = []
        for index in 0..<120 {
            let x = CGFloat(index) * 2
            points.append(CGPoint(x: x, y: sin(CGFloat(index)) * 2.5))
        }
        let metrics = ScratchOutRecognizer.metrics(for: points)
        XCTAssertEqual(metrics.reversals, 0)
    }

    func testPrincipalAxisFollowsTheInk() {
        let horizontal = ScratchOutRecognizer.principalAxis(of: polyline([
            CGPoint(x: 0, y: 0), CGPoint(x: 100, y: 0),
        ]))
        XCTAssertEqual(abs(horizontal.dx), 1, accuracy: 0.001)

        let vertical = ScratchOutRecognizer.principalAxis(of: polyline([
            CGPoint(x: 0, y: 0), CGPoint(x: 0, y: 100),
        ]))
        XCTAssertEqual(abs(vertical.dy), 1, accuracy: 0.001)

        let diagonal = ScratchOutRecognizer.principalAxis(of: polyline([
            CGPoint(x: 0, y: 0), CGPoint(x: 100, y: 100),
        ]))
        XCTAssertEqual(abs(diagonal.dx), abs(diagonal.dy), accuracy: 0.001)
    }

    // MARK: - Overlap selection

    func testOverlapPicksCoveredStrokesAndSparesCrossedOnes() {
        let scratch = scratchOut()  // spans x 0…100, y 0…18

        // A short word-sized stroke living entirely under the scribble.
        let word = ScratchOutRecognizer.OverlapCandidate(
            points: polyline([CGPoint(x: 10, y: 9), CGPoint(x: 90, y: 9)], spacing: 3),
            hitRadius: 8)
        // A long rule the scribble merely crosses: only a fifth of it is covered.
        let underline = ScratchOutRecognizer.OverlapCandidate(
            points: polyline([CGPoint(x: -200, y: 9), CGPoint(x: 300, y: 9)], spacing: 3),
            hitRadius: 8)
        // Ink on another line entirely.
        let elsewhere = ScratchOutRecognizer.OverlapCandidate(
            points: polyline([CGPoint(x: 10, y: 500), CGPoint(x: 90, y: 500)], spacing: 3),
            hitRadius: 8)

        let hits = ScratchOutRecognizer.overlappedCandidates(
            scratch: scratch,
            candidates: [word, underline, elsewhere])
        XCTAssertEqual(hits, [0], "only the substantially covered stroke is erased")
    }

    /// A tapped dot degenerates every assumption in the overlap path: its
    /// bounding box has zero width and height, and it is a one-sample polyline
    /// so there is no segment to measure a distance against. Both the
    /// `reach.intersects(...)` prefilter and `coveredFraction`'s
    /// `path.count >= 2` guard sit right next to that case, and either could
    /// start dropping dots under a plausible refactor — a zero-size rect is
    /// `isEmpty`, and `CGRectIntersectsRect` is documented in terms of empty
    /// rects. It currently works; this pins it.
    func testScribblingOverATappedDotErasesIt() {
        let scratch = scratchOut()  // sweeps x 0…100 around y 0…18
        let dot = ScratchOutRecognizer.OverlapCandidate(
            points: [CGPoint(x: 50, y: 9)],
            hitRadius: 8)

        let hits = ScratchOutRecognizer.overlappedCandidates(scratch: scratch, candidates: [dot])
        XCTAssertEqual(hits, [0], "a dot under the scribble must be erased like any other ink")
    }

    /// The other zero-size box: a rule drawn dead flat has zero height, so it is
    /// `isEmpty` too even though it is a perfectly ordinary multi-sample stroke.
    /// Real Pencil input is never exactly axis-aligned, but imported or
    /// programmatically drawn ink can be.
    func testScribblingOverAPerfectlyFlatStrokeErasesIt() {
        let scratch = scratchOut()
        let flat = ScratchOutRecognizer.OverlapCandidate(
            points: polyline([CGPoint(x: 20, y: 9), CGPoint(x: 80, y: 9)], spacing: 2),
            hitRadius: 8)

        let hits = ScratchOutRecognizer.overlappedCandidates(scratch: scratch, candidates: [flat])
        XCTAssertEqual(hits, [0], "a flat stroke fully under the scribble must be erased")
    }

    func testCoveredFractionIsProportionalToOverlap() {
        let scratch = scratchOut()  // covers x 0…100
        let half = polyline([CGPoint(x: 0, y: 9), CGPoint(x: 200, y: 9)], spacing: 2)
        let fraction = ScratchOutRecognizer.coveredFraction(of: half, by: scratch, within: 8)
        XCTAssertEqual(fraction, 0.5, accuracy: 0.08, "half the rule lies under the scribble")
    }

    func testCoverageIgnoresStrokesJustOutOfReach() {
        let scratch = scratchOut()
        let nearMiss = polyline([CGPoint(x: 0, y: 40), CGPoint(x: 100, y: 40)], spacing: 3)
        XCTAssertEqual(
            ScratchOutRecognizer.coveredFraction(of: nearMiss, by: scratch, within: 8), 0,
            accuracy: 0.001,
            "the scribble bottoms out at y = 18; a line 22 pt below is untouched")
    }

    // MARK: - PencilKit integration (ScratchOutInk)

    private func stroke(_ points: [CGPoint], width: CGFloat = 4) -> PKStroke {
        let controlPoints = points.enumerated().map { index, location in
            PKStrokePoint(
                location: location,
                timeOffset: TimeInterval(index) * 0.008,
                size: CGSize(width: width, height: width),
                opacity: 1,
                force: 1,
                azimuth: 0,
                altitude: .pi / 2)
        }
        return PKStroke(
            ink: PKInk(.pen, color: .black),
            path: PKStrokePath(controlPoints: controlPoints, creationDate: Date(timeIntervalSince1970: 0)))
    }

    func testEraseRemovesTheScribbleAndWhatItCovers() throws {
        let word = stroke(polyline([CGPoint(x: 10, y: 9), CGPoint(x: 90, y: 9)]))
        let bystander = stroke(polyline([CGPoint(x: 10, y: 400), CGPoint(x: 90, y: 400)]))
        let scribble = stroke(scratchOut())
        let drawing = PKDrawing(strokes: [word, bystander, scribble])

        let result = try XCTUnwrap(ScratchOutInk.erase(scratchIndex: 2, in: drawing))
        XCTAssertEqual(result.erasedStrokeCount, 1)
        XCTAssertEqual(result.drawing.strokes.count, 1, "the scribble deletes itself too")
        XCTAssertEqual(
            result.drawing.strokes[0].renderBounds.midY,
            bystander.renderBounds.midY,
            accuracy: 1,
            "the untouched stroke on another line survives")
    }

    func testScribbleOnBlankPaperIsKeptAsInk() {
        // The single most important guard: scribble-shaped geometry over nothing
        // is a doodle, not an erase, so `erase` declines and the stroke stays.
        let drawing = PKDrawing(strokes: [stroke(scratchOut())])
        XCTAssertNil(ScratchOutInk.erase(scratchIndex: 0, in: drawing))
    }

    func testOrdinaryStrokeOverInkIsNotAnErase() {
        let word = stroke(polyline([CGPoint(x: 10, y: 9), CGPoint(x: 90, y: 9)]))
        // An underline drawn right on top of the word — overlapping, but not a
        // scratch-out.
        let underline = stroke(polyline([CGPoint(x: 5, y: 11), CGPoint(x: 95, y: 11)]))
        let drawing = PKDrawing(strokes: [word, underline])
        XCTAssertNil(ScratchOutInk.erase(scratchIndex: 1, in: drawing))
    }

    /// The realistic data-loss case: notes on ruled lines. Scrubbing out a word
    /// must not reach the line above. The scribble drifts over 18 pt, so with
    /// 16 pt line spacing the neighbour sits ~16 pt from the scribble's top pass
    /// — outside the ~9 pt effective hit radius, but only just, which is exactly
    /// why it needs a test rather than a comment.
    func testAdjacentLineOfHandwritingSurvives() throws {
        let target = stroke(polyline([CGPoint(x: 10, y: 9), CGPoint(x: 90, y: 9)]))
        let lineAbove = stroke(polyline([CGPoint(x: 10, y: -16), CGPoint(x: 90, y: -16)]))
        let lineBelow = stroke(polyline([CGPoint(x: 10, y: 34), CGPoint(x: 90, y: 34)]))
        let drawing = PKDrawing(strokes: [lineAbove, target, lineBelow, stroke(scratchOut())])

        let result = try XCTUnwrap(ScratchOutInk.erase(scratchIndex: 3, in: drawing))
        XCTAssertEqual(result.erasedStrokeCount, 1, "only the scrubbed line is erased")
        XCTAssertEqual(result.drawing.strokes.count, 2)
        let survivingMidYs = result.drawing.strokes.map { $0.renderBounds.midY }.sorted()
        XCTAssertEqual(survivingMidYs[0], -16, accuracy: 2)
        XCTAssertEqual(survivingMidYs[1], 34, accuracy: 2)
    }

    /// Undo restoring a stroke looks exactly like the user drawing one if you
    /// only compare counts, and the restored stroke need not come back at the
    /// end. Prefix comparison is what makes "appended" a fact.
    func testAppendedStrokeIndexRejectsANonAppendInsertion() {
        let a = stroke(polyline([CGPoint(x: 0, y: 0), CGPoint(x: 50, y: 0)]))
        let b = stroke(polyline([CGPoint(x: 0, y: 20), CGPoint(x: 50, y: 20)]))
        let restored = stroke(polyline([CGPoint(x: 0, y: 40), CGPoint(x: 50, y: 40)]))
        let previous = PKDrawing(strokes: [a, b])

        XCTAssertEqual(
            ScratchOutInk.appendedStrokeIndex(
                in: PKDrawing(strokes: [a, b, restored]), after: previous),
            2,
            "a genuine append is identified")
        XCTAssertNil(
            ScratchOutInk.appendedStrokeIndex(
                in: PKDrawing(strokes: [restored, a, b]), after: previous),
            "a stroke restored at the front is not an append")
        XCTAssertNil(
            ScratchOutInk.appendedStrokeIndex(
                in: PKDrawing(strokes: [a, restored, b]), after: previous),
            "a stroke restored in the middle is not an append")
        XCTAssertNil(
            ScratchOutInk.appendedStrokeIndex(in: PKDrawing(strokes: [a]), after: previous),
            "a vector erase is not an append")
        XCTAssertNil(
            ScratchOutInk.appendedStrokeIndex(in: previous, after: previous),
            "an unchanged drawing is not an append")
    }

    /// The bitmap eraser masks a stroke instead of shortening it, so coverage has
    /// to be measured against what still renders. Half-erase a word, scribble
    /// over the surviving half, and it must go: against the full original path
    /// that scores ≈0.5 and falls just under `minimumCoverage`.
    func testCoverageMeasuresOnlyTheUnmaskedPartOfAStroke() throws {
        let word = stroke(polyline([CGPoint(x: 0, y: 9), CGPoint(x: 200, y: 9)]))
        // Keep only x ≤ 100 — the half the scribble (x 0…100) sits over.
        let halfErased = PKStroke(
            ink: word.ink,
            path: word.path,
            transform: word.transform,
            mask: UIBezierPath(rect: CGRect(x: -50, y: -50, width: 150, height: 200)))
        XCTAssertTrue(PdfInk.strokeHasVisibleInk(halfErased), "precondition: half survives")

        let visible = ScratchOutInk.centerline(of: halfErased)
        XCTAssertLessThan(
            visible.map(\.x).max() ?? .greatestFiniteMagnitude, 130,
            "the centreline stops at the mask rather than running the full 200 pt")

        let result = try XCTUnwrap(
            ScratchOutInk.erase(
                scratchIndex: 1,
                in: PKDrawing(strokes: [halfErased, stroke(scratchOut())])))
        XCTAssertEqual(result.erasedStrokeCount, 1, "the surviving half is fully covered")
    }

    func testAlreadyErasedStrokesAreNotCounted() {
        // A stroke the bitmap eraser wiped out still lives in `drawing.strokes`.
        // It renders as nothing, so a scribble over its old position must not
        // count it as a hit — otherwise the gesture would "erase" invisible
        // objects and fire on what looks to the user like blank paper.
        let word = stroke(polyline([CGPoint(x: 10, y: 9), CGPoint(x: 90, y: 9)]))
        let ghost = PKStroke(
            ink: word.ink,
            path: word.path,
            transform: word.transform,
            mask: UIBezierPath(rect: CGRect(x: 5000, y: 5000, width: 1, height: 1)))
        XCTAssertFalse(PdfInk.strokeHasVisibleInk(ghost), "precondition: the ghost is invisible")

        let drawing = PKDrawing(strokes: [ghost, stroke(scratchOut())])
        XCTAssertNil(ScratchOutInk.erase(scratchIndex: 1, in: drawing))
    }
}
#endif
