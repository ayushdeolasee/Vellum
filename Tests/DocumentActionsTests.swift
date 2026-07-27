import CoreGraphics
import CoreText
import XCTest
@testable import Vellum

@MainActor
final class DocumentActionsTests: XCTestCase {
    private var tempDirectory: URL!

    override func setUp() async throws {
        tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("vellum-document-actions-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: tempDirectory, withIntermediateDirectories: true)
        PdfDocIdRegistry.reset()
    }

    override func tearDown() async throws {
        PdfDocIdRegistry.reset()
        if let tempDirectory {
            try? FileManager.default.removeItem(at: tempDirectory)
        }
    }

    func testSaveAsRetargetsExistingTabWithoutLosingWorkspaceState() async throws {
        let source = tempDirectory.appendingPathComponent("Original.pdf")
        makePDF(at: source, pages: 3)
        let destination = tempDirectory.appendingPathComponent("Retargeted.pdf")

        let workspace = WorkspaceStore(sessions: DocumentSessionManager())
        let originalPane = workspace.focusedPane
        await originalPane.app.openFile(path: source.path)
        let originalTabId = try XCTUnwrap(originalPane.app.activeTabId)
        originalPane.app.setCurrentPage(2)
        originalPane.app.setZoom(1.7)
        originalPane.app.setMode(.note)
        workspace.sidebarOpen = true
        workspace.sidebarTab = .ai

        // Keep this tab in a split so the test also guards its pane placement.
        workspace.splitFocused(.horizontal)
        XCTAssertNotNil(workspace.root.leaf(id: originalPane.id))

        let rebound = try await originalPane.app.savePdfAs(
            tabId: originalTabId, destination: destination)

        XCTAssertEqual(
            URL(fileURLWithPath: rebound.pdfPath).lastPathComponent,
            destination.lastPathComponent)
        XCTAssertEqual(originalPane.app.activeTabId, originalTabId)
        XCTAssertEqual(originalPane.app.tabs.count, 1)
        XCTAssertEqual(originalPane.app.tabs[0].id, originalTabId)
        XCTAssertEqual(originalPane.app.tabs[0].document?.pdfPath, rebound.pdfPath)
        XCTAssertEqual(originalPane.app.currentPage, 2)
        XCTAssertEqual(originalPane.app.zoom, 1.7, accuracy: 0.001)
        XCTAssertEqual(originalPane.app.mode, .note)
        XCTAssertNotNil(workspace.root.leaf(id: originalPane.id))
        XCTAssertEqual(workspace.root.allLeaves().count, 2)
        XCTAssertTrue(workspace.sidebarOpen)
        XCTAssertEqual(workspace.sidebarTab, .ai)
        XCTAssertTrue(FileManager.default.fileExists(atPath: source.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: destination.path))

        // Save As stamps and copies the stable id, which is what keeps
        // document-scoped conversation/scratchpad identity continuous.
        let sourceId = try XCTUnwrap(PdfMetadata.documentId(atPath: source.path))
        let destinationId = try XCTUnwrap(PdfMetadata.documentId(atPath: destination.path))
        XCTAssertEqual(destinationId, sourceId)
        XCTAssertEqual(rebound.docId, sourceId)
    }

    func testSaveAsToSamePathIsANoOp() async throws {
        let source = tempDirectory.appendingPathComponent("Same.pdf")
        makePDF(at: source, pages: 1)
        let app = AppStore(sessions: DocumentSessionManager())
        await app.openFile(path: source.path)
        let tabId = try XCTUnwrap(app.activeTabId)
        let original = try XCTUnwrap(app.document)

        let result = try await app.savePdfAs(tabId: tabId, destination: source)

        XCTAssertEqual(result, original)
        XCTAssertEqual(app.activeTabId, tabId)
        XCTAssertEqual(app.tabs.count, 1)
        XCTAssertNil(app.document?.docId, "a no-op must not stamp or rewrite the PDF")
        XCTAssertNil(PdfMetadata.documentId(atPath: source.path))
    }

    func testSaveAsStampsReadOnlySourceFallbackIdentityIntoWritableCopy() async throws {
        let lockedDirectory = tempDirectory.appendingPathComponent("read-only", isDirectory: true)
        try FileManager.default.createDirectory(at: lockedDirectory, withIntermediateDirectories: true)
        let source = lockedDirectory.appendingPathComponent("Original.pdf")
        makePDF(at: source, pages: 1)
        let sourceBytes = try Data(contentsOf: source)
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: lockedDirectory.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: lockedDirectory.path) }
        let destination = tempDirectory.appendingPathComponent("Writable Copy.pdf")

        let app = AppStore(sessions: DocumentSessionManager())
        await app.openFile(path: source.path)
        let tabId = try XCTUnwrap(app.activeTabId)

        let rebound = try await app.savePdfAs(tabId: tabId, destination: destination)

        let fallback = DocumentIdentity.byteHash(sourceBytes)
        XCTAssertEqual(PdfMetadata.documentId(atPath: source.path), nil)
        XCTAssertEqual(PdfMetadata.documentId(atPath: destination.path), fallback)
        XCTAssertEqual(rebound.docId, fallback)
    }

    func testSaveAsRefusesDestinationAlreadyOpenInAnotherPane() async throws {
        let source = tempDirectory.appendingPathComponent("Source.pdf")
        let destination = tempDirectory.appendingPathComponent("Open Elsewhere.pdf")
        makePDF(at: source, pages: 1)
        makePDF(at: destination, pages: 1)

        let workspace = WorkspaceStore(sessions: DocumentSessionManager())
        let sourcePane = workspace.focusedPane
        await sourcePane.app.openFile(path: source.path)
        let sourceTab = try XCTUnwrap(sourcePane.app.activeTabId)
        workspace.splitFocused(.horizontal)
        await workspace.focusedPane.app.openFile(path: destination.path)

        do {
            _ = try await sourcePane.app.savePdfAs(tabId: sourceTab, destination: destination)
            XCTFail("Save As must not retarget onto another open tab")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("already open"))
        }
        XCTAssertEqual(sourcePane.app.document?.pdfPath, source.path)
        XCTAssertEqual(workspace.focusedPane.app.document?.pdfPath, destination.path)
    }

    private func makePDF(at url: URL, pages: Int) {
        var mediaBox = CGRect(x: 0, y: 0, width: 612, height: 792)
        let context = CGContext(url as CFURL, mediaBox: &mediaBox, nil)!
        for page in 1...pages {
            context.beginPDFPage(nil)
            let font = CTFontCreateWithName("Helvetica" as CFString, 24, nil)
            let attributes = [kCTFontAttributeName: font] as CFDictionary
            let attributed = CFAttributedStringCreate(
                nil, "Page \(page)" as CFString, attributes)!
            let line = CTLineCreateWithAttributedString(attributed)
            context.textPosition = CGPoint(x: 72, y: 700)
            CTLineDraw(line, context)
            context.endPDFPage()
        }
        context.closePDF()
    }
}
