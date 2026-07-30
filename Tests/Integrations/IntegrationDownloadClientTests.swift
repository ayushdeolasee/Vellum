import AppKit
import Foundation
import Testing
@testable import Vellum

@Suite(.serialized)
struct IntegrationDownloadClientTests {
    @Test func hashDerivedTemporaryDestinationCannotTraverse() async throws {
        let root = try IntegrationTemporaryRoot.make(); defer { try? FileManager.default.removeItem(at: root) }
        let cache = IntegrationsCache(root: root)
        let url = try await cache.temporaryDownloadURL(provider: .readwise, itemID: "../../secret")
        #expect(url.deletingLastPathComponent().lastPathComponent == "downloads")
        #expect(!url.lastPathComponent.contains(".."))
    }

    @Test func thumbnailStreamingStopsAtTheConfiguredByteLimit() async throws {
        let root = try IntegrationTemporaryRoot.make(); defer { try? FileManager.default.removeItem(at: root) }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [OversizedThumbnailURLProtocol.self]
        OversizedThumbnailURLProtocol.payload = Data(repeating: 0, count: 5)
        let cache = IntegrationThumbnailCache(root: root, session: URLSession(configuration: configuration), maximumBytes: 4)

        let result = await cache.imageURL(for: URL(string: "https://example.com/oversized-image"))

        #expect(result == nil)
        #expect((try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil).isEmpty) != false)
    }

    @Test func thumbnailMetadataRejectsImagesAboveThePixelLimit() async throws {
        let root = try IntegrationTemporaryRoot.make(); defer { try? FileManager.default.removeItem(at: root) }
        let representation = try #require(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 2, pixelsHigh: 2, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        OversizedThumbnailURLProtocol.payload = try #require(representation.representation(using: .png, properties: [:]))
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [OversizedThumbnailURLProtocol.self]
        let cache = IntegrationThumbnailCache(root: root, session: URLSession(configuration: configuration), maximumPixelCount: 3)

        let result = await cache.imageURL(for: URL(string: "https://example.com/image-bomb"))

        #expect(result == nil)
    }
}

private final class OversizedThumbnailURLProtocol: URLProtocol {
    nonisolated(unsafe) static var payload = Data()
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Self.payload)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
