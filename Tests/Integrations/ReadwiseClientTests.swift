import Foundation
import Testing
@testable import Vellum

// .serialized: the move test installs the process-global StubURLProtocol handler.
extension StubbedTransportSuites { @Suite(.serialized) struct ReadwiseClientTests {
    @Test func mapsSourceURLTagObjectLocationDatesAndCursor() throws {
        let page = try ReadwiseClient.mapPage(FixtureLoader.data("Readwise", "items-page-1"))
        let item = try #require(page.items.first)
        #expect(item.sourceURL.absoluteString == "https://example.com/original")
        #expect(item.title == "Original article")
        #expect(item.author == "Ada")
        #expect(item.excerpt == "Excerpt")
        #expect(item.tags == ["reading", "swift"])
        #expect(item.collectionIDs == ["readwise:collection:later"])
        #expect(item.kind == .article)
        #expect(item.thumbnailURL?.absoluteString == "https://example.com/image.png")
        #expect(item.savedAt == IntegrationDateParser.parse("2026-01-01T00:00:00Z"))
        #expect(item.updatedAt == IntegrationDateParser.parse("2026-01-02T00:00:00Z"))
        #expect(page.nextCursor == "cursor-2")
        #expect(page.hasMore)
    }

    @Test func minimalRecordUsesStableFallbacks() throws {
        let page = try ReadwiseClient.mapPage(FixtureLoader.data("Readwise", "item-minimal"))
        let item = try #require(page.items.first)
        #expect(item.id == "readwise:minimal")
        #expect(item.title == "example.com")
        #expect(item.kind == .other)
        #expect(item.savedAt == Date(timeIntervalSince1970: 0))
        #expect(item.updatedAt == Date(timeIntervalSince1970: 0))
        #expect(page.hasMore == false)
    }

    @Test func malformedSiblingDoesNotDiscardValidItem() throws {
        let page = try ReadwiseClient.mapPage(FixtureLoader.data("Readwise", "malformed-among-valid"))
        #expect(page.items.map(\.id) == ["readwise:good"])
        #expect(page.skippedRecordCount == 1)
    }

    @Test func pdfUsesDurableItemStrategyWithoutPersistingSignedURL() throws {
        let item = try #require(ReadwiseClient.mapPage(FixtureLoader.data("Readwise", "items-page-final")).items.first)
        #expect(item.pdfRetrieval == .readwiseItem(id: "rw-pdf"))
        let encoded = String(decoding: try JSONEncoder.integrations.encode(item), as: UTF8.self)
        #expect(encoded.contains("signed.example.com") == false)
        #expect(encoded.contains("raw_source_url") == false)
    }

    @Test func moveItemPatchesLocationAndRefusesUnsupportedDestinations() async throws {
        let recorder = RequestRecorder()
        StubURLProtocol.install { request in
            recorder.record(request)
            return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, Data("{}".utf8))
        }
        defer { StubURLProtocol.reset() }
        let client = ReadwiseClient(http: ReadLaterHTTPClient(session: StubURLProtocol.session(), sleeper: NoWaitIntegrationSleeper()))

        try await client.moveItem(token: "secret", itemID: "doc-1", locationVendorID: "archive")

        let request = try #require(recorder.requests().first)
        #expect(request.httpMethod == "PATCH")
        #expect(request.url?.path() == "/api/v3/update/doc-1/")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Token secret")
        let body = try JSONSerialization.jsonObject(with: try #require(recorder.bodies().first)) as? [String: String]
        #expect(body == ["location": "archive"])

        // feed is excluded deliberately; shortlist is a list-filter value the
        // Reader v3 update endpoint does not accept.
        await #expect(throws: IntegrationError.unsupportedDestination) {
            try await client.moveItem(token: "secret", itemID: "doc-1", locationVendorID: "feed")
        }
        await #expect(throws: IntegrationError.unsupportedDestination) {
            try await client.moveItem(token: "secret", itemID: "doc-1", locationVendorID: "shortlist")
        }
        #expect(recorder.requests().count == 1)
    }

    // A hostile itemID must not be able to retarget the request via
    // `URL.appending(path:)`'s "/" handling (e.g. escaping into "../auth").
    @Test func moveItemRejectsItemIDsOutsideTheSafeCharset() async throws {
        let recorder = RequestRecorder()
        StubURLProtocol.install { request in
            recorder.record(request)
            return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, Data("{}".utf8))
        }
        defer { StubURLProtocol.reset() }
        let client = ReadwiseClient(http: ReadLaterHTTPClient(session: StubURLProtocol.session(), sleeper: NoWaitIntegrationSleeper()))

        await #expect(throws: IntegrationError.invalidResponse) {
            try await client.moveItem(token: "secret", itemID: "../auth", locationVendorID: "archive")
        }
        #expect(recorder.requests().isEmpty)
    }
}
}
