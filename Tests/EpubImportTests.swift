import Foundation
import Testing
@testable import Vellum

@Suite("EPUB import and download detection", .serialized)
struct EpubImportTests {
    private let directory: URL

    init() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("vellum-epub-import-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    private var library: URL { directory.appendingPathComponent("Books") }

    // MARK: - Library admission

    @Test("Import copies into Books/<docId>/ and reuses identical bytes")
    func importDedupes() throws {
        let first = try EpubFixture.epub3().write(to: directory.appendingPathComponent("a.epub"))
        let second = try EpubFixture.epub3().write(to: directory.appendingPathComponent("copy.epub"))
        let docId = try EpubIdentity.contentDocId(fileAt: first)

        let managed = try EpubLibrary.importBook(at: first, into: library)
        #expect(managed.deletingLastPathComponent().lastPathComponent == docId)
        #expect(managed.lastPathComponent == "a.epub")
        #expect(try EpubIdentity.contentDocId(fileAt: managed) == docId)
        #expect(try EpubLibrary.importBook(at: second, into: library).path == managed.path)
        #expect(try EpubLibrary.importBook(at: managed, into: library).path == managed.path)

        let edition = try EpubFixture.epub3(title: "Second").write(to: directory.appendingPathComponent("a2.epub"))
        #expect(try EpubLibrary.importBook(at: edition, into: library).path != managed.path)
    }

    @Test("Invalid books are never admitted")
    func invalidRejected() throws {
        var zip = EpubFixture.epub3()
        zip.items.removeAll { $0.path == EpubPackageParser.containerPath }
        let source = try zip.write(to: directory.appendingPathComponent("broken.epub"))
        #expect(throws: EpubError.missingContainer) { try EpubLibrary.importBook(at: source, into: library) }
        let admitted = (try? FileManager.default.contentsOfDirectory(atPath: library.path)) ?? []
        #expect(admitted.isEmpty)
    }

    @Test("Library filenames are a single safe component")
    func filenames() {
        #expect(EpubLibrary.filename(preferred: "My Book.EPUB", title: nil) == "My Book.epub")
        #expect(EpubLibrary.filename(preferred: "../../x:y.epub", title: nil) == "x y.epub")
        #expect(EpubLibrary.filename(preferred: "download", title: nil) == "download.epub")
        #expect(EpubLibrary.filename(preferred: "..", title: "Title") == "Title.epub")
        #expect(EpubLibrary.filename(preferred: nil, title: nil) == "Book.epub")
    }

    // MARK: - Routing helpers

    @Test("Drops accept EPUB files")
    func dropSupport() {
        #expect(HomeDrop.isSupported(URL(fileURLWithPath: "/tmp/a.epub")))
        #expect(HomeDrop.isSupported(URL(fileURLWithPath: "/tmp/a.PDF")))
        #expect(!HomeDrop.isSupported(URL(fileURLWithPath: "/tmp/a.zip")))
    }

    @Test("Response classification")
    func verdicts() {
        let page = URL(string: "https://example.com/book")!
        let file = URL(string: "https://example.com/book.epub")!
        #expect(EpubDownload.verdict(contentType: "application/epub+zip; charset=binary", filename: nil, url: page) == .epub)
        #expect(EpubDownload.verdict(contentType: "application/octet-stream", filename: "b.epub", url: page) == .epub)
        #expect(EpubDownload.verdict(contentType: "text/html", filename: nil, url: file) == .notEpub)
        #expect(EpubDownload.verdict(contentType: nil, filename: nil, url: file) == .epub)
        #expect(EpubDownload.verdict(contentType: "application/octet-stream", filename: nil, url: page) == .maybe)
        #expect(EpubDownload.verdict(contentType: "application/pdf", filename: nil, url: page) == .notEpub)
    }

    @Test("Content-Disposition filenames")
    func dispositions() {
        #expect(EpubDownload.filename(contentDisposition: #"attachment; filename="My Book.epub""#) == "My Book.epub")
        #expect(EpubDownload.filename(contentDisposition: "attachment; filename*=UTF-8''Caf%C3%A9.epub") == "Café.epub")
        #expect(EpubDownload.filename(contentDisposition: "inline") == nil)
    }

    @Test("OCF signature sniffing")
    func signature() throws {
        let book = EpubFixture.epub3().archiveData()
        #expect(EpubDownload.hasEpubSignature(book))
        #expect(!EpubDownload.hasEpubSignature(Data("<html></html>".utf8)))
        #expect(!EpubDownload.hasEpubSignature(Data(book.prefix(40))))
    }

    // MARK: - Downloads

    private func session(_ responses: [String: EpubStubProtocol.Response]) -> URLSession {
        EpubStubProtocol.responses = responses
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [EpubStubProtocol.self]
        return URLSession(configuration: config)
    }

    @Test("A suffixless octet-stream book downloads; a webpage does not")
    func downloads() async throws {
        let book = EpubFixture.epub3().archiveData()
        let session = session([
            "https://example.com/get?id=1": .init(type: "application/octet-stream", body: book),
            "https://example.com/article": .init(type: "text/html", body: Data("<html/>".utf8)),
            "https://example.com/data.zip": .init(type: "application/zip", body: Data(repeating: 1, count: 100)),
        ])
        let outcome = try await EpubDownload.fetch(
            URL(string: "https://example.com/get?id=1")!, into: directory, session: session)
        guard case .downloaded(let file, _) = outcome else {
            Issue.record("expected a download, got \(outcome)")
            return
        }
        #expect(try Data(contentsOf: file) == book)
        #expect(try await EpubDownload.fetch(URL(string: "https://example.com/article")!,
                                             into: directory, session: session) == .notEpub)
        #expect(try await EpubDownload.fetch(URL(string: "https://example.com/data.zip")!,
                                             into: directory, session: session) == .notEpub)
    }

    @Test("Oversized books fail with a useful message and leave nothing behind")
    func oversized() async throws {
        let book = EpubFixture.epub3().archiveData()
        let session = session(["https://example.com/b.epub": .init(type: "application/epub+zip", body: book)])
        await #expect(throws: SessionServiceError.self) {
            try await EpubDownload.fetch(URL(string: "https://example.com/b.epub")!,
                                         into: directory, session: session, maxBytes: 100)
        }
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: directory.path)
            .filter { $0.hasPrefix("vellum-download-") }
        #expect(leftovers.isEmpty)
    }
}

final class EpubStubProtocol: URLProtocol {
    struct Response: Sendable {
        var type: String
        var body: Data
    }

    nonisolated(unsafe) static var responses: [String: Response] = [:]

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url, let stub = Self.responses[url.absoluteString] else {
            client?.urlProtocol(self, didFailWithError: URLError(.fileDoesNotExist))
            return
        }
        let response = HTTPURLResponse(
            url: url, statusCode: 200, httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": stub.type, "Content-Length": "\(stub.body.count)"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: stub.body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
