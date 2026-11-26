import Foundation

public enum PdfAnnotationEdit: Sendable {
    case create(CreateAnnotationInput)
    case update(UpdateAnnotationInput)
    case delete(id: String)
}

/// An original and its raw /Annots slots. PDFKit's visible annotation index
/// skips nulls, but the identity assigned by the Apple CGPDF reader counts them.
struct PdfAnnotationPage {
    let index: Int
    let number: Int
    var dictionary: PdfDictSource
    let arrayNumber: Int?
    var array: [UInt8]
    let spans: [Range<Int>]

    init(index: Int, number: Int, dictionary: PdfDictSource, file: ClassicPdfFile) throws {
        self.index = index
        self.number = number
        self.dictionary = dictionary
        arrayNumber = dictionary.reference(forKey: "Annots")
        array = file.resolvedValue(forKey: "Annots", in: dictionary) ?? Array("[]".utf8)
        guard let spans = PdfArraySource.elementSpans(inArray: array) else { throw PdfReadOnlyReason.ambiguousAnnotation }
        self.spans = spans
    }

    func slot(_ index: Int, file: ClassicPdfFile) -> (object: Int?, dictionary: PdfDictSource)? {
        let raw = Array(array[spans[index]])
        guard let resolved = file.resolvedValue(raw), resolved.starts(with: [60, 60]) else { return nil }
        return (PdfDictSource.parseReference(raw), PdfDictSource(resolved))
    }

    func id(_ dictionary: PdfDictSource, at slot: Int) -> String {
        dictionary.textString(forKey: "NM") ?? "pdf-direct-\(index)-\(slot)"
    }

    mutating func saveArray(to increment: inout PdfIncrement) {
        if let arrayNumber {
            increment.setObject(arrayNumber, source: array)
        } else {
            dictionary.setValue(forKey: "Annots", raw: array)
            increment.setObject(number, source: dictionary.sourceBytes)
        }
    }
}

public enum PdfAnnotationIncrement {
    /// The caller supplies the creation ID and UTC timestamp, making the same
    /// edit on the same snapshot reproducible. No file or renderer is opened.
    /// Editing/deleting changes the latest revision only. Previous revisions
    /// retain the original note contents; this operation never erases history.
    public static func applying(_ edit: PdfAnnotationEdit, to original: Data, now: String) throws -> Data {
        if case let .readOnly(reason) = PdfEditEligibility.classify(original) { throw reason }
        let file = try ClassicPdfFile(data: original)
        guard let root = file.rootNumber, let catalog = file.objectSource(root) else { throw PdfReadOnlyReason.malformed }
        var increment = PdfIncrement(file: file)
        let found = try PdfOutlineIncrement.firstPage(in: file, catalog: catalog) { index, number, dictionary in
            if case let .create(input) = edit, index != input.pageNumber { return false }
            var page = try PdfAnnotationPage(index: index, number: number, dictionary: dictionary, file: file)
            switch edit {
            case .create(let input):
                let geometry = try PageGeometry(pageNumber: index, in: file)
                let annotation = try create(input, geometry: geometry, now: now)
                let object = increment.allocateObjectNumber()
                increment.setObject(object, source: annotation.sourceBytes)
                page.array.insert(contentsOf: " \(object) 0 R ".utf8, at: page.array.count - 1)
                page.saveArray(to: &increment)
                return true
            case .update(let input):
                return try editSlot(id: input.id, update: input, page: &page, file: file, now: now, increment: &increment)
            case .delete(let id):
                return try editSlot(id: id, update: nil, page: &page, file: file, now: now, increment: &increment)
            }
        }
        guard found != nil else { throw PdfCoreError.invalidDocument("Annotation or page does not exist") }
        let output = increment.appended()
        // New caller-supplied IDs, object numbers and revision size must also
        // meet the same proof before a session may commit these bytes.
        try PdfEditEligibility.validateOutput(output)
        return output
    }

    private static func create(_ input: CreateAnnotationInput, geometry: PageGeometry, now: String) throws -> PdfDictSource {
        guard let id = input.id, input.type != .bookmark else {
            throw PdfCoreError.invalidDocument("A highlight or note with a creation ID is required")
        }
        let highlight = input.type == .highlight
        var dict = PdfDictSource(Array((highlight
            ? "<< /Type /Annot /Subtype /Highlight /CA 0.4 /F 4 /T (Vellum) >>"
            : "<< /Type /Annot /Subtype /Text /Name /Note /F 4 /T (Vellum) >>").utf8))
        dict.setTextString(forKey: "NM", to: id)
        dict.setTextString(forKey: "M", to: try modificationDate(now))
        dict.setTextString(forKey: "VellumCreatedAt", to: input.createdAt ?? now)
        dict.setTextString(forKey: "VellumUpdatedAt", to: input.createdAt ?? now)
        if let content = input.content { dict.setTextString(forKey: "Contents", to: content) }
        setColor(input.color ?? (highlight ? "#fef08a" : "#fde68a"), in: &dict)
        let position = input.positionData ?? PositionData(rects: [.init(x: 0, y: 0, width: 0, height: 0)],
            pageWidth: geometry.displayWidth, pageHeight: geometry.displayHeight)
        try setPosition(position, highlight: highlight, geometry: geometry, in: &dict)
        return dict
    }

    private static func editSlot(id: String, update: UpdateAnnotationInput?, page: inout PdfAnnotationPage,
                                 file: ClassicPdfFile, now: String, increment: inout PdfIncrement) throws -> Bool {
        for index in page.spans.indices {
            guard let slot = page.slot(index, file: file), page.id(slot.dictionary, at: index) == id else { continue }
            var dict = slot.dictionary
            let subtype = dict.name(forKey: "Subtype")
            let vellumType = file.resolvedValue(forKey: "VellumType", in: dict)
            guard ["Highlight", "Text", "FreeText"].contains(subtype), !dict.hasKey("VellumInk"),
                  vellumType.flatMap(PdfDictSource.decodeName) != "Bookmark"
            else { throw PdfCoreError.invalidDocument("Unsupported annotation") }

            if let update {
                dict.setTextString(forKey: "NM", to: id)
                dict.setTextString(forKey: "M", to: try modificationDate(now))
                dict.setTextString(forKey: "VellumUpdatedAt", to: now)
                if let color = update.color { setColor(color, in: &dict) }
                if let content = update.content {
                    dict.setTextString(forKey: "Contents", to: content)
                    // PDF viewers may prefer rich text over /Contents.
                    if subtype == "FreeText" || subtype == "Text" { dict.removeEntry(forKey: "RC") }
                }
                if let pinned = update.isPinned { dict.setInteger(forKey: "VellumPinned", to: pinned ? 1 : 0) }
                if let position = update.positionData {
                    let geometry = try PageGeometry(pageNumber: page.index, in: file)
                    try setPosition(position, highlight: subtype == "Highlight", geometry: geometry, in: &dict)
                }
                // A cached appearance paints the old location/color/text.
                if update.color != nil || update.positionData != nil || (subtype == "FreeText" && update.content != nil) {
                    dict.removeEntry(forKey: "AP")
                }
                if let object = slot.object {
                    increment.setObject(object, source: dict.sourceBytes)
                    return true
                }
                page.array.replaceSubrange(page.spans[index], with: dict.sourceBytes)
            } else {
                // Keep the slot if splicing it out would change the identity of
                // a subsequent unnamed annotation (including an ink carrier).
                let needsSlot = page.spans.indices.dropFirst(index + 1).contains { next in
                    guard let later = page.slot(next, file: file) else { return false }
                    return !later.dictionary.hasKey("NM")
                }
                page.array.replaceSubrange(page.spans[index], with: Array((needsSlot ? " null " : " ").utf8))
            }
            page.saveArray(to: &increment)
            return true
        }
        return false
    }

    private static func modificationDate(_ now: String) throws -> String {
        let parser = ISO8601DateFormatter()
        parser.formatOptions.insert(.withFractionalSeconds)
        var date = parser.date(from: now)
        if date == nil {
            parser.formatOptions.remove(.withFractionalSeconds)
            date = parser.date(from: now)
        }
        guard let date else { throw PdfCoreError.invalidDocument("Invalid annotation timestamp") }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "'D:'yyyyMMddHHmmss'Z'"
        return formatter.string(from: date)
    }

    private static func numbers(_ values: [Double]) -> [UInt8] {
        let items = values.map { value -> String in
            let decimal = String(value)
            // Swift's shortest round-trip decimal may use an exponent. PDF
            // number tokens cannot, so expand those values at Double precision.
            guard let e = decimal.firstIndex(of: "e"), let exponent = Int(decimal[decimal.index(after: e)...]) else { return decimal }
            return String(format: "%.*f", CInt(max(1, 17 - exponent)), value)
        }
        return Array(("[ " + items.joined(separator: " ") + " ]").utf8)
    }

    private static func setColor(_ color: String, in dict: inout PdfDictSource) {
        let hex = color.hasPrefix("#") ? color.dropFirst() : color[...]
        let rgb = hex.count == 6 ? UInt32(hex, radix: 16) ?? 0xfef08a : 0xfef08a
        dict.setValue(forKey: "C", raw: numbers([16, 8, 0].map { Double((rgb >> $0) & 255) / 255 }))
    }

    private static func setPosition(_ position: PositionData, highlight: Bool,
                                    geometry: PageGeometry, in dict: inout PdfDictSource) throws {
        guard let anchor = position.rects.first, position.pageWidth.isFinite, position.pageWidth > 0,
              position.pageHeight.isFinite, position.pageHeight > 0 else {
            throw PdfCoreError.invalidDocument("Invalid annotation position")
        }
        let rects = highlight ? position.rects : [.init(x: anchor.x, y: anchor.y, width: 18, height: 18)]
        var left = Double.infinity, bottom = Double.infinity
        var right = -Double.infinity, top = -Double.infinity
        var quads: [Double] = []
        for rect in rects {
            guard rect.width >= 0, rect.height >= 0 else { throw PdfCoreError.invalidDocument("Negative annotation extent") }
            for y in [rect.y, rect.y + rect.height] {
                for x in [rect.x, rect.x + rect.width] {
                    let point = geometry.uiToPdf(x, y, pageWidth: position.pageWidth, pageHeight: position.pageHeight)
                    guard point.x.isFinite, point.y.isFinite else { throw PdfCoreError.invalidDocument("Non-finite annotation position") }
                    left = min(left, point.x)
                    right = max(right, point.x)
                    bottom = min(bottom, point.y)
                    top = max(top, point.y)
                    if highlight { quads.append(contentsOf: [point.x, point.y]) }
                }
            }
        }
        dict.setValue(forKey: "Rect", raw: numbers([left, bottom, right, top]))
        if highlight { dict.setValue(forKey: "QuadPoints", raw: numbers(quads)) }
        if let text = position.selectedText { dict.setTextString(forKey: "VellumSelectedText", to: text) }
    }
}
