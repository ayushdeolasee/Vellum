import Foundation
import Testing

@testable import Vellum

@Suite("EPUB library integration", .serialized, .isolatedStorage, .scratchDefaults)
struct EpubLibraryIntegrationTests {
    private let stores: EpubLibraryTestStores

    init() throws { stores = try EpubLibraryTestStores() }

    @Test("Import catalogs title, authors and a bounded local cover without changing original bytes")
    func catalogOnImport() throws {
        let source = try stores.source()
        let bytes = try Data(contentsOf: source)
        let managed = try EpubLibrary.importBook(at: source)
        let entry = try #require(EpubLibraryCatalog.list().first)
        #expect(entry.record.version == 1)
        #expect(entry.record.docId == (try EpubIdentity.contentDocId(fileAt: source)))
        #expect(entry.record.title == "Sample Book")
        #expect(entry.record.authors == ["Ada Writer", "Bo Editor"])
        #expect(entry.fileURL == managed)
        #expect(entry.available)
        #expect(entry.originalBytes == Int64(bytes.count))
        #expect(entry.coverBytes == 4)
        #expect(entry.coverURL?.lastPathComponent == EpubLibraryCatalog.coverFilename)
        #expect(entry.metadataBytes > 0 && entry.metadataBytes <= EpubLibraryCatalog.maxRecordBytes)
        #expect(try Data(contentsOf: managed) == bytes)
        #expect(try Data(contentsOf: source) == bytes)
        let before = entry.record.importedAt
        _ = try EpubLibrary.importBook(at: source)
        #expect(try EpubLibraryCatalog.list().first?.record.importedAt == before)
    }

    @Test("Custom titles survive recents eviction and reimport without creating user sidecars")
    func customTitle() async throws {
        let source = try stores.source()
        let managed = try EpubLibrary.importBook(at: source)
        let docId = managed.deletingLastPathComponent().lastPathComponent
        #expect(try EpubLibraryCatalog.setTitle(docId: docId, title: "My Edition"))
        #expect(EpubLibraryCatalog.customTitle(docId: docId) == "My Edition")
        _ = try EpubLibrary.importBook(at: source)
        #expect(EpubLibraryCatalog.customTitle(docId: docId) == "My Edition")
        #expect(RecentFilesService.getRecent().isEmpty)
        #expect(DocumentDataStore.listDocumentMetas().isEmpty)
        let items = try await EpubBooksSearchProvider().items(matching: "")
        #expect(items.first?.title == "My Edition")
        #expect(try EpubLibraryCatalog.setTitle(docId: docId, title: nil))
        #expect(EpubLibraryCatalog.customTitle(docId: docId) == nil)
        #expect(EpubLibraryCatalog.customTitle(docId: "../outside") == nil)
    }

    @Test("Stage 2 originals are discovered once and must match the enclosing content ID")
    func legacyDiscovery() throws {
        let source = try stores.source()
        let docId = try EpubIdentity.contentDocId(fileAt: source)
        let legacy = stores.library.appendingPathComponent(docId).appendingPathComponent("legacy.epub")
        try FileManager.default.createDirectory(at: legacy.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: source, to: legacy)
        let wrongFolder = stores.library.appendingPathComponent(String(repeating: "f", count: 64))
        try FileManager.default.createDirectory(at: wrongFolder, withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: source, to: wrongFolder.appendingPathComponent("wrong.epub"))
        let entries = try EpubLibraryCatalog.list()
        #expect(entries.count == 1)
        #expect(entries.first?.record.docId == docId)
        #expect(entries.first?.record.filename == "legacy.epub")
        let catalog = legacy.deletingLastPathComponent().appendingPathComponent(EpubLibraryCatalog.recordFilename)
        let bytes = try Data(contentsOf: catalog)
        #expect(try EpubLibraryCatalog.list() == entries)
        #expect(try Data(contentsOf: catalog) == bytes)
    }

    @Test("Missing and modified originals stay visible as unavailable, and altered imports are not overwritten")
    func unavailableOriginals() async throws {
        let source = try stores.source()
        let managed = try EpubLibrary.importBook(at: source)
        let docId = managed.deletingLastPathComponent().lastPathComponent
        try Data("not the imported book".utf8).write(to: managed)
        #expect(try EpubLibraryCatalog.list().first?.available == false)
        #expect(EpubLibraryCatalog.resolve(docId: docId) == nil)
        #expect(throws: (any Error).self) { try EpubLibrary.importBook(at: source) }
        #expect(try Data(contentsOf: managed) == Data("not the imported book".utf8))
        try FileManager.default.removeItem(at: managed)
        let entry = try #require(EpubLibraryCatalog.list().first)
        #expect(!entry.available)
        #expect(entry.originalBytes == 0)
        #expect(entry.record.title == "Sample Book")
        let row = StorageInventory.joinRows(documents: [], cacheEntries: [], webEntries: [], bookEntries: [entry]).first
        #expect(row?.sourceExists == false)
        let items = try await EpubBooksSearchProvider().items(matching: "")
        #expect(items.first?.badges.contains(.missing) == true)
    }

    @Test("Invalid and future catalog records are skipped without reparsing or overwriting them", arguments: ["path", "identity", "version", "oversize"])
    func invalidRecords(reason: String) throws {
        let managed = try EpubLibrary.importBook(at: stores.source())
        let catalog = managed.deletingLastPathComponent().appendingPathComponent(EpubLibraryCatalog.recordFilename)
        var record = try #require(EpubLibraryCatalog.list().first?.record)
        switch reason {
        case "path": record.filename = "../escape.epub"
        case "identity": record.docId = String(repeating: "0", count: 64)
        case "version": record.version = 99
        default: break
        }
        let data = reason == "oversize"
            ? Data(repeating: 0x20, count: EpubLibraryCatalog.maxRecordBytes + 1)
            : try JSONEncoder().encode(record)
        try data.write(to: catalog)
        #expect(try EpubLibraryCatalog.list().isEmpty)
        #expect(try Data(contentsOf: catalog) == data)
    }

    @Test("Symlinked book directories and managed originals cannot escape the catalog")
    func symlinksRejected() throws {
        let source = try stores.source()
        let sourceLink = stores.root.appendingPathComponent("linked.epub")
        try FileManager.default.createSymbolicLink(at: sourceLink, withDestinationURL: source)
        #expect(throws: (any Error).self) { try EpubLibrary.importBook(at: sourceLink) }
        let docId = try EpubIdentity.contentDocId(fileAt: source)
        let folder = stores.library.appendingPathComponent(docId)
        let outside = stores.root.appendingPathComponent("outside")
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: source, to: outside.appendingPathComponent("book.epub"))
        try FileManager.default.createSymbolicLink(at: folder, withDestinationURL: outside)
        #expect(try EpubLibraryCatalog.list().isEmpty)
        #expect(throws: (any Error).self) { try EpubLibrary.importBook(at: source) }
        try FileManager.default.removeItem(at: folder)
        let managed = try EpubLibrary.importBook(at: source)
        try FileManager.default.removeItem(at: managed)
        try FileManager.default.createSymbolicLink(at: managed, withDestinationURL: source)
        #expect(try EpubLibraryCatalog.list().first?.available == false)
        #expect(EpubLibraryCatalog.resolve(docId: docId) == nil)
        #expect(EpubLibraryCatalog.resolve(docId: "../../outside") == nil)
    }

    @Test("Cover extraction respects the byte cap", arguments: [2 * 1024 * 1024, 2 * 1024 * 1024 + 1])
    func coverCap(size: Int) throws {
        var zip = EpubFixture.epub3()
        zip.items.removeAll { $0.path == "images/cover.png" }
        zip.add("images/cover.png", data: Data(repeating: 0x61, count: size))
        let source = try zip.write(to: stores.root.appendingPathComponent("cover.epub"))
        _ = try EpubLibrary.importBook(at: source)
        let entry = try #require(EpubLibraryCatalog.list().first)
        #expect(entry.available)
        if size <= EpubLibraryCatalog.maxCoverBytes {
            #expect(entry.coverBytes == Int64(size))
            #expect(entry.coverURL != nil)
        } else {
            #expect(entry.coverBytes == 0)
            #expect(entry.coverURL == nil)
        }
    }

    @Test("Oversized local covers are counted but never offered for display or decoded")
    func coverReadCap() throws {
        _ = try EpubLibrary.importBook(at: stores.source())
        let entry = try #require(EpubLibraryCatalog.list().first)
        let cover = try #require(entry.coverURL)
        let size = EpubLibraryCatalog.maxCoverBytes + 1
        try Data(repeating: 0x61, count: size).write(to: cover)
        #expect(EpubLibraryCatalog.boundedData(cover, cap: EpubLibraryCatalog.maxCoverBytes) == nil)
        let updated = try #require(EpubLibraryCatalog.list().first)
        #expect(updated.coverURL == nil)
        #expect(updated.coverBytes == Int64(size))
        try FileManager.default.removeItem(at: cover)
        try FileManager.default.createSymbolicLink(at: cover, withDestinationURL: stores.source())
        #expect(EpubLibraryCatalog.boundedData(cover, cap: EpubLibraryCatalog.maxCoverBytes) == nil)
    }

    @Test("Books remain searchable by title and author after recents eviction with no user sidecars")
    func searchAfterEviction() async throws {
        let managed = try EpubLibrary.importBook(at: stores.source())
        let docId = managed.deletingLastPathComponent().lastPathComponent
        RecentFilesService.record(DocumentInfo(kind: .epub, pdfPath: "/old/import.epub", title: "Book", pageCount: 3, docId: docId))
        let recent = try #require(RecentFilesService.getRecent().first)
        #expect(RecentFilesService.resolvedPath(for: recent) == managed.path)
        for index in 0...RecentFilesService.maxRecent {
            RecentFilesService.record(DocumentInfo(kind: .pdf, pdfPath: "/missing/\(index).pdf", title: nil, pageCount: 1, docId: nil))
        }
        #expect(!RecentFilesService.getRecent().contains { $0.kind == .epub })
        #expect(DocumentDataStore.listDocumentMetas().isEmpty)
        let engine = HomeSearchEngine(providers: [RecentDocumentsSearchProvider(), EpubBooksSearchProvider()])
        await engine.reload()
        for query in ["Sample Book", "Ada Writer"] {
            let items = await engine.results(query: query, filter: .documents).flatMap(\.items)
            #expect(items.count == 1)
            #expect(items.first?.identity == "epub:\(docId)")
            #expect(items.first?.target.openKey == managed.path)
            #expect(items.first?.subtitle.contains("EPUB") == true)
            #expect(items.first?.localCoverURL != nil)
            #expect(items.first?.thumbnailURL == nil)
            #expect(items.first?.systemImage == "book.closed")
        }
    }

    @Test("Catalog availability and managed path replace stale recent targets without losing recency")
    func recentMerge() async throws {
        let managed = try EpubLibrary.importBook(at: stores.source())
        let docId = managed.deletingLastPathComponent().lastPathComponent
        RecentFilesService.record(DocumentInfo(kind: .epub, pdfPath: "/old/import.epub", title: "Stale", pageCount: 3, docId: docId))
        let recents = RecentDocumentsSearchProvider(resolvePath: { $0.pdfPath }, fileExists: { _ in false })
        let engine = HomeSearchEngine(providers: [recents, EpubBooksSearchProvider()])
        await engine.reload()
        let items = await engine.corpus
        let item = try #require(items.first)
        #expect(items.count == 1)
        #expect(item.section == .recents)
        #expect(item.title == "Sample Book")
        #expect(item.target == .file(path: managed.path, recordedPath: "/old/import.epub"))
        #expect(item.canRevealInFinder)
        #expect(!item.badges.contains(.missing))
        let removed = await MainActor.run {
            HomeSearchStore(engine: engine).removeFromRecent(item) != nil
        }
        #expect(removed)
        #expect(RecentFilesService.getRecent().isEmpty)
        #expect(try EpubLibraryCatalog.list().count == 1)
    }

    @Test("Continue Reading joins EPUB content IDs and excludes unavailable originals")
    func continueReading() async throws {
        _ = try EpubLibrary.importBook(at: stores.source())
        let items = try await EpubBooksSearchProvider().items(matching: "")
        let item = try #require(items.first)
        let docId = try #require(item.storageKey)
        let resume = ResumeEntry(key: try #require(DocumentKey.epub(docId: docId)), title: nil, openedAt: Date(), position: nil, lastOpenedOn: nil, openElsewhere: [])
        #expect(ContinueReadingResolver.resolve([resume], in: items).first?.document.identity == item.identity)
        let pdf = ResumeEntry(key: .pdf(stableIdentifier: docId), title: nil, openedAt: Date(), position: nil, lastOpenedOn: nil, openElsewhere: [])
        #expect(ContinueReadingResolver.resolve([pdf], in: items).isEmpty)
        try FileManager.default.removeItem(atPath: item.target.openKey)
        let missing = try await EpubBooksSearchProvider().items(matching: "")
        #expect(ContinueReadingResolver.resolve([resume], in: missing).isEmpty)
    }

    @Test("Book-only rename persists without notes or recents, and survives reimport")
    func catalogRename() async throws {
        let source = try stores.source()
        let managed = try EpubLibrary.importBook(at: source)
        let docId = managed.deletingLastPathComponent().lastPathComponent
        let target = DocumentRenameService.Target(kind: .epub, locator: managed.path, recordedPath: nil, storageKey: docId)
        #expect(DocumentRenameService.apply(target, title: "My title"))
        _ = try EpubLibrary.importBook(at: source)
        #expect(try await EpubBooksSearchProvider().items(matching: "").first?.title == "My title")
        #expect(DocumentDataStore.listDocumentMetas().isEmpty)
        #expect(await DocumentRenameService.persistOpenDocument(target, title: "Tab title", storage: nil))
        #expect(try await EpubBooksSearchProvider().items(matching: "").first?.title == "Tab title")
        #expect(await DocumentRenameService.apply(target, title: nil, storage: WebLibraryStorage()))
        #expect(try await EpubBooksSearchProvider().items(matching: "").first?.title == "Sample Book")
        #expect(try Data(contentsOf: source) == Data(contentsOf: managed))
    }

    @Test("Existing custom metadata wins over publication titles; deleting user data preserves books and catalog")
    func inventoryAndSidecarDeletion() async throws {
        let managed = try EpubLibrary.importBook(at: stores.source())
        let docId = managed.deletingLastPathComponent().lastPathComponent
        let document = DocumentInfo(kind: .epub, pdfPath: managed.path, title: "Custom metadata title", pageCount: 3, docId: docId)
        try DocumentDataStore.touch(document: document, force: true)
        try DocumentDataStore.saveScratchpad(forKey: docId, text: "My note")
        #expect(try await EpubBooksSearchProvider().items(matching: "").first?.title == "Custom metadata title")
        let entries = try EpubLibraryCatalog.list()
        let entry = try #require(entries.first)
        let row = try #require(StorageInventory.joinRows(documents: DocumentDataStore.listDocuments(), cacheEntries: [], webEntries: [], bookEntries: entries).first)
        #expect(row.kind == .epub)
        #expect(row.title == "Custom metadata title")
        #expect(row.sourcePath == managed.path && row.sourceExists)
        #expect(row.originalBookBytes == entry.originalBytes)
        #expect(row.coverBytes == entry.coverBytes && row.catalogBytes == entry.metadataBytes)
        #expect(row.totalBytes == entry.totalBytes + row.notesBytes)
        #expect(row.archiveBytes == 0)
        #expect(StorageInventory.matches(row, searchText: "epub book"))
        DocumentDataStore.deleteAll(forKey: docId)
        #expect(try EpubLibraryCatalog.list() == entries)
        let after = StorageInventory.joinRows(documents: [], cacheEntries: [], webEntries: [], bookEntries: entries)
        #expect(after.first?.totalBytes == entry.totalBytes)
        #expect(FileManager.default.fileExists(atPath: managed.path))
    }

}

private final class EpubLibraryTestStores {
    let root: URL
    let library: URL
    private let previousBooks: URL?
    private let previousDocuments: URL?

    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("vellum-epub-library-\(UUID().uuidString)").resolvingSymlinksInPath()
        library = root.appendingPathComponent("Books")
        let documents = root.appendingPathComponent("documents")
        try FileManager.default.createDirectory(at: library, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: documents, withIntermediateDirectories: true)
        previousBooks = EpubLibrary.directoryOverride
        previousDocuments = DocumentDataStore.rootDirectoryOverride
        EpubLibrary.directoryOverride = library
        DocumentDataStore.rootDirectoryOverride = documents
    }

    deinit {
        EpubLibrary.directoryOverride = previousBooks
        DocumentDataStore.rootDirectoryOverride = previousDocuments
        try? FileManager.default.removeItem(at: root)
    }

    func source() throws -> URL {
        try EpubFixture.epub3().write(to: root.appendingPathComponent("source.epub"))
    }
}
