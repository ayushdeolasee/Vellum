import Foundation
import Testing
import VellumCore
#if canImport(ImageIO)
import ImageIO
#endif
#if !SWIFT_PACKAGE
@testable import Vellum
#endif

/// Shared inputs for the deterministic transport, the native Mac → Linux → Mac
/// exchange, and the isolated pair of daemons. Every write is rooted in a fixture.
struct PeerLibrary {
    static let address = "https://example.invalid/article"
    static let key = DocumentKey.web(normalizedURL: address)
    static let record = ".vellum/records/\(key.hash).json"
    static let doc = ".vellum/documents/\(key.hash)/"
    static let messages = doc + "conversations.json"
    static let note = doc + "scratchpad.md"
    static let meta = doc + "meta.json"
    static let imageName = "abc.png"
    static let imageLink = "![Image](attachments/\(imageName))"
    static let png = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAABEAAAALCAIAAAAWQvFQAAAAFElEQVR4nGNQKogjFTGM6hnVA0QAvTWvUWQMAeMAAAAASUVORK5CYII=")!
    static let title = "Café"
    static let capture = "Web Pages/Café.vellumweb"
    static let longTitle = String(repeating: "각", count: 80)
    static let longName = String(repeating: "각", count: 27) + ".vellumweb"
    static let longKey = DocumentKey.web(normalizedURL: address + "/long").hash
    static let index = ".vellum/index.json"
    static let future: JSONValue = .object(["array": .array([.bool(true), .null, .int(17)])])
    static let pdf = "PDFs/Paper.pdf"

    let root: URL
    var store: LocalFolderFileStore { LocalFolderFileStore(root: root) }
    var positions: FilePositionStorage { FilePositionStorage(root: url(".vellum/positions")) }

    func url(_ path: String) -> URL { root.appendingPathComponent(path) }

    func write(_ path: String, _ bytes: Data) async throws {
        try await store.replace(url(path), with: bytes)
    }

    func read(_ path: String) throws -> Data { try Data(contentsOf: url(path)) }

    static func annotation(_ id: String) -> Annotation {
        Annotation(id: id, type: .note, pageNumber: 1, content: id,
                   createdAt: "2026-01-01T00:00:00Z", updatedAt: "2026-01-01T00:00:00Z")
    }

    static func messageBytes(_ ids: [String]) throws -> Data {
        try JSONSerialization.data(withJSONObject: ids.map {
            ["id": $0, "role": "user", "content": $0, "createdAt": "2026-01-01T00:00:00Z"]
        }, options: [.sortedKeys])
    }

    static func archive(_ peer: String, title: String = title) throws -> Data {
        let address = Self.address + "/" + peer
        let page = "<html>\(peer)</html>"
        let text = Data("[]".utf8)
        let manifest = ArchiveManifest(format: "vellumweb", version: 1, url: address, canonicalUrl: address,
            title: peer == "linux" ? title.decomposedStringWithCanonicalMapping : title, capturedAt: "2026-01-01T00:00:00Z", generator: "fixture",
            loadingPolicy: "snapshot-only", pageCount: 1, lastPage: 1,
            hashes: ManifestHashes(snapshotHtml: ArchiveCodec.sha256Hex(Data(page.utf8)),
                                   pageText: ArchiveCodec.sha256Hex(text)), assets: [], assetsSkipped: 0)
        return try ArchiveCodec.encode(manifest: manifest, snapshotHtml: page, assets: [],
                                      pagesJson: text, annotations: [annotation(peer)])
    }

    static func position(_ peer: String, pdfID: String? = nil) -> PositionDeviceRecord {
        let mac = peer == "mac"
        let stamp = Date(timeIntervalSince1970: mac ? 100 : 200)
        var documents = [key: PositionDeviceRecord.DocumentEntry(readingPosition: Stamped(at: stamp, value: ReadingPosition(page: mac ? 1 : 2)))]
        if let pdfID {
            documents[.pdf(stableIdentifier: pdfID)] = .init(readingPosition: Stamped(at: stamp, value: ReadingPosition(page: 1)))
        }
        return PositionDeviceRecord(deviceID: DeviceID(mac ? "aaaaaaaa-0000-4000-8000-000000000001" :
                                                       "bbbbbbbb-0000-4000-8000-000000000002"),
            deviceName: peer, devicePlatform: mac ? "macos" : "linux", writtenAt: stamp,
            documents: documents,
            unknownFields: ["future_position": future])
    }

    static let stagingPaths = [
        ".vellum/index.json.tmp", ".vellum/documents/abc/scratchpad.md.tmp",
        ".vellum/positions/.device.json.tmp-42-00000000-0000-4000-8000-000000000001",
        "PDFs/.Paper.pdf.vellum-00000000-0000-4000-8000-000000000001.tmp",
        ".vellum/cache/items", "Web Pages/.DS_Store"
    ]

    func prepareIgnore(_ peer: String) async throws {
        let userRule = Data(("// private to " + peer + "\nlocal-" + peer + "\n").utf8)
        try await write(".stignore", userRule)
        let installed = try StignoreManager.ensure(at: root)
        try #require(installed)
        let bytes = try read(".stignore")
        #expect(bytes.starts(with: userRule))
        #expect(try !StignoreManager.ensure(at: root))
        #expect(try read(".stignore") == bytes)
    }

    #if !SWIFT_PACKAGE
    func removeOfflineImage() async throws {
        let local = root.deletingLastPathComponent().appendingPathComponent("app-local/web", isDirectory: true)
        let coordinator = StorageCoordinator(storeDir: local, modeProvider: { .syncedFolder },
            syncedFolderRootResolver: { root }, conflictArchiveRegistry: .init(load: { [] }, save: { _ in }))
        await coordinator.start()
        do {
            try #require(await coordinator.currentStatus().effectiveMode == .syncedFolder)
            let before = try store.contents(of: url(Self.doc))
            #expect(!before.contains { $0.url.lastPathComponent.contains("sync-conflict") })
            let document = DocumentInfo(kind: .web, pdfPath: Self.address, title: "Fixture",
                                        pageCount: 1, lastPage: 1, docId: Self.key.hash)
            let saved = await ScratchpadPersistence.save(forKey: Self.key.hash, document: document,
                schemeText: "Removed image", expectedBaseline: ScratchpadPersistence.relativeToScheme(Self.imageLink),
                attachments: [], dirtyAttachmentNames: [], coordinator: coordinator)
            try #require(saved == "Removed image")
            #expect(try read(Self.doc + "attachments/" + Self.imageName) == Self.png)
        } catch { await coordinator.stop(); throw error }
        await coordinator.stop()
    }
    #endif

    var catalog: SharedWebArchives {
        FolderSyncedContainer(root: root, store: store, watcher: FolderDirectoryWatcher()).webArchives
    }

    func verifyLongCapture() async throws {
        let found = try #require(try await catalog.lookup(forKey: Self.longKey))
        #expect(found.name == Self.longName)
        #expect(found.name.decomposedStringWithCanonicalMapping.utf8.count <= 255)
        #expect(try ArchiveCodec.decode(found.bytes).manifest.title == Self.longTitle)
    }

    func seed() async throws {
        var record = WebPageRecord(url: Self.address)
        record.unknownFields["future"] = Self.future
        record.annotations = [Self.annotation("shared")]
        try await write(Self.record, JSONEncoder().encode(record))
        try await write(Self.messages, Self.messageBytes(["shared"]))
        try await write(Self.doc + "attachments/" + Self.imageName, Self.png)
        try await write(Self.note, Data(Self.imageLink.utf8))
        _ = try await catalog.save(Self.archive("long", title: Self.longTitle), forKey: Self.longKey)
        try await migratePDFs()
    }

    func edit(_ peer: String) async throws {
        var record = try JSONDecoder().decode(WebPageRecord.self, from: read(Self.record))
        record.annotations.append(Self.annotation(peer))
        record.title = peer
        try await write(Self.record, JSONEncoder().encode(record))
        try await write(Self.messages, Self.messageBytes(["shared", peer]))
        let note = peer == "mac" ? "Removed image" : "Retained offline\n" + Self.imageLink
        #if SWIFT_PACKAGE
        try await write(Self.note, Data(note.utf8))
        #else
        if peer == "mac" { try await removeOfflineImage() }
        else { try await write(Self.note, Data(note.utf8)) }
        #endif
        var meta = ["kind": "web", "last_known_path": Self.address + "/" + peer,
                    "last_opened": peer == "mac" ? "2026-02-01T00:00:00Z" : "2026-01-01T00:00:00Z",
                    "future_" + peer: peer] as [String: Any]
        meta["version"] = 1
        if peer == "linux" { meta["title"] = "Retained title" }
        try await write(Self.meta, JSONSerialization.data(withJSONObject: meta))
        let captureKey = DocumentKey.web(normalizedURL: Self.address + "/" + peer)
        let saved = try await catalog.save(Self.archive(peer), forKey: captureKey.hash)
        #expect(saved == root.standardizedFileURL.appendingPathComponent(Self.capture))
        let pdfID = try await verifyPDFs()
        try await positions.write(Self.position(peer, pdfID: pdfID))
        // Explicit, distinct mtimes let the real daemon and simulator agree on winner.
        for file in Self.conflictingPaths {
            try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: peer == "mac" ? 180 : 120)],
                                                   ofItemAtPath: url(file).path)
        }
    }

    static let conflictingPaths: Set<String> = [record, messages, note, meta, capture, index]

    func verifyPositions() async throws {
        let files = try FileManager.default.contentsOfDirectory(atPath: positions.root.path)
        let records = try files.map { name in
            let file = try #require(PositionLayout.parseFileName(name))
            return try file.decode(Data(contentsOf: positions.root.appendingPathComponent(name)))
        }
        #expect(records.count == 2)
        let merged = PositionMerge.merge(records)[Self.key]?.readingPosition
        #expect(merged?.device.platform == "linux")
        #expect(merged?.value.page == 2)
        let pdfID = try await verifyPDFs()
        let expected = ["mac", "linux"].map { Self.position($0, pdfID: pdfID) }
        #expect(Set(files) == Set(expected.map { $0.deviceID.rawValue + ".v1.json" }))
        for record in expected {
            let file = positions.root.appendingPathComponent(record.deviceID.rawValue + ".v1.json")
            let data = try Data(contentsOf: file)
            #expect(data == (try PositionCoding.encoder.encode(record)))
            let wire = try JSONDecoder().decode([String: JSONValue].self, from: data)
            #expect(wire["schema_version"] == .int(1))
            #expect(wire["future_position"] == Self.future)
        }
    }

    // The Mac app injects its typed policies. Portable peers ship the Core preserve policy.
    func recover(macPeer: Bool = true) async throws {
        let container: FolderSyncedContainer
        #if !SWIFT_PACKAGE
        if macPeer {
            container = FolderSyncedContainer(root: root, store: store, watcher: FolderDirectoryWatcher(),
                                              rescanInterval: .milliseconds(80), merge: ConflictMerge.decide)
        } else {
            container = portableContainer()
        }
        #else
        container = portableContainer()
        #endif
        await container.resume()
        do {
            try await withThrowingTaskGroup(of: Void.self) { group in
                group.addTask {
                    var pending = Set(Self.conflictingPaths.map { url($0) })
                    for await event in container.conflicts where pending.contains(event.url) {
                        let outcome = try await container.resolveConflict(event)
                        guard outcome != .deferred else { continue }
                        pending.remove(event.url)
                        if pending.isEmpty { return }
                    }
                    throw CocoaError(.fileReadUnknown)
                }
                group.addTask {
                    try await Task.sleep(for: .seconds(3))
                    throw CocoaError(.fileReadUnknown, userInfo: [NSLocalizedDescriptionKey: "Expected peer conflicts did not arrive"])
                }
                defer { group.cancelAll() }
                _ = try await group.next()
            }
        } catch { await container.suspend(); throw error }
        await container.suspend()
    }

    private func portableContainer() -> FolderSyncedContainer {
        FolderSyncedContainer(root: root, store: store, watcher: FolderDirectoryWatcher(),
                              rescanInterval: .milliseconds(80))
    }

    // Walk the unfiltered trees, including hidden directories and archived files.
    func conflictSiblings() throws -> Set<String> {
        var pending = [root]
        var found = Set<String>()
        while let directory = pending.popLast() {
            for entry in try store.contents(of: directory) {
                if entry.isDirectory { pending.append(entry.url) }
                if entry.url.lastPathComponent.contains(".sync-conflict-") {
                    found.insert(entry.url.pathComponents.dropFirst(root.pathComponents.count).joined(separator: "/"))
                }
            }
        }
        return found
    }

    func versions(_ path: String) throws -> [Data] {
        let canonical = url(path)
        let dir = canonical.deletingLastPathComponent().appendingPathComponent("conflicts")
        let prefix = canonical.deletingPathExtension().lastPathComponent + "."
        let matches = try store.contents(of: dir).filter {
            $0.url.lastPathComponent.hasPrefix(prefix) && $0.url.pathExtension == canonical.pathExtension
        }
        return try [read(path)] + matches.map { try Data(contentsOf: $0.url) }
    }

    func verifyRecovery(expectMergedMeta: Bool = true) async throws {
        let pages = try versions(Self.record).map { try JSONDecoder().decode(WebPageRecord.self, from: $0) }
        #expect(pages.map { $0.annotations.map(\.id) } == [["shared", "mac"], ["shared", "linux"]])
        #expect(pages.allSatisfy { $0.unknownFields["future"] == Self.future })
        let messages = try versions(Self.messages)
        for (i, peer) in ["mac", "linux"].enumerated() {
            let bytes = try #require(messages.indices.contains(i) ? messages[i] : nil)
            #expect(bytes == (try Self.messageBytes(["shared", peer])))
            #if !SWIFT_PACKAGE
            #expect(try JSONDecoder().decode([AiMessage].self, from: bytes).map(\.id) == ["shared", peer])
            #endif
        }
        #expect(messages.count == 2)
        let notes = try versions(Self.note).map { String(decoding: $0, as: UTF8.self) }
        #expect(notes == ["Removed image", "Retained offline\n" + Self.imageLink])
        let retained = try #require(notes.last?.components(separatedBy: "](").last?.dropLast())
        let imageURL = url(Self.doc + retained)
        #expect(try Data(contentsOf: imageURL) == Self.png)
        #if canImport(ImageIO)
        let source = try #require(CGImageSourceCreateWithURL(imageURL as CFURL, nil))
        let pixels = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
        #expect(pixels.width > 0 && pixels.height > 0)
        #endif
        let index = try JSONDecoder().decode(WebArchiveIndexContents.self, from: read(Self.index))
        let keys = ["mac", "linux"].map { DocumentKey.web(normalizedURL: Self.address + "/" + $0).hash }.sorted()
        let expectedNames = [keys[0]: "Café.vellumweb", keys[1]: "Café (\(keys[1].prefix(6))).vellumweb", Self.longKey: Self.longName]
        #expect(index.entries == expectedNames)
        // Read the stored index and its ZIPs directly. Catalog lookup can repair them.
        let longName = try #require(index.entries[Self.longKey])
        try #require(longName == Self.longName)
        let long = try ArchiveCodec.decode(read("Web Pages/" + longName))
        #expect(long.manifest.title == Self.longTitle)
        #expect(long.manifest.canonicalUrl == Self.address + "/long")
        for peer in ["mac", "linux"] {
            let address = Self.address + "/" + peer
            let key = DocumentKey.web(normalizedURL: address).hash
            let name = try #require(index.entries[key])
            try #require(name == expectedNames[key])
            let capture = try ArchiveCodec.decode(read("Web Pages/" + name))
            #expect(capture.manifest.canonicalUrl == address && capture.manifest.title == Self.title)
            #expect(capture.annotations.map(\.id) == [peer])
            #expect(capture.snapshotHtml == "<html>\(peer)</html>")
        }
        let metadata = try versions(Self.meta).map { try JSONDecoder().decode([String: JSONValue].self, from: $0) }
        let current = try #require(metadata.first)
        #expect(current["last_known_path"] == .string(Self.address + "/mac"))
        #expect(current["future_mac"] == .string("mac"))
        #expect(current["title"] == (expectMergedMeta ? .string("Retained title") : nil))
        #expect(current["future_linux"] == (expectMergedMeta ? .string("linux") : nil))
        #expect(metadata.dropFirst().contains { $0["last_known_path"] == .string(Self.address + "/linux")
            && $0["future_linux"] == .string("linux") && $0["title"] == .string("Retained title") })
        try await verifyPositions()
    }
}

#if SWIFT_PACKAGE
@Suite
#else
@Suite(.isolatedStorage)
#endif
struct TwoPeerOfflineConflictTests {
    @Test func concurrentEdits() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).standardizedFileURL
        defer { try? FileManager.default.removeItem(at: dir) }
        let a = PeerLibrary(root: dir.appendingPathComponent("a", isDirectory: true))
        let b = PeerLibrary(root: dir.appendingPathComponent("b", isDirectory: true))
        var transport = SyncthingSimulator(a: .init(id: "MACPEER", root: a.root), b: .init(id: "LNXPEER", root: b.root))
        try await a.prepareIgnore("mac")
        try await b.prepareIgnore("linux")
        for path in PeerLibrary.stagingPaths { try await a.write(path, Data([42])) }
        try await a.write(".vellum/documents/abc/attachments/real.tmp", Data([43]))
        try await a.seed()
        #expect(try await transport.sync().isEmpty)
        for path in PeerLibrary.stagingPaths {
            #expect(try await b.store.read(b.url(path)) == nil)
            try await a.store.remove(a.url(path))
        }
        #expect(try b.read(".vellum/documents/abc/attachments/real.tmp") == Data([43]))
        #expect(try a.read(".stignore") != b.read(".stignore"))
        try await a.edit("mac")
        try await b.edit("linux")
        #expect(try await transport.sync() == PeerLibrary.conflictingPaths)
        let siblings = Set(PeerLibrary.conflictingPaths.map { path in
            let file = path as NSString
            return file.deletingPathExtension + ".sync-conflict-20260101-000002-LNXPEER." + file.pathExtension
        })
        try #require(try a.conflictSiblings() == siblings)
        try #require(try b.conflictSiblings() == siblings)
        try await a.recover()
        try #require(try a.conflictSiblings().isEmpty)
        try #require(try b.conflictSiblings() == siblings)
        try await b.recover(macPeer: false)
        try #require(try b.conflictSiblings().isEmpty)
        #if SWIFT_PACKAGE
        let typedMac = false
        #else
        let typedMac = true
        #endif
        try await a.verifyRecovery(expectMergedMeta: typedMac)
        try await b.verifyRecovery(expectMergedMeta: false)
        let remainingConflicts = try await transport.sync()
        #expect(remainingConflicts == [])
        for library in [a, b] {
            try #require(try library.conflictSiblings().isEmpty)
            try await library.verifyRecovery(expectMergedMeta: typedMac)
        }
    }
}
