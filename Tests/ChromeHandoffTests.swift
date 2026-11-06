#if os(macOS)
import CoreGraphics
import Foundation
import Testing

@testable import Vellum

@Suite("Chrome document handoff", .serialized, .isolatedStorage)
struct ChromeHandoffTests {
    @Test(
        "PDF MIME types, extensions and download filenames use the PDF pipeline",
        arguments: [
            ("/download", "application/pdf", "inline; filename=Report.pdf"),
            ("/Report.PDF?token=abc", "application/octet-stream", ""),
            ("/download", "application/octet-stream", "attachment; filename=Report.pdf"),
        ])
    func downloadsPDF(path: String, mime: String, disposition: String) async throws {
        let bytes = pdfData()
        let session = responseSession(mime: mime, disposition: disposition, data: bytes)
        defer {
            session.invalidateAndCancel()
            ChromeDownloadProtocol.handler = nil
        }
        let url = URL(string: "https://example.test\(path)")!
        let file = try #require(await IncomingPDFDownload.download(url, session: session))
        #expect(file.pathExtension == "pdf")
        #expect(try Data(contentsOf: file) == bytes)
        await IncomingPDFDownload.remove(file.deletingLastPathComponent())
        #expect(!FileManager.default.fileExists(atPath: file.path))
    }

    @Test(
        "HTML pages, including PDF-named login pages, stay web documents",
        arguments: [
            ("/article?q=swift#notes", "text/html"),
            ("/Report.pdf", "text/html"),
            ("/download", "application/octet-stream"),
        ])
    func keepsWebpages(path: String, mime: String) async throws {
        let before = try stagingDirectories()
        let session = responseSession(mime: mime, data: Data("<html>Article</html>".utf8))
        defer {
            session.invalidateAndCancel()
            ChromeDownloadProtocol.handler = nil
        }
        let result = try await IncomingPDFDownload.download(
            URL(string: "https://example.test\(path)")!, session: session)
        #expect(result == nil)
        #expect(try stagingDirectories() == before)
    }

    @Test(
        "Failed, invalid and oversized PDF downloads leave no temporary files",
        arguments: [
            (404, false, 1_000_000), (200, true, 1_000_000), (200, false, 1),
        ])
    func failedDownload(status: Int, corrupt: Bool, limit: Int) async throws {
        let before = try stagingDirectories()
        let session = responseSession(
            mime: "application/pdf", status: status,
            data: corrupt ? Data("not a PDF".utf8) : pdfData())
        defer {
            session.invalidateAndCancel()
            ChromeDownloadProtocol.handler = nil
        }
        await #expect(throws: (any Error).self) {
            try await IncomingPDFDownload.download(
                URL(string: "https://example.test/report.pdf")!, session: session, maximumBytes: limit)
        }
        #expect(try stagingDirectories() == before)
    }

    @Test("Cancellation cleans up; an offline webpage still reaches the existing reader")
    func cancelledAndOffline() async throws {
        let before = try stagingDirectories()
        for code in [URLError.Code.cancelled, .notConnectedToInternet] {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.protocolClasses = [ChromeDownloadProtocol.self]
            ChromeDownloadProtocol.handler = { _ in throw URLError(code) }
            let session = URLSession(configuration: configuration)
            do {
                if code == .cancelled {
                    await #expect(throws: (any Error).self) {
                        try await IncomingPDFDownload.download(
                            URL(string: "https://example.test/article")!, session: session)
                    }
                } else {
                    let result = try await IncomingPDFDownload.download(
                        URL(string: "https://example.test/article")!, session: session)
                    #expect(result == nil)
                }
                #expect(try stagingDirectories() == before)
            }
            session.invalidateAndCancel()
            ChromeDownloadProtocol.handler = nil
        }
    }

    @Test("The shared downloader still accepts non-PDF responses by default")
    func defaultDownloader() async throws {
        let root = try scratchDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let bytes = Data("an integration payload".utf8)
        let session = responseSession(mime: "application/octet-stream", data: bytes)
        defer {
            session.invalidateAndCancel()
            ChromeDownloadProtocol.handler = nil
        }
        let destination = root.appendingPathComponent("payload")
        _ = try await IntegrationDownloadClient(session: session).download(
            URLRequest(url: URL(string: "https://example.test/payload")!),
            to: destination, maximumBytes: 1_000
        ) { _ in }
        #expect(try Data(contentsOf: destination) == bytes)
    }

    @Test("The byte cap also applies without a Content-Length header")
    func streamedByteLimit() async throws {
        let before = try stagingDirectories()
        let session = responseSession(mime: "application/pdf", data: pdfData(), contentLength: false)
        defer {
            session.invalidateAndCancel()
            ChromeDownloadProtocol.handler = nil
        }
        await #expect(throws: IntegrationError.downloadTooLarge) {
            try await IncomingPDFDownload.download(
                URL(string: "https://example.test/large.pdf")!, session: session, maximumBytes: 1)
        }
        #expect(try stagingDirectories() == before)
    }

    @Test(
        "Navigation anchors do not change canonical annotation identity",
        arguments: [
            "https://example.test/article?q=swift&sort=new#notes",
            "https://example.test/article?q=swift#section%202",
            "https://example.test/article#:~:text=reader",
            "https://example.test/article#",
        ])
    @MainActor
    func fragmentIdentity(address: String) async throws {
        _ = try #require(TestEnvironment.storageRoot)
        let url = URL(string: address)!
        let route = try #require(VellumExternalWebLink.url(for: url))
        let parsed = try #require(VellumExternalWebLink.parse(route))
        let session = try await WebSessionBackend().openWebDocument(
            url: parsed.absoluteString, sessionId: UUID().uuidString, replacing: nil)
        #expect(session.info.webNavigationURL == address)
        let canonical = try WebUrl.normalize(address)
        #expect(session.info.pdfPath == canonical)
        #expect(session.info.docId == WebLibrary.pageKey(canonical))
        #expect(!session.info.pdfPath.contains("#"))
        #expect(
            VellumWebSchemeHandler.realUrl(
                from: VellumWebSchemeHandler.proxyUrl(for: address)) == address)
    }

    @Test("Mixed browser deliveries import PDFs durably and retain webpage anchors")
    @MainActor
    func mixedDelivery() async throws {
        let root = try scratchDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let staging = root.appendingPathComponent("staging")
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        let incoming = staging.appendingPathComponent("Report.pdf")
        try pdfData().write(to: incoming)
        let registry = TabTeardownRegistry()
        let app = makeApp(root: root, registry: registry)
        app.incomingPDFDownload = { url in url.pathExtension == "pdf" ? incoming : nil }
        let webpage = URL(string: "https://example.test/\(UUID().uuidString)?q=swift#notes")!
        let pdf = URL(string: "https://example.test/report.pdf?token=abc")!
        await app.openIncomingURLs([
            VellumExternalWebLink.url(for: pdf)!, VellumExternalWebLink.url(for: webpage)!,
        ])
        #expect(app.error == nil)
        #expect(!app.isLoading)
        #expect(app.tabs.compactMap { $0.document?.kind } == [.pdf, .web])
        let imported = try #require(app.tabs.first?.document)
        #expect(
            imported.pdfPath
                == (try PdfDocumentLoader.canonicalize(
                    root.appendingPathComponent("library/Report.pdf").path)))
        #expect(FileManager.default.fileExists(atPath: imported.pdfPath))
        #expect(!FileManager.default.fileExists(atPath: staging.path))
        #expect(app.document?.webNavigationURL == webpage.absoluteString)
        let tabId = try #require(app.activeTabId)
        let nextAddress = webpage.absoluteString.replacingOccurrences(of: "#notes", with: "#chapter2")
        await app.openIncomingURLs([VellumExternalWebLink.url(for: URL(string: nextAddress)!)!])
        #expect(app.tabs.count == 2)
        #expect(app.activeTabId == tabId)
        #expect(app.document?.webNavigationURL == nextAddress)
        for tab in app.tabs { await app.closeTab(tab.id) }
        await registry.awaitAll()
        // A fresh session must still open the native PDF after staging has gone.
        let sessions = DocumentSessionManager()
        let reopened = try await sessions.openFile(path: imported.pdfPath, sessionId: "reopened")
        #expect(reopened.kind == .pdf)
        try await sessions.closeFile(sessionId: "reopened")
    }

    @Test("A failed PDF does not prevent a following webpage from opening")
    @MainActor
    func partialFailure() async throws {
        let root = try scratchDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let registry = TabTeardownRegistry()
        let app = makeApp(root: root, registry: registry)
        app.incomingPDFDownload = { url in
            if url.pathExtension == "pdf" { throw URLError(.badServerResponse) }
            return nil
        }
        let webpage = URL(string: "https://example.test/\(UUID().uuidString)#notes")!
        await app.openIncomingURLs([
            VellumExternalWebLink.url(for: URL(string: "https://example.test/report.pdf")!)!,
            VellumExternalWebLink.url(for: webpage)!,
        ])
        #expect(app.error?.contains("report.pdf") == true)
        #expect(!app.isLoading)
        #expect(app.tabs.compactMap { $0.document?.kind } == [.web])
        #expect(app.document?.webNavigationURL == webpage.absoluteString)
        for tab in app.tabs { await app.closeTab(tab.id) }
        await registry.awaitAll()
    }

    @MainActor
    private func makeApp(root: URL, registry: TabTeardownRegistry) -> AppStore {
        AppStore(
            sessions: DocumentSessionManager(), teardowns: registry,
            documentAccess: DocumentAccessResolver(
                store: DocumentAccessBookmarkStore(directory: root.appendingPathComponent("bookmarks")),
                adapter: SystemDocumentAccessAdapter(),
                libraryDirectory: { root.appendingPathComponent("library") }))
    }

    private func scratchDirectory() throws -> URL {
        _ = try #require(TestEnvironment.storageRoot)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func stagingDirectories() throws -> Set<String> {
        Set(
            try FileManager.default.contentsOfDirectory(
                atPath: FileManager.default.temporaryDirectory.path
            ).filter { $0.hasPrefix("vellum-incoming-") })
    }

    private func responseSession(
        mime: String, status: Int = 200, disposition: String = "", data: Data,
        contentLength: Bool = true
    ) -> URLSession {
        ChromeDownloadProtocol.handler = { request in
            var headers = ["Content-Type": mime, "Content-Disposition": disposition]
            if contentLength { headers["Content-Length"] = String(data.count) }
            let response = HTTPURLResponse(
                url: request.url!, statusCode: status,
                httpVersion: "HTTP/1.1", headerFields: headers)!
            return (response, data)
        }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ChromeDownloadProtocol.self]
        return URLSession(configuration: configuration)
    }

    private func pdfData() -> Data {
        let data = NSMutableData()
        var box = CGRect(x: 0, y: 0, width: 612, height: 792)
        let consumer = CGDataConsumer(data: data)!
        let context = CGContext(consumer: consumer, mediaBox: &box, nil)!
        context.beginPDFPage(nil)
        context.endPDFPage()
        context.closePDF()
        return data as Data
    }
}

private final class ChromeDownloadProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var handler: (@Sendable (URLRequest) throws -> (HTTPURLResponse, Data))?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        do {
            let (response, data) = try Self.handler!(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }
    override func stopLoading() {}
}
#endif
