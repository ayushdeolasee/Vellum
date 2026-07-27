#if os(iOS)
import CoreGraphics
import Foundation
import PencilKit

/// Adapts `ScratchOutRecognizer` (pure geometry) to PencilKit: samples stroke
/// centrelines, decides whether the stroke the user just finished is a
/// scratch-out, and produces the drawing that should replace the current one.
///
/// ## Erase semantics
/// Scratch-out always removes **whole strokes**, i.e. it behaves like the
/// eraser's `.object` mode even when the user's eraser is set to `.pixel`. Two
/// reasons:
/// * PencilKit exposes no API to apply a bitmap mask to a `PKStroke`
///   programmatically — `PKEraserTool(.bitmap)` masking only happens inside the
///   canvas's own touch handling — so a pixel-accurate erase simply isn't
///   reachable from here.
/// * It is also the right semantics: scratching something out means "delete this
///   thing", not "shave the pixels I happened to cross". Notes and GoodNotes both
///   remove the whole stroke. The `minimumCoverage` guard is what makes that safe
///   — a stroke is only removed when the scribble covers most of its length.
///
/// Everything runs in page (zoom-1) space, which is the canvas's content space at
/// every super-sample factor `K` (see `InkOverlayProvider_iOS`), so the
/// thresholds mean the same thing at 100% and at 400% zoom.
enum ScratchOutInk {
    /// Spacing used to resample every stroke centreline. Uniform spacing is what
    /// lets `coveredFraction` treat "fraction of samples covered" as "fraction of
    /// arc length covered". 3 pt is fine enough to follow the tightest handwriting
    /// curve and coarse enough that the O(candidate × scratch) coverage scan on a
    /// densely inked page stays well inside one frame.
    static let sampleSpacing: CGFloat = 3

    /// Slack added to the hit radius on top of both strokes' half-widths, to
    /// absorb the fact that people scribble roughly and that a centreline sample
    /// is not the edge of the rendered stroke. Small enough that neighbouring
    /// lines of handwriting (typically ≥ 12 pt apart) don't get swept up.
    static let hitSlack: CGFloat = 3

    /// Floor on the hit radius so a hairline 2 pt pen scribbled over hairline ink
    /// still registers coverage despite hand wobble.
    static let minimumHitRadius: CGFloat = 7

    /// The outcome of a recognized scratch-out.
    struct Result: Sendable {
        /// The drawing with the scribble and everything it covered removed.
        var drawing: PKDrawing
        /// How many pre-existing strokes were removed (excludes the scribble).
        var erasedStrokeCount: Int
    }

    /// If `drawing.strokes[scratchIndex]` is a scratch-out that substantially
    /// covers other strokes, return the drawing with it and its victims removed.
    ///
    /// `nil` means "leave the drawing alone" — either the stroke isn't a
    /// scratch-out, or it is scribble-shaped but sits on blank paper. That second
    /// case is the most important false-positive guard in the feature: an
    /// idle doodle, a shading pass or a hatched fill drawn on empty space is
    /// simply kept as ink.
    static func erase(
        scratchIndex: Int,
        in drawing: PKDrawing,
        thresholds: ScratchOutRecognizer.Thresholds = .default
    ) -> Result? {
        let strokes = drawing.strokes
        guard strokes.indices.contains(scratchIndex) else { return nil }
        let scratch = strokes[scratchIndex]
        guard PdfInk.strokeHasVisibleInk(scratch) else { return nil }

        let scratchPath = centerline(of: scratch)
        guard ScratchOutRecognizer.isScratchOut(scratchPath, thresholds: thresholds) else { return nil }

        // Build the candidate list, skipping strokes the bitmap eraser has already
        // fully masked away — they render as nothing, so "erasing" them would
        // silently delete invisible objects the user can't reason about.
        let scratchReach = max(minimumHitRadius, halfWidth(of: scratch) + hitSlack)
        // Bounds prefilter before paying for centreline sampling: `renderBounds`
        // is already computed by PencilKit and includes the stroke's rendered
        // width, and on a densely inked page almost every stroke is nowhere near
        // the scribble. Without this, a scratch-out on a full page of notes
        // resamples every stroke on it.
        let reach = scratch.renderBounds.insetBy(dx: -scratchReach, dy: -scratchReach)
        var candidates: [ScratchOutRecognizer.OverlapCandidate] = []
        var candidateIndices: [Int] = []
        for (index, stroke) in strokes.enumerated() where index != scratchIndex {
            guard PdfInk.strokeHasVisibleInk(stroke), stroke.renderBounds.intersects(reach) else {
                continue
            }
            candidates.append(ScratchOutRecognizer.OverlapCandidate(
                points: centerline(of: stroke),
                hitRadius: scratchReach + halfWidth(of: stroke)))
            candidateIndices.append(index)
        }

        let hits = ScratchOutRecognizer.overlappedCandidates(
            scratch: scratchPath,
            candidates: candidates,
            thresholds: thresholds)
        guard !hits.isEmpty else { return nil }

        var doomed = Set(hits.map { candidateIndices[$0] })
        doomed.insert(scratchIndex)
        let kept = strokes.enumerated().filter { !doomed.contains($0.offset) }.map(\.element)
        return Result(drawing: PKDrawing(strokes: kept), erasedStrokeCount: doomed.count - 1)
    }

    /// Index of the single stroke `drawing` has that `previous` didn't, but only
    /// if every earlier stroke is unchanged — i.e. only if this really was an
    /// *append*. `nil` otherwise.
    ///
    /// The count alone (`previous.count + 1`) is not enough. Undoing a
    /// single-stroke object-erase also restores exactly one stroke, and it does
    /// not have to come back at the end; taking `strokes.last` on that callback
    /// would run the recognizer against an unrelated older stroke and, if that
    /// one happened to be scribble-shaped and over ink, delete it and everything
    /// under it. Comparing the prefix makes "a stroke landed at the end" a fact
    /// rather than an assumption.
    static func appendedStrokeIndex(in drawing: PKDrawing, after previous: PKDrawing) -> Int? {
        let strokes = drawing.strokes
        let old = previous.strokes
        guard strokes.count == old.count + 1 else { return nil }
        for index in old.indices where !isSameStroke(strokes[index], old[index]) { return nil }
        return old.count
    }

    /// Cheap identity proxy. `PKStroke` isn't `Equatable`, but a stroke's path
    /// creation date, control-point count and rendered bounds together are
    /// specific enough to tell "this is the same stroke object" from "the list
    /// shifted underneath us", which is all `appendedStrokeIndex` needs.
    private static func isSameStroke(_ lhs: PKStroke, _ rhs: PKStroke) -> Bool {
        lhs.path.creationDate == rhs.path.creationDate
            && lhs.path.count == rhs.path.count
            && lhs.renderBounds == rhs.renderBounds
    }

    /// A stroke's *visible* centreline in page space, resampled at
    /// `sampleSpacing`.
    ///
    /// Only the surviving `maskedPathRanges` are walked. This matters for
    /// coverage: the bitmap eraser masks a stroke rather than shortening it, so
    /// sampling the whole path would measure the fraction covered against the
    /// stroke's *original* length. Erase the right half of a word with the pixel
    /// eraser, then scribble over the surviving left half, and a full-path
    /// denominator scores ≈0.5 — just under `minimumCoverage` — leaving the
    /// remnant behind even though the user covered all of it.
    ///
    /// `stroke.transform` must be applied: PencilKit stores a path plus a
    /// transform, and undo/redo can leave a non-identity one behind.
    static func centerline(of stroke: PKStroke) -> [CGPoint] {
        guard !stroke.path.isEmpty else { return [] }
        var points: [CGPoint] = []
        for range in stroke.maskedPathRanges {
            for point in stroke.path.interpolatedPoints(in: range, by: .distance(sampleSpacing)) {
                points.append(point.location.applying(stroke.transform))
            }
        }
        // A tap-dot can interpolate to nothing; fall back to the first control
        // point so the stroke still has a position for the overlap test.
        if points.isEmpty, let first = stroke.path.first {
            points.append(first.location.applying(stroke.transform))
        }
        return points
    }

    /// Mean rendered half-width of a stroke, matching how `PdfInk` measures width
    /// (`PKStrokePoint.size` is the full ellipse, so a quarter of w+h is the
    /// average radius).
    static func halfWidth(of stroke: PKStroke) -> CGFloat {
        guard !stroke.path.isEmpty else { return 0 }
        var total: CGFloat = 0
        for point in stroke.path {
            total += (point.size.width + point.size.height) / 4
        }
        return total / CGFloat(stroke.path.count)
    }
}
#endif
