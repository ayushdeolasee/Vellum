import Foundation
import Testing
@testable import Vellum

@Suite("EPUB package loading and identity", .serialized)
struct EpubPackageTests {
    private let directory: URL

    init() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("vellum-epub-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    private func write(_ zip: ZipFixture, name: String = "book.epub") throws -> URL {
        try zip.write(to: directory.appendingPathComponent(name))
    }

    private func load(_ zip: ZipFixture, limits: EpubContainer.Limits = .standard) throws -> EpubBook {
        try EpubBook.load(path: write(zip).path, limits: limits)
    }

    private func expectFailure(_ expected: EpubError, _ zip: ZipFixture,
                               limits: EpubContainer.Limits = .standard,
                               sourceLocation: SourceLocation = #_sourceLocation) throws {
        #expect(throws: expected, sourceLocation: sourceLocation) {
            try load(zip, limits: limits)
        }
    }

    // MARK: - Parsing

    @Test("EPUB 3 metadata, spine, cover and nav table of contents")
    func epub3() throws {
        let publication = try load(EpubFixture.epub3()).publication
        #expect(publication.version == "3.0")
        #expect(publication.packagePath == "OEBPS/content.opf")
        #expect(publication.metadata.title == "Sample Book")
        #expect(publication.metadata.creators == ["Ada Writer", "Bo Editor"])
        #expect(publication.metadata.language == "en")
        #expect(publication.metadata.identifier == "urn:uuid:1234")
        #expect(publication.metadata.publisher == "Vellum Press")
        #expect(publication.coverPath == "images/cover.png")
        #expect(publication.spine.map(\.path) == [
            "OEBPS/text/chapter 1.xhtml", "OEBPS/text/notes.xhtml",
            "OEBPS/text/chapter2.xhtml", "OEBPS/text/chapter3.xhtml",
        ])
        #expect(publication.spine.map(\.linear) == [true, false, true, true])
        #expect(publication.spine[3].idref == "dtb")
        #expect(publication.manifest.contains { $0.id == "remote" } == false)

        let toc = publication.toc
        #expect(toc.map(\.title) == ["Part\u{00A0}One — Start", "Appendix"])
        #expect(toc[0].path == "OEBPS/text/chapter 1.xhtml")
        #expect(toc[0].children.first?.title == "Section © Two")
        #expect(toc[0].children.first?.path == "OEBPS/text/chapter2.xhtml")
        #expect(toc[0].children.first?.fragment == "sec")
        #expect(toc[1].path == nil)
        #expect(toc[1].children.map(\.path) == ["OEBPS/text/chapter3.xhtml"])
    }

    @Test("EPUB 2 NCX navigation and meta cover")
    func epub2() throws {
        let publication = try load(EpubFixture.epub2()).publication
        #expect(publication.metadata.title == "Old Book")
        #expect(publication.metadata.creators == ["Cy Author"])
        #expect(publication.coverPath == "OEBPS/cover.jpg")
        #expect(publication.spine.map(\.path) == ["OEBPS/a.html", "OEBPS/b.html"])
        #expect(publication.toc.map(\.title) == ["First", "Second"])
        #expect(publication.toc[0].children.first?.fragment == "inner")
    }

    @Test("A broken table of contents falls back to reading order only")
    func brokenNavigation() throws {
        var zip = EpubFixture.epub3()
        zip.items.removeAll { $0.path == "OEBPS/nav.xhtml" }
        zip.add("OEBPS/nav.xhtml", "<html><body><nav><ol><li>")
        let publication = try load(zip).publication
        #expect(publication.toc.isEmpty)
        #expect(publication.spine.count == 4)
    }

    @Test("Resource reads return archive bytes")
    func resourceRead() throws {
        let book = try load(EpubFixture.epub3())
        #expect(try book.container.data(at: "images/cover.png") == Data([0x89, 0x50, 0x4E, 0x47]))
        #expect(throws: EpubError.missingResource("nope")) { try book.container.data(at: "nope") }
    }

    // MARK: - Validation

    @Test("Non-ZIP files, wrong mimetypes and missing containers are rejected")
    func invalidPackages() throws {
        let garbage = directory.appendingPathComponent("garbage.epub")
        try Data("not a zip".utf8).write(to: garbage)
        #expect(throws: EpubError.notAnArchive) { try EpubBook.load(path: garbage.path) }

        var wrongMimetype = EpubFixture.epub3()
        wrongMimetype.items[0].data = Data("application/zip".utf8)
        try expectFailure(.invalidMimetype, wrongMimetype)

        var noContainer = EpubFixture.epub3()
        noContainer.items.removeAll { $0.path == EpubPackageParser.containerPath }
        try expectFailure(.missingContainer, noContainer)

        var noChapters = EpubFixture.epub2()
        noChapters.items.removeAll { $0.path.hasSuffix(".html") }
        try expectFailure(.emptySpine, noChapters)
    }

    @Test("Traversal paths and symlinks are rejected")
    func unsafeEntries() throws {
        var traversal = EpubFixture.epub3()
        traversal.add("OEBPS/../../escape.xhtml", "x")
        try expectFailure(.unsafeArchive("it contains an unsafe path"), traversal)

        var absolute = EpubFixture.epub3()
        absolute.add("/etc/passwd", "x")
        try expectFailure(.unsafeArchive("it contains an unsafe path"), absolute)

        var symlink = EpubFixture.epub3()
        symlink.add("OEBPS/link", "/etc/passwd", kind: .symlink)
        try expectFailure(.unsafeArchive("it contains a symbolic link"), symlink)
    }

    @Test("Expansion limits are enforced")
    func expansionLimits() throws {
        var tight = EpubContainer.Limits.standard
        tight.maxTotalSize = 2_000
        try expectFailure(.archiveTooLarge, EpubFixture.epub3(), limits: tight)

        var entryLimit = EpubContainer.Limits.standard
        entryLimit.maxEntrySize = 64
        #expect(throws: EpubError.self) { try load(EpubFixture.epub3(), limits: entryLimit) }

        var countLimit = EpubContainer.Limits.standard
        countLimit.maxEntryCount = 3
        try expectFailure(.unsafeArchive("it contains too many files"), EpubFixture.epub3(), limits: countLimit)
    }

    @Test("DTD entities (XXE and expansion bombs) abort parsing")
    func entityDeclarations() throws {
        for doctype in [
            #"<!DOCTYPE package [<!ENTITY xxe SYSTEM "file:///etc/passwd">]>"#,
            #"<!DOCTYPE package [<!ENTITY a "aaaaaaaaaa"><!ENTITY b "&a;&a;&a;&a;&a;&a;&a;&a;&a;&a;">]>"#,
        ] {
            var zip = EpubFixture.epub3()
            let index = try #require(zip.items.firstIndex { $0.path == "OEBPS/content.opf" })
            let opf = String(decoding: zip.items[index].data, as: UTF8.self)
                .replacingOccurrences(of: #"<?xml version="1.0" encoding="UTF-8"?>"#,
                                      with: #"<?xml version="1.0" encoding="UTF-8"?>"# + doctype)
                .replacingOccurrences(of: "Sample Book", with: "&xxe;&b;")
            zip.items[index].data = Data(opf.utf8)
            #expect(throws: EpubError.self) { try load(zip) }
        }
    }

    @Test("DRM is rejected; font obfuscation is not DRM")
    func encryption() throws {
        func encryption(_ algorithm: String) -> String {
            """
            <encryption xmlns="urn:oasis:names:tc:opendocument:xmlns:container"
                        xmlns:enc="http://www.w3.org/2001/04/xmlenc#">
              <enc:EncryptedData>
                <enc:EncryptionMethod Algorithm="\(algorithm)"/>
                <enc:CipherData><enc:CipherReference URI="OEBPS/fonts/a.otf"/></enc:CipherData>
              </enc:EncryptedData>
            </encryption>
            """
        }
        var drm = EpubFixture.epub3()
        drm.add(EpubPackageParser.encryptionPath, encryption("http://www.w3.org/2001/04/xmlenc#aes128-cbc"))
        try expectFailure(.drmProtected, drm)

        var fonts = EpubFixture.epub3()
        fonts.add(EpubPackageParser.encryptionPath, encryption("http://www.idpf.org/2008/embedding"))
        #expect(try load(fonts).publication.obfuscatedResourcePaths == ["OEBPS/fonts/a.otf"])
    }

    @Test("Fixed-layout books are rejected")
    func fixedLayout() throws {
        let zip = EpubFixture.epub3(metadataExtra: #"<meta property="rendition:layout">pre-paginated</meta>"#)
        try expectFailure(.fixedLayoutUnsupported, zip)
    }

    @Test("Href resolution stays inside the archive")
    func pathResolution() {
        #expect(EpubPath.resolve("../images/a.png", relativeTo: "OEBPS/text/c.xhtml")?.path == "OEBPS/images/a.png")
        #expect(EpubPath.resolve("./a%20b.xhtml#x%20y", relativeTo: "OEBPS/c.opf").map { [$0.path, $0.fragment] }
            == ["OEBPS/a b.xhtml", "x y"])
        #expect(EpubPath.resolve("#note", relativeTo: "OEBPS/c.xhtml")?.path == "OEBPS/c.xhtml")
        #expect(EpubPath.resolve("../../a.xhtml", relativeTo: "OEBPS/c.xhtml") == nil)
        #expect(EpubPath.resolve("https://example.com/a", relativeTo: "OEBPS/c.xhtml") == nil)
        #expect(EpubPath.resolve("mailto:a@b.c", relativeTo: "OEBPS/c.xhtml") == nil)
        #expect(EpubPath.resolve("/abs.xhtml", relativeTo: "OEBPS/c.xhtml") == nil)
        #expect(EpubPath.resolve("a%00b", relativeTo: "c.xhtml") == nil)
    }

    // MARK: - Identity and sessions

    @Test("docId follows the bytes, not the path")
    func contentIdentity() throws {
        let original = try write(EpubFixture.epub3(), name: "a.epub")
        let moved = try write(EpubFixture.epub3(), name: "renamed copy.epub")
        let edition = try write(EpubFixture.epub3(title: "Second Edition"), name: "b.epub")
        let id = try EpubIdentity.contentDocId(fileAt: original)
        #expect(id.count == 64)
        #expect(DocumentIdentity.isCanonicalKey(id))
        #expect(try EpubIdentity.contentDocId(fileAt: moved) == id)
        #expect(try EpubIdentity.contentDocId(fileAt: edition) != id)
    }

    @Test("DocumentSessionManager opens EPUB sessions")
    @MainActor
    func sessionRouting() async throws {
        let url = try write(EpubFixture.epub3())
        let manager = DocumentSessionManager()
        let info = try await manager.openEpubFile(path: url.path, sessionId: "tab-1")
        #expect(info.kind == .epub)
        #expect(info.title == "Sample Book")
        #expect(info.pageCount == 4)
        #expect(info.docId == (try EpubIdentity.contentDocId(fileAt: url)))
        #expect(try await manager.ensureDocumentId(sessionId: "tab-1") == info.docId)
        #expect(try await manager.getAnnotations(sessionId: "tab-1", pageNumber: nil).isEmpty)
        await #expect(throws: SessionServiceError.self) { try await manager.readPdfBytes(sessionId: "tab-1") }

        let session = try #require(manager.documentSession(sessionId: "tab-1") as? EpubDocumentSession)
        #expect(try await session.resourceData(at: "OEBPS/text/chapter2.xhtml").isEmpty == false)
        try await manager.closeFile(sessionId: "tab-1")
        #expect(manager.documentSession(sessionId: "tab-1") == nil)
        await #expect(throws: SessionServiceError.self) { try await session.resourceData(at: "images/cover.png") }
    }

    @Test("An invalid book never becomes a session")
    @MainActor
    func failedOpen() async throws {
        var zip = EpubFixture.epub3()
        zip.items.removeAll { $0.path == EpubPackageParser.containerPath }
        let url = try write(zip)
        let manager = DocumentSessionManager()
        await #expect(throws: EpubError.missingContainer) {
            try await manager.openEpubFile(path: url.path, sessionId: "tab-1")
        }
        #expect(manager.documentSession(sessionId: "tab-1") == nil)
    }
}
