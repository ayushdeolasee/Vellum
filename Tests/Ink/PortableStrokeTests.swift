import PDFKit
import PencilKit
import VellumCore
import XCTest
@testable import Vellum

final class PortableStrokeTests: XCTestCase {
    private func fixture(_ name: String, _ ext: String, in directory: String) throws -> Data {
        let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: name, withExtension: ext,
                                                           subdirectory: directory))
        return try Data(contentsOf: url)
    }

    private func pdfStrokes(_ name: String) throws -> [PKStroke] {
        let document = try XCTUnwrap(PDFDocument(data: fixture(name, "pdf", in: "Pdf")))
        let page = try XCTUnwrap(document.page(at: 0))
        let drawing = page.annotations.compactMap { annotation -> Data? in
            let value = annotation.value(forAnnotationKey: .init(rawValue: "VellumInk")) as? String
            return value.flatMap { Data(base64Encoded: $0) }
        }.first
        return try PKDrawing(data: XCTUnwrap(drawing)).strokes
    }

    private func roundTrip(_ original: PKStroke) throws -> PortableStroke {
        let portable = try PortableStroke(original)
        let wire = try JSONEncoder().encode(portable)
        let rebuilt = try PKStroke(JSONDecoder().decode(PortableStroke.self, from: wire))
        XCTAssertEqual(rebuilt.ink.inkType, original.ink.inkType)
        XCTAssertEqual(rebuilt.transform, original.transform)
        XCTAssertEqual(rebuilt.randomSeed, original.randomSeed)
        XCTAssertEqual(rebuilt.mask?.cgPath, original.mask?.cgPath)
        XCTAssertEqual(rebuilt.maskedPathRanges, original.maskedPathRanges)
        XCTAssertEqual(rebuilt.path.creationDate.timeIntervalSince(original.path.creationDate), 0, accuracy: 1e-6)
        XCTAssertEqual(rebuilt.path.count, original.path.count)
        for (p, q) in zip(rebuilt.path, original.path) {
            XCTAssertEqual(p.location, q.location)
            XCTAssertEqual(p.timeOffset, q.timeOffset)
            let a = [p.size.width, p.size.height, p.opacity, p.force, p.azimuth, p.altitude, p.secondaryScale]
            let b = [q.size.width, q.size.height, q.opacity, q.force, q.azimuth, q.altitude, q.secondaryScale]
            for (v, w) in zip(a, b) { XCTAssertEqual(v, w, accuracy: 1e-6) }
        }
        let rebuiltPortable = try PortableStroke(rebuilt)
        XCTAssertEqual(rebuiltPortable.id, portable.id)
        for (v, w) in zip(rebuiltPortable.color, portable.color) { XCTAssertEqual(v, w, accuracy: 1e-6) }
        return portable
    }

    func testEmbeddedIPadDrawings() throws {
        let cases = [("ipad-vellum-ink", 2), ("pdf-ink-marker", 2), ("pdf-ink-erased-full", 2),
                     ("pdf-ink-erased-partial", 2), ("pdf-ink-rotated", 1)]
        for (name, count) in cases {
            let strokes = try pdfStrokes(name)
            XCTAssertEqual(strokes.count, count)
            let portable = try strokes.map(roundTrip)
            let first = try XCTUnwrap(portable.first)
            switch name {
            case "pdf-ink-marker":
                XCTAssertEqual(first.ink, "com.apple.ink.marker")
                for (v, w) in zip(first.color, [254.0 / 255, 240.0 / 255, 138.0 / 255, 1]) {
                    XCTAssertEqual(v, w, accuracy: 1e-6)
                }
            case "pdf-ink-erased-full":
                XCTAssertNotNil(first.mask)
                XCTAssertEqual(first.visibleRanges, [])
                var rangesOnly = first
                rangesOnly.mask = nil
                XCTAssertThrowsError(try PKStroke(rangesOnly))
            case "pdf-ink-erased-partial":
                let golden = try JSONDecoder().decode(PortableStroke.self, from: fixture("partial-stroke", "json", in: "Ink"))
                XCTAssertEqual(first.id, golden.id)
                XCTAssertEqual(first.points, golden.points)
                XCTAssertEqual(first.visibleRanges, golden.visibleRanges)
                let rebuilt = try PKStroke(golden)
                XCTAssertEqual(rebuilt.maskedPathRanges, strokes[0].maskedPathRanges)
                #if os(macOS)
                XCTAssertEqual(first, golden)
                #endif
                var rangesOnly = first
                rangesOnly.mask = nil
                XCTAssertThrowsError(try PKStroke(rangesOnly))
            default:
                XCTAssertEqual(first.ink, "com.apple.ink.pen")
            }
        }

        struct Record: Decodable {
            struct Cluster: Decodable { var drawing: Data }
            var clusters: [Cluster]
        }
        let web = try JSONDecoder().decode(Record.self, from: fixture("web-ink-v3.ink", "json", in: "Web"))
        let drawing = try PKDrawing(data: XCTUnwrap(web.clusters.first).drawing)
        XCTAssertEqual(drawing.strokes.count, 1)
        let stroke = try roundTrip(XCTUnwrap(drawing.strokes.first))
        XCTAssertEqual(stroke.transform, [1, 0, 0, 1, -29, -175])
        XCTAssertEqual(stroke.points.first?.x, 32)
        XCTAssertEqual(stroke.id, "574625a0a8d7677e6c5068c0527baf9e74144b575b6cd1c203d1af531eb4dd05")
    }

    func testCanonicalMicrosecondsRawBitsAndSecondaryScale() throws {
        func point(_ x: CGFloat, _ y: CGFloat, _ t: Double) -> PKStrokePoint {
            PKStrokePoint(location: CGPoint(x: x, y: y), timeOffset: t, size: CGSize(width: 4, height: 6),
                          opacity: 0.8, force: 0.5, azimuth: 0.5, altitude: 0.38, secondaryScale: 0.66)
        }
        let points = [point(-3.25, 0.5, 0), point(4, 7.5, 0.125)]
        func stroke(_ time: Double) -> PKStroke {
            PKStroke(ink: PKInk(.pencil, color: .black),
                     path: PKStrokePath(controlPoints: points, creationDate: Date(timeIntervalSinceReferenceDate: time)),
                     transform: CGAffineTransform(a: 0, b: 1, c: -1, d: 0, tx: 3, ty: 4), randomSeed: 12)
        }
        let portable = try roundTrip(stroke(0.1234567))
        XCTAssertEqual(portable.createdAt, "2001-01-01T00:00:00.123457Z")
        XCTAssertEqual(portable.id, "f0335e3d03942902b0f1e938c78a8b090da99ed84dfc4b5e526818aaf5af3b7c")
        XCTAssertEqual(try XCTUnwrap(portable.points.first).secondaryScale, 0.66, accuracy: 1e-6)
        XCTAssertNotEqual(try PortableStroke(stroke(0.1234557)).id, portable.id)
        XCTAssertEqual(try PortableStroke(stroke(-0.0000001)).createdAt, "2001-01-01T00:00:00.000000Z")

        var changed = portable
        changed.points[0].x = changed.points[0].x.nextUp
        XCTAssertThrowsError(try PKStroke(changed), "Identity inputs have no epsilon")
        changed = portable
        changed.ink = "future.brush"
        XCTAssertThrowsError(try PKStroke(changed))
        changed = portable
        changed.visibleRanges[0][1] -= 1e-8
        XCTAssertThrowsError(try PKStroke(changed), "Display intervals cannot supply a missing mask")
    }
}
