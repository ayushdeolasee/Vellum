import Foundation

/// Synthetic PDF inputs for reader and writer tests. Coordinates are in PDF user space.
enum PdfFixtureBuilder {
    private final class BundleToken {}

    /// Pass the PDF basename without its extension.
    static func fixtureURL(_ name: String) throws -> URL {
        #if SWIFT_PACKAGE
        let bundle = Bundle.module
        let directory = "Fixtures/Pdf"
        #else
        let bundle = Bundle(for: BundleToken.self)
        let directory = "Pdf"
        #endif
        guard let url = bundle.url(forResource: name, withExtension: "pdf", subdirectory: directory) else {
            throw CocoaError(.fileNoSuchFile, userInfo: [NSFilePathErrorKey: "\(directory)/\(name).pdf"])
        }
        return url
    }

    enum AnnotsLayout {
        case absent, inlineEmpty, indirectEmpty, withForeignInline
    }

    struct TextRun {
        var x, y: Int
        var text: String
    }

    struct Page {
        var width = 612
        var height = 792
        var rotation = 0
        var runs: [TextRun] = []
        var drawing = ""
    }

    // The crop box lives on /Pages so consumers must resolve inherited geometry.
    static func makeClassicPdf(
        pages: [Page],
        cropBox: (Int, Int, Int, Int)? = nil,
        annotsLayout: AnnotsLayout = .absent,
        generation: Int = 0
    ) -> Data {
        precondition(!pages.isEmpty && (0..<65535).contains(generation))
        func ref(_ number: Int) -> String { "\(number) \(generation) R" }
        let kids = pages.indices.map { ref(4 + 2 * $0) }.joined(separator: " ")
        let crop = cropBox.map { " /CropBox [\($0.0) \($0.1) \($0.2) \($0.3)]" } ?? ""
        var objects = [
            "<< /Type /Catalog /Pages \(ref(2)) >>",
            "<< /Type /Pages /Kids [\(kids)] /Count \(pages.count)\(crop) >>",
            font
        ]
        var annotations: [String] = []
        for (index, page) in pages.enumerated() {
            let firstAnnot = 4 + 2 * pages.count + annotations.count
            let annots: String
            switch annotsLayout {
            case .absent:
                annots = ""
            case .inlineEmpty:
                annots = " /Annots []"
            case .indirectEmpty:
                annots = " /Annots \(ref(firstAnnot))"
                annotations.append("[]")
            case .withForeignInline:
                let highlight = "<< /Type /Annot /Subtype /Highlight /Rect [72 695 172 711] /QuadPoints [72 711 172 711 72 695 172 695] /C [1 1 0] /F 4 >>"
                let freeText = "<< /Type /Annot /Subtype /FreeText /Rect [72 600 230 632] /DA (/Helv 12 Tf 0 g) /Contents (Margin note) /F 4 >>"
                let link = "<< /Type /Annot /Subtype /Link /Rect [72 546 180 566] /Border [0 0 1] /Dest [\(ref(4 + 2 * index)) /Fit] >>"
                annots = " /Annots [\(ref(firstAnnot)) null \(freeText) \(ref(firstAnnot + 1))]"
                annotations += [highlight, link]
            }
            let contents = ref(5 + 2 * index)
            objects.append("<< /Type /Page /Parent \(ref(2)) /MediaBox [0 0 \(page.width) \(page.height)] /Rotate \(page.rotation) /Resources << /Font << /Helv \(ref(3)) >> >> /Contents \(contents)\(annots) >>")
            let contentsSource = [textCommands(page.runs), page.drawing].filter { !$0.isEmpty }.joined(separator: "\n")
            objects.append(stream(contentsSource))
        }
        return classicObjects(objects + annotations, generation: generation)
    }

    /// Objects are in number order, starting at 1 (the catalog).
    static func classicObjects(_ objects: [String], generation: Int = 0) -> Data {
        var data = Data("%PDF-1.7\n".utf8)
        var offsets: [Int] = []
        for (index, body) in objects.enumerated() {
            offsets.append(data.count)
            data.append(contentsOf: "\(index + 1) \(generation) obj\n\(body)\nendobj\n".utf8)
        }
        let startXref = data.count
        let size = objects.count + 1
        var table = "xref\n0 \(size)\n0000000000 65535 f \n"
        for offset in offsets {
            table += String(format: "%010lld %05d n \n", Int64(offset), Int32(generation))
        }
        table += "trailer\n<< /Size \(size) /Root 1 \(generation) R >>\nstartxref\n\(startXref)\n%%EOF\n"
        data.append(contentsOf: table.utf8)
        return data
    }

    static func twoColumnPdf() -> Data {
        // Content order alternates columns, so a raw stream-order walk crosses the gutter.
        makeClassicPdf(pages: [Page(runs: [
            TextRun(x: 64, y: 704, text: "Left column: Café"),
            TextRun(x: 336, y: 704, text: "Right column: naïve"),
            TextRun(x: 64, y: 680, text: "First line of evidence."),
            TextRun(x: 336, y: 680, text: "Second line of evidence.")
        ])])
    }

    static func rotatedPdf() -> Data {
        // Distinct positions, dimensions, and colors make a flip or wrong rotation observable.
        let corners = """
            q
            1 0 0 rg 36 48 7 11 re f
            0 1 0 rg 548 56 13 7 re f
            0 0 1 rg 42 714 9 19 re f
            1 0 1 rg 539 710 17 13 re f
            Q
            """
        return makeClassicPdf(pages: [0, 90, 180, 270].map { angle in
            Page(rotation: angle, runs: [TextRun(x: 72, y: 700, text: "Rotation \(angle) degrees")],
                 drawing: corners)
        }, cropBox: (24, 36, 576, 744))
    }

    static func foreignAnnotationsPdf() -> Data {
        makeClassicPdf(pages: [Page(runs: [TextRun(x: 72, y: 700, text: "Highlighted text")])],
                       annotsLayout: .withForeignInline)
    }

    static func xrefStreamPdf() -> Data {
        var data = Data("%PDF-1.7\n".utf8)
        let contentOffset = data.count
        let content = stream(textCommands([TextRun(x: 72, y: 700, text: "Compressed page dictionary")]))
        data.append(contentsOf: "5 0 obj\n\(content)\nendobj\n".utf8)
        let objectStreamOffset = data.count
        // Precompressed with Python's zlib.compress(payload, 9) to keep the builder portable.
        // The 20-byte header "1 0 2 34 3 76 4 189 " locates the catalog, page tree, page and font.
        let objectStream = Data(base64Encoded: """
            eNplj9EKgjAYhe97ivMGc2qaIEJGEUQQFnQhXSwdMpAt3Ix6+/4p1EUwxnbOf76dcQQI\
            EcWIkCaIwVcZ8hzs8n5IsI1wojcd2El00tJggApFsfhNzAY7qNaijrx/o5gZtQP/n/T7\
            IMmbSewoWyVK80IdkJDwEGkWEqCS1oxDQ2Sf3xlK+MNe9k/qOJfwi17SjngWy/9qU4yd\
            x7ubrl7kYKWwcnY8TTrVCLCtbkyrNH30qvRaW/UViPgBVGpSig==
            """)!
        data.append(contentsOf: "6 0 obj\n<< /Type /ObjStm /N 4 /First 20 /Filter /FlateDecode /Length \(objectStream.count) >>\nstream\n".utf8)
        data.append(objectStream)
        data.append(contentsOf: "\nendstream\nendobj\n".utf8)
        let xrefOffset = data.count

        // /W [1 2 2]. Every row starts with PNG filter byte 2 (Up), then
        // each field byte minus the corresponding byte in the previous row.
        let entries = [(0, 0, 65535)] + (0..<4).map { (2, 6, $0) }
            + [contentOffset, objectStreamOffset, xrefOffset].map { (1, $0, 0) }
        var previous = [UInt8](repeating: 0, count: 5)
        var differences: [UInt8] = []
        for (type, location, index) in entries {
            let row = [UInt8(type), UInt8(location >> 8), UInt8(truncatingIfNeeded: location),
                       UInt8(index >> 8), UInt8(truncatingIfNeeded: index)]
            differences.append(2)
            differences += zip(row, previous).map { $0 &- $1 }
            previous = row
        }
        let bytes = zlibStoredBlock(differences)
        data.append(contentsOf: """
            7 0 obj
            << /Type /XRef /Size 8 /Root 1 0 R /W [1 2 2] /Filter /FlateDecode /DecodeParms << /Predictor 12 /Columns 5 >> /Length \(bytes.count) >>
            stream\n
            """.utf8)
        data.append(contentsOf: bytes)
        data.append(contentsOf: "\nendstream\nendobj\nstartxref\n\(xrefOffset)\n%%EOF\n".utf8)
        return data
    }

    private static let font = "<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica /Encoding /WinAnsiEncoding >>"

    private static func textCommands(_ runs: [TextRun]) -> String {
        runs.map { run in
            // Base-14 Helvetica, printable ASCII and Latin-1 subset of WinAnsi.
            // Hex strings avoid delimiter escaping and locale-dependent encodings.
            let hex = run.text.unicodeScalars.map { scalar in
                precondition((32...126).contains(scalar.value) || (160...255).contains(scalar.value))
                return String(format: "%02X", scalar.value)
            }.joined()
            return "BT /Helv 14 Tf \(run.x) \(run.y) Td <\(hex)> Tj ET"
        }.joined(separator: "\n")
    }

    private static func stream(_ contents: String, entries: String = "") -> String {
        "<< \(entries) /Length \(contents.utf8.count) >>\nstream\n\(contents)\nendstream"
    }

    // A single uncompressed DEFLATE block in a zlib wrapper (RFC 1950/1951).
    // The xref payload is only 48 bytes. This keeps the test builder Foundation-only.
    private static func zlibStoredBlock(_ bytes: [UInt8]) -> [UInt8] {
        let length = UInt16(bytes.count)
        var encoded: [UInt8] = [0x78, 0x01, 0x01]
        for value in [length, ~length] {
            encoded += [UInt8(truncatingIfNeeded: value), UInt8(value >> 8)]
        }
        encoded += bytes
        var a: UInt32 = 1
        var b: UInt32 = 0
        for byte in bytes {
            a = (a + UInt32(byte)) % 65521
            b = (b + a) % 65521
        }
        let checksum = (b << 16) | a
        encoded += [24, 16, 8, 0].map { UInt8(truncatingIfNeeded: checksum >> $0) }
        return encoded
    }
}
