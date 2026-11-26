import Foundation
import Testing
import VellumCore

/// Invoked in three different processes by roundtrip-e2e.sh. The marker and
/// peer names are outside the shared folder, never part of replicated state.
@Suite struct CrossPlatformRoundTripTests {
    private final class BundleToken {}
    private let inkKey = DocumentKey.web(normalizedURL: "https://fixture.test/article").hash
    private let captureKey = DocumentKey.web(normalizedURL: PeerLibrary.address + "/mac").hash

    private func inkFixture() throws -> Data {
        #if SWIFT_PACKAGE
        let bundle = Bundle.module, directory = "Fixtures/Web"
        #else
        let bundle = Bundle(for: BundleToken.self), directory = "Web"
        #endif
        let file = try #require(bundle.url(forResource: "web-ink-v3.ink", withExtension: "json", subdirectory: directory))
        return try Data(contentsOf: file)
    }

    static func runPhase() throws -> (PeerLibrary, String) {
        let env = ProcessInfo.processInfo.environment
        let parent = URL(fileURLWithPath: try #require(env["VELLUM_S9_SANDBOX"]), isDirectory: true)
        guard try String(contentsOf: parent.appendingPathComponent(".synthetic-s9"), encoding: .utf8) == "synthetic\n"
        else { throw CocoaError(.fileReadCorruptFile) }
        let peer = try #require(env["VELLUM_S9_PEER"])
        try #require(["mac", "linux"].contains(peer))
        let library = PeerLibrary(root: parent.appendingPathComponent(peer, isDirectory: true))
        return (library, try #require(env["VELLUM_S9_PHASE"]))
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["VELLUM_S9_PHASE"] != nil))
    func exchange() async throws {
        let (library, phase) = try Self.runPhase()
        switch phase {
        case "prepare":
            try await library.prepareIgnore(library.root.lastPathComponent)
        case "seed":
            try await library.seed()
            try await library.write(".vellum/index.json.tmp", Data([42]))
        case "mac-edit", "linux-edit":
            try await library.edit(phase == "mac-edit" ? "mac" : "linux")
        case "recover":
            try await library.recover()
            try #require(try library.conflictSiblings().isEmpty)
            try await library.verifyRecovery(expectMergedMeta: library.root.lastPathComponent == "mac")
        case "verify-merged", "verify-preserved":
            try #require(try library.conflictSiblings().isEmpty)
            try await library.verifyRecovery(expectMergedMeta: phase == "verify-merged")
        case "send":
            #if os(macOS)
            try await library.seed()
            _ = try await library.verifyPDFs()
            let ink = try inkFixture()
            try await library.write(".vellum/records/\(inkKey).ink.json", ink)
            let capture = try ArchiveCodec.decode(PeerLibrary.archive("mac"))
            var manifest = capture.manifest
            let image = CapturedAsset(name: "sample.png", url: PeerLibrary.address + "/sample.png",
                                      contentType: "image/png", bytes: PeerLibrary.png)
            manifest.assets = [ManifestAsset(path: "snapshot/assets/sample.png", url: image.url,
                contentType: image.contentType, bytes: image.bytes.count, sha256: ArchiveCodec.sha256Hex(image.bytes))]
            let bytes = try ArchiveCodec.encode(manifest: manifest, snapshotHtml: capture.snapshotHtml,
                assets: [image], pagesJson: Data("[]".utf8), annotations: capture.annotations, inkJson: ink)
            _ = try await library.catalog.save(bytes, forKey: captureKey)
            #else
            Issue.record("The first writer must be native macOS.")
            #endif
        case "mutate":
            #if os(Linux)
            try await library.verifyLongCapture()
            let baseline = try library.read(PeerLibrary.record)
            var page = try JSONDecoder().decode(WebPageRecord.self, from: baseline)
            try #require(page.unknownFields["future"] == PeerLibrary.future)
            try #require(page.annotations.map(\.id) == ["shared"])
            page.title = "Read on Linux"
            page.annotations.append(PeerLibrary.annotation("linux"))
            page.annotations[1].unknownFields["extension"] = PeerLibrary.future
            try await library.write(PeerLibrary.record, JSONEncoder().encode(page))
            let existing = await library.positions.loadAll()
            try #require(existing.count == 1 && existing[0].devicePlatform == "macos")
            #if canImport(LinuxReader)
            let pdfID = try await library.verifyPDFs()
            try await library.positions.write(PeerLibrary.position("linux", pdfID: pdfID))
            #else
            Issue.record("Run the exchange with the production Linux reader linked by roundtrip-e2e.sh.")
            #endif

            // Read the Mac ZIP and re-export its actual manifest and contents.
            let incoming = try await library.catalog.lookup(forKey: captureKey)
            let original = try #require(incoming?.bytes)
            let archive = try ArchiveCodec.decode(original)
            var manifest = archive.manifest
            manifest.unknownFields["future_capture"] = PeerLibrary.future
            let zip = try MiniZip(data: original, maxBytes: 16384, maxEntries: 8, maxUncompressedBytes: 16384)
            let asset = try #require(archive.assets.first)
            let descriptor = try #require(manifest.assets.first)
            let image = CapturedAsset(name: asset.0, url: descriptor.url, contentType: descriptor.contentType, bytes: asset.1)
            #expect(image.bytes == PeerLibrary.png)
            #expect(archive.inkJSON == (try library.read(".vellum/records/\(inkKey).ink.json")))
            let output = try ArchiveCodec.encode(manifest: manifest, snapshotHtml: archive.snapshotHtml,
                assets: [image], pagesJson: zip.readCapped("text/pages.json", cap: 1024),
                annotations: archive.annotations + [PeerLibrary.annotation("linux")], inkJson: archive.inkJSON)
            _ = try await library.catalog.save(output, forKey: captureKey)
            #else
            Issue.record("The middle writer must run on Linux.")
            #endif
        case "receive":
            #if os(macOS)
            try await library.verifyLongCapture()
            var page = try JSONDecoder().decode(WebPageRecord.self, from: library.read(PeerLibrary.record))
            #expect(page.title == "Read on Linux")
            #expect(page.annotations.map(\.id) == ["shared", "linux"])
            #expect(page.unknownFields["future"] == PeerLibrary.future)
            page.lastPage = 2
            try await library.write(PeerLibrary.record, JSONEncoder().encode(page))
            let reopened = try JSONDecoder().decode(WebPageRecord.self, from: library.read(PeerLibrary.record))
            #expect(reopened.annotations.last?.unknownFields["extension"] == PeerLibrary.future)
            #expect(reopened.lastPage == 2)
            let capture = try ArchiveCodec.decode(at: library.url(PeerLibrary.capture))
            #expect(capture.manifest.unknownFields["future_capture"] == PeerLibrary.future)
            #expect(capture.annotations.map(\.id) == ["mac", "linux"])
            #expect(capture.snapshotHtml == "<html>mac</html>")
            #expect(capture.assets.map { $0.1 } == [PeerLibrary.png])
            let originalInk = try inkFixture()
            #expect(capture.inkJSON == originalInk)
            #expect(try library.read(".vellum/records/\(inkKey).ink.json") == originalInk)
            let originalDigest = library.root.deletingLastPathComponent().appendingPathComponent("before-migration/published.sha256")
            #expect(try DocumentIdentity.byteHash(library.read(PeerLibrary.pdf)) == String(contentsOf: originalDigest, encoding: .utf8))
            #expect(try library.read(PeerLibrary.messages) == PeerLibrary.messageBytes(["shared"]))
            #expect(try library.read(PeerLibrary.note) == Data(PeerLibrary.imageLink.utf8))
            #expect(try library.read(PeerLibrary.doc + "attachments/" + PeerLibrary.imageName) == PeerLibrary.png)
            try await library.verifyPositions()
            #else
            Issue.record("The final reader must be native macOS.")
            #endif
        default: throw CocoaError(.featureUnsupported)
        }
        try Data(phase.utf8).write(to: library.root.deletingLastPathComponent().appendingPathComponent("completed-" + phase))
    }
}
