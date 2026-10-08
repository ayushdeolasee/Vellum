#if os(macOS)
import AppKit
import PencilKit

/// Read-only presentation of the shared ink sidecar. Neither reflow nor Mac
/// annotation edits write a drawing or recapture its original text anchors.
enum WebSavedInkRenderer {
    private struct Cluster: Encodable {
        let bounds: WebInkRecord.Bounds
        let anchor: WebInkRecord.Anchor?
        let image: String
    }

    private struct Payload: Encodable {
        let url: String
        let clusters: [Cluster]
    }

    /// Blocking file access and PencilKit rasterization; call off the main actor.
    static func load(url: String, pageURL: String) -> String? {
        guard !Task.isCancelled,
              let record = WebInkStore.loadRecord(forKey: WebLibrary.pageKey(url)),
              (1...WebInkRecord.currentVersion).contains(record.version),
              (try? WebUrl.normalize(record.url)) == url else { return nil }
        var clusters: [Cluster] = []
        for cluster in record.clusters {
            guard !Task.isCancelled else { return nil }
            let bounds = cluster.bounds
            guard bounds.x.isFinite, bounds.y.isFinite,
                  bounds.w.isFinite, bounds.h.isFinite,
                  bounds.w > 0, bounds.h > 0,
                  let drawing = try? PKDrawing(data: cluster.drawing),
                  !drawing.strokes.isEmpty else { continue }
            // Bound each raster's memory, including unusually large freehand
            // clusters. CSS geometry stays in the original zoom-1 coordinates.
            let scale = min(2, 8192 / max(bounds.w, bounds.h),
                            sqrt(16_000_000 / bounds.w / bounds.h))
            guard scale.isFinite, scale > 0 else { continue }
            let image = drawing.image(
                from: CGRect(x: 0, y: 0, width: bounds.w, height: bounds.h),
                scale: CGFloat(scale))
            guard let tiff = image.tiffRepresentation,
                  let bitmap = NSBitmapImageRep(data: tiff),
                  let png = bitmap.representation(using: .png, properties: [:]) else { continue }
            clusters.append(Cluster(
                bounds: bounds, anchor: cluster.anchor,
                image: "data:image/png;base64," + png.base64EncodedString()))
        }
        guard !Task.isCancelled,
              let data = try? JSONEncoder().encode(Payload(url: pageURL, clusters: clusters))
        else { return nil }
        return String(data: data, encoding: .utf8)
    }
}
#endif
