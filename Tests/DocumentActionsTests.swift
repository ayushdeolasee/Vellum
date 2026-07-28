import CoreGraphics
import CoreText
import PDFKit
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

    /// Retargeting keeps the tab live (issue #52 residency): the host stays
    /// mounted and `isActive` never changes, so the tab's runtime has to drop
    /// the document it parsed from the old location and bump the generation the
    /// viewer's load task keys on. Without this the viewer goes on rendering the
    /// file the user just saved *away* from.
    func testSaveAsInvalidatesLiveTabRuntimeSoTheMountedViewerReloads() async throws {
        let source = tempDirectory.appendingPathComponent("Live.pdf")
        makePDF(at: source, pages: 2)
        let destination = tempDirectory.appendingPathComponent("Live Copy.pdf")

        let workspace = WorkspaceStore(sessions: DocumentSessionManager())
        let pane = workspace.focusedPane
        await pane.app.openFile(path: source.path)
        let tabId = try XCTUnwrap(pane.app.activeTabId)

        // Stand in for the mounted viewer having parsed the old location.
        let runtime = workspace.liveTabRuntime(for: tabId)
        let parsed = try XCTUnwrap(PDFDocument(url: source))
        runtime.adoptPreparedPdf(parsed, byteCount: 4096)
        runtime.pdfLoadState = .loaded(parsed)
        let generationBefore = runtime.documentGeneration

        _ = try await pane.app.savePdfAs(tabId: tabId, destination: destination)

        XCTAssertNil(runtime.preparedDocument)
        XCTAssertGreaterThan(runtime.documentGeneration, generationBefore)
        guard case .idle = runtime.pdfLoadState else {
            return XCTFail("a retargeted tab must reload instead of keeping the old document")
        }
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
        XCTAssertEqual(Self.normalized(sourcePane.app.document?.pdfPath), Self.normalized(source.path))
        XCTAssertEqual(
            Self.normalized(workspace.focusedPane.app.document?.pdfPath),
            Self.normalized(destination.path))
    }

    func testSaveAsRollbackFailureClosesLastTabAndRetainsHomeError() async throws {
        let source = tempDirectory.appendingPathComponent("Original.pdf")
        let destination = tempDirectory.appendingPathComponent("Copy.pdf")
        makePDF(at: source, pages: 1)

        let sessions = StubSessionService()
        let sourceInfo = DocumentInfo(
            kind: .pdf, pdfPath: source.path, title: nil, pageCount: 1, lastPage: nil)
        var sourceOpenCount = 0
        sessions.openFileHandler = { path, _ in
            if path == source.path {
                sourceOpenCount += 1
                if sourceOpenCount == 1 { return sourceInfo }
                throw SessionServiceError.io("injected rollback failure")
            }
            XCTAssertEqual(path, destination.path)
            throw SessionServiceError.io("injected destination reopen failure")
        }
        sessions.pdfBytes = try Data(contentsOf: source)
        sessions.documentId = "test-save-as-id"

        let app = AppStore(sessions: sessions)
        await app.openFile(path: source.path)
        let tabId = try XCTUnwrap(app.activeTabId)

        do {
            _ = try await app.savePdfAs(tabId: tabId, destination: destination)
            XCTFail("the injected destination and rollback failures must escape")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("tab was closed"))
        }

        XCTAssertTrue(app.tabs.isEmpty)
        XCTAssertNil(app.document)
        XCTAssertTrue(app.error?.contains("tab was closed") == true)
    }

    /// A Keep Offline task must reject an in-tab navigation even though the
    /// session id is deliberately retained. The toolbar re-checks this exact
    /// identity after every await before succeeding or rolling back.
    func testWebActionIdentityRejectsSameSessionAfterNavigation() async throws {
        let firstURL = "https://example.com/first"
        let secondURL = "https://example.com/second"
        let sessions = StubSessionService()
        sessions.openWebDocumentHandler = { url, _ in
            DocumentInfo(
                kind: .web, pdfPath: url, title: nil, pageCount: 1,
                lastPage: nil, docId: "web-\(url)")
        }

        let app = AppStore(sessions: sessions)
        await app.openUrl(firstURL)
        let identity = try XCTUnwrap(app.activeWebDocumentActionIdentity())

        _ = await app.webNavigated(tabId: identity.sessionId, url: secondURL)

        XCTAssertEqual(app.activeTabId, identity.sessionId)
        XCTAssertEqual(app.document?.pdfPath, secondURL)
        XCTAssertFalse(app.isCurrentWebDocument(identity))
    }

    /// The session backend reports the filesystem's own path (/private/var/…)
    /// while `FileManager.temporaryDirectory` hands back the /var symlink form,
    /// and Foundation's standardization maps the former onto the latter. Compare
    /// both ends the same way so these assertions test retargeting rather than
    /// which spelling of the temp directory the OS happened to return.
    private static func normalized(_ path: String?) -> String? {
        guard let path else { return nil }
        return URL(fileURLWithPath: path).resolvingSymlinksInPath().path
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

/// Session-service seam for document-action failure paths. The production
/// manager is deliberately concrete; this lets the tests inject a reopen or
/// rollback failure without weakening its runtime behavior.
@MainActor
private final class StubSessionService: SessionService {
    var openFileHandler: ((String, String) throws -> DocumentInfo)?
    var openWebDocumentHandler: ((String, String) throws -> DocumentInfo)?
    var pdfBytes = Data()
    var documentId = "stub-document-id"

    func openFile(path: String, sessionId: String) async throws -> DocumentInfo {
        guard let openFileHandler else {
            throw SessionServiceError.io("unexpected openFile for \(path)")
        }
        return try openFileHandler(path, sessionId)
    }

    func openWebDocument(url: String, sessionId: String) async throws -> DocumentInfo {
        guard let openWebDocumentHandler else {
            throw SessionServiceError.io("unexpected openWebDocument for \(url)")
        }
        return try openWebDocumentHandler(url, sessionId)
    }

    func openVellumwebFile(path: String, sessionId: String) async throws -> DocumentInfo {
        throw SessionServiceError.io("unexpected openVellumwebFile for \(path)")
    }

    func saveFile(sessionId: String) async throws {}
    func closeFile(sessionId: String) async throws {}
    func readPdfBytes(sessionId: String) async throws -> Data { pdfBytes }

    func setWebpageSaved(sessionId: String, saved: Bool) async throws {}
    func getWebpageSaved(sessionId: String) async throws -> Bool { false }
    func listSavedWebpages() async throws -> [WebLibraryEntry] { [] }
    func removeSavedWebpage(url: String) async throws {}
    func exportVellumweb(
        sessionId: String, destPath: String, pages: [WebPageText]
    ) async throws -> VellumwebExportSummary {
        throw SessionServiceError.io("unexpected exportVellumweb")
    }
    func archiveWebpageDefault(
        sessionId: String, pages: [WebPageText], expectedUrl: String
    ) async throws -> Bool {
        throw SessionServiceError.io("unexpected archiveWebpageDefault")
    }

    func getAnnotations(sessionId: String, pageNumber: Int?) async throws -> [Annotation] { [] }
    func createAnnotation(sessionId: String, input: CreateAnnotationInput) async throws -> Annotation {
        throw SessionServiceError.io("unexpected createAnnotation")
    }
    func updateAnnotation(sessionId: String, input: UpdateAnnotationInput) async throws -> Bool { false }
    func deleteAnnotation(sessionId: String, id: String) async throws -> Bool { false }
    func setDocumentMetadata(sessionId: String, key: String, value: String) async throws {}
    func ensureDocumentId(sessionId: String) async throws -> String { documentId }
}
