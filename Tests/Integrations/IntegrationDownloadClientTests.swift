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

    // MARK: - IntegrationDownloadClient

    @Test func maximumBytesEnforcedMidFlightWhenContentLengthIsAbsent() async throws {
        let root = try IntegrationTemporaryRoot.make(); defer { try? FileManager.default.removeItem(at: root) }
        let destination = root.appendingPathComponent("payload.pdf")
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]
        StubURLProtocol.installStreaming { request in
            // No Content-Length header: the client can only learn the payload is
            // oversized by counting bytes as chunks arrive.
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            let chunks = (0..<8).map { _ in StubStreamingChunk(Data(repeating: 7, count: 4096)) }
            return StubStreamingResponse(response: response, chunks: chunks)
        }
        defer { StubURLProtocol.reset() }
        let client = IntegrationDownloadClient(session: URLSession(configuration: configuration))

        await #expect(throws: IntegrationError.downloadTooLarge) {
            try await client.download(URLRequest(url: URL(string: "https://example.com/oversized.pdf")!), to: destination, maximumBytes: 10_000) { _ in }
        }
        #expect(!FileManager.default.fileExists(atPath: destination.path))
    }

    @Test func cancellationDuringDownloadPropagatesAndCleansUpTheTemporaryFile() async throws {
        let root = try IntegrationTemporaryRoot.make(); defer { try? FileManager.default.removeItem(at: root) }
        let destination = root.appendingPathComponent("payload.pdf")
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]
        StubURLProtocol.installStreaming { request in
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            let chunks = [
                StubStreamingChunk(Data(repeating: 1, count: 4096)),
                StubStreamingChunk(Data(repeating: 2, count: 4096), delay: .seconds(60)),
            ]
            return StubStreamingResponse(response: response, chunks: chunks)
        }
        defer { StubURLProtocol.reset() }
        let client = IntegrationDownloadClient(session: URLSession(configuration: configuration))
        let startedDownloading = IntegrationTestGate()

        let downloadTask = Task {
            try await client.download(URLRequest(url: URL(string: "https://example.com/slow.pdf")!), to: destination, maximumBytes: 10_000_000) { _ in
                await startedDownloading.open()
            }
        }
        await startedDownloading.wait()
        downloadTask.cancel()

        await #expect(throws: CancellationError.self) { try await downloadTask.value }
        #expect(!FileManager.default.fileExists(atPath: destination.path))
    }

    @Test func successfulDownloadWritesExactlyTheChunkedPayloadBytes() async throws {
        let root = try IntegrationTemporaryRoot.make(); defer { try? FileManager.default.removeItem(at: root) }
        let destination = root.appendingPathComponent("payload.pdf")
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]
        let payload = [Data(repeating: 1, count: 1_000), Data(repeating: 2, count: 200_000), Data(repeating: 3, count: 500)]
        let expected = payload.reduce(Data(), +)
        StubURLProtocol.installStreaming { request in
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: ["Content-Length": String(expected.count)])!
            return StubStreamingResponse(response: response, chunks: payload.map { StubStreamingChunk($0) })
        }
        defer { StubURLProtocol.reset() }
        let client = IntegrationDownloadClient(session: URLSession(configuration: configuration))

        let result = try await client.download(URLRequest(url: URL(string: "https://example.com/file.pdf")!), to: destination, maximumBytes: 1_000_000) { _ in }

        #expect(result.response.statusCode == 200)
        #expect(try Data(contentsOf: destination) == expected)
    }

    @Test func nonSuccessStatusThrowsInvalidResponseAndCleansUpTheTemporaryFile() async throws {
        let root = try IntegrationTemporaryRoot.make(); defer { try? FileManager.default.removeItem(at: root) }
        let destination = root.appendingPathComponent("payload.pdf")
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]
        StubURLProtocol.installStreaming { request in
            let response = HTTPURLResponse(url: request.url!, statusCode: 404, httpVersion: nil, headerFields: nil)!
            return StubStreamingResponse(response: response, chunks: [])
        }
        defer { StubURLProtocol.reset() }
        let client = IntegrationDownloadClient(session: URLSession(configuration: configuration))

        await #expect(throws: IntegrationError.invalidResponse) {
            try await client.download(URLRequest(url: URL(string: "https://example.com/missing.pdf")!), to: destination, maximumBytes: 1_000_000) { _ in }
        }
        #expect(!FileManager.default.fileExists(atPath: destination.path))
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
