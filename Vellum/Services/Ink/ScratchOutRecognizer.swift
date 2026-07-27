import CoreGraphics
import Foundation

/// Pure geometry behind "scribble to erase": decide whether one finished ink
/// stroke is a *scratch-out* (a back-and-forth scribble meaning "delete this"),
/// and work out which existing strokes that scribble covered.
///
/// Everything here is a pure function over `CGPoint` arrays — no PencilKit, no
/// UIKit, no canvas state — so the heuristic can be unit-tested against
/// synthesized shapes. `ScratchOutInk` (iOS) is the thin adapter that samples
/// `PKStroke` centrelines and feeds them in.
///
/// ## Why these signals
/// The two properties that separate a scratch-out from real handwriting are:
///
/// 1. **Reversals along the stroke's own principal axis.** A scratch-out sweeps
///    back and forth along one line; letters do not. Crucially we project onto
///    the stroke's *principal* (largest-variance) axis rather than counting raw
///    turns, because that is what kills the classic false positive: cursive
///    `m`/`w`/`mmm` is a pile of sharp turns, but the pen still travels
///    monotonically left-to-right, so it registers **zero** reversals along its
///    principal (horizontal) axis. A scribble over the same word registers one
///    per pass.
/// 2. **Density** — path length relative to the bounding box diagonal. A
///    scratch-out re-covers ground it already covered; a letter, an underline
///    or a circle travels roughly once around its own bounding box.
///
/// Self-intersection counting (the other textbook scribble signal) is
/// deliberately *not* used: a pure sawtooth scratch-out — probably the most
/// common shape people draw — has zero self-intersections, so requiring them
/// would miss the main case, while allowing them as an alternative trigger
/// would fire on ordinary cursive (`e`, `l`, `b` and friends each self-cross).
///
/// The recognizer is only half of the guard. The caller must *also* require the
/// scribble to substantially cover existing ink (`overlappedCandidates`), so a
/// scribble on blank paper is kept as ordinary ink rather than eaten.
enum ScratchOutRecognizer {
    /// Every tunable in one place. Values are in page (zoom-1) points — the
    /// same space stroke geometry is stored in, so a scratch-out is judged
    /// identically whether the user drew it at 100% or 400% zoom.
    struct Thresholds: Sendable, Equatable {
        /// Minimum spacing when thinning the input polyline. Apple Pencil
        /// samples at ~240 Hz, so a slow pass produces clusters of points whose
        /// pairwise directions are pure noise; anything below this is dropped.
        /// 2 pt is below the width of the thinnest pen preset, so thinning can
        /// never erase a real feature of the path.
        var resampleSpacing: CGFloat = 2

        /// A scratch-out is a long gesture. Below this many thinned samples the
        /// "stroke" is a tick, a dot or an accent, and the statistics below are
        /// too noisy to trust.
        var minimumPointCount: Int = 8

        /// Total path length floor. 40 pt is roughly three passes over a single
        /// 12 pt character — under that the user is writing, not scrubbing.
        /// This alone rejects almost all individual letter strokes, which is why
        /// printed handwriting (one short stroke per letter) is safe by
        /// construction.
        var minimumPathLength: CGFloat = 40

        /// How far the pen must travel back along the principal axis before a
        /// turn counts as a real reversal (hysteresis). 8 pt is larger than
        /// handwriting tremor and larger than the retrace at the top of a
        /// cursive loop, but far smaller than a deliberate scrub pass.
        var minimumReversalTravel: CGFloat = 8

        /// How many confirmed reversals are required. 4 reversals means at least
        /// **5** directional passes over the same line. No Latin letterform
        /// needs that: `M` and `W` are 3 passes (2 reversals), `N` and `Z` are 2
        /// passes. Set deliberately above the busiest letter so that a single
        /// sloppy character can never trip the gesture; the cost is that a very
        /// lazy two-pass scribble is treated as ink, which is the failure
        /// direction we want.
        var minimumReversals: Int = 4

        /// Path length ÷ bounding-box diagonal. A straight line scores 1.0, a
        /// circle ≈ 2.2, a printed word ≈ 2, and a 5-pass scribble ≈ 5. 2.5
        /// sits above every "travels once around its own box" shape — notably a
        /// circle, which the reversal test alone would not reject as firmly.
        var minimumDensity: CGFloat = 2.5

        /// Fraction of an existing stroke's length that must sit under the
        /// scribble before that stroke is erased. 0.5 encodes "substantially
        /// overlaps": scribbling over a word wipes each letter stroke (they are
        /// short and end up fully covered) while a scribble that merely *crosses*
        /// a long underline or a diagram edge leaves it alone.
        var minimumCoverage: CGFloat = 0.5

        static let `default` = Thresholds()
    }

    /// The measured geometry of a candidate stroke. Returned separately from the
    /// boolean so tests (and a DEBUG log) can see *why* a stroke was or was not
    /// recognized instead of only that it wasn't.
    struct Metrics: Sendable, Equatable {
        var pointCount: Int
        var pathLength: CGFloat
        var boundingBox: CGRect
        var principalAxis: CGVector
        var reversals: Int
        /// `pathLength / boundingBox` diagonal; 0 for a degenerate box.
        var density: CGFloat
    }

    // MARK: - Recognition

    /// Whether `points` (a stroke centreline in page space) is a scratch-out.
    static func isScratchOut(_ points: [CGPoint], thresholds: Thresholds = .default) -> Bool {
        let metrics = metrics(for: points, thresholds: thresholds)
        return metrics.pointCount >= thresholds.minimumPointCount
            && metrics.pathLength >= thresholds.minimumPathLength
            && metrics.reversals >= thresholds.minimumReversals
            && metrics.density >= thresholds.minimumDensity
    }

    /// Measure `points` without judging them.
    static func metrics(for points: [CGPoint], thresholds: Thresholds = .default) -> Metrics {
        let thinned = thinned(points, spacing: thresholds.resampleSpacing)
        guard thinned.count >= 2 else {
            return Metrics(
                pointCount: thinned.count,
                pathLength: 0,
                boundingBox: .null,
                principalAxis: CGVector(dx: 1, dy: 0),
                reversals: 0,
                density: 0)
        }

        let box = boundingBox(of: thinned)
        let length = pathLength(of: thinned)
        let axis = principalAxis(of: thinned)
        let projections = thinned.map { $0.x * axis.dx + $0.y * axis.dy }
        let diagonal = hypot(box.width, box.height)

        return Metrics(
            pointCount: thinned.count,
            pathLength: length,
            boundingBox: box,
            principalAxis: axis,
            reversals: reversals(in: projections, minimumTravel: thresholds.minimumReversalTravel),
            density: diagonal > 0 ? length / diagonal : 0)
    }

    // MARK: - Overlap selection

    /// One existing stroke considered for deletion, already reduced to its
    /// centreline. `hitRadius` folds in both strokes' rendered half-widths, so a
    /// fat marker line counts as covered when the scribble passes near — not
    /// only dead through — its centre.
    struct OverlapCandidate: Sendable, Equatable {
        var points: [CGPoint]
        var hitRadius: CGFloat

        init(points: [CGPoint], hitRadius: CGFloat) {
            self.points = points
            self.hitRadius = hitRadius
        }
    }

    /// Indices of the candidates the scribble substantially covers.
    ///
    /// "Substantially" is a *length* fraction, not a hit test: a single crossing
    /// point is not enough. That is what keeps a scratch-out from taking out the
    /// long underline or table rule it happens to sit on top of, while still
    /// wiping the short strokes that make up the word being deleted.
    static func overlappedCandidates(
        scratch: [CGPoint],
        candidates: [OverlapCandidate],
        thresholds: Thresholds = .default
    ) -> [Int] {
        guard scratch.count >= 2 else { return [] }
        let scratchBox = boundingBox(of: scratch)

        var hits: [Int] = []
        for (index, candidate) in candidates.enumerated() {
            guard candidate.points.count >= 1 else { continue }
            // Cheap reject first: the coverage scan below is O(candidate × scratch).
            let reach = scratchBox.insetBy(dx: -candidate.hitRadius, dy: -candidate.hitRadius)
            guard reach.intersects(boundingBox(of: candidate.points)) else { continue }
            let covered = coveredFraction(
                of: candidate.points,
                by: scratch,
                within: candidate.hitRadius,
                giveUpBelow: thresholds.minimumCoverage)
            if covered >= thresholds.minimumCoverage { hits.append(index) }
        }
        return hits
    }

    /// Fraction of `polyline`'s samples that lie within `radius` of `path`.
    ///
    /// Sample-count is used as a stand-in for arc length, which is exact as long
    /// as the caller samples at a uniform spacing (`ScratchOutInk` does).
    /// `giveUpBelow` lets the scan bail as soon as enough samples have missed
    /// that the threshold is unreachable.
    static func coveredFraction(
        of polyline: [CGPoint],
        by path: [CGPoint],
        within radius: CGFloat,
        giveUpBelow: CGFloat = 0
    ) -> CGFloat {
        guard !polyline.isEmpty, path.count >= 2 else { return 0 }
        let total = CGFloat(polyline.count)
        var covered = 0
        var remaining = polyline.count
        for point in polyline {
            if distance(from: point, toPolyline: path) <= radius { covered += 1 }
            remaining -= 1
            // Bail once the threshold is arithmetically out of reach. Compared
            // directly rather than via a precomputed miss budget: `Int((1 -
            // giveUpBelow) * total)` truncates, and for thresholds whose binary
            // representation is inexact (0.3 × 90 = 62.999…) that rounds the
            // budget down by one and bails on a stroke that exactly met the bar.
            if CGFloat(covered + remaining) < giveUpBelow * total { return 0 }
        }
        return CGFloat(covered) / total
    }

    // MARK: - Geometry primitives

    /// Drop samples closer together than `spacing`, keeping the first and last.
    /// The final sample is always kept because the last leg of a scratch-out is
    /// often a short flick, and losing it would hide a reversal.
    static func thinned(_ points: [CGPoint], spacing: CGFloat) -> [CGPoint] {
        guard let first = points.first else { return [] }
        var result: [CGPoint] = [first]
        for point in points.dropFirst() {
            let last = result[result.count - 1]
            if hypot(point.x - last.x, point.y - last.y) >= spacing { result.append(point) }
        }
        if let last = points.last, last != result[result.count - 1] { result.append(last) }
        return result
    }

    static func pathLength(of points: [CGPoint]) -> CGFloat {
        guard points.count >= 2 else { return 0 }
        var total: CGFloat = 0
        for index in 1..<points.count {
            total += hypot(
                points[index].x - points[index - 1].x,
                points[index].y - points[index - 1].y)
        }
        return total
    }

    static func boundingBox(of points: [CGPoint]) -> CGRect {
        guard let first = points.first else { return .null }
        var minX = first.x, maxX = first.x, minY = first.y, maxY = first.y
        for point in points.dropFirst() {
            minX = min(minX, point.x); maxX = max(maxX, point.x)
            minY = min(minY, point.y); maxY = max(maxY, point.y)
        }
        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }

    /// Unit vector along the direction of greatest variance (2×2 PCA).
    ///
    /// The bounding box's major axis would be cheaper but is wrong for a
    /// diagonal scribble: a 45° scratch-out has a near-square box, so the box
    /// axis is arbitrary and the reversals project away to nothing. PCA follows
    /// the ink itself.
    static func principalAxis(of points: [CGPoint]) -> CGVector {
        guard points.count >= 2 else { return CGVector(dx: 1, dy: 0) }
        let count = CGFloat(points.count)
        let meanX = points.reduce(CGFloat(0)) { $0 + $1.x } / count
        let meanY = points.reduce(CGFloat(0)) { $0 + $1.y } / count

        var sxx: CGFloat = 0, syy: CGFloat = 0, sxy: CGFloat = 0
        for point in points {
            let dx = point.x - meanX
            let dy = point.y - meanY
            sxx += dx * dx
            syy += dy * dy
            sxy += dx * dy
        }

        // Larger eigenvalue of the symmetric covariance matrix [[sxx, sxy], [sxy, syy]].
        let trace = sxx + syy
        let determinant = sxx * syy - sxy * sxy
        let discriminant = max(0, trace * trace / 4 - determinant)
        let eigenvalue = trace / 2 + sqrt(discriminant)

        // Either row of (C − λI) gives the eigenvector; take the longer one so a
        // near-degenerate row (axis-aligned input) doesn't amplify rounding error.
        let rowA = CGVector(dx: sxy, dy: eigenvalue - sxx)
        let rowB = CGVector(dx: eigenvalue - syy, dy: sxy)
        let vector = (rowA.dx * rowA.dx + rowA.dy * rowA.dy)
            >= (rowB.dx * rowB.dx + rowB.dy * rowB.dy) ? rowA : rowB
        let length = hypot(vector.dx, vector.dy)
        guard length > 1e-6 else { return CGVector(dx: 1, dy: 0) }
        return CGVector(dx: vector.dx / length, dy: vector.dy / length)
    }

    /// Count direction flips in a 1-D sequence, ignoring anything that doesn't
    /// travel back at least `minimumTravel`.
    ///
    /// Implemented as extremum tracking with hysteresis rather than
    /// sign-of-difference counting: consecutive samples on a hand-drawn line
    /// flip sign constantly from tremor, so a naive count is dominated by noise.
    /// Here the running extremum only moves outward, and a flip is confirmed
    /// only once the pen has retreated `minimumTravel` from it.
    static func reversals(in projections: [CGFloat], minimumTravel: CGFloat) -> Int {
        guard let start = projections.first, projections.count >= 2 else { return 0 }
        var extremum = start
        var direction = 0
        var count = 0

        for value in projections.dropFirst() {
            let delta = value - extremum
            if direction == 0 {
                // No established direction yet: the first significant move sets it.
                if abs(delta) >= minimumTravel {
                    direction = delta > 0 ? 1 : -1
                    extremum = value
                }
            } else if delta * CGFloat(direction) > 0 {
                // Still going the same way — push the extremum out.
                extremum = value
            } else if abs(delta) >= minimumTravel {
                // Retreated far enough from the extremum: a real reversal.
                count += 1
                direction = -direction
                extremum = value
            }
        }
        return count
    }

    /// Shortest distance from `point` to the polyline `path`.
    static func distance(from point: CGPoint, toPolyline path: [CGPoint]) -> CGFloat {
        guard let first = path.first else { return .greatestFiniteMagnitude }
        guard path.count >= 2 else { return hypot(point.x - first.x, point.y - first.y) }
        var best = CGFloat.greatestFiniteMagnitude
        for index in 1..<path.count {
            best = min(best, distance(from: point, toSegment: path[index - 1], path[index]))
            if best == 0 { break }
        }
        return best
    }

    /// Shortest distance from `point` to the line segment `a`–`b`.
    static func distance(from point: CGPoint, toSegment a: CGPoint, _ b: CGPoint) -> CGFloat {
        let dx = b.x - a.x
        let dy = b.y - a.y
        let lengthSquared = dx * dx + dy * dy
        guard lengthSquared > 1e-9 else { return hypot(point.x - a.x, point.y - a.y) }
        // Projection parameter of `point` onto the infinite line, clamped to the segment.
        var t = ((point.x - a.x) * dx + (point.y - a.y) * dy) / lengthSquared
        t = min(max(t, 0), 1)
        return hypot(point.x - (a.x + t * dx), point.y - (a.y + t * dy))
    }
}
