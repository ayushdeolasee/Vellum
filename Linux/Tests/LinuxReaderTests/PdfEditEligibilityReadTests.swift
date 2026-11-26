import Foundation
import Testing
import VellumCore
@testable import LinuxReader

extension PdfiumTests {
    @Test func rendersOriginalBytesRegardlessOfEditEligibility() async throws {
        let classic = try fixture("classic-two-column")
        let file = try ClassicPdfFile(data: classic)
        func withObject(_ number: Int, _ body: String) -> Data {
            var increment = PdfIncrement(file: file)
            increment.setObject(number, source: Array(body.utf8))
            return increment.appended()
        }
        let page = "/Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Contents 5 0 R"
        let geometry = withObject(4, "<< \(page) /UserUnit 2 >>")
        let annots = withObject(4, "<< \(page) /Annots [<< /Subtype /Text /NM (same) >> << /Subtype /Text /NM (same) >>] >>")
        let certified = withObject(1, "<< /Type /Catalog /Pages 2 0 R /Perms << /DocMDP 3 0 R >> >>")
        var removed = PdfIncrement(file: try ClassicPdfFile(data: certified))
        removed.setObject(1, source: Array("<< /Type /Catalog /Pages 2 0 R >>".utf8))

        // Use the actual fixture's xref stream as the supplemental table.
        var hybrid = try fixture("xref-stream-objstm")
        let trailer = try #require(hybrid.range(of: Data("startxref\n".utf8), options: .backwards))
        let offset = try #require(Int(String(decoding: hybrid[trailer.upperBound...], as: UTF8.self)
            .prefix(while: { $0.isNumber })))
        hybrid.removeSubrange(trailer.lowerBound...)
        let classicXref = hybrid.count
        hybrid.append(contentsOf: "xref\n0 1\n0000000000 65535 f \ntrailer\n<< /Size 8 /Root 1 0 R /XRefStm \(offset) >>\nstartxref\n\(classicXref)\n%%EOF\n".utf8)

        let nonzero = String(decoding: classic, as: UTF8.self)
            .replacingOccurrences(of: " 0 R", with: " 3 R")
            .replacingOccurrences(of: " 0 obj", with: " 3 obj")
            .replacingOccurrences(of: " 00000 n", with: " 00003 n")
        let latest = withObject(4, "<< \(page) >>")
        var badPrevious = latest
        let prev = try #require(badPrevious.range(of: Data("/Prev ".utf8), options: .backwards))
        badPrevious[prev.upperBound] = 57 // Keep the rest of the revision and its startxref intact.
        var cyclic = latest
        let start = try #require(cyclic.range(of: Data("xref\n4 1".utf8), options: .backwards))
        let end = cyclic[prev.upperBound...].prefix { (48...57).contains($0) }.endIndex
        cyclic.replaceSubrange(prev.upperBound..<end, with: String(start.lowerBound).utf8)

        let cases: [(String, Data, PdfEditEligibility, String?)] = [
            ("classic", classic, .editable, nil),
            ("xref stream", try fixture("xref-stream-objstm"), .editable, nil),
            ("hybrid", hybrid, .editable, nil),
            ("encrypted", try fixture("encrypted-user-pass"), .readOnly(.encrypted), "vellum"),
            ("signed", try fixture("digitally-signed"), .readOnly(.signed), nil),
            ("certified", certified, .readOnly(.signed), nil),
            ("previous certification", removed.appended(), .readOnly(.signed), nil),
            ("bad previous revision", badPrevious, .readOnly(.malformed), nil),
            ("cyclic previous revision", cyclic, .readOnly(.malformed), nil),
            ("generation three", Data(nonzero.utf8), .readOnly(.nonzeroGeneration), nil),
            ("user unit", geometry, .readOnly(.unsupportedGeometry), nil),
            ("duplicate annotation ID", annots, .readOnly(.ambiguousAnnotation), nil)
        ]
        for (label, bytes, expected, password) in cases {
            let before = [UInt8](bytes)
            #expect(PdfEditEligibility.classify(bytes) == expected, "\(label)")
            let bitmap = try await PdfiumDocument.render(in: bytes, at: 0, scale: 0.25, password: password)
            #expect(bitmap.width == 153 && bitmap.height == 198, "\(label)")
            #expect(bytes.elementsEqual(before), "\(label)")
        }
    }
}

extension PdfiumTests {
    @Test func streamAnnotationAndVerifiedStorageKeyUseOneRevision() async throws {
        let stamp = "01234567-89ab-cdef-0123-456789abcdef"
        for name in ["xref-stream-objstm", "resume-stream-string", "resume-stream-name"] {
            let original = try fixture(name)
            let edit = PdfAnnotationEdit.create(.init(type: .note, pageNumber: 1, content: "literal endobj", id: "shared"))
            let key = name == "resume-stream-string" ? stamp : DocumentIdentity.byteHash(original)
            let date = "2026-11-26T00:00:00Z"
            if name == "resume-stream-name" {
                #expect(throws: (any Error).self) {
                    try PdfAnnotationIncrement.applying(edit, to: original, now: date, preservingStorageKey: key)
                }
                continue
            }
            let output = try PdfAnnotationIncrement.applying(edit, to: original, now: date, preservingStorageKey: key)
            try PdfEditEligibility.validateForReading(output)
            #expect(output.starts(with: original))
            let suffix = output.dropFirst(original.count)
            #expect(suffix.ranges(of: Data("startxref".utf8)).count == 1)
            #expect(try await PdfiumDocument.openingInfo(in: output).stableIdentifier == key)
            #expect(try PdfAnnotationPureReader.annotations(on: 1, in: output, now: date).contains { $0.id == "shared" })
        }
    }
}
