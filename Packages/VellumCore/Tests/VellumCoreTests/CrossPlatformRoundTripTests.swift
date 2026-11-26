import Foundation
import Testing
import VellumCore

/// Invoked in three different processes by roundtrip-e2e.sh. The marker and
/// peer names are outside the shared folder, never part of replicated state.
@Suite struct CrossPlatformRoundTripTests {
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
            try await library.verifyRecovery()
        case "send":
            #if os(macOS)
            try await library.seed()
            try await library.positions.write(PeerLibrary.position("mac"))
            try await library.write(PeerLibrary.capture, PeerLibrary.archive("mac"))
            #else
            Issue.record("The first writer must be native macOS.")
            #endif
        case "mutate":
            #if os(Linux)
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
            try await library.positions.write(PeerLibrary.position("linux"))

            // Read the Mac ZIP and re-export its actual manifest and contents.
            let original = try library.read(PeerLibrary.capture)
            let archive = try ArchiveCodec.decode(original)
            var manifest = archive.manifest
            manifest.unknownFields["future_capture"] = PeerLibrary.future
            let zip = try MiniZip(data: original, maxBytes: 16384, maxEntries: 8, maxUncompressedBytes: 16384)
            let output = try ArchiveCodec.encode(manifest: manifest, snapshotHtml: archive.snapshotHtml,
                assets: [], pagesJson: zip.readCapped("text/pages.json", cap: 1024),
                annotations: archive.annotations + [PeerLibrary.annotation("linux")])
            try await library.write(PeerLibrary.capture, output)
            #else
            Issue.record("The middle writer must run on Linux.")
            #endif
        case "receive":
            #if os(macOS)
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
            #expect(try library.read(PeerLibrary.pdf) == Data(contentsOf: PdfFixtureBuilder.fixtureURL("classic-two-column")))
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
