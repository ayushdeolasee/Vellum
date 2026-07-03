import Foundation
import CoreGraphics

// Page geometry + raw CGPDF read helpers — port of the coordinate machinery in
// src-tauri/src/pdf_annotations.rs (PageGeometry, page_geometry, inherited_object,
// object_f64/object_i64 and friends).
//
// All reads go through CoreGraphics' CGPDF object model because PDFKit does not
// expose inherited page attributes (/UserUnit at all, /Rotate only normalized)
// nor raw dictionary values for custom keys. CGPDF resolves indirect references
// transparently, matching the Rust code's `dereference` calls.

/// Raw CGPDF value accessors. Every function mirrors a lopdf accessor used by
/// pdf_annotations.rs; references are auto-resolved by CoreGraphics.
enum CgPdf {
    static func object(_ dictionary: CGPDFDictionaryRef, _ key: String) -> CGPDFObjectRef? {
        var value: CGPDFObjectRef?
        guard CGPDFDictionaryGetObject(dictionary, key, &value) else { return nil }
        return value
    }

    static func has(_ dictionary: CGPDFDictionaryRef, _ key: String) -> Bool {
        object(dictionary, key) != nil
    }

    /// Decoded PDF text string (PDFDocEncoding or UTF-16BE, like decode_text_string).
    static func string(_ dictionary: CGPDFDictionaryRef, _ key: String) -> String? {
        var value: CGPDFStringRef?
        guard CGPDFDictionaryGetString(dictionary, key, &value), let value else { return nil }
        return CGPDFStringCopyTextString(value) as String?
    }

    static func name(_ dictionary: CGPDFDictionaryRef, _ key: String) -> String? {
        var value: UnsafePointer<CChar>?
        guard CGPDFDictionaryGetName(dictionary, key, &value), let value else { return nil }
        return String(cString: value)
    }

    static func array(_ dictionary: CGPDFDictionaryRef, _ key: String) -> CGPDFArrayRef? {
        var value: CGPDFArrayRef?
        guard CGPDFDictionaryGetArray(dictionary, key, &value) else { return nil }
        return value
    }

    static func dictionary(_ dictionary: CGPDFDictionaryRef, _ key: String) -> CGPDFDictionaryRef? {
        var value: CGPDFDictionaryRef?
        guard CGPDFDictionaryGetDictionary(dictionary, key, &value) else { return nil }
        return value
    }

    /// Integer-typed value only (mirrors lopdf `as_i64`, which rejects reals).
    static func integer(_ dictionary: CGPDFDictionaryRef, _ key: String) -> Int? {
        var value: CGPDFInteger = 0
        guard CGPDFDictionaryGetInteger(dictionary, key, &value) else { return nil }
        return value
    }

    // MARK: Object-typed accessors

    static func objectArray(_ object: CGPDFObjectRef) -> CGPDFArrayRef? {
        var value: CGPDFArrayRef?
        guard CGPDFObjectGetValue(object, .array, &value) else { return nil }
        return value
    }

    /// Numeric value: integer or real (mirrors lopdf `as_float`).
    static func objectNumber(_ object: CGPDFObjectRef) -> Double? {
        switch CGPDFObjectGetType(object) {
        case .integer:
            var value: CGPDFInteger = 0
            guard CGPDFObjectGetValue(object, .integer, &value) else { return nil }
            return Double(value)
        case .real:
            var value: CGPDFReal = 0
            guard CGPDFObjectGetValue(object, .real, &value) else { return nil }
            return Double(value)
        default:
            return nil
        }
    }

    /// Integer-typed value only (mirrors lopdf `as_i64`).
    static func objectInteger(_ object: CGPDFObjectRef) -> Int? {
        guard CGPDFObjectGetType(object) == .integer else { return nil }
        var value: CGPDFInteger = 0
        guard CGPDFObjectGetValue(object, .integer, &value) else { return nil }
        return value
    }

    static func objectString(_ object: CGPDFObjectRef) -> String? {
        var value: CGPDFStringRef?
        guard CGPDFObjectGetValue(object, .string, &value), let value else { return nil }
        return CGPDFStringCopyTextString(value) as String?
    }

    // MARK: Array element accessors

    static func count(_ array: CGPDFArrayRef) -> Int {
        CGPDFArrayGetCount(array)
    }

    static func numberAt(_ array: CGPDFArrayRef, _ index: Int) -> Double? {
        var value: CGPDFReal = 0
        guard CGPDFArrayGetNumber(array, index, &value) else { return nil }
        return Double(value)
    }

    static func dictionaryAt(_ array: CGPDFArrayRef, _ index: Int) -> CGPDFDictionaryRef? {
        var value: CGPDFDictionaryRef?
        guard CGPDFArrayGetDictionary(array, index, &value) else { return nil }
        return value
    }

    static func objectAt(_ array: CGPDFArrayRef, _ index: Int) -> CGPDFObjectRef? {
        var value: CGPDFObjectRef?
        guard CGPDFArrayGetObject(array, index, &value) else { return nil }
        return value
    }

    /// Inheritable page attribute — walks the /Parent chain like inherited_object.
    static func inherited(_ pageDictionary: CGPDFDictionaryRef, _ key: String) -> CGPDFObjectRef? {
        var current: CGPDFDictionaryRef? = pageDictionary
        var depth = 0
        while let dictionary = current, depth < 64 {
            if let value = object(dictionary, key) { return value }
            current = self.dictionary(dictionary, "Parent")
            depth += 1
        }
        return nil
    }
}

/// Per-page coordinate transformer — exact port of the Rust PageGeometry.
///
/// UI space: top-left origin, y down, PDF points at zoom 1 with rotation and
/// /UserUnit folded in. PDF space: bottom-left origin, page-box units.
struct PageGeometry {
    let left: Double
    let bottom: Double
    let width: Double
    let height: Double
    /// 0/90/180/270 (any other /Rotate value behaves as 0, like the Rust match).
    let rotation: Int
    let userUnit: Double

    /// Mirrors page_geometry(): inherited /CropBox falling back to inherited
    /// /MediaBox, per-element defaults 0/0/612/792, /Rotate rem_euclid(360),
    /// /UserUnit > 0 else 1.0.
    init(pageDictionary: CGPDFDictionaryRef) throws {
        guard let box = CgPdf.inherited(pageDictionary, "CropBox")
            ?? CgPdf.inherited(pageDictionary, "MediaBox")
        else {
            throw SessionServiceError.invalidDocument("PDF page has no MediaBox")
        }
        guard let values = CgPdf.objectArray(box), CgPdf.count(values) >= 4 else {
            throw SessionServiceError.invalidDocument("PDF page has an invalid MediaBox")
        }
        let left = CgPdf.numberAt(values, 0) ?? 0.0
        let bottom = CgPdf.numberAt(values, 1) ?? 0.0
        let right = CgPdf.numberAt(values, 2) ?? 612.0
        let top = CgPdf.numberAt(values, 3) ?? 792.0

        let rawRotation = CgPdf.inherited(pageDictionary, "Rotate")
            .flatMap(CgPdf.objectInteger) ?? 0
        // rem_euclid(360): always in 0..<360.
        let rotation = ((rawRotation % 360) + 360) % 360

        let userUnit = CgPdf.inherited(pageDictionary, "UserUnit")
            .flatMap(CgPdf.objectNumber)
            .flatMap { $0 > 0 ? $0 : nil } ?? 1.0

        self.left = left
        self.bottom = bottom
        self.width = abs(right - left)
        self.height = abs(top - bottom)
        self.rotation = rotation
        self.userUnit = userUnit
    }

    var right: Double { left + width }
    var top: Double { bottom + height }

    var displayWidth: Double {
        rotation == 90 || rotation == 270 ? height * userUnit : width * userUnit
    }

    var displayHeight: Double {
        rotation == 90 || rotation == 270 ? width * userUnit : height * userUnit
    }

    func pdfToUi(_ x: Double, _ y: Double) -> (x: Double, y: Double) {
        switch rotation {
        case 90:
            return ((y - bottom) * userUnit, (x - left) * userUnit)
        case 180:
            return ((right - x) * userUnit, (y - bottom) * userUnit)
        case 270:
            return ((top - y) * userUnit, (right - x) * userUnit)
        default:
            return ((x - left) * userUnit, (top - y) * userUnit)
        }
    }

    /// UI → PDF. Rects are first rescaled by the stored page size so old
    /// annotations survive page-box changes (rescale-by-stored-page-size step).
    func uiToPdf(_ x: Double, _ y: Double, pageWidth: Double, pageHeight: Double) -> (x: Double, y: Double) {
        let displayX = x * displayWidth / max(pageWidth, .ulpOfOne)
        let displayY = y * displayHeight / max(pageHeight, .ulpOfOne)
        let xUnits = displayX / userUnit
        let yUnits = displayY / userUnit

        switch rotation {
        case 90:
            return (left + yUnits, bottom + xUnits)
        case 180:
            return (right - xUnits, bottom + yUnits)
        case 270:
            return (right - yUnits, top - xUnits)
        default:
            return (left + xUnits, top - yUnits)
        }
    }
}
