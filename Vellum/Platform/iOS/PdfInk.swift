#if os(iOS)
import PDFKit
import PencilKit
import UIKit

// Apple Pencil ink ⇄ PDF bridge. Ink is stored inside the PDF as native `/Ink`
// annotations (so any reader shows the strokes and they render for free in
// PDFKit), while the full PKDrawing is embedded in a custom `/VellumInk` key so
// the iPad can re-edit losslessly. Coordinates use the page's zoom-1 display
// space (top-left origin) — the same "UI units" the rest of the app uses.
//
// Rotation-0 pages are handled exactly; rotated pages fall back to the same
// mapping (a documented limitation to revisit if rotated scans need ink).
enum PdfInk {
    /// Marks a Vellum-managed ink annotation and carries the base64 PKDrawing.
    static let dataKey = PDFAnnotationKey(rawValue: "VellumInk")

    // MARK: - Write: PKDrawing → native ink annotations on a page

    /// Replace this page's Vellum-managed ink with `drawing`. Returns the new
    /// annotations (already added to the page); pass an empty drawing to clear.
    @discardableResult
    static func apply(_ drawing: PKDrawing, to page: PDFPage) -> [PDFAnnotation] {
        removeVellumInk(from: page)
        let crop = page.bounds(for: .cropBox)
        var made: [PDFAnnotation] = []
        var storedData = false
        for stroke in drawing.strokes {
            // The bitmap eraser masks a stroke rather than deleting it, so fully
            // erased strokes linger in `drawing.strokes` with an empty
            // `renderBounds`. Skip them: don't write them back as native ink (which
            // would make the page read as annotated again and resurrect erased ink
            // in other viewers / on reload).
            guard !stroke.renderBounds.isEmpty else { continue }
            guard let annotation = inkAnnotation(for: stroke, crop: crop) else { continue }
            if !storedData {
                // Stash the whole drawing once per page for lossless re-edit.
                annotation.setValue(
                    drawing.dataRepresentation().base64EncodedString() as NSString,
                    forAnnotationKey: dataKey)
                storedData = true
            } else {
                annotation.setValue("1" as NSString, forAnnotationKey: dataKey)
            }
            page.addAnnotation(annotation)
            made.append(annotation)
        }
        // No strokes but we still want a marker-free page — nothing to add.
        return made
    }

    static func removeVellumInk(from page: PDFPage) {
        for annotation in page.annotations where isVellumInk(annotation) {
            page.removeAnnotation(annotation)
        }
    }

    static func isVellumInk(_ annotation: PDFAnnotation) -> Bool {
        annotation.value(forAnnotationKey: dataKey) != nil
    }

    private static func inkAnnotation(for stroke: PKStroke, crop: CGRect) -> PDFAnnotation? {
        let points = sampledPoints(of: stroke)
        guard points.count >= 1 else { return nil }
        let bounds = CGRect(origin: crop.origin, size: crop.size)
        let annotation = PDFAnnotation(bounds: bounds, forType: .ink, withProperties: nil)

        let path = UIBezierPath()
        // Path points are relative to the annotation's bounds origin.
        func local(_ ui: CGPoint) -> CGPoint {
            CGPoint(x: ui.x, y: crop.height - ui.y)
        }
        path.move(to: local(points[0].location))
        for p in points.dropFirst() { path.addLine(to: local(p.location)) }
        if points.count == 1 {
            // A dot: tiny segment so it renders.
            path.addLine(to: local(CGPoint(x: points[0].location.x + 0.6, y: points[0].location.y)))
        }
        let width = max(1, points.map(\.width).reduce(0, +) / CGFloat(points.count))
        path.lineWidth = width
        path.lineCapStyle = .round
        path.lineJoinStyle = .round
        annotation.add(path)

        let border = PDFBorder()
        border.lineWidth = width
        annotation.border = border
        annotation.color = stroke.ink.color
        // Highlighter (marker) ink is translucent; preserve that via /CA later
        // if needed — PDFKit renders the marker color's own alpha.
        return annotation
    }

    /// Centreline points (in drawing/UI space) with per-point width, read
    /// straight from the stroke's control points.
    private static func sampledPoints(of stroke: PKStroke) -> [(location: CGPoint, width: CGFloat)] {
        var result: [(location: CGPoint, width: CGFloat)] = []
        for point in stroke.path {
            let location = point.location.applying(stroke.transform)
            result.append((location, (point.size.width + point.size.height) / 4))
        }
        return result
    }

    // MARK: - Read: page's embedded PKDrawing

    /// Decode the lossless PKDrawing stored for this page, if any.
    static func drawing(on page: PDFPage) -> PKDrawing? {
        for annotation in page.annotations {
            guard let value = annotation.value(forAnnotationKey: dataKey) as? String,
                  value != "1",
                  let data = Data(base64Encoded: value) else { continue }
            return try? PKDrawing(data: data)
        }
        return nil
    }

    static func hasInk(on page: PDFPage) -> Bool {
        page.annotations.contains { isVellumInk($0) }
    }
}
#endif
