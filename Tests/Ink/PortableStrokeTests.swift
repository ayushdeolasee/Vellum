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

final class PortableInkReaderTests: XCTestCase {
    private func fixture(_ name: String, _ ext: String, in directory: String) throws -> Data {
        let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: name, withExtension: ext,
                                                           subdirectory: directory))
        return try Data(contentsOf: url)
    }

    private func webRecord(dual: Bool = false) throws -> WebInkRecord {
        let bytes = try fixture("web-ink-v3.ink", "json", in: "Web")
        var record = try JSONDecoder().decode(WebInkRecord.self, from: bytes)
        var stroke = try PortableStroke(XCTUnwrap(record.clusters[0].localDrawing().strokes.first))
        stroke.id = "other-device/opaque-007"
        stroke.unknownFields["brush"] = .int(17)
        stroke.points[0].unknownFields["sample"] = .null
        record.clusters[0].unknownFields["label"] = .string("original")
        record.clusters[0].strokes = [stroke]
        if !dual { record.clusters[0].drawing = nil }
        return record
    }

    private func withStore(_ test: () async throws -> Void) async throws {
        let previous = WebLibrary.storeDirOverride
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let previousLayout = WebLibrary.layoutOverride
        WebLibrary.storeDirOverride = root
        WebLibrary.layoutOverride = .local(storeDir: root)
        defer {
            WebLibrary.layoutOverride = previousLayout
            WebLibrary.storeDirOverride = previous
            try? FileManager.default.removeItem(at: root)
        }
        try await test()
    }

    func testStrokesOnlyClusterLoadsAndSurvivesEditAndArchive() async throws {
        try await withStore {
            for dual in [false, true] {
                let record = try webRecord(dual: dual)
                let key = WebLibrary.pageKey(record.url)
                try WebInkStore.writeRecord(record, to: WebInkStore.inkPath(forKey: key))
                let reopened = try XCTUnwrap(WebInkStore.loadRecord(forKey: key))
                let drawing = try reopened.validatedMergedDrawing()
                XCTAssertEqual(drawing.strokes.count, 1)
                XCTAssertEqual(drawing.bounds.minX, record.clusters[0].bounds.x, accuracy: 0.01)
                XCTAssertEqual(drawing.bounds.minY, record.clusters[0].bounds.y, accuracy: 0.01)
                #if os(macOS)
                let payload = try XCTUnwrap(WebSavedInkRenderer.load(url: record.url, pageURL: record.url))
                let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(payload.utf8)) as? [String: Any])
                let image = try XCTUnwrap((object["clusters"] as? [[String: Any]])?.first?["image"] as? String)
                XCTAssertTrue(image.hasPrefix("data:image/png;base64,iVBOR"))
                XCTAssertEqual(SavedHandwritingReader.webClusters(url: record.url), record.clusters)
                #endif

                // A new stroke close enough to share the original anchor.
                let first = try XCTUnwrap(drawing.strokes.first)
                let newPath = PKStrokePath(controlPoints: Array(first.path),
                                           creationDate: first.path.creationDate.addingTimeInterval(1))
                let added = PKStroke(ink: first.ink, path: newPath, transform: first.transform)
                let edited = drawing.appending(PKDrawing(strokes: [added]))
                #if os(iOS)
                let persister = await WebInkPersister(url: record.url)
                await persister.seedBaseline(reopened)
                await persister.drawingChanged(edited, layout: record.layout)
                let saved = await persister.flushPendingInkAndWait()
                XCTAssertTrue(saved)
                #else
                let snapshot = WebInkRecord.snapshot(of: edited, url: record.url, layout: record.layout)
                _ = try WebInkStore.applySnapshot(snapshot, replacing: reopened, forKey: key)
                #endif
                let restored = try XCTUnwrap(WebInkStore.loadRecordForExport(forKey: key))
                XCTAssertEqual(restored.version, 3)
                XCTAssertEqual(try restored.validatedMergedDrawing().strokes.count, 2)
                let original = try XCTUnwrap(restored.clusters.first { $0.strokes != nil })
                XCTAssertEqual(original.strokes, record.clusters[0].strokes)
                XCTAssertEqual(original.drawing, record.clusters[0].drawing)
                XCTAssertEqual(original.unknownFields, record.clusters[0].unknownFields)
                XCTAssertEqual(restored.clusters.filter { $0.strokes == nil }.count, 1)
                XCTAssertEqual(Set(restored.clusters.map(\.id)).count, restored.clusters.count)
                var imported: WebInkRecord? = record
                try WebArchive.mergeInk(&imported, incoming: restored)
                let merged = try XCTUnwrap(imported)
                XCTAssertEqual(try merged.validatedMergedDrawing().strokes.count, 2)
                XCTAssertEqual(merged.clusters.compactMap(\.strokes), [try XCTUnwrap(original.strokes)])
                let pages = try WebArchive.encodePagesJson([])
                let html = "<p>Ink</p>"
                let manifest = WebArchive.buildManifest(url: record.url, title: nil, pageCount: 1, lastPage: 1,
                    loadingPolicy: "snapshot-only", snapshotHtml: html, pagesJson: pages, assets: [], assetsSkipped: 0)
                let archive = try WebArchive.encodeArchive(manifest: manifest, snapshotHtml: html, assets: [],
                    pagesJson: pages, annotations: [], inkJson: JSONEncoder().encode(merged))
                XCTAssertEqual(try WebArchive.readArchive(data: archive).inkRecord, merged)
            }
        }
    }

    func testMovingMaskedWebInkPreservesOpaqueMetadata() async throws {
        try await withStore {
            var source = try webRecord()
            var wire = try JSONDecoder().decode(PortableStroke.self, from: fixture("partial-stroke", "json", in: "Ink"))
            wire.id = "opaque/masked"
            wire.points[0].unknownFields["device"] = .int(42)
            wire.mask?.unknownFields["operation"] = .string("erase")
            source.clusters[0].strokes = [wire]
            let key = WebLibrary.pageKey(source.url)
            try WebInkStore.writeRecord(source, to: WebInkStore.inkPath(forKey: key))
            let moved = try source.validatedMergedDrawing().transformed(
                using: CGAffineTransform(translationX: 45, y: 75))
            let change = WebInkRecord.snapshot(of: moved, url: source.url, layout: source.layout)
            _ = try WebInkStore.applySnapshot(change, replacing: source, forKey: key)
            let reopened = try XCTUnwrap(WebInkStore.loadRecordForExport(forKey: key))
            let stroke = try XCTUnwrap(reopened.validatedMergedDrawing().strokes.first)
            let expected = try XCTUnwrap(moved.strokes.first)
            XCTAssertEqual(stroke.transform, expected.transform)
            XCTAssertEqual(stroke.mask?.cgPath, expected.mask?.cgPath)
            XCTAssertEqual(stroke.maskedPathRanges, expected.maskedPathRanges)
            let persisted = try XCTUnwrap(reopened.clusters.first?.strokes?.first)
            XCTAssertEqual(persisted.id, wire.id)
            XCTAssertEqual(persisted.points[0].unknownFields, wire.points[0].unknownFields)
            XCTAssertEqual(persisted.mask?.unknownFields, wire.mask?.unknownFields)
            XCTAssertNil(reopened.clusters.first?.drawing)
        }
    }

    func testInvalidPortableRecordRefusesLoadAndOverwrite() async throws {
        try await withStore {
            let source = try webRecord()
            var missing = source
            missing.clusters[0].strokes = nil
            var damaged = source
            damaged.clusters[0].strokes?[0].visibleRanges = []
            var empty = source
            empty.clusters[0].strokes = []
            let key = WebLibrary.pageKey(source.url)
            let path = WebInkStore.inkPath(forKey: key)
            for invalid in [missing, damaged, empty] {
                try WebInkStore.writeRecord(invalid, to: path)
                let bytes = try Data(contentsOf: path)
                XCTAssertNil(WebInkStore.loadRecord(at: path))
                XCTAssertThrowsError(try WebInkStore.loadRecordForExport(forKey: key))
                XCTAssertThrowsError(try WebInkStore.applySnapshot(source, replacing: nil, forKey: key))
                var original: WebInkRecord? = source
                XCTAssertThrowsError(try WebArchive.mergeInk(&original, incoming: invalid))
                XCTAssertEqual(original, source)
                XCTAssertEqual(try Data(contentsOf: path), bytes)
            }
        }
    }

    /// The fixture keeps I0's partial erasure and native appearance, with its
    /// drawing replaced by the zlib-compressed golden stroke on the carrier.
    func testPortablePDFInkSurvivesUnrelatedNote() async throws {
        let bytes = try fixture("portable-partial", "pdf", in: "Ink")
        let document = try XCTUnwrap(PDFDocument(data: bytes))
        let page = try XCTUnwrap(document.page(at: 0))
        let key = PDFAnnotationKey(rawValue: "VellumInkStrokes")
        let carrier = try XCTUnwrap(page.annotations.first)
        let payload = try XCTUnwrap(carrier.value(forAnnotationKey: key) as? String)
        let golden = try JSONDecoder().decode(PortableStroke.self, from: fixture("partial-stroke", "json", in: "Ink"))
        XCTAssertEqual(try PortableStroke.decodePDFPayload(payload), [golden])
        XCTAssertThrowsError(try PKDrawing(pdfStrokePayload: "bWFsZm9ybWVk"))
        let drawing = try PKDrawing(pdfStrokePayload: payload)
        XCTAssertEqual(drawing.strokes.first?.maskedPathRanges, try PKStroke(golden).maskedPathRanges)
        #if os(macOS)
        XCTAssertEqual(try SavedHandwritingReader.pdfPages(data: bytes, password: nil), [1])
        #else
        XCTAssertTrue(PdfInk.hasPortableInk(on: page))
        XCTAssertEqual(PdfInk.drawing(on: page)?.strokes.first?.maskedPathRanges, drawing.strokes.first?.maskedPathRanges)
        let legacy = try webRecord(dual: true)
        carrier.setValue(try XCTUnwrap(legacy.clusters[0].drawing).base64EncodedString(), forAnnotationKey: PdfInk.dataKey)
        XCTAssertNil(try XCTUnwrap(PdfInk.drawing(on: page)?.strokes.first).mask, "Dual pages prefer native ink")
        #endif

        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("editable.pdf")
        try bytes.write(to: url)
        #if os(iOS)
        let wrote = await InkDiskWriter().write(drawings: [1: PKDrawing()], path: url.path)
        XCTAssertFalse(wrote)
        XCTAssertEqual(try Data(contentsOf: url), bytes)
        #endif
        let session = try await PdfSessionBackend().open(path: url.path, sessionId: UUID().uuidString)
        let note = try await session.createAnnotation(.init(type: .note, pageNumber: 1, color: nil, content: "Margin",
            positionData: PositionData(rects: [.init(x: 20, y: 20, width: 0, height: 0)], pageWidth: 320,
                pageHeight: 240, selectedText: nil, startOffset: nil, endOffset: nil, prefix: nil, suffix: nil,
                viewportOffset: nil)))
        let notes = try await session.annotations(pageNumber: 1)
        XCTAssertTrue(notes.contains { $0.id == note.id })
        let reread = try XCTUnwrap(PDFDocument(url: url))
        let stored = try XCTUnwrap(reread.page(at: 0)).annotations.compactMap { $0.value(forAnnotationKey: key) as? String }
        XCTAssertEqual(stored, [payload])
    }
}
