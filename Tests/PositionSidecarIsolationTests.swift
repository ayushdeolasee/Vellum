import CryptoKit
import Foundation
import Testing

@testable import Vellum

// The reason this module exists: `web/records/<key>.json` holds annotations,
// and reading state used to be read-modify-written into the same file on every
// open. These tests are the proof that the position store never goes near it.
//
// `.serialized` because both `WebLibrary.storeDirOverride` and
// `PositionLayout.rootOverride` are process-global.

@Suite("Position store — never touches the sidecar", .serialized)
struct PositionSidecarIsolationTests {
    private let pageURL = "https://example.com/spec-150"

    private struct Scratch {
        let root: URL
        let webDir: URL
        let positionsDir: URL
        let key: String
    }

    private func withScratch(_ body: (Scratch) async throws -> Void) async rethrows {
        let root = PositionFixtures.scratchDirectory("position-sidecar")
        let webDir = root.appendingPathComponent("web", isDirectory: true)
        let positionsDir = root.appendingPathComponent("positions", isDirectory: true)
        try? FileManager.default.createDirectory(at: webDir, withIntermediateDirectories: true)
        let previousStore = WebLibrary.storeDirOverride
        let previousRoot = PositionLayout.rootOverride
        WebLibrary.storeDirOverride = webDir
        PositionLayout.rootOverride = positionsDir
        defer {
            WebLibrary.storeDirOverride = previousStore
            PositionLayout.rootOverride = previousRoot
            PositionFixtures.remove(root)
        }
        try await body(
            Scratch(
                root: root, webDir: webDir, positionsDir: positionsDir,
                key: WebLibrary.pageKey(pageURL)))
    }

    private func seedSidecar(annotations: [Annotation] = []) throws -> URL {
        var record = WebPageRecord(url: pageURL)
        record.title = "Spec #150"
        record.saved = true
        record.savedAt = "2026-08-01T09:00:00.000000+00:00"
        record.openedAt = "2026-08-01T09:00:00.000000+00:00"
        record.annotations = annotations
        let path = WebLibrary.recordPath(forKey: WebLibrary.pageKey(pageURL))
        try WebLibrary.saveRecord(record, at: path)
        return path
    }

    private func annotation(_ id: String) -> Annotation {
        Annotation(
            id: id,
            type: .highlight,
            pageNumber: 1,
            color: "#ffd60a",
            content: "the coordination layer wraps every container access",
            positionData: PositionData(
                rects: [AnnotationRect(x: 12, y: 40, width: 220, height: 18)],
                pageWidth: 800,
                pageHeight: 4200,
                selectedText: "the coordination layer",
                startOffset: nil,
                endOffset: nil,
                prefix: "…",
                suffix: "…",
                viewportOffset: 220.5),
            createdAt: "2026-08-01T09:00:00.000000+00:00",
            updatedAt: "2026-08-01T09:00:00.000000+00:00")
    }

    private func digest(_ url: URL) throws -> String {
        SHA256.hash(data: try Data(contentsOf: url)).map { String(format: "%02x", $0) }.joined()
    }

    private func modified(_ url: URL) throws -> Date {
        try #require(
            FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate] as? Date)
    }

    private func fileTree(_ root: URL) -> [String] {
        guard let enumerator = FileManager.default.enumerator(atPath: root.path) else { return [] }
        return (enumerator.allObjects as? [String] ?? []).sorted()
    }

    private func makeStore() -> PositionStore {
        PositionStore(
            storage: FilePositionStorage(),
            device: .phone,
            clock: SystemPositionClock(),
            timer: ManualPositionTimer(),
            policy: .default)
    }

    @Test("Recording an open leaves the webpage sidecar's bytes and mtime untouched")
    func recordingAnOpenLeavesTheSidecarAlone() async throws {
        try await withScratch { scratch in
            let sidecar = try seedSidecar(annotations: [annotation("a1")])
            let before = try digest(sidecar)
            let beforeModified = try modified(sidecar)

            let store = makeStore()
            await store.record(.opened(title: "Spec #150", tabOrdinal: 0), for: .web(normalizedURL: pageURL))
            await store.flush()

            #expect(try digest(sidecar) == before)
            #expect(try modified(sidecar) == beforeModified)
            #expect(FileManager.default.fileExists(atPath: scratch.positionsDir.path))
        }
    }

    @Test("Recording a reading position writes only under positions/")
    func recordingAPositionWritesOnlyUnderPositions() async throws {
        try await withScratch { scratch in
            _ = try seedSidecar(annotations: [annotation("a1")])
            let webBefore = fileTree(scratch.webDir)

            let store = makeStore()
            await store.record(
                .moved(ReadingPosition(page: 4, scrollFraction: 0.41)),
                for: .web(normalizedURL: pageURL))
            await store.flush()

            #expect(fileTree(scratch.webDir) == webBefore)
            #expect(
                fileTree(scratch.positionsDir)
                    == [PositionLayout.fileName(for: PositionFixtures.phone.id)])
        }
    }

    @Test("A full open-scroll-close-flush cycle leaves the sidecar's annotations byte-identical")
    func fullCycleLeavesAnnotationsByteIdentical() async throws {
        try await withScratch { _ in
            let sidecar = try seedSidecar(annotations: [annotation("a1"), annotation("a2")])
            let before = try Data(contentsOf: sidecar)

            let store = makeStore()
            let key = DocumentKey.web(normalizedURL: pageURL)
            await store.record(.opened(title: "Spec #150", tabOrdinal: 0), for: key)
            for page in 1...50 {
                await store.record(.moved(ReadingPosition(page: page)), for: key)
            }
            await store.record(.closed, for: key)
            await store.flush()

            #expect(try Data(contentsOf: sidecar) == before)
            let reloaded = try #require(WebLibrary.loadRecord(at: sidecar))
            #expect(reloaded.annotations.map(\.id) == ["a1", "a2"])
        }
    }

    @Test("The positions directory is a sibling of web/, never inside it")
    func positionsIsASiblingOfWeb() {
        let previousStore = WebLibrary.storeDirOverride
        let previousRoot = PositionLayout.rootOverride
        WebLibrary.storeDirOverride = nil
        PositionLayout.rootOverride = nil
        defer {
            WebLibrary.storeDirOverride = previousStore
            PositionLayout.rootOverride = previousRoot
        }

        let positions = PositionLayout.root
        let web = WebLibrary.storeDir

        #expect(positions.deletingLastPathComponent() == web.deletingLastPathComponent())
        #expect(positions.lastPathComponent == "positions")
        #expect(!positions.path.hasPrefix(web.path + "/"))
        #expect(!web.path.hasPrefix(positions.path + "/"))
    }

    /// Construction-level, not behavioural: the adapter is handed a root and
    /// only ever appends a single leaf name to it, so there is no string it can
    /// be given that makes it address `records/`.
    @Test("The store's storage adapter cannot address the records directory")
    func storageAdapterCannotAddressTheRecordsDirectory() async throws {
        try await withScratch { scratch in
            let storage = FilePositionStorage()
            let file = storage.fileURL(for: PositionFixtures.phone.id)

            #expect(storage.root == scratch.positionsDir)
            #expect(file.deletingLastPathComponent() == scratch.positionsDir)
            #expect(file.lastPathComponent == PositionLayout.fileName(for: PositionFixtures.phone.id))
            #expect(!file.path.hasPrefix(WebLibrary.activeLayout.recordsDir.path + "/"))
            #expect(!file.path.hasPrefix(scratch.webDir.path + "/"))
        }
    }
}
