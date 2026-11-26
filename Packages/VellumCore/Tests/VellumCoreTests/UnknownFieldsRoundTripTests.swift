import Foundation
import Testing
import VellumCore
#if canImport(Vellum)
@testable import Vellum
#endif

/// Exercise each object codec independently. Decode the injected numbers from
/// literal JSON so a lossy Double conversion cannot make both sides match.
@Suite struct UnknownFieldsRoundTripTests {
    private static let extras = #""future":{"array":[null,true,9223372036854775807,12345678901234567890],"string":"next"}"#

    private func check<T: Codable>(_ sample: T, _ edit: (inout T) -> Void) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let original = String(decoding: try encoder.encode(sample), as: UTF8.self)
        let enriched = original.dropLast() + "," + Self.extras + "}"
        var value = try JSONDecoder().decode(T.self, from: Data(enriched.utf8))
        edit(&value)
        let output = String(decoding: try encoder.encode(value), as: UTF8.self)
        #expect(output.contains(Self.extras))
        var expected = sample
        edit(&expected)
        let expectedKnown = try JSONDecoder().decode([String: JSONValue].self, from: encoder.encode(expected))
        var actual = try JSONDecoder().decode([String: JSONValue].self, from: Data(output.utf8))
        actual.removeValue(forKey: "future")
        #expect(actual == expectedKnown)
    }

    @Test func coreObjects() throws {
        let rect = AnnotationRect(x: 1, y: 2, width: 3, height: 4)
        try check(rect) { $0.x = 12 }
        try check(PositionData(rects: [rect], pageWidth: 30, pageHeight: 50)) { $0.prefix = "before" }
        try check(Annotation(id: "a", type: .note, pageNumber: 1, createdAt: "then", updatedAt: "now")) { $0.content = "edit" }
        try check(WebPageRecord(url: "https://example.test")) { $0.title = "edit" }
        try check(ReadingPosition(page: 1)) { $0.page = 2 }
        try check(Stamped(at: Date(), value: "old")) { $0.value = "new" }
        try check(OpenState(isOpen: true)) { $0.isOpen = false }
        let hashes = ManifestHashes(snapshotHtml: "h", pageText: "t")
        let asset = ManifestAsset(path: "p", url: "u", contentType: "c", bytes: 0)
        try check(hashes) { $0.annotations = "a" }
        try check(asset) { $0.bytes = 1 }
        try check(ArchiveManifest(format: "vellumweb", version: 1, url: "u", canonicalUrl: "u",
            title: nil, capturedAt: "now", generator: "fixture", loadingPolicy: "live-first",
            pageCount: nil, lastPage: nil, hashes: hashes, assets: [asset], assetsSkipped: 0)) { $0.title = "edit" }
    }

    #if canImport(Vellum)
    @Test func appleObjects() throws {
        let bounds = WebInkRecord.Bounds(.zero)
        let layout = WebInkRecord.Layout(contentWidth: 10, docHeight: 30)
        let anchor = WebInkRecord.Anchor(startOffset: 1, rect: bounds)
        let cluster = WebInkRecord.Cluster(id: "a", drawing: Data(), bounds: bounds, anchor: anchor)
        try check(bounds) { $0.x = 1 }
        try check(layout) { $0.contentWidth = 2 }
        try check(anchor) { $0.text = "edit" }
        try check(cluster) { $0.anchor = nil }
        try check(WebInkRecord(version: 3, url: "u", updatedAt: "t", layout: layout, clusters: [cluster])) { $0.updatedAt = "new" }
        try check(WebArchiveIndex.Contents()) { $0.entries["key"] = "file" }
        try check(DocumentDataStore.Meta(version: 1, kind: "pdf", lastKnownPath: "p", lastOpened: "t")) { $0.title = "new" }
        try check(AiMessage(id: "m", role: .user, content: "old", createdAt: "t")) { $0.content = "new" }
        try check(AiReference(kind: .selection(text: "old", page: 1))) { $0.kind = .selection(text: "new", page: 1) }
        try check(AiPageImageSnapshot(base64Data: "bytes", mediaType: "png", width: 10, height: 20)) { $0.base64Data = "" }
        try check(AiToolSummary(title: "source")) { $0.detail = "edit" }
        try check(AiToolSummary.Source(page: 1, excerpt: "old")) { $0.excerpt = "new" }
        try check(AiUsage()) { $0.inputTokens += 1 }
    }
    #endif
}
