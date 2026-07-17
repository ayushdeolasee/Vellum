import AppKit
import PDFKit
import UniformTypeIdentifiers
import XCTest
@testable import Vellum

// Drag-and-drop attachment harness. A real drop is just AppKit calling the
// dragging overrides with an `NSDraggingInfo` — and that's a protocol, so the
// whole pipeline short of the OS drag session is exercised here with a fake
// backed by a real scratch `NSPasteboard`:
//
//   pasteboard fixture (per source app) → AttachmentDrop.carriesAttachment /
//   .payload → the real view overrides (SubmitTextView / ComposerDropScrollView
//   / TranscriptTextView) → forwarded AttachmentDropPayload → aiFileAttachment
//   classification and reading.
//
// Not covered (needs a real drag session): AppKit's routing of a live drag to
// whichever registered view sits under the cursor. The registration half of
// that is asserted here via `registeredDraggedTypes`; the routing itself is a
// manual / UI-test check.
//
// FIDELITY RULE for new fixtures: a fixture must write the pasteboard the way
// the real source app does, not the way that makes the test pass. If a drop
// from some app misbehaves, log `sender.draggingPasteboard.types` in
// `performDragOperation`, do one manual drag from that app, and freeze what it
// printed as a new style below.

// MARK: - Fake dragging info

/// The minimal `NSDraggingInfo` the drop code touches, backed by a real
/// pasteboard so `readObjects` / `canReadObject` / UTType conformance run for
/// real. Everything else is inert stubs.
final class FakeDraggingInfo: NSObject, NSDraggingInfo {
    let pasteboard: NSPasteboard
    /// Where the drag sits, in the destination view's window coordinates.
    /// SwiftUI's `.onDrop` reads this to place the drop; the AppKit-view tests
    /// leave it at `.zero` (they call the overrides directly), while the sidebar
    /// routing test sets it so the drag lands over the AI panel.
    var location: NSPoint
    init(pasteboard: NSPasteboard, location: NSPoint = .zero) {
        self.pasteboard = pasteboard
        self.location = location
    }

    var draggingPasteboard: NSPasteboard { pasteboard }
    var draggingDestinationWindow: NSWindow? { nil }
    var draggingSourceOperationMask: NSDragOperation { .copy }
    var draggingLocation: NSPoint { location }
    var draggedImageLocation: NSPoint { .zero }
    var draggedImage: NSImage? { nil }
    var draggingSource: Any? { nil }
    var draggingSequenceNumber: Int { 0 }
    var draggingFormation: NSDraggingFormation = .default
    var animatesToDestination: Bool = false
    var numberOfValidItemsForDrop: Int = 0
    var springLoadingHighlight: NSSpringLoadingHighlight { .none }
    func slideDraggedImage(to screenPoint: NSPoint) {}
    func resetSpringLoading() {}

    /// SwiftUI's `_PlatformDraggingDestinationView.performDragOperation` builds
    /// its `[NSItemProvider]` by enumerating dragging items. AppKit's real
    /// implementation yields one item per matching pasteboard object; mirror
    /// that so the sidebar's real `.onDrop` closure receives providers instead
    /// of an empty list. (The AppKit-view tests never call this — they read the
    /// pasteboard directly through `AttachmentDrop`.)
    func enumerateDraggingItems(
        options enumOpts: NSDraggingItemEnumerationOptions = [],
        for view: NSView?,
        classes classArray: [AnyClass],
        searchOptions: [NSPasteboard.ReadingOptionKey: Any] = [:],
        using block: @escaping (NSDraggingItem, Int, UnsafeMutablePointer<ObjCBool>) -> Void
    ) {
        let objects = pasteboard.readObjects(forClasses: classArray, options: searchOptions) ?? []
        var stop = ObjCBool(false)
        for (index, object) in objects.enumerated() {
            guard let writer = object as? NSPasteboardWriting else { continue }
            let item = NSDraggingItem(pasteboardWriter: writer)
            block(item, index, &stop)
            if stop.boolValue { return }
        }
    }
}

@MainActor
final class AttachmentDropTests: XCTestCase {

    private var scratchPasteboards: [NSPasteboard] = []
    private var fixtureDir: URL!

    override func setUp() async throws {
        fixtureDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("attachment-drop-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: fixtureDir, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        // Scratch pasteboards are process-global until released; leaking one per
        // test would accumulate across the whole suite run.
        for pasteboard in scratchPasteboards { pasteboard.releaseGlobally() }
        scratchPasteboards = []
        try? FileManager.default.removeItem(at: fixtureDir)
    }

    // MARK: Pasteboard fixtures — one per real-world drag source

    private func scratchPasteboard() -> NSPasteboard {
        let pasteboard = NSPasteboard(name: .init("vellum-drop-test-\(UUID().uuidString)"))
        pasteboard.clearContents()
        scratchPasteboards.append(pasteboard)
        return pasteboard
    }

    /// Finder: file URLs written as pasteboard objects (`public.file-url`).
    private func finderDrag(of urls: [URL]) -> FakeDraggingInfo {
        let pasteboard = scratchPasteboard()
        XCTAssertTrue(pasteboard.writeObjects(urls as [NSURL]), "fixture sanity")
        return FakeDraggingInfo(pasteboard: pasteboard)
    }

    /// Preview / screenshot thumbnail: raw image bytes, no file URL.
    private func imageBytesDrag(_ data: Data, type: NSPasteboard.PasteboardType) -> FakeDraggingInfo {
        let pasteboard = scratchPasteboard()
        pasteboard.setData(data, forType: type)
        return FakeDraggingInfo(pasteboard: pasteboard)
    }

    /// Browser image drag: the image's remote URL plus rendered bitmap bytes.
    private func browserImageDrag(pageURL: URL, imageData: Data) -> FakeDraggingInfo {
        let pasteboard = scratchPasteboard()
        XCTAssertTrue(pasteboard.writeObjects([pageURL as NSURL]), "fixture sanity")
        pasteboard.setData(imageData, forType: .tiff)
        return FakeDraggingInfo(pasteboard: pasteboard)
    }

    /// Plain text drag (e.g. selected text from another app) — must fall through.
    private func textDrag(_ text: String) -> FakeDraggingInfo {
        let pasteboard = scratchPasteboard()
        pasteboard.setString(text, forType: .string)
        return FakeDraggingInfo(pasteboard: pasteboard)
    }

    // MARK: File fixtures

    private func writeFixture(_ name: String, _ data: Data) throws -> URL {
        let url = fixtureDir.appendingPathComponent(name)
        try data.write(to: url)
        return url
    }

    /// A tiny valid PNG (4×4, opaque red), built in-process.
    private func pngFixtureData() throws -> Data {
        let rep = try XCTUnwrap(NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: 4, pixelsHigh: 4,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
            isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        let context = try XCTUnwrap(NSGraphicsContext(bitmapImageRep: rep))
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        NSColor.red.setFill()
        NSRect(x: 0, y: 0, width: 4, height: 4).fill()
        NSGraphicsContext.restoreGraphicsState()
        return try XCTUnwrap(rep.representation(using: .png, properties: [:]))
    }

    /// A one-page PDF; with `text` nil the page is blank (no extractable text).
    private func pdfFixtureData(text: String?) throws -> Data {
        let data = NSMutableData()
        var mediaBox = CGRect(x: 0, y: 0, width: 200, height: 200)
        let consumer = try XCTUnwrap(CGDataConsumer(data: data as CFMutableData))
        let context = try XCTUnwrap(CGContext(consumer: consumer, mediaBox: &mediaBox, nil))
        context.beginPDFPage(nil)
        if let text {
            let line = CTLineCreateWithAttributedString(NSAttributedString(
                string: text, attributes: [.font: NSFont.systemFont(ofSize: 12)]))
            context.textPosition = CGPoint(x: 20, y: 100)
            CTLineDraw(line, context)
        }
        context.endPDFPage()
        context.closePDF()
        return data as Data
    }

    /// Bytes that are not valid UTF-8 no matter where a prefix cap lands.
    private var binaryFixtureData: Data {
        Data([0xFF, 0xFE, 0xFD, 0x00, 0x80, 0x81] + Array(repeating: 0xFF, count: 64))
    }

    // MARK: - §1 AttachmentDrop payload detection

    func testFinderFileDragCarriesAttachmentAndYieldsFileURLs() throws {
        let file = try writeFixture("notes.txt", Data("hello".utf8))
        let drag = finderDrag(of: [file])
        XCTAssertTrue(AttachmentDrop.carriesAttachment(drag))
        guard case let .files(urls)? = AttachmentDrop.payload(drag) else {
            return XCTFail("expected .files, got \(String(describing: AttachmentDrop.payload(drag)))")
        }
        XCTAssertEqual(urls.map(\.standardizedFileURL), [file.standardizedFileURL])
    }

    func testFinderMultiFileDragYieldsAllURLs() throws {
        let a = try writeFixture("a.txt", Data("a".utf8))
        let b = try writeFixture("b.png", try pngFixtureData())
        let drag = finderDrag(of: [a, b])
        guard case let .files(urls)? = AttachmentDrop.payload(drag) else {
            return XCTFail("expected .files")
        }
        XCTAssertEqual(urls.count, 2)
    }

    func testRawImageBytesDragYieldsImageData() throws {
        let png = try pngFixtureData()
        let drag = imageBytesDrag(png, type: .png)
        XCTAssertTrue(AttachmentDrop.carriesAttachment(drag))
        guard case let .imageData(data, _)? = AttachmentDrop.payload(drag) else {
            return XCTFail("expected .imageData")
        }
        XCTAssertEqual(data, png)
    }

    /// A browser image drag offers both a (non-file) URL and bitmap bytes; the
    /// URL must not be mistaken for a file, and the bytes must win.
    func testBrowserImageDragFallsThroughToImageData() throws {
        let tiff = try XCTUnwrap(NSBitmapImageRep(data: try pngFixtureData())?.tiffRepresentation)
        let drag = browserImageDrag(
            pageURL: try XCTUnwrap(URL(string: "https://example.com/cat.png")),
            imageData: tiff)
        XCTAssertTrue(AttachmentDrop.carriesAttachment(drag))
        guard case let .imageData(data, _)? = AttachmentDrop.payload(drag) else {
            return XCTFail("expected .imageData")
        }
        XCTAssertEqual(data, tiff)
    }

    func testPlainTextDragIsNotAnAttachment() {
        let drag = textDrag("just some selected text")
        XCTAssertFalse(AttachmentDrop.carriesAttachment(drag))
        XCTAssertNil(AttachmentDrop.payload(drag))
    }

    func testNonFileURLAloneIsNotAnAttachment() throws {
        let pasteboard = scratchPasteboard()
        XCTAssertTrue(pasteboard.writeObjects(
            [try XCTUnwrap(URL(string: "https://example.com")) as NSURL]))
        let drag = FakeDraggingInfo(pasteboard: pasteboard)
        XCTAssertFalse(AttachmentDrop.carriesAttachment(drag))
        XCTAssertNil(AttachmentDrop.payload(drag))
    }

    /// Regression guard: Finder offers `public.file-url` — if it ever leaves
    /// `draggedTypes`, views stop being offered Finder drags at all and every
    /// other assertion here still passes.
    func testDraggedTypesCoverFinderAndRawImageSources() {
        XCTAssertTrue(AttachmentDrop.draggedTypes.contains(.fileURL))
        XCTAssertTrue(AttachmentDrop.draggedTypes.contains(.png))
        XCTAssertTrue(AttachmentDrop.draggedTypes.contains(.tiff))
    }

    // MARK: - §2 fileURL(fromDropItem:) — provider item decoding

    func testFileURLFromDropItemAcceptsEveryRegisteredShape() throws {
        let url = try XCTUnwrap(URL(string: "file:///tmp/x.txt"))
        XCTAssertEqual(fileURL(fromDropItem: url as NSURL), url)
        XCTAssertEqual(fileURL(fromDropItem: url.dataRepresentation as NSData as Data as NSSecureCoding), url)
        XCTAssertNil(fileURL(fromDropItem: nil))
        XCTAssertNil(fileURL(fromDropItem: "not a url" as NSString))
    }

    // MARK: - §3 View integration — the real dragging overrides

    private func assertForwardsFinderDrop<V: NSView>(
        _ view: V,
        install: (V, @escaping (AttachmentDropPayload) -> Void, @escaping (Bool) -> Void) -> Void
    ) throws {
        let file = try writeFixture("dropped.txt", Data("payload".utf8))
        var received: AttachmentDropPayload?
        var targeted: [Bool] = []
        install(view, { received = $0 }, { targeted.append($0) })

        // Registration is what makes AppKit offer the drag at all.
        let registered = Set(view.registeredDraggedTypes)
        for type in AttachmentDrop.draggedTypes {
            XCTAssertTrue(registered.contains(type), "missing registration for \(type.rawValue)")
        }

        let drag = finderDrag(of: [file])
        XCTAssertEqual(view.draggingEntered(drag), .copy)
        XCTAssertEqual(targeted.last, true, "hover must arm the drop outline")
        XCTAssertTrue(view.performDragOperation(drag))
        XCTAssertEqual(targeted.last, false, "drop must clear the outline")
        guard case let .files(urls)? = received else {
            return XCTFail("payload was not forwarded: \(String(describing: received))")
        }
        XCTAssertEqual(urls.map(\.standardizedFileURL), [file.standardizedFileURL])
    }

    func testComposerTextViewForwardsFinderDrop() throws {
        try assertForwardsFinderDrop(SubmitTextView()) { view, onDrop, onTargeted in
            view.onAttachmentDrop = onDrop
            view.onDropTargeted = onTargeted
            // No didSet on this one — production calls it from makeNSView, and
            // AppKit re-runs it whenever editability flips (see the override's
            // doc comment). The test must go through the same funnel.
            view.updateDragTypeRegistration()
        }
    }

    func testComposerScrollViewForwardsFinderDrop() throws {
        try assertForwardsFinderDrop(ComposerDropScrollView()) { view, onDrop, onTargeted in
            view.onAttachmentDrop = onDrop
            view.onDropTargeted = onTargeted
        }
    }

    func testTranscriptTextViewForwardsFinderDrop() throws {
        try assertForwardsFinderDrop(TranscriptTextView()) { view, onDrop, onTargeted in
            view.onAttachmentDrop = onDrop
            view.onDropTargeted = onTargeted
        }
    }

    func testTranscriptTextViewForwardsRawImageBytes() throws {
        let view = TranscriptTextView()
        var received: AttachmentDropPayload?
        view.onAttachmentDrop = { received = $0 }
        let png = try pngFixtureData()
        XCTAssertTrue(view.performDragOperation(imageBytesDrag(png, type: .png)))
        guard case let .imageData(data, _)? = received else {
            return XCTFail("expected .imageData")
        }
        XCTAssertEqual(data, png)
    }

    /// Negative routing, asserted on TranscriptTextView because its non-match
    /// paths return without calling `super` — the composer views fall through to
    /// AppKit's own handlers there, which expect a real drag session, so their
    /// fall-through legs are deliberately not driven with a fake.
    func testTranscriptTextViewIgnoresTextDragsAndUnwiredDrops() throws {
        let view = TranscriptTextView()
        var received: AttachmentDropPayload?
        view.onAttachmentDrop = { received = $0 }

        let text = textDrag("selection")
        XCTAssertEqual(view.draggingEntered(text), [])
        XCTAssertEqual(view.draggingUpdated(text), [])
        XCTAssertFalse(view.performDragOperation(text))
        XCTAssertNil(received)

        // nil handler = tab not visible: registration must be withdrawn so
        // AppKit never offers the drag to a stale view.
        view.onAttachmentDrop = nil
        XCTAssertTrue(view.registeredDraggedTypes.isEmpty)
    }

    // MARK: - §4 aiFileAttachment — classify (images-only policy)

    func testImageFileBecomesImageSnapshot() throws {
        let url = try writeFixture("photo.png", try pngFixtureData())
        guard case let .image(snapshot, name)? = aiFileAttachment(from: url) else {
            return XCTFail("expected .image")
        }
        XCTAssertEqual(name, "photo.png")
        XCTAssertFalse(snapshot.base64Data.isEmpty)
    }

    func testCorruptImageFileIsRejectedByName() throws {
        // Image by extension, garbage by content: the decoder rejects it, so
        // the file is declined by name — never attached as a text placeholder.
        let url = try writeFixture("broken.png", binaryFixtureData)
        guard case let .rejected(name)? = aiFileAttachment(from: url) else {
            return XCTFail("expected .rejected")
        }
        XCTAssertEqual(name, "broken.png")
    }

    func testPdfFileIsRejectedByName() throws {
        // Even a PDF with extractable text is not an image, so it is declined.
        let url = try writeFixture("doc.pdf", try pdfFixtureData(text: "vellum pdf fixture"))
        guard case let .rejected(name)? = aiFileAttachment(from: url) else {
            return XCTFail("expected .rejected")
        }
        XCTAssertEqual(name, "doc.pdf")
    }

    func testTextFileIsRejectedByName() throws {
        let url = try writeFixture("readme.md", Data("# Heading\n\ncontent — émoji ✅".utf8))
        guard case let .rejected(name)? = aiFileAttachment(from: url) else {
            return XCTFail("expected .rejected")
        }
        XCTAssertEqual(name, "readme.md")
    }

    func testExtensionlessTextFileIsRejectedByName() throws {
        let url = try writeFixture("Makefile", Data("all:\n\techo hi\n".utf8))
        guard case let .rejected(name)? = aiFileAttachment(from: url) else {
            return XCTFail("expected .rejected")
        }
        XCTAssertEqual(name, "Makefile")
    }

    func testBinaryFileIsRejectedByName() throws {
        let url = try writeFixture("blob.bin", binaryFixtureData)
        guard case let .rejected(name)? = aiFileAttachment(from: url) else {
            return XCTFail("expected .rejected")
        }
        XCTAssertEqual(name, "blob.bin")
    }

    func testDirectoryAndMissingFileReturnNil() throws {
        XCTAssertNil(aiFileAttachment(from: fixtureDir))
        XCTAssertNil(aiFileAttachment(from: fixtureDir.appendingPathComponent("nope.txt")))
    }
}
