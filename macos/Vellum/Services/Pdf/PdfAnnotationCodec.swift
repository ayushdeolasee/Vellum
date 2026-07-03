import Foundation
import PDFKit
import AppKit

// Annotation dictionary codec — port of the read/write halves of
// src-tauri/src/pdf_annotations.rs (create_dictionary, apply_position,
// dictionary_to_annotation, read_position, read_color, color_array,
// pdf_date_now, timestamps).
//
// Reads go through CGPDF (exact raw values); writes go through PDFAnnotation
// with setValue(_:forAnnotationKey:) for custom keys. Two values PDFKit cannot
// write (/CA real, /Name name-object) are produced via same-length byte
// patches on the serialized data (see PdfBytePatch).

enum PdfAnnotationDefaults {
    static let highlightColor = "#fef08a"
    static let noteColor = "#fde68a"
    /// Sticky-note anchor square, UI units (NOTE_SIZE).
    static let noteSize = 18.0
}

// MARK: - Timestamps

enum PdfDates {
    /// RFC3339 UTC with microseconds and +00:00 offset, matching chrono's
    /// `Utc::now().to_rfc3339()` closely enough for the string-compare sort
    /// contract (ASCII, fixed offset, chronological ordering).
    static func rfc3339Now() -> String {
        formatter(dateFormat: "yyyy-MM-dd'T'HH:mm:ss.SSSSSS'+00:00'").string(from: Date())
    }

    /// `D:YYYYMMDDHHMMSSZ` (UTC), the /M modification date format.
    static func pdfDateNow() -> String {
        "D:" + formatter(dateFormat: "yyyyMMddHHmmss'Z'").string(from: Date())
    }

    private static func formatter(dateFormat: String) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = dateFormat
        return formatter
    }
}

// MARK: - Colors

enum PdfColor {
    /// "#rrggbb" → channels; nil when unparsable (mirrors parse_hex_color).
    static func parseHex(_ color: String) -> (red: UInt8, green: UInt8, blue: UInt8)? {
        let hex = color.hasPrefix("#") ? String(color.dropFirst()) : color
        guard hex.count == 6 else { return nil }
        let chars = Array(hex)
        guard let red = UInt8(String(chars[0...1]), radix: 16),
              let green = UInt8(String(chars[2...3]), radix: 16),
              let blue = UInt8(String(chars[4...5]), radix: 16)
        else { return nil }
        return (red, green, blue)
    }

    /// NSColor whose /C serialization is channel/255.0 (fallback rgb(254,240,138),
    /// mirroring color_array's unparsable-color fallback).
    static func annotationColor(fromHex color: String) -> NSColor {
        let (red, green, blue) = parseHex(color) ?? (254, 240, 138)
        return NSColor(
            deviceRed: CGFloat(red) / 255.0,
            green: CGFloat(green) / 255.0,
            blue: CGFloat(blue) / 255.0,
            alpha: 1.0)
    }

    /// /C array → "#rrggbb" via round(clamp(c,0,1)*255) (mirrors read_color).
    static func readHex(from dictionary: CGPDFDictionaryRef) -> String? {
        guard let values = CgPdf.array(dictionary, "C"), CgPdf.count(values) >= 3 else { return nil }
        var channels: [Double] = []
        for index in 0..<3 {
            guard let object = CgPdf.objectAt(values, index), let value = CgPdf.objectNumber(object) else {
                return nil
            }
            channels.append(value)
        }
        let components = channels.map { UInt8((min(max($0, 0.0), 1.0) * 255.0).rounded()) }
        return String(format: "#%02x%02x%02x", components[0], components[1], components[2])
    }

    static func defaultHex(for type: AnnotationType) -> String {
        type == .highlight ? PdfAnnotationDefaults.highlightColor : PdfAnnotationDefaults.noteColor
    }
}

// MARK: - Reading embedded annotations

enum PdfAnnotationReader {
    /// All supported annotations on one page, in /Annots order — mirror of the
    /// per-page loop in get_annotations (annotation_entries + dictionary_to_annotation).
    static func annotations(
        onPage pageDictionary: CGPDFDictionaryRef,
        pageNumber: Int,
        geometry: PageGeometry
    ) -> [Annotation] {
        guard let entries = CgPdf.array(pageDictionary, "Annots") else { return [] }
        var annotations: [Annotation] = []
        for index in 0..<CgPdf.count(entries) {
            guard let dictionary = CgPdf.dictionaryAt(entries, index) else { continue }
            if let annotation = annotation(
                from: dictionary, pageNumber: pageNumber, index: index, geometry: geometry)
            {
                annotations.append(annotation)
            }
        }
        return annotations
    }

    /// Stable id: decoded /NM, else a derived id. The Rust code derives
    /// `pdf-{obj}-{gen}` for referenced entries; CGPDF hides object numbers, so
    /// this port derives `pdf-direct-{page}-{index}` for every /NM-less entry
    /// (stable across reads of the same file; stamped into /NM on first update).
    static func annotationId(dictionary: CGPDFDictionaryRef, pageNumber: Int, index: Int) -> String {
        CgPdf.string(dictionary, "NM") ?? "pdf-direct-\(pageNumber)-\(index)"
    }

    /// dictionary_to_annotation: /Highlight → highlight; /Text | /FreeText →
    /// note (bookmark when /VellumType /Bookmark); anything else ignored.
    static func annotation(
        from dictionary: CGPDFDictionaryRef,
        pageNumber: Int,
        index: Int,
        geometry: PageGeometry
    ) -> Annotation? {
        guard let subtype = CgPdf.name(dictionary, "Subtype") else { return nil }
        let type: AnnotationType
        switch subtype {
        case "Highlight":
            type = .highlight
        case "Text", "FreeText":
            type = CgPdf.name(dictionary, "VellumType") == "Bookmark" ? .bookmark : .note
        default:
            return nil
        }

        let id = annotationId(dictionary: dictionary, pageNumber: pageNumber, index: index)
        let color = PdfColor.readHex(from: dictionary) ?? PdfColor.defaultHex(for: type)
        let content = CgPdf.string(dictionary, "Contents")
            .flatMap { type == .bookmark && $0 == "Bookmark" ? nil : $0 }
        let selectedText = CgPdf.string(dictionary, "VellumSelectedText")
        guard let position = readPosition(
            dictionary: dictionary, type: type, geometry: geometry, selectedText: selectedText)
        else { return nil }

        let now = PdfDates.rfc3339Now()
        let createdAt = CgPdf.string(dictionary, "VellumCreatedAt") ?? now
        let updatedAt = CgPdf.string(dictionary, "VellumUpdatedAt") ?? now

        return Annotation(
            id: id,
            type: type,
            pageNumber: pageNumber,
            color: color,
            content: content,
            positionData: position,
            createdAt: createdAt,
            updatedAt: updatedAt)
    }

    /// read_position: highlights from /QuadPoints (one UI rect per quad,
    /// falling back to /Rect); notes/bookmarks as a zero-size point at the
    /// /Rect's top-left UI corner.
    static func readPosition(
        dictionary: CGPDFDictionaryRef,
        type: AnnotationType,
        geometry: PageGeometry,
        selectedText: String?
    ) -> PositionData? {
        let rects: [AnnotationRect]
        if type == .highlight {
            var quadRects: [AnnotationRect] = []
            if let quadPoints = CgPdf.array(dictionary, "QuadPoints") {
                let quadCount = CgPdf.count(quadPoints) / 8
                for quad in 0..<quadCount {
                    var points: [(Double, Double)] = []
                    for pair in 0..<4 {
                        let base = quad * 8 + pair * 2
                        guard let xObject = CgPdf.objectAt(quadPoints, base),
                              let yObject = CgPdf.objectAt(quadPoints, base + 1),
                              let x = CgPdf.objectNumber(xObject),
                              let y = CgPdf.objectNumber(yObject)
                        else { continue }
                        points.append(geometry.pdfToUi(x, y))
                    }
                    if let rect = uiBoundingRect(points) {
                        quadRects.append(rect)
                    }
                }
            }
            if !quadRects.isEmpty {
                rects = quadRects
            } else if let points = readPdfRect(dictionary),
                      let rect = uiBoundingRect(points.map { geometry.pdfToUi($0.0, $0.1) })
            {
                rects = [rect]
            } else {
                return nil
            }
        } else {
            guard let points = readPdfRect(dictionary),
                  let rect = uiBoundingRect(points.map { geometry.pdfToUi($0.0, $0.1) })
            else { return nil }
            rects = [AnnotationRect(x: rect.x, y: rect.y, width: 0.0, height: 0.0)]
        }

        return PositionData(
            rects: rects,
            pageWidth: geometry.displayWidth,
            pageHeight: geometry.displayHeight,
            selectedText: selectedText,
            startOffset: nil,
            endOffset: nil,
            prefix: nil,
            suffix: nil,
            viewportOffset: nil)
    }

    /// /Rect → the two corner points (mirrors read_pdf_rect).
    static func readPdfRect(_ dictionary: CGPDFDictionaryRef) -> [(Double, Double)]? {
        guard let values = CgPdf.array(dictionary, "Rect"), CgPdf.count(values) >= 4 else { return nil }
        var numbers: [Double] = []
        for index in 0..<4 {
            guard let object = CgPdf.objectAt(values, index), let value = CgPdf.objectNumber(object) else {
                return nil
            }
            numbers.append(value)
        }
        return [(numbers[0], numbers[1]), (numbers[2], numbers[3])]
    }

    static func uiBoundingRect(_ points: [(Double, Double)]) -> AnnotationRect? {
        guard let first = points.first else { return nil }
        var minX = first.0, minY = first.1, maxX = first.0, maxY = first.1
        for (x, y) in points.dropFirst() {
            minX = min(minX, x)
            minY = min(minY, y)
            maxX = max(maxX, x)
            maxY = max(maxY, y)
        }
        return AnnotationRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }
}

// MARK: - Writing annotations

enum PdfAnnotationWriter {
    static let nmKey = PDFAnnotationKey(rawValue: "NM")

    /// Build the PDFAnnotation for create_annotation (highlight/note only —
    /// bookmarks divert to outlines before reaching this). Returns the
    /// annotation plus the echoed position/color/content for the response,
    /// and the byte patches the serialized data needs.
    static func makeAnnotation(
        input: CreateAnnotationInput,
        geometry: PageGeometry,
        id: String,
        now: String
    ) throws -> (annotation: PDFAnnotation, position: PositionData, color: String?, content: String?, patches: [PdfBytePatch]) {
        let position = input.positionData ?? defaultPosition(input: input, geometry: geometry)
        let color = input.color ?? PdfColor.defaultHex(for: input.type)

        let subtype: PDFAnnotationSubtype = input.type == .highlight ? .highlight : .text
        let annotation = PDFAnnotation(bounds: .zero, forType: subtype, withProperties: nil)
        setText(annotation, "NM", id)
        setText(annotation, "M", PdfDates.pdfDateNow())
        setValue(annotation, "F", 4 as NSNumber)
        setText(annotation, "T", "Vellum")
        setText(annotation, "VellumCreatedAt", now)
        setText(annotation, "VellumUpdatedAt", now)
        annotation.color = PdfColor.annotationColor(fromHex: color)

        var patches: [PdfBytePatch] = []
        switch input.type {
        case .highlight:
            // /CA 0.4 — placeholder rewritten by PdfBytePatch.highlightOpacity.
            setValue(annotation, "VellumOpacityPlaceholder", 4 as NSNumber)
            patches.append(.highlightOpacity)
        default:
            // /Name /Note — string placeholder rewritten into a name object.
            setText(annotation, "Name", "Note")
            patches.append(.noteIconName)
        }

        if let content = input.content {
            annotation.contents = content
        }
        if let selectedText = position.selectedText {
            setText(annotation, "VellumSelectedText", selectedText)
        }
        try applyPosition(annotation, geometry: geometry, position: position, isHighlight: input.type == .highlight)

        return (annotation, position, color, input.content, patches)
    }

    /// default_position: zero-size anchor at the origin (bookmarks would anchor
    /// at display_width − 18, kept for parity even though bookmarks never
    /// reach annotation creation).
    static func defaultPosition(input: CreateAnnotationInput, geometry: PageGeometry) -> PositionData {
        let x = input.type == .bookmark ? max(geometry.displayWidth - PdfAnnotationDefaults.noteSize, 0.0) : 0.0
        return PositionData(
            rects: [AnnotationRect(x: x, y: 0.0, width: 0.0, height: 0.0)],
            pageWidth: geometry.displayWidth,
            pageHeight: geometry.displayHeight,
            selectedText: nil,
            startOffset: nil,
            endOffset: nil,
            prefix: nil,
            suffix: nil,
            viewportOffset: nil)
    }

    /// apply_position: highlights get /QuadPoints (TL, TR, BL, BR per rect)
    /// plus a /Rect bounding all quad points; notes get an 18×18 UI-unit /Rect
    /// anchored at rects[0].
    ///
    /// PDFKit's quadrilateralPoints are RELATIVE to the annotation bounds, so
    /// bounds are set first and the corners are offset by the bounds origin.
    static func applyPosition(
        _ annotation: PDFAnnotation,
        geometry: PageGeometry,
        position: PositionData,
        isHighlight: Bool
    ) throws {
        if isHighlight {
            guard !position.rects.isEmpty else {
                throw SessionServiceError.invalidDocument("Highlight has no rectangles")
            }
            var quads: [(Double, Double)] = []
            for rect in position.rects {
                let topLeft = geometry.uiToPdf(
                    rect.x, rect.y,
                    pageWidth: position.pageWidth, pageHeight: position.pageHeight)
                let topRight = geometry.uiToPdf(
                    rect.x + rect.width, rect.y,
                    pageWidth: position.pageWidth, pageHeight: position.pageHeight)
                let bottomLeft = geometry.uiToPdf(
                    rect.x, rect.y + rect.height,
                    pageWidth: position.pageWidth, pageHeight: position.pageHeight)
                let bottomRight = geometry.uiToPdf(
                    rect.x + rect.width, rect.y + rect.height,
                    pageWidth: position.pageWidth, pageHeight: position.pageHeight)
                quads.append(contentsOf: [topLeft, topRight, bottomLeft, bottomRight])
            }
            let bounds = boundingBox(of: quads)
            annotation.bounds = bounds
            annotation.quadrilateralPoints = quads.map {
                NSValue(point: NSPoint(x: $0.0 - bounds.origin.x, y: $0.1 - bounds.origin.y))
            }
        } else {
            guard let anchor = position.rects.first else {
                throw SessionServiceError.invalidDocument("Note has no position")
            }
            let topLeft = geometry.uiToPdf(
                anchor.x, anchor.y,
                pageWidth: position.pageWidth, pageHeight: position.pageHeight)
            let bottomRight = geometry.uiToPdf(
                anchor.x + PdfAnnotationDefaults.noteSize, anchor.y + PdfAnnotationDefaults.noteSize,
                pageWidth: position.pageWidth, pageHeight: position.pageHeight)
            annotation.bounds = boundingBox(of: [topLeft, bottomRight])
        }
    }

    static func boundingBox(of points: [(Double, Double)]) -> CGRect {
        guard let first = points.first else { return .zero }
        var minX = first.0, minY = first.1, maxX = first.0, maxY = first.1
        for (x, y) in points.dropFirst() {
            minX = min(minX, x)
            minY = min(minY, y)
            maxX = max(maxX, x)
            maxY = max(maxY, y)
        }
        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }

    static func setText(_ annotation: PDFAnnotation, _ key: String, _ value: String) {
        _ = annotation.setValue(value as NSString, forAnnotationKey: PDFAnnotationKey(rawValue: key))
    }

    static func setValue(_ annotation: PDFAnnotation, _ key: String, _ value: NSNumber) {
        _ = annotation.setValue(value, forAnnotationKey: PDFAnnotationKey(rawValue: key))
    }
}
