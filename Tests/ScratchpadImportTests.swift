import AppKit
import XCTest
@testable import Vellum

// Coverage for the scratchpad image-import feature: the disk attachment store
// (save / resolve / GC), dropped-image normalization, and the store's
// snapshot/drop entry point that turns an image into note markdown.
//
// The UI gestures themselves — the drag-to-crop marquee and external file
// drop — are exercised out-of-process by ScratchpadSnapshotUITests (a UI-test
// target). Everything they funnel into is verified deterministically here.

@MainActor
final class ScratchpadImportTests: XCTestCase {
    private var tempDir: URL!

    override func setUp() async throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("vellum-scratch-attach-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        // Redirect the attachment store so tests never touch a real user's files.
        ScratchpadAttachmentStore.directoryOverride = tempDir
    }

    override func tearDown() async throws {
        ScratchpadAttachmentStore.directoryOverride = nil
        ScratchpadAttachmentStore.activeDirectory = nil
        if let tempDir { try? FileManager.default.removeItem(at: tempDir) }
    }

    // MARK: - Attachment store

    func testSaveThenResolveRoundTrips() throws {
        let bytes = Data([0x01, 0x02, 0x03, 0x04])
        let id = try XCTUnwrap(ScratchpadAttachmentStore.save(data: bytes, fileExtension: "jpg"))

        let url = try XCTUnwrap(ScratchpadAttachmentStore.fileURL(for: id))
        XCTAssertEqual(url.pathExtension, "jpg")
        XCTAssertEqual(try Data(contentsOf: url), bytes)
        // Ids are matched case-insensitively (URL hosts may be lowercased).
        XCTAssertNotNil(ScratchpadAttachmentStore.fileURL(for: id.uppercased()))
    }

    func testFileURLMissingIdIsNil() {
        XCTAssertNil(ScratchpadAttachmentStore.fileURL(for: "does-not-exist"))
        XCTAssertNil(ScratchpadAttachmentStore.fileURL(for: ""))
    }

    func testMediaTypeMapping() {
        XCTAssertEqual(ScratchpadAttachmentStore.mediaType(forExtension: "JPG"), "image/jpeg")
        XCTAssertEqual(ScratchpadAttachmentStore.mediaType(forExtension: "jpeg"), "image/jpeg")
        XCTAssertEqual(ScratchpadAttachmentStore.mediaType(forExtension: "png"), "image/png")
        XCTAssertEqual(ScratchpadAttachmentStore.mediaType(forExtension: "gif"), "image/gif")
        XCTAssertEqual(ScratchpadAttachmentStore.mediaType(forExtension: "xyz"), "application/octet-stream")
    }

    func testReferencedIdsExtractsFromMarkdown() {
        let a = "aaaaaaaa-1111-2222-3333-444444444444"
        let b = "bbbbbbbb-5555-6666-7777-888888888888"
        let note = """
        Notes here.

        ![Region · p.3](vellum-scratchpad://\(a))

        More text ![Image](vellum-scratchpad://\(b)) inline.
        """
        let ids = ScratchpadAttachmentStore.referencedIds(in: note)
        XCTAssertEqual(ids, [a, b])
        XCTAssertTrue(ScratchpadAttachmentStore.referencedIds(in: "no refs").isEmpty)
    }

    func testCollectGarbagePrunesOnlyOrphans() throws {
        let keep = try XCTUnwrap(ScratchpadAttachmentStore.save(data: Data([1]), fileExtension: "jpg"))
        let orphan = try XCTUnwrap(ScratchpadAttachmentStore.save(data: Data([2]), fileExtension: "png"))

        ScratchpadAttachmentStore.collectGarbage(in: tempDir, referencedIds: [keep])

        XCTAssertNotNil(ScratchpadAttachmentStore.fileURL(for: keep), "referenced attachment must survive")
        XCTAssertNil(ScratchpadAttachmentStore.fileURL(for: orphan), "unreferenced attachment must be pruned")
    }

    // MARK: - Dropped-image normalization (scratchpadCapture)

    func testCapturePreservesSmallPNG() throws {
        let data = try pngData(width: 40, height: 30)
        let capture = try XCTUnwrap(scratchpadCapture(from: data))
        XCTAssertEqual(capture.fileExtension, "png")
        XCTAssertEqual(capture.mediaType, "image/png")
        XCTAssertEqual(capture.width, 40)
        XCTAssertEqual(capture.height, 30)
        // A small PNG is kept verbatim.
        XCTAssertEqual(capture.data, data)
    }

    func testCapturePreservesSmallJPEG() throws {
        let data = try jpegData(width: 32, height: 32)
        let capture = try XCTUnwrap(scratchpadCapture(from: data))
        XCTAssertEqual(capture.fileExtension, "jpg")
        XCTAssertEqual(capture.mediaType, "image/jpeg")
    }

    func testCaptureDownscalesLargeImage() throws {
        // 3000px on the long side must be capped to 2000 and re-encoded.
        let data = try pngData(width: 3000, height: 1500)
        let capture = try XCTUnwrap(scratchpadCapture(from: data))
        XCTAssertLessThanOrEqual(max(capture.width, capture.height), 2000)
        XCTAssertEqual(capture.width, 2000)
        XCTAssertEqual(capture.height, 1000, "aspect ratio must be preserved")
    }

    func testCaptureRejectsNonImageData() {
        XCTAssertNil(scratchpadCapture(from: Data("not an image".utf8)))
    }

    // MARK: - Store entry point (addImage)

    func testAddImageWritesAttachmentAndInsertsMarkdown() throws {
        let store = ScratchpadStore()
        var inserted: String?
        store.insertMarkdownHandler = { inserted = $0 }

        let capture = ScratchpadImageCapture(
            data: Data([0xAA, 0xBB]), fileExtension: "jpg", mediaType: "image/jpeg",
            width: 10, height: 8, pageNumber: 3)
        store.addImage(capture, label: "Region · p.3")

        let markdown = try XCTUnwrap(inserted)
        // ![Region · p.3](vellum-scratchpad://<uuid>)
        let pattern = #"^!\[Region · p\.3\]\(vellum-scratchpad://([0-9a-f-]+)\)$"#
        let regex = try NSRegularExpression(pattern: pattern)
        let match = try XCTUnwrap(
            regex.firstMatch(in: markdown, range: NSRange(markdown.startIndex..., in: markdown)),
            "unexpected markdown: \(markdown)")
        let id = String(markdown[Range(match.range(at: 1), in: markdown)!])

        // The referenced attachment must exist on disk with the right bytes.
        let url = try XCTUnwrap(ScratchpadAttachmentStore.fileURL(for: id))
        XCTAssertEqual(try Data(contentsOf: url), capture.data)
    }

    func testAddImageSanitizesLabel() throws {
        let store = ScratchpadStore()
        var inserted: String?
        store.insertMarkdownHandler = { inserted = $0 }

        let capture = ScratchpadImageCapture(
            data: Data([1]), fileExtension: "png", mediaType: "image/png",
            width: 1, height: 1, pageNumber: nil)
        store.addImage(capture, label: "we]ird\nlabel")

        let markdown = try XCTUnwrap(inserted)
        // The `]` and newline must not leak into (and break) the alt text.
        XCTAssertFalse(markdown.contains("]e"), "unescaped ] leaked: \(markdown)")
        XCTAssertFalse(markdown.contains("\n"))
        XCTAssertTrue(markdown.hasPrefix("![we ird label]("))
    }

    func testWarnUnsupportedDropSetsMessage() {
        let store = ScratchpadStore()
        XCTAssertNil(store.dropWarning)
        store.warnUnsupportedDrop()
        XCTAssertNotNil(store.dropWarning, "a non-image drop should surface a warning")
        XCTAssertTrue(store.dropWarning?.localizedCaseInsensitiveContains("image") ?? false)
    }

    // MARK: - Helpers

    private func pngData(width: Int, height: Int) throws -> Data {
        let rep = try makeRep(width: width, height: height)
        return try XCTUnwrap(rep.representation(using: .png, properties: [:]))
    }

    private func jpegData(width: Int, height: Int) throws -> Data {
        let rep = try makeRep(width: width, height: height)
        return try XCTUnwrap(rep.representation(using: .jpeg, properties: [.compressionFactor: 0.9]))
    }

    /// A solid-color RGBA bitmap. Always 4-sample so a graphics context can be
    /// created headlessly (opaque 3-sample reps fail `NSGraphicsContext.init`);
    /// the encoding — PNG vs JPEG — is chosen by the callers above.
    private func makeRep(width: Int, height: Int) throws -> NSBitmapImageRep {
        let rep = try XCTUnwrap(NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
            isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        let ctx = try XCTUnwrap(NSGraphicsContext(bitmapImageRep: rep))
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = ctx
        NSColor.systemBlue.setFill()
        NSRect(x: 0, y: 0, width: width, height: height).fill()
        NSGraphicsContext.restoreGraphicsState()
        return rep
    }
}
