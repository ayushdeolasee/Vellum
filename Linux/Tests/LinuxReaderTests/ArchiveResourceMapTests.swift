import Foundation
import LinuxReader
import Testing
import VellumCore

@Test func archiveResourcesAreConfinedToOneSelection() throws {
    let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent()
    let archive = try ArchiveCodec.decode(at: repo.appendingPathComponent(
        "Packages/VellumCore/Tests/VellumCoreTests/Fixtures/harbor.vellumweb"))
    let map = ArchiveResourceMap(archive: archive, documentToken: UUID())
    let base = map.documentURL.deletingLastPathComponent().absoluteString
    let asset = base + "__VELLUM_ASSET__/sample.png"
    #expect(map.hasHandwriting)
    #expect(try map.response(for: map.documentURL).bytes == Data(archive.snapshotHtml.utf8))
    let response = try map.response(for: #require(URL(string: asset)))
    #expect(response.mime == "image/png")
    #expect(response.bytes == archive.assets.first?.1)
    for raw in [asset.replacingOccurrences(of: "//archive/", with: "//other/"),
                asset.replacingOccurrences(of: "//archive/", with: "//user@archive/"),
                asset.replacingOccurrences(of: "vellum-web:", with: "https:"),
                ArchiveResourceMap(archive: archive, documentToken: UUID()).documentURL.absoluteString,
                base + "__VELLUM_ASSET__/missing.png", asset + "?a", asset + "#a",
                base + "__VELLUM_ASSET__/%2e%2e%2fsample.png",
                base + "__VELLUM_ASSET__/dir%5csample.png"] {
        let uri = try #require(URL(string: raw))
        #expect(throws: URLError.self) { try map.response(for: uri) }
    }
}
