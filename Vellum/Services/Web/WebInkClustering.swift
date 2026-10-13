import CoreGraphics
import PencilKit

// Spatial clustering of web-ink strokes (WEB-INK-PLAN decision 8, Phase 3).
// The live canvas holds ONE PKDrawing for the whole document; at save time its
// strokes are grouped into proximity clusters so each cluster can carry its
// own text anchor and be translated independently when the page reflows.
// Clusters are derived data — nothing here mutates the live drawing.

enum WebInkClustering {
    /// Horizontal gaps can be fairly wide inside one handwritten word, arrow,
    /// or margin note, so keep the original generous threshold on that axis.
    static let defaultHorizontalProximity: CGFloat = 48
    /// Vertical gaps must be much tighter. A symmetric 48-point threshold
    /// transitively merged separate underlines on adjacent text rows into one
    /// tall cluster. Toolbar page zoom reflows those rows by different amounts,
    /// but one cluster has only one text anchor and can only translate rigidly,
    /// so some of its strokes inevitably drifted. Line-sized clusters let each
    /// annotated row follow its own anchor.
    static let defaultVerticalProximity: CGFloat = 16

    /// One spatial group of strokes, in document space (zoom-1 CSS px).
    struct Cluster {
        /// The cluster's strokes, still in document coordinates.
        var drawing: PKDrawing
        /// `drawing.bounds` — the union of the strokes' render bounds.
        var bounds: CGRect
    }

    /// Group a document-space drawing into proximity clusters.
    ///
    /// Deterministic: the same drawing always yields the same clusters —
    /// membership comes from a union-find over stroke bounds (order-
    /// independent by transitivity), strokes keep their original z-order
    /// within a cluster, and clusters are sorted by document position
    /// (minY, then minX).
    static func clusters(
        of drawing: PKDrawing,
        horizontalProximity: CGFloat = defaultHorizontalProximity,
        verticalProximity: CGFloat = defaultVerticalProximity
    ) -> [Cluster] {
        let strokes = drawing.strokes
        guard !strokes.isEmpty else { return [] }

        // Strokes whose bounds, each grown by half the per-axis threshold,
        // intersect are close enough to share one text anchor.
        let grown = strokes.map {
            $0.renderBounds.insetBy(
                dx: -horizontalProximity / 2,
                dy: -verticalProximity / 2)
        }

        var parent = Array(0..<strokes.count)
        func find(_ i: Int) -> Int {
            var root = i
            while parent[root] != root { root = parent[root] }
            var node = i
            while parent[node] != root {
                let next = parent[node]
                parent[node] = root
                node = next
            }
            return root
        }
        func union(_ i: Int, _ j: Int) {
            let ri = find(i)
            let rj = find(j)
            if ri != rj { parent[max(ri, rj)] = min(ri, rj) }
        }

        for i in 0..<strokes.count {
            for j in (i + 1)..<strokes.count where grown[i].intersects(grown[j]) {
                union(i, j)
            }
        }

        // Group stroke indexes by root, preserving original stroke order.
        var groups: [Int: [Int]] = [:]
        for i in 0..<strokes.count {
            groups[find(i), default: []].append(i)
        }

        let built = groups.values.map { indexes -> Cluster in
            let clusterDrawing = PKDrawing(strokes: indexes.map { strokes[$0] })
            return Cluster(drawing: clusterDrawing, bounds: clusterDrawing.bounds)
        }
        return built.sorted {
            ($0.bounds.minY, $0.bounds.minX) < ($1.bounds.minY, $1.bounds.minX)
        }
    }

    /// Rebuild the single live drawing from clusters, translating each by its
    /// re-anchor delta (nil = anchor unresolved or cluster unanchored → stays
    /// at its stored coordinates). `deltas` aligns with `clusters`. Returns
    /// whether any cluster actually moved (sub-half-pixel deltas are noise
    /// from rect measurement, not reflow).
    /// Re-anchor deltas at or below half a pixel are rect-measurement noise,
    /// not reflow. Shared with the anchor-cache refresh so a skipped delta is
    /// also not absorbed into the cached rect.
    static func exceedsTranslationThreshold(_ delta: CGVector) -> Bool {
        abs(delta.dx) > 0.5 || abs(delta.dy) > 0.5
    }

    static func translated(
        _ clusters: [Cluster],
        by deltas: [CGVector?]
    ) -> (drawing: PKDrawing, moved: Bool) {
        var out = PKDrawing()
        var moved = false
        for (i, cluster) in clusters.enumerated() {
            var drawing = cluster.drawing
            if let delta = deltas[i], exceedsTranslationThreshold(delta) {
                drawing = drawing.transformed(
                    using: CGAffineTransform(translationX: delta.dx, y: delta.dy))
                moved = true
            }
            out = out.appending(drawing)
        }
        return (out, moved)
    }
}
