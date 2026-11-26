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
                XCTAssertEqual(rebuilt.mask?.cgPath, strokes[0].mask?.cgPath)
                XCTAssertEqual(rebuilt.maskedPathRanges, strokes[0].maskedPathRanges)
                XCTAssertTrue(try golden.describes(strokes[0]))
                // A clipped corner changes the filled mask away from the
                // centerline while leaving both visible intervals identical.
                var clipped = golden
                clipped.mask?.path[2].coordinates[1] = 5
                XCTAssertEqual(try PKStroke(clipped).maskedPathRanges, rebuilt.maskedPathRanges)
                XCTAssertFalse(try clipped.describes(strokes[0]))
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

    func testMovedMaskSurvivesPencilKitSerialization() throws {
        let original = try XCTUnwrap(pdfStrokes("pdf-ink-erased-partial").first)
        let payload = try fixture("portable-shifted", "zlib", in: "Ink").base64EncodedString()
        var wire = try XCTUnwrap(PortableStroke.decodePDFPayload(payload).first)
        let rebuilt = try PKStroke(wire)
        let reopened = try XCTUnwrap(PKDrawing(data: PKDrawing(strokes: [rebuilt]).dataRepresentation()).strokes.first)
        XCTAssertEqual(reopened.transform, CGAffineTransform(translationX: 20, y: 0))
        XCTAssertEqual(reopened.mask?.cgPath, original.mask?.cgPath)
        XCTAssertEqual(reopened.maskedPathRanges, original.maskedPathRanges)
        XCTAssertTrue(try wire.describes(reopened))

        // A stroke erased at its final placement can have different intervals.
        let direct = PKStroke(ink: original.ink, path: original.path, transform: rebuilt.transform,
                              mask: original.mask, randomSeed: original.randomSeed)
        XCTAssertEqual(try PKStroke(PortableStroke(direct)).maskedPathRanges, direct.maskedPathRanges)
        wire.visibleRanges = [[0, 8]]
        XCTAssertThrowsError(try PKStroke(wire))
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
            XCTAssertEqual(persisted.mask, wire.mask, "Moving a stroke preserves its original wire mask and unknown fields")
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

    private func nativeFixture(_ name: String) throws -> PKDrawing {
        let pdf = try XCTUnwrap(PDFDocument(data: fixture(name, "pdf", in: "Pdf")))
        let page = try XCTUnwrap(pdf.page(at: 0))
        let bytes = page.annotations.compactMap {
            ($0.value(forAnnotationKey: .init(rawValue: "VellumInk")) as? String).flatMap { Data(base64Encoded: $0) }
        }
        return try PKDrawing(data: XCTUnwrap(bytes.first))
    }

    func testDualPairingSurvivesReorderEditAndInvisibleOmission() async throws {
        try await withStore {
            for name in ["pdf-ink-erased-partial", "pdf-ink-erased-full"] {
                var record = try webRecord(dual: true)
                let drawing = try nativeFixture(name)
                let visible = drawing.strokes.indices.filter { !drawing.strokes[$0].maskedPathRanges.isEmpty }
                let reversed = visible.reversed()
                let wire = try reversed.map { i in
                    var member = try PortableStroke(drawing.strokes[i])
                    member.id = "opaque-\(i)"
                    member.points[0].unknownFields["source"] = .int(i)
                    return member
                }
                record.clusters[0].drawing = drawing.dataRepresentation()
                record.clusters[0].strokes = wire
                let local = try record.clusters[0].localDrawing()
                XCTAssertEqual(local.strokes.count, 2)
                XCTAssertEqual(try record.clusters[0].portableIndices(for: local),
                               name.hasSuffix("partial") ? [1, 0] : [nil, 0])
                let key = WebLibrary.pageKey(record.url)
                let path = WebInkStore.inkPath(forKey: key)
                try WebInkStore.writeRecord(record, to: path)
                let moved = try record.validatedMergedDrawing().transformed(using: .init(translationX: 20, y: 12))
                _ = try WebInkStore.applySnapshot(.snapshot(of: moved, url: record.url, layout: record.layout),
                                                  replacing: record, forKey: key)
                let saved = try XCTUnwrap(WebInkStore.loadRecordForExport(forKey: key))
                XCTAssertEqual(try saved.validatedMergedDrawing().strokes.count, 2)
                let persisted = saved.clusters.flatMap { $0.strokes ?? [] }
                XCTAssertEqual(Set(persisted.map(\.id)), Set(wire.map(\.id)))
                for item in persisted {
                    let original = try XCTUnwrap(wire.first { $0.id == item.id })
                    XCTAssertEqual(item.points, original.points)
                    XCTAssertEqual(item.rawPathID, original.rawPathID)
                    XCTAssertEqual(item.mask, original.mask)
                }
            }
        }
    }

    func testAmbiguousAndStaleDualInkDisplaysNativeAndRefusesMutation() async throws {
        try await withStore {
            let valid = try webRecord(dual: true)
            let native = try valid.clusters[0].localDrawing()
            var stale = valid
            stale.clusters[0].strokes?[0].transform[4] += 10
            var missing = valid
            missing.clusters[0].strokes = []
            var ambiguous = valid
            var other = try XCTUnwrap(valid.clusters[0].strokes?.first)
            other.id = "another-id"
            ambiguous.clusters[0].strokes?.append(other)
            ambiguous.clusters[0].drawing = native.appending(native).dataRepresentation()
            var malformed = valid
            malformed.clusters[0].strokes = nil
            malformed.clusters[0].unreadableStrokes = .object(["future": .string("v4")])
            let key = WebLibrary.pageKey(valid.url)
            let url = WebInkStore.inkPath(forKey: key)
            for bad in [stale, missing, ambiguous, malformed] {
                try WebInkStore.writeRecord(bad, to: url)
                let bytes = try Data(contentsOf: url)
                let read = try XCTUnwrap(WebInkStore.loadRecordForExport(forKey: key))
                XCTAssertEqual(read, bad)
                XCTAssertEqual(try read.clusters[0].localDrawing().strokes.count,
                               try PKDrawing(data: XCTUnwrap(bad.clusters[0].drawing)).strokes.count)
                XCTAssertThrowsError(try read.validateForEditing())
                let next = WebInkRecord.snapshot(of: PKDrawing(), url: read.url, layout: read.layout)
                XCTAssertThrowsError(try WebInkStore.applySnapshot(next, replacing: read, forKey: key))
                var imported: WebInkRecord? = read
                XCTAssertThrowsError(try WebArchive.mergeInk(&imported, incoming: valid))
                XCTAssertEqual(imported, bad)
                XCTAssertEqual(try Data(contentsOf: url), bytes)
            }
            var pure = valid.clusters[0]
            pure.drawing = nil
            other.transform[4] += 20
            pure.strokes?.append(other)
            XCTAssertEqual(try pure.portableIndices(for: pure.localDrawing()), [0, 1])
        }
    }

    #if os(macOS)
    func testNavigatorSkipsBadCarriersAndKeepsNativeAndPortablePages() throws {
        let fixturePDF = try ClassicPdfFile(data: fixture("portable-partial", "pdf", in: "Ink"))
        let payload = try XCTUnwrap(fixturePDF.objectSource(7)?.textString(forKey: "VellumInkStrokes"))
        let attrs = ["/InkList [[1 2 3 4]]", "/VellumInkStrokes (bad)",
                     "/VellumInkStrokes (1)", "/VellumInkStrokes (\(payload))",
                     "/InkList [[1 2 3 4]] /VellumInkStrokes (bad)"]
        let pages = attrs.indices.map { "\(3 + $0) 0 R" }.joined(separator: " ")
        let objects = ["<< /Type /Catalog /Pages 2 0 R >>",
                       "<< /Type /Pages /Kids [\(pages)] /Count 5 >>"]
            + attrs.indices.map { "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 320 240] /Annots [\(8 + $0) 0 R] >>" }
            + attrs.map { "<< /Type /Annot /Subtype /Ink /Rect [0 0 320 240] \($0) >>" }
        XCTAssertEqual(try SavedHandwritingReader.pdfPages(data: PdfFixtureBuilder.classicObjects(objects),
                                                           password: nil), [1, 4, 5])
    }
    #endif

    #if os(iOS)
    @MainActor
    func testOverlayReadsIndependentCarriersAndLeavesUnrepresentedInkVisible() throws {
        let doc = try XCTUnwrap(PDFDocument(data: fixture("portable-partial", "pdf", in: "Ink")))
        let page = try XCTUnwrap(doc.page(at: 0))
        let original = try XCTUnwrap(page.annotations.first)
        let payload = try XCTUnwrap(original.value(forAnnotationKey: PdfInk.strokesKey) as? String)
        func add(_ value: String?, key: PDFAnnotationKey = PdfInk.strokesKey) -> PDFAnnotation {
            let annotation = PDFAnnotation(bounds: page.bounds(for: .cropBox), forType: .ink, withProperties: nil)
            if let value { annotation.setValue(value, forAnnotationKey: key) }
            page.addAnnotation(annotation)
            return annotation
        }
        let duplicate = add(payload)
        let shifted = add(try fixture("portable-shifted", "zlib", in: "Ink").base64EncodedString())
        let legacy = add(try nativeFixture("pdf-ink-marker").dataRepresentation().base64EncodedString(), key: PdfInk.dataKey)
        let invalid = add("bad")
        let orphan = add("1", key: PdfInk.dataKey)
        let foreign = add(nil)
        let view = PDFView()
        view.document = doc
        let controller = InkController_iOS()
        let overlay = try XCTUnwrap(controller.inkProvider.pdfView(view, overlayViewFor: page) as? InkOverlayContainer_iOS)
        XCTAssertTrue(overlay.canvas.portableInkReadOnly)
        XCTAssertEqual(overlay.canvas.drawing.strokes.count, 4)
        XCTAssertEqual(overlay.canvas.drawing.strokes.filter { $0.mask != nil }.count, 2)
        for carrier in [original, duplicate, shifted, legacy] { XCTAssertFalse(carrier.shouldDisplay) }
        for remaining in [invalid, orphan, foreign] { XCTAssertTrue(remaining.shouldDisplay) }
        controller.toolState.tool = .textHighlight
        controller.isActive = true
        XCTAssertFalse(overlay.canvas.isUserInteractionEnabled, "Text highlighting passes through to PDFKit")
    }

    @MainActor
    func testConflictingPDFPageKeepsLocalInkWhileOtherPageSaves() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("two-pages.pdf")
        let clean = PdfFixtureBuilder.makeClassicPdf(pages: [.init(), .init()])
        try clean.write(to: file)
        let app = AppStore(sessions: DocumentSessionManager())
        await app.openFile(path: file.path)
        let ink = InkController_iOS()
        ink.app = app
        let drawing = try nativeFixture("pdf-ink-marker")
        ink.drawingChanged(drawing, page: 1)
        ink.drawingChanged(drawing, page: 2)
        let payload = try fixture("portable-shifted", "zlib", in: "Ink").base64EncodedString()
        let changed = PdfFixtureBuilder.classicObjects([
            "<< /Type /Catalog /Pages 2 0 R >>", "<< /Type /Pages /Kids [3 0 R 4 0 R] /Count 2 >>",
            "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 320 240] /Annots [5 0 R] >>",
            "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 320 240] >>",
            "<< /Type /Annot /Subtype /Ink /Rect [0 0 320 240] /InkList [[10 20 30 40]] /VellumInkStrokes (\(payload)) >>"
        ])
        try changed.write(to: file)
        let complete = await ink.flushPendingInkAndWait()
        XCTAssertFalse(complete)
        XCTAssertTrue(app.error?.contains("(pages 1)") == true)
        let after = try XCTUnwrap(PDFDocument(url: file))
        let protected = try XCTUnwrap(after.page(at: 0)?.annotations.first)
        XCTAssertEqual(protected.value(forAnnotationKey: PdfInk.strokesKey) as? String, payload)
        XCTAssertEqual(PdfInk.drawing(on: try XCTUnwrap(after.page(at: 1)))?.strokes.count, 2)
        // Resolve the external conflict and replace page two's ink externally.
        // Retrying must write only the retained page-one draft.
        try clean.write(to: file)
        let retried = await ink.flushPendingInkAndWait()
        XCTAssertTrue(retried)
        let final = try XCTUnwrap(PDFDocument(url: file))
        XCTAssertEqual(PdfInk.drawing(on: try XCTUnwrap(final.page(at: 0)))?.strokes.count, 2)
        XCTAssertNil(PdfInk.drawing(on: try XCTUnwrap(final.page(at: 1))))
    }
    #endif

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
