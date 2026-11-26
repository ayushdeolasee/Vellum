import Foundation

/// Reads a classic page's supported annotations in raw /Annots order using
/// the same fallback IDs and UI coordinate system as PdfAnnotationReader.
public enum PdfAnnotationPureReader {
    public static func annotations(on pageNumber: Int, in data: Data, now: String) throws -> [Annotation] {
        let file = try ClassicPdfFile(data: data)
        guard let root = file.rootNumber, let catalog = file.objectSource(root),
              let number = PdfOutlineIncrement.pageObjectNumber(in: file, catalog: catalog, pageNumber: pageNumber),
              let dictionary = file.objectSource(number) else { throw PdfCoreError.invalidDocument("Page does not exist") }
        let geometry = try PageGeometry(pageNumber: pageNumber, in: file)
        let page = try PdfAnnotationPage(index: pageNumber, number: number, dictionary: dictionary, file: file)
        return try page.spans.indices.compactMap { index in
            guard let dict = page.slot(index, file: file)?.dictionary else { return nil }
            func raw(_ key: String) -> [UInt8]? { file.resolvedValue(forKey: key, in: dict) }
            func string(_ key: String) -> String? { raw(key).flatMap(PdfDictSource.decodeTextString) }
            func numbers(_ key: String) -> [Double] {
                guard let array = raw(key), let spans = PdfArraySource.elementSpans(inArray: array) else { return [] }
                var values: [Double] = []
                for span in spans {
                    guard let bytes = file.resolvedValue(Array(array[span])),
                          let value = Double(String(decoding: bytes, as: UTF8.self)), value.isFinite else { return [] }
                    values.append(value)
                }
                return values
            }
            let type: AnnotationType
            switch raw("Subtype").flatMap(PdfDictSource.decodeName) {
            case "Highlight": type = .highlight
            case "FreeText", "Text": type = raw("VellumType").flatMap(PdfDictSource.decodeName) == "Bookmark" ? .bookmark : .note
            default: return nil
            }

            func bounds(_ coords: ArraySlice<Double>) -> AnnotationRect {
                let pairs = stride(from: coords.startIndex, to: coords.endIndex, by: 2)
                let points = pairs.map { geometry.pdfToUi(coords[$0], coords[$0 + 1]) }
                let xs = points.map(\.x), ys = points.map(\.y)
                let left = xs.min()!, top = ys.min()!
                return AnnotationRect(x: left, y: top, width: xs.max()! - left, height: ys.max()! - top)
            }
            var rects: [AnnotationRect] = []
            if type == .highlight {
                let quads = numbers("QuadPoints")
                for i in 0..<(quads.count / 8) { rects.append(bounds(quads[(i * 8)..<(i * 8 + 8)])) }
            }
            if rects.isEmpty {
                let coords = numbers("Rect")
                guard coords.count >= 4 else { return nil }
                var rect = bounds(coords.prefix(4))
                if type != .highlight { rect.width = 0; rect.height = 0 }
                rects = [rect]
            }
            let channels = numbers("C")
            let color = channels.count < 3 ? (type == .highlight ? "#fef08a" : "#fde68a") :
                "#" + channels.prefix(3).map { String(format: "%02x", Int((min(1, max(0, $0)) * 255).rounded())) }.joined()
            let position = PositionData(rects: rects, pageWidth: geometry.displayWidth, pageHeight: geometry.displayHeight,
                                        selectedText: string("VellumSelectedText"))
            let content = string("Contents")
            return Annotation(id: try page.id(dict, at: index), type: type, pageNumber: pageNumber, color: color,
                              content: type == .bookmark && content == "Bookmark" ? nil : content, positionData: position,
                              createdAt: string("VellumCreatedAt") ?? now, updatedAt: string("VellumUpdatedAt") ?? now,
                              isPinned: raw("VellumPinned").flatMap { Int(String(decoding: $0, as: UTF8.self)) } == 1 ? true : nil)
        }
    }
}
