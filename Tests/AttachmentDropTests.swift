import CoreText
import UIKit
import UniformTypeIdentifiers
import XCTest
@testable import Vellum

// Attachment-drop coverage, rebuilt for the iPad (#129 packet 5 §4).
//
// Main's version is `import AppKit` end to end: it builds a `FakeDraggingInfo`
// over a scratch `NSPasteboard` and drives the dragging overrides on
// `SubmitTextView` / `ComposerDropScrollView` / `TranscriptTextView`. None of
// those types — nor `NSDraggingInfo`, nor a writable scratch pasteboard — exists
// on iOS, where the same gesture arrives as `NSItemProvider`s through SwiftUI's
// `.onDrop` and `UIDropInteraction`. The pasteboard-fidelity fixtures and the
// `assertForwardsFinderDrop` harness are therefore dropped entirely (packet 9
// §4.2: "the FakeDraggingInfo/NSPasteboard harness has no iOS analogue").
//
// What is covered here instead, per packet 5 §4's rebuild recipe:
//   (a) `aiFileAttachment(from:)` classification over real temp files;
//   (b) `AiStore.nameList` string shapes;
//   (c) the four notice-copy contracts of `AiStore.attachFiles(at:)`, driven by
//       calling it directly with temp URLs — no drop harness needed;
//   (d) `AttachmentDrop.payload(for:)` / `payloads(for:)` / `carriesAttachment`
//       over real `NSItemProvider`s, which is the iOS payload seam.
//
// Live-drag ROUTING (which of the three registered destinations receives a drag
// that lands over a bubble) is not asserted here: on iOS that is UIKit's own
// hit-testing of a `UIDropInteraction`, with no protocol to fake. The iPad's
// drop path covers it — `SelectableTextView` installs/withdraws its interaction
// with the handler (`setAttachmentDropHandler`), and the panel registers
// `AttachmentDrop.draggedTypes` — and end-to-end routing is a manual check.
@MainActor
final class AttachmentDropTests: XCTestCase {

    private var fixtureDir: URL!

    override func setUp() async throws {
        fixtureDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("attachment-drop-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: fixtureDir, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: fixtureDir)
    }

    // MARK: File fixtures

    private func writeFixture(_ name: String, _ data: Data) throws -> URL {
        let url = fixtureDir.appendingPathComponent(name)
        try data.write(to: url)
        return url
    }

    /// A tiny valid PNG (4×4, opaque red), built in-process with the iPad's
    /// established bitmap pattern (`UIGraphicsImageRenderer`, scale pinned to 1
    /// so the pixel dimensions are the ones asked for).
    private func pngFixtureData() throws -> Data {
        let format = UIGraphicsImageRendererFormat.preferred()
        format.scale = 1
        format.opaque = true
        let image = UIGraphicsImageRenderer(size: CGSize(width: 4, height: 4), format: format)
            .image { context in
                UIColor.red.setFill()
                context.fill(CGRect(x: 0, y: 0, width: 4, height: 4))
            }
        return try XCTUnwrap(image.pngData())
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
                string: text, attributes: [.font: UIFont.systemFont(ofSize: 12)]))
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

    // MARK: - §1 AttachmentDrop payload detection (NSItemProvider)

    // ⚠️ REGRESSION GUARDS — DO NOT WEAKEN THESE THREE.
    //
    // The three `.files` assertions below were RED when this suite was first
    // written, and they caught a real iOS-only defect in `AttachmentDrop`.
    // Measured in the simulator: `loadItem(forTypeIdentifier: "public.file-url")`
    // resolves to neither `URL` nor `NSURL` but to `Data` holding a **binary
    // plist** (`bplist00…`, 284 bytes: the URL string plus its bookmark), so the
    // `case let data as Data: URL(dataRepresentation:relativeTo:)` branch — the
    // only branch that ever fired on iOS — yielded a URL whose last path
    // component was `notes.txtP\u{08}\u{0C}…`, i.e. the file name with the
    // bookmark bytes percent-escaped onto the end. Every such path is
    // unreachable, so `aiFileAttachment` returned nil and the user was told
    // their PNG was "a folder or unreadable" — packet 5 §5 risk 8's predicted
    // symptom, arriving through URL decoding rather than through security
    // scoping.
    //
    // Reproduced with both provider shapes a real drag can take
    // (`NSItemProvider(contentsOf:)` — the constructor packet 5 §4(d) names —
    // and `NSItemProvider(object: url as NSURL)`); both return the same plist
    // `Data`. Fixed in production, not here: `loadFileURL` now prefers
    // `provider.loadObject(ofClass: URL.self)`, and `fileURL(fromDropItem:)`
    // decodes the plist shape before falling back to `URL(dataRepresentation:)`.
    // The raw-`Data`-is-a-URL shape is still legitimate for other sources, and
    // `fileURL(fromDropItem:)` keeps its own coverage in §2 below.

    /// A drag out of Files, or a `.fileImporter` pick: the provider advertises
    /// `public.file-url` and the payload names the file without reading it.
    func testFileProviderYieldsFileURLPayload() async throws {
        let file = try writeFixture("notes.txt", Data("hello".utf8))
        let provider = try XCTUnwrap(NSItemProvider(contentsOf: file))
        XCTAssertTrue(AttachmentDrop.carriesAttachment(provider))
        guard case let .files(urls)? = await AttachmentDrop.payload(for: provider) else {
            return XCTFail("expected .files")
        }
        XCTAssertEqual(urls.map(\.standardizedFileURL.lastPathComponent), ["notes.txt"])
    }

    /// An image FILE advertises both identifiers. The file branch has to win, or
    /// the decline notices lose the filename they name the file by — and the
    /// security-scoped read in `attachFiles` never happens.
    func testImageFileProviderStillTakesTheFileBranch() async throws {
        let file = try writeFixture("photo.png", try pngFixtureData())
        let provider = try XCTUnwrap(NSItemProvider(contentsOf: file))
        XCTAssertTrue(provider.hasItemConformingToTypeIdentifier(UTType.image.identifier),
                      "fixture sanity: an image file also conforms to public.image")
        guard case let .files(urls)? = await AttachmentDrop.payload(for: provider) else {
            return XCTFail("expected .files for an image FILE, not raw bytes")
        }
        XCTAssertEqual(urls.map(\.standardizedFileURL.lastPathComponent), ["photo.png"])
    }

    /// Photos, or an image dragged out of a browser: raw bytes and no file URL.
    func testRawImageBytesProviderYieldsImageData() async throws {
        let png = try pngFixtureData()
        let provider = NSItemProvider(item: png as NSData, typeIdentifier: UTType.png.identifier)
        provider.suggestedName = "cat.png"
        XCTAssertTrue(AttachmentDrop.carriesAttachment(provider))
        guard case let .imageData(data, name)? = await AttachmentDrop.payload(for: provider) else {
            return XCTFail("expected .imageData")
        }
        XCTAssertEqual(data, png)
        XCTAssertEqual(name, "cat.png", "the drag's suggested name is what the chip is labelled with")
    }

    /// Nothing names a screenshot dragged out of Preview's thumbnail bar, so the
    /// chip needs a fallback rather than an empty label.
    func testRawImageBytesWithoutASuggestedNameGetAFallbackLabel() async throws {
        let png = try pngFixtureData()
        let provider = NSItemProvider(item: png as NSData, typeIdentifier: UTType.png.identifier)
        guard case let .imageData(_, name)? = await AttachmentDrop.payload(for: provider) else {
            return XCTFail("expected .imageData")
        }
        XCTAssertEqual(name, "Dropped image")
    }

    func testPlainTextProviderIsNotAnAttachment() async {
        let provider = NSItemProvider(
            item: "just some selected text" as NSString, typeIdentifier: UTType.plainText.identifier)
        XCTAssertFalse(AttachmentDrop.carriesAttachment(provider))
        let payload = await AttachmentDrop.payload(for: provider)
        XCTAssertNil(payload)
    }

    /// Regression guard: Files hands over a file URL and NOT an image, so
    /// `.image` alone never matches it. If `.fileURL` ever leaves `draggedTypes`
    /// the panel stops being offered Files drags at all, and every other
    /// assertion here still passes.
    func testDraggedTypesCoverFilesAndRawImageSources() {
        XCTAssertTrue(AttachmentDrop.draggedTypes.contains(.fileURL))
        XCTAssertTrue(AttachmentDrop.draggedTypes.contains(.image))
    }

    /// The batching contract (packet 5 §5 risk 7): a four-item mixed drop must
    /// coalesce into ONE `.files` payload — one notice naming the rejects — plus
    /// the raw-byte payloads, which each carry their own name and cannot be
    /// declined. macOS gets this free from `NSPasteboard.readObjects`; on iOS the
    /// providers arrive one per item, so the coalescing is explicit and testable.
    func testPayloadsCoalesceEveryFileIntoASingleFilesPayload() async throws {
        let png = try pngFixtureData()
        let providers = [
            try XCTUnwrap(NSItemProvider(contentsOf: try writeFixture("a.pdf", try pdfFixtureData(text: nil)))),
            try XCTUnwrap(NSItemProvider(contentsOf: try writeFixture("b.txt", Data("b".utf8)))),
            try XCTUnwrap(NSItemProvider(contentsOf: try writeFixture("c.png", png))),
            NSItemProvider(item: png as NSData, typeIdentifier: UTType.png.identifier),
        ]
        let payloads = await AttachmentDrop.payloads(for: providers)
        XCTAssertEqual(payloads.count, 2, "three files must arrive as one payload, got \(payloads)")
        guard case let .files(urls) = payloads.first else {
            return XCTFail("expected the coalesced .files payload first")
        }
        XCTAssertEqual(
            urls.map(\.lastPathComponent).sorted(), ["a.pdf", "b.txt", "c.png"])
        guard case .imageData = payloads.last else {
            return XCTFail("raw bytes must stay their own payload")
        }
    }

    // MARK: - §2 fileURL(fromDropItem:) — provider item decoding

    /// `loadItem` hands back whichever shape the drag source registered.
    func testFileURLFromDropItemAcceptsEveryRegisteredShape() throws {
        let url = try XCTUnwrap(URL(string: "file:///tmp/x.txt"))
        XCTAssertEqual(fileURL(fromDropItem: url as NSURL), url)
        XCTAssertEqual(fileURL(fromDropItem: url.dataRepresentation as NSData as Data as NSSecureCoding), url)
        XCTAssertNil(fileURL(fromDropItem: nil))
        XCTAssertNil(fileURL(fromDropItem: "not a url" as NSString))
    }

    // MARK: - §3 aiFileAttachment — classify (images-only policy)

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

    // MARK: - §4 AiStore.nameList

    func testNameListNamesTheFirstFileAndCountsTheRest() {
        XCTAssertEqual(AiStore.nameList([]), "")
        XCTAssertEqual(AiStore.nameList(["photo.png"]), "photo.png")
        XCTAssertEqual(AiStore.nameList(["photo.png", "doc.pdf"]), "photo.png and 1 more")
        XCTAssertEqual(AiStore.nameList(["photo.png", "doc.pdf", "notes.txt"]), "photo.png and 2 more")
    }

    // MARK: - §5 attachFiles — the notice copy

    /// A mixed drop must land its images AND explain the rest, in one notice.
    func testMixedDropAttachesTheImagesAndNamesTheRejects() async throws {
        let store = AiStore()
        let image = try writeFixture("photo.png", try pngFixtureData())
        let text = try writeFixture("notes.txt", Data("hello".utf8))
        store.attachFiles(at: [image, text])

        let notice = try await noticeText(on: store)
        XCTAssertEqual(notice, "Only image files can be attached. notes.txt wasn't added.")
        XCTAssertEqual(store.composerReferences.count, 1, "the image half of the drop must still land")
        guard case let .image(_, name)? = store.composerReferences.first?.kind else {
            return XCTFail("expected an image reference, got \(store.composerReferences)")
        }
        XCTAssertEqual(name, "photo.png")
        XCTAssertNil(store.error, "the attachment notice must not leak into the inline transcript error")
    }

    /// Plural verb, and the file that could not be reached at all is folded into
    /// the images-only notice rather than producing a second toast: the policy
    /// the user is bumping into takes precedence.
    func testImagesOnlyNoticeTakesPrecedenceAndPluralisesItsVerb() async throws {
        let store = AiStore()
        let text = try writeFixture("notes.txt", Data("hello".utf8))
        let pdf = try writeFixture("doc.pdf", try pdfFixtureData(text: nil))
        store.attachFiles(at: [text, pdf, fixtureDir])

        let notice = try await noticeText(on: store)
        XCTAssertEqual(notice, "Only image files can be attached. notes.txt and 1 more weren't added.")
        XCTAssertTrue(store.composerReferences.isEmpty)
    }

    /// A pure folder/unreadable drop gets its own message, in both numbers.
    func testFolderAndUnreadableDropsGetTheirOwnNotice() async throws {
        let singular = AiStore()
        singular.attachFiles(at: [fixtureDir])
        let singularNotice = try await noticeText(on: singular)
        XCTAssertEqual(
            singularNotice,
            "Couldn't attach \(fixtureDir.lastPathComponent). It's a folder or unreadable.")

        let plural = AiStore()
        plural.attachFiles(at: [fixtureDir, fixtureDir.appendingPathComponent("nope.txt")])
        let pluralNotice = try await noticeText(on: plural)
        XCTAssertEqual(
            pluralNotice,
            "Couldn't attach \(fixtureDir.lastPathComponent) and 1 more. "
                + "They're folders or unreadable.")
    }

    /// Showing an attachment notice sets it; re-showing replaces the text (and
    /// resets the auto-clear timer, since the prior task is cancelled); the ×
    /// button clears it immediately. The 15-second auto-clear itself is not
    /// waited on — that would make the suite flaky — it is left to live QA.
    func testAttachmentNoticeShowDismissReplace() {
        let store = AiStore()
        XCTAssertNil(store.attachmentNotice)

        store.showAttachmentNotice("first")
        XCTAssertEqual(store.attachmentNotice, "first")

        store.showAttachmentNotice("second")
        XCTAssertEqual(store.attachmentNotice, "second")

        store.dismissAttachmentNotice()
        XCTAssertNil(store.attachmentNotice)
    }

    /// `attachFiles` reads and classifies off the main actor, so the notice
    /// lands a few hops later. Polls rather than sleeping a fixed interval.
    private func noticeText(on store: AiStore, timeout: Duration = .seconds(5)) async throws -> String {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if let notice = store.attachmentNotice { return notice }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("no attachment notice within \(timeout)")
        return ""
    }
}
