#if os(iOS)
import PDFKit
import PencilKit
import UIKit
import VellumCore

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

    static let strokesKey = PDFAnnotationKey(rawValue: "VellumInkStrokes")

    static func hasPortableInk(on page: PDFPage) -> Bool {
        page.annotations.contains { $0.type == "Ink" && $0.value(forAnnotationKey: strokesKey) != nil }
    }

    // MARK: - Write: PKDrawing → native ink annotations on a page

    /// Replace this page's Vellum-managed ink with `drawing`. Returns the new
    /// annotations (already added to the page); pass an empty drawing to clear.
    @discardableResult
    static func apply(_ drawing: PKDrawing, to page: PDFPage) -> [PDFAnnotation] {
        guard !hasPortableInk(on: page) else { return [] }
        removeVellumInk(from: page)
        let crop = page.bounds(for: .cropBox)
        var made: [PDFAnnotation] = []
        var storedData = false
        for stroke in drawing.strokes {
            // The bitmap eraser masks a stroke rather than deleting it, so fully
            // erased strokes linger in `drawing.strokes`. Skip them: don't write
            // them back as native ink (which would make the page read as annotated
            // again and resurrect erased ink in other viewers / on reload).
            guard strokeHasVisibleInk(stroke) else { continue }
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
        for annotation in overlayInk(on: page).represented {
            page.removeAnnotation(annotation)
        }
    }

    static func isVellumInk(_ annotation: PDFAnnotation) -> Bool {
        annotation.type == "Ink" && (annotation.value(forAnnotationKey: dataKey) != nil
            || annotation.value(forAnnotationKey: strokesKey) != nil)
    }

    private static func inkAnnotation(for stroke: PKStroke, crop: CGRect) -> PDFAnnotation? {
        let points = sampledPoints(of: stroke)
        guard points.count >= 1 else { return nil }
        let bounds = CGRect(origin: crop.origin, size: crop.size)
        let annotation = PDFAnnotation(bounds: bounds, forType: .ink, withProperties: nil)

        let path = nativePath(points, crop: crop)
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

    private static func nativePath(_ points: [(location: CGPoint, width: CGFloat)], crop: CGRect) -> UIBezierPath {
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
        return path
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

    struct OverlayInk {
        var drawing: PKDrawing
        var represented: [PDFAnnotation]
    }

    /// A carrier describes its own payload. A legacy drawing takes precedence
    /// over its portable sibling, but independent carriers still contribute.
    static func overlayInk(on page: PDFPage) -> OverlayInk {
        var strokes: [PKStroke] = []
        var represented: [PDFAnnotation] = []
        var markers: [PDFAnnotation] = []
        var seen: [String: [PortableStroke]] = [:]
        for annotation in page.annotations where isVellumInk(annotation) {
            let native = annotation.value(forAnnotationKey: dataKey) as? String
            let wire = annotation.value(forAnnotationKey: strokesKey) as? String
            let members: [PKStroke]
            let ids: [String]?
            if let native, native != "1", let data = Data(base64Encoded: native),
               let drawing = try? PKDrawing(data: data), !drawing.strokes.isEmpty {
                members = drawing.strokes
                ids = nil
            } else if let wire, wire != "1", let records = try? PortableStroke.decodePDFPayload(wire),
                      let drawing = try? PKDrawing(portableStrokes: records) {
                members = drawing.strokes
                ids = records.map(\.id)
            } else {
                if [native, wire].compactMap({ $0 }).allSatisfy({ $0 == "1" }),
                   native == "1" || wire == "1" { markers.append(annotation) }
                continue
            }
            represented.append(annotation)
            // Compare full rendering signatures across carriers only. Repeated
            // strokes within a single drawing retain their original z-order.
            var signatures: [(String, PortableStroke)] = []
            for (index, stroke) in members.enumerated() {
                if let signature = try? PortableStroke(stroke) {
                    let key = ids?[index] ?? signature.id
                    if seen[key]?.contains(signature) == true { continue }
                    signatures.append((key, signature))
                }
                strokes.append(stroke)
            }
            for (key, signature) in signatures { seen[key, default: []].append(signature) }
        }
        // A "1" marker carries no drawing. Only suppress it when an actual
        // reconstructed stroke describes its native /InkList geometry.
        if !markers.isEmpty {
            let crop = page.bounds(for: .cropBox)
            let paths = strokes.filter(strokeHasVisibleInk).compactMap { stroke -> CGPath? in
                let points = sampledPoints(of: stroke)
                return points.isEmpty ? nil : nativePath(points, crop: crop).cgPath
            }
            represented += markers.filter { annotation in
                guard annotation.bounds == crop, let lines = annotation.paths, lines.count == 1 else { return false }
                return paths.contains { $0 == lines[0].cgPath }
            }
        }
        return OverlayInk(drawing: PKDrawing(strokes: strokes), represented: represented)
    }

    static func drawing(on page: PDFPage) -> PKDrawing? {
        let drawing = overlayInk(on: page).drawing
        return drawing.strokes.isEmpty ? nil : drawing
    }

    static func hasInk(on page: PDFPage) -> Bool {
        page.annotations.contains { isVellumInk($0) }
    }

    /// Whether any part of the stroke still renders. `maskedPathRanges` is the
    /// only reliable signal: a fully bitmap-erased stroke keeps a mask that
    /// excludes the whole path, but its `renderBounds` still reports the mask's
    /// bounds (never empty) — so a `renderBounds.isEmpty` check reads a fully
    /// erased stroke as visible. An unmasked (or empty-mask) stroke reports the
    /// full path range here, matching how PencilKit actually renders it.
    static func strokeHasVisibleInk(_ stroke: PKStroke) -> Bool {
        !stroke.maskedPathRanges.isEmpty
    }
}
#endif
