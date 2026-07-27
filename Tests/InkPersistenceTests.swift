#if os(iOS)
import PDFKit
import PencilKit
import UIKit
import XCTest
@testable import Vellum

/// Round-trips Apple Pencil ink through the PDF: PKDrawing → native `/Ink`
/// annotations (+ embedded PKDrawing) → write to data → reload → decode.
final class InkPersistenceTests: XCTestCase {
    /// A one-page US-Letter PDF to annotate.
    private func blankPage() throws -> (PDFDocument, PDFPage) {
        let bounds = CGRect(x: 0, y: 0, width: 612, height: 792)
        let renderer = UIGraphicsPDFRenderer(bounds: bounds)
        let data: Data = renderer.pdfData { ctx in
            ctx.beginPage()
            let fill: UIColor = .white
            fill.setFill()
            UIRectFill(bounds)
        }
        let document = try XCTUnwrap(PDFDocument(data: data))
        let page = try XCTUnwrap(document.page(at: 0))
        return (document, page)
    }

    /// A multi-page US-Letter PDF, written to `url`.
    private func writeBlankDocument(pageCount: Int, to url: URL) throws {
        let bounds = CGRect(x: 0, y: 0, width: 612, height: 792)
        let renderer = UIGraphicsPDFRenderer(bounds: bounds)
        let data: Data = renderer.pdfData { ctx in
            for _ in 0..<pageCount {
                ctx.beginPage()
                UIColor.white.setFill()
                UIRectFill(bounds)
            }
        }
        try data.write(to: url)
    }

    private func sampleDrawing() -> PKDrawing {
        var points: [PKStrokePoint] = []
        for i in 0..<10 {
            let x = CGFloat(100 + i * 20)
            let y = CGFloat(200 + (i % 3) * 5)
            let location = CGPoint(x: x, y: y)
            let size = CGSize(width: 4, height: 4)
            let point = PKStrokePoint(
                location: location,
                timeOffset: TimeInterval(i) * 0.01,
                size: size,
                opacity: 1,
                force: 1,
                azimuth: 0,
                altitude: CGFloat.pi / 2)
            points.append(point)
        }
        let path = PKStrokePath(controlPoints: points, creationDate: Date(timeIntervalSince1970: 0))
        let stroke = PKStroke(ink: PKInk(.pen, color: .systemIndigo), path: path)
        return PKDrawing(strokes: [stroke])
    }

    @MainActor
    func testInkApplyAddsNativeAndEmbeddedData() throws {
        let (_, page) = try blankPage()
        XCTAssertFalse(PdfInk.hasInk(on: page))

        PdfInk.apply(sampleDrawing(), to: page)

        XCTAssertTrue(PdfInk.hasInk(on: page), "native ink annotation added")
        let inkAnnotations = page.annotations.filter { PdfInk.isVellumInk($0) }
        XCTAssertFalse(inkAnnotations.isEmpty)
        XCTAssertTrue(
            inkAnnotations.allSatisfy { $0.type == "Ink" || $0.type == "/Ink" },
            "annotations are native PDF ink")
        XCTAssertNotNil(PdfInk.drawing(on: page), "embedded PKDrawing decodes")
    }

    @MainActor
    func testInkSurvivesWriteAndReload() throws {
        let (document, page) = try blankPage()
        let original = sampleDrawing()
        PdfInk.apply(original, to: page)

        let written = try XCTUnwrap(document.dataRepresentation(), "serialize PDF with ink")
        let reloaded = try XCTUnwrap(PDFDocument(data: written), "reparse written PDF")
        let reloadedPage = try XCTUnwrap(reloaded.page(at: 0))

        XCTAssertTrue(PdfInk.hasInk(on: reloadedPage), "ink present after round-trip")
        let decoded = try XCTUnwrap(PdfInk.drawing(on: reloadedPage), "PKDrawing survives round-trip")
        XCTAssertEqual(decoded.strokes.count, original.strokes.count)
    }

    @MainActor
    func testApplyEmptyDrawingClearsInk() throws {
        let (_, page) = try blankPage()
        PdfInk.apply(sampleDrawing(), to: page)
        XCTAssertTrue(PdfInk.hasInk(on: page))

        PdfInk.apply(PKDrawing(), to: page)
        XCTAssertFalse(PdfInk.hasInk(on: page), "clearing removes Vellum ink")
    }

    /// A stroke fully erased with the bitmap eraser keeps a mask that excludes
    /// its whole path. Re-create that shape directly and pin down the trap this
    /// guards against: `renderBounds` still reports the mask's bounds (never
    /// empty), so only `maskedPathRanges` can tell the stroke no longer renders.
    private func fullyErasedStroke() -> PKStroke {
        let base = sampleDrawing().strokes[0]
        // A mask nowhere near the path: nothing of the stroke is kept.
        let mask = UIBezierPath(rect: CGRect(x: 5000, y: 5000, width: 1, height: 1))
        return PKStroke(ink: base.ink, path: base.path, transform: base.transform, mask: mask)
    }

    @MainActor
    func testFullyErasedStrokeIsNotVisibleInk() throws {
        let erased = fullyErasedStroke()
        XCTAssertFalse(
            erased.renderBounds.isEmpty,
            "precondition: renderBounds cannot detect a fully erased stroke — "
                + "if this ever fails, PencilKit changed and this suite should be revisited")
        XCTAssertFalse(PdfInk.strokeHasVisibleInk(erased))

        // A page whose only strokes are fully erased must not read as inked,
        // and must not write native ink back to the PDF (which would resurrect
        // the erased stroke on reload and keep the sidebar chip alive).
        let (_, page) = try blankPage()
        PdfInk.apply(PKDrawing(strokes: [erased]), to: page)
        XCTAssertFalse(PdfInk.hasInk(on: page), "fully erased page reads as un-inked")
        XCTAssertTrue(page.annotations.filter { PdfInk.isVellumInk($0) }.isEmpty)
    }

    @MainActor
    func testPartiallyErasedStrokeStillCountsAsInk() throws {
        let base = sampleDrawing().strokes[0]
        // Keep roughly the left half of the stroke (its x span is 100...280).
        let mask = UIBezierPath(rect: CGRect(x: 0, y: 0, width: 190, height: 792))
        let half = PKStroke(ink: base.ink, path: base.path, transform: base.transform, mask: mask)
        XCTAssertTrue(PdfInk.strokeHasVisibleInk(half))

        let (_, page) = try blankPage()
        PdfInk.apply(PKDrawing(strokes: [half]), to: page)
        XCTAssertTrue(PdfInk.hasInk(on: page), "partially erased stroke is still ink")
    }

    @MainActor
    func testUnmaskedStrokeIsVisibleInk() {
        XCTAssertTrue(PdfInk.strokeHasVisibleInk(sampleDrawing().strokes[0]))
    }

    /// The latent lost-update race: an Apple Pencil ink write and an annotation
    /// write to the SAME file are both full read-modify-writes. Routed through
    /// the shared `PdfFileGate` they serialize, so whichever runs second sees
    /// the other's changes on disk. Fire both concurrently and require BOTH the
    /// note annotation and the ink to survive.
    @MainActor
    func testConcurrentInkAndAnnotationWritesBothSurvive() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("vellum-ink-race-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let url = dir.appendingPathComponent("race.pdf")
        let (document, _) = try blankPage()
        try XCTUnwrap(document.dataRepresentation()).write(to: url)

        let session = try await PdfSessionBackend().open(path: url.path, sessionId: UUID().uuidString)

        let inkDrawing = sampleDrawing()
        let inkPath = url.path

        // Run the two writers concurrently against the same file.
        async let annotation: Annotation = session.createAnnotation(CreateAnnotationInput(
            type: .note,
            pageNumber: 1,
            color: nil,
            content: "race note",
            positionData: PositionData(
                rects: [AnnotationRect(x: 300, y: 400, width: 0, height: 0)],
                pageWidth: 612, pageHeight: 792, selectedText: nil,
                startOffset: nil, endOffset: nil, prefix: nil, suffix: nil, viewportOffset: nil)))

        // Exercise the production writer, including the iPadOS 26 main-actor
        // PDFKit compatibility path and the shared non-reentrant file gate.
        async let inkDone: Void = InkDiskWriter().write(
            drawings: [1: inkDrawing], path: inkPath)

        let created = try await annotation
        _ = await inkDone

        // Reload from disk: BOTH writes must have survived.
        let reloaded = try await PdfSessionBackend().open(path: url.path, sessionId: UUID().uuidString)
        let annotations = try await reloaded.annotations(pageNumber: nil)
        let note = try XCTUnwrap(
            annotations.first { $0.id == created.id }, "annotation write was lost")
        XCTAssertEqual(note.content, "race note")

        let finalDoc = try XCTUnwrap(PDFDocument(url: url))
        let finalPage = try XCTUnwrap(finalDoc.page(at: 0))
        XCTAssertTrue(PdfInk.hasInk(on: finalPage), "ink write was lost")
    }

    /// On iPadOS 26, a full PDFKit rewrite drops application-defined keys.
    /// The production ink writer must restore the metadata of annotations that
    /// already belong to Vellum while adding the native ink annotation.
    @MainActor
    func testInkWritePreservesVellumAnnotationMetadata() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("vellum-ink-metadata-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let url = dir.appendingPathComponent("metadata.pdf")
        let (document, _) = try blankPage()
        try XCTUnwrap(document.dataRepresentation()).write(to: url)
        let session = try await PdfSessionBackend().open(
            path: url.path,
            sessionId: UUID().uuidString)
        let created = try await session.createAnnotation(CreateAnnotationInput(
            type: .note,
            pageNumber: 1,
            color: nil,
            content: "metadata note",
            positionData: PositionData(
                rects: [AnnotationRect(x: 300, y: 400, width: 0, height: 0)],
                pageWidth: 612, pageHeight: 792, selectedText: nil,
                startOffset: nil, endOffset: nil, prefix: nil, suffix: nil,
                viewportOffset: nil)))

        await InkDiskWriter().write(drawings: [1: sampleDrawing()], path: url.path)

        let reloaded = try await PdfSessionBackend().open(
            path: url.path,
            sessionId: UUID().uuidString)
        let annotations = try await reloaded.annotations(pageNumber: nil)
        let note = try XCTUnwrap(annotations.first { $0.id == created.id })
        XCTAssertEqual(note.createdAt, created.createdAt)
        XCTAssertEqual(note.updatedAt, created.updatedAt)

        let raw = try PdfDocumentLoader.loadRaw(path: url.path)
        let pageDictionary = try XCTUnwrap(raw.page(at: 1)?.dictionary)
        let entries = try XCTUnwrap(CgPdf.array(pageDictionary, "Annots"))
        let rawNote = try XCTUnwrap((0..<CgPdf.count(entries)).compactMap {
            CgPdf.dictionaryAt(entries, $0)
        }.first { CgPdf.string($0, "NM") == created.id })
        XCTAssertEqual(CgPdf.string(rawNote, "T"), "Vellum")
        XCTAssertEqual(CgPdf.string(rawNote, "VellumCreatedAt"), created.createdAt)
        XCTAssertEqual(CgPdf.string(rawNote, "VellumUpdatedAt"), created.updatedAt)
    }

    /// Turning ink mode off starts an immediate retained flush; a scene
    /// background callback that follows must be able to join that same task and
    /// return only after the latest drawing is on disk.
    @MainActor
    func testImmediateInkFlushCanBeJoinedByBackgroundFlush() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("vellum-ink-background-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let url = dir.appendingPathComponent("background.pdf")
        let (document, _) = try blankPage()
        try XCTUnwrap(document.dataRepresentation()).write(to: url)

        let app = AppStore(sessions: DocumentSessionManager())
        await app.openFile(path: url.path)
        let controller = InkController_iOS()
        controller.app = app
        controller.drawingChanged(sampleDrawing(), page: 1)

        controller.flushPendingInk()
        await controller.flushPendingInkAndWait()

        let reloaded = try XCTUnwrap(PDFDocument(url: url))
        let page = try XCTUnwrap(reloaded.page(at: 0))
        XCTAssertTrue(PdfInk.hasInk(on: page))
    }

    /// Every dirty page is folded into ONE read-modify-write of the PDF. A
    /// per-page loop re-read, re-parsed, re-serialized and rewrote the whole
    /// file once per page, which on a large document was the app's single
    /// biggest energy cost while taking notes.
    @MainActor
    func testBatchedWriteAppliesInkToEveryDirtyPage() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("vellum-ink-batch-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let url = dir.appendingPathComponent("batch.pdf")
        try writeBlankDocument(pageCount: 3, to: url)

        await InkDiskWriter().write(
            drawings: [1: sampleDrawing(), 3: sampleDrawing()],
            path: url.path)

        let reloaded = try XCTUnwrap(PDFDocument(url: url))
        XCTAssertEqual(reloaded.pageCount, 3)
        XCTAssertTrue(PdfInk.hasInk(on: try XCTUnwrap(reloaded.page(at: 0))), "page 1 ink")
        XCTAssertFalse(PdfInk.hasInk(on: try XCTUnwrap(reloaded.page(at: 1))), "page 2 untouched")
        XCTAssertTrue(PdfInk.hasInk(on: try XCTUnwrap(reloaded.page(at: 2))), "page 3 ink")
    }

    /// An out-of-range page must not discard the pages that ARE valid — the
    /// batch writer applies what it can rather than bailing on the whole file.
    @MainActor
    func testBatchedWriteSkipsOutOfRangePagesWithoutLosingValidOnes() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("vellum-ink-range-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let url = dir.appendingPathComponent("range.pdf")
        try writeBlankDocument(pageCount: 2, to: url)

        await InkDiskWriter().write(
            drawings: [1: sampleDrawing(), 99: sampleDrawing()],
            path: url.path)

        let reloaded = try XCTUnwrap(PDFDocument(url: url))
        XCTAssertTrue(PdfInk.hasInk(on: try XCTUnwrap(reloaded.page(at: 0))))
    }

    /// Inking two pages inside one debounce window must persist both. The
    /// controller now keeps a single coalesced batch rather than a task per
    /// page, so this pins down that neither page is dropped.
    @MainActor
    func testFlushPersistsEveryPageDirtiedInOneWindow() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("vellum-ink-multipage-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let url = dir.appendingPathComponent("multipage.pdf")
        try writeBlankDocument(pageCount: 2, to: url)

        let app = AppStore(sessions: DocumentSessionManager())
        await app.openFile(path: url.path)
        let controller = InkController_iOS()
        controller.app = app
        controller.drawingChanged(sampleDrawing(), page: 1)
        controller.drawingChanged(sampleDrawing(), page: 2)

        await controller.flushPendingInkAndWait()

        let reloaded = try XCTUnwrap(PDFDocument(url: url))
        XCTAssertTrue(PdfInk.hasInk(on: try XCTUnwrap(reloaded.page(at: 0))), "page 1 ink")
        XCTAssertTrue(PdfInk.hasInk(on: try XCTUnwrap(reloaded.page(at: 1))), "page 2 ink")
    }

    /// The last drawing wins: a page re-inked before the debounce elapses must
    /// persist its newest state, not the one that was pending first.
    @MainActor
    func testLatestDrawingForAPageWins() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("vellum-ink-latest-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let url = dir.appendingPathComponent("latest.pdf")
        try writeBlankDocument(pageCount: 1, to: url)

        let app = AppStore(sessions: DocumentSessionManager())
        await app.openFile(path: url.path)
        let controller = InkController_iOS()
        controller.app = app
        // Ink, then erase it all again inside the same debounce window.
        controller.drawingChanged(sampleDrawing(), page: 1)
        controller.drawingChanged(PKDrawing(), page: 1)

        await controller.flushPendingInkAndWait()

        let reloaded = try XCTUnwrap(PDFDocument(url: url))
        let page = try XCTUnwrap(reloaded.page(at: 0))
        XCTAssertFalse(PdfInk.hasInk(on: page), "the empty drawing was the newest state")
    }
}
#endif
