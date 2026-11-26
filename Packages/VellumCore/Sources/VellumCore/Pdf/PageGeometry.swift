/// Per-page coordinate transformer — exact port of the Rust PageGeometry.
///
/// UI space: top-left origin, y down, PDF points at zoom 1 with rotation and
/// /UserUnit folded in. PDF space: bottom-left origin, page-box units.
public struct PageGeometry: Sendable {
    public let left: Double
    public let bottom: Double
    public let width: Double
    public let height: Double
    /// 0/90/180/270 (any other /Rotate value behaves as 0, like the Rust match).
    public let rotation: Int
    public let userUnit: Double

    public init(left: Double, bottom: Double, width: Double, height: Double, rotation: Int, userUnit: Double) {
        self.left = left.isFinite ? left : 0
        self.bottom = bottom.isFinite ? bottom : 0
        self.width = width.isFinite ? width : 612
        self.height = height.isFinite ? height : 792
        self.rotation = ((rotation % 360) + 360) % 360
        let canScale = (self.width * userUnit).isFinite && (self.height * userUnit).isFinite
        self.userUnit = userUnit.isFinite && userUnit > 0 && canScale ? userUnit : 1
    }

    public var right: Double { left + width }
    public var top: Double { bottom + height }

    public var displayWidth: Double {
        rotation == 90 || rotation == 270 ? height * userUnit : width * userUnit
    }

    public var displayHeight: Double {
        rotation == 90 || rotation == 270 ? width * userUnit : height * userUnit
    }

    public func pdfToUi(_ x: Double, _ y: Double) -> (x: Double, y: Double) {
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
    public func uiToPdf(_ x: Double, _ y: Double, pageWidth: Double, pageHeight: Double) -> (x: Double, y: Double) {
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

extension PageGeometry {
    /// ISO 32000 numbers have an optional sign, decimal digits and at most
    /// one decimal point. Swift also accepts exponents, hex, NaN and infinity.
    private static func pdfNumber(_ bytes: [UInt8]) -> Double? {
        var index = 0
        if bytes.first == UInt8(ascii: "+") || bytes.first == UInt8(ascii: "-") { index += 1 }
        var sawDigit = false
        var sawPoint = false
        for byte in bytes[index...] {
            if PdfBytes.isDigit(byte) { sawDigit = true }
            else if byte == UInt8(ascii: "."), !sawPoint { sawPoint = true }
            else { return nil }
        }
        guard sawDigit, let value = Double(String(decoding: bytes, as: UTF8.self)), value.isFinite else { return nil }
        return value
    }

    /// Resolve the same inherited page attributes as the CGPDF adapter. A crop
    /// box on an ancestor takes precedence over a media box on the page itself.
    public init(pageNumber: Int, in file: ClassicPdfFile) throws {
        guard pageNumber > 0, let root = file.rootNumber, let catalog = file.objectSource(root),
              let number = PdfOutlineIncrement.pageObjectNumber(in: file, catalog: catalog, pageNumber: pageNumber)
        else { throw PdfCoreError.invalidDocument("Page \(pageNumber) does not exist") }

        var ancestors: [PdfDictSource] = []
        var parent: Int? = number
        var seen = Set<Int>()
        while let number = parent, ancestors.count < 64, seen.insert(number).inserted,
              let node = file.objectSource(number) {
            ancestors.append(node)
            parent = node.reference(forKey: "Parent")
        }

        func inherited(_ key: String) -> [UInt8]? {
            for node in ancestors {
                if let value = file.resolvedValue(forKey: key, in: node) { return value }
            }
            return nil
        }

        guard let box = inherited("CropBox") ?? inherited("MediaBox") else {
            throw PdfCoreError.invalidDocument("PDF page has no MediaBox")
        }
        guard let elements = PdfArraySource.elementSpans(inArray: box), elements.count >= 4 else {
            throw PdfCoreError.invalidDocument("PDF page has an invalid MediaBox")
        }
        func coordinate(_ index: Int, fallback: Double) -> Double {
            guard let bytes = file.resolvedValue(Array(box[elements[index]])) else { return fallback }
            return Self.pdfNumber(bytes) ?? fallback
        }

        let left = coordinate(0, fallback: 0)
        let bottom = coordinate(1, fallback: 0)
        let right = coordinate(2, fallback: 612)
        let top = coordinate(3, fallback: 792)
        let rotation = inherited("Rotate").flatMap { Int(String(decoding: $0, as: UTF8.self)) } ?? 0
        let unit = inherited("UserUnit").flatMap(Self.pdfNumber) ?? 1
        self.init(left: min(left, right), bottom: min(bottom, top), width: abs(right - left), height: abs(top - bottom),
                  rotation: rotation, userUnit: unit)
    }
}
