import Foundation
import Testing
@testable import Vellum

// .serialized because the move tests install the process-global StubURLProtocol
// handler; suites run in parallel with each other, so every stub-using suite
// must serialize its own tests and tolerate none elsewhere running concurrently.
@Suite(.serialized)
struct RaindropClientTests {
    @Test func mapsLosslessIDsTagsDatesPDFAndCollection() throws {
        let page = try RaindropClient.mapPage(FixtureLoader.data("Raindrop", "items-page-0"), page: 0, perPage: 50)
        let item = try #require(page.items.first)
        #expect(item.id == "raindrop:99")
        #expect(item.tags == ["pdf", "research"])
        #expect(item.kind == .pdf)
        #expect(item.collectionIDs == ["raindrop:collection:11"])
        #expect(item.sourceURL.absoluteString == "https://example.com/file.pdf")
        #expect(item.thumbnailURL?.absoluteString == "https://example.com/cover.png")
        #expect(item.savedAt == IntegrationDateParser.parse("2026-01-01T00:00:00Z"))
        #expect(item.updatedAt == IntegrationDateParser.parse("2026-01-04T00:00:00Z"))
        #expect(item.pdfRetrieval == .raindropURL(URL(string: "https://example.com/file.pdf")!))
    }

    @Test func fullSizedPageContinuesAndShortPageTerminates() throws {
        let continuing = try RaindropClient.mapPage(FixtureLoader.data("Raindrop", "items-page-0"), page: 0, perPage: 1)
        #expect(continuing.hasMore)
        #expect(continuing.nextCursor == "1")

        let terminal = try RaindropClient.mapPage(FixtureLoader.data("Raindrop", "items-page-final"), page: 1, perPage: 50)
        #expect(terminal.hasMore == false)
        #expect(terminal.nextCursor == nil)
        #expect(terminal.responseWasEmpty)
    }

    @Test func siblingCollectionsFollowDescendingVendorSortOrder() throws {
        let data = Data("""
        [{"_id":1,"title":"Lower","sort":10},{"_id":2,"title":"Higher","sort":100}]
        """.utf8)
        let collections = try JSONDecoder().decode([RaindropCollectionDTO].self, from: data)

        let values = RaindropClient.flattenCollections(collections)

        #expect(values.map(\.title) == ["Higher", "Lower"])
    }

    @Test func nestedCollectionsHaveStableParentageAndDepth() throws {
        let rootsJSON = try JSONSerialization.jsonObject(with: FixtureLoader.data("Raindrop", "collections-root"))
        let childrenJSON = try JSONSerialization.jsonObject(with: FixtureLoader.data("Raindrop", "collections-child"))
        let rootsObject = try #require(rootsJSON as? [String: Any])
        let childrenObject = try #require(childrenJSON as? [String: Any])
        let rootsData = try JSONSerialization.data(withJSONObject: try #require(rootsObject["items"]))
        let childrenData = try JSONSerialization.data(withJSONObject: try #require(childrenObject["items"]))
        let roots = try JSONDecoder().decode([RaindropCollectionDTO].self, from: rootsData)
        let children = try JSONDecoder().decode([RaindropCollectionDTO].self, from: childrenData)

        let values = RaindropClient.flattenCollections(roots + children)

        #expect(values.map(\.title) == ["Research", "Swift", "Concurrency"])
        #expect(values.map(\.depth) == [0, 1, 2])
        #expect(values.map(\.parentID) == [nil, "raindrop:collection:10", "raindrop:collection:11"])
        #expect(values.map(\.sortIndex) == [0, 1, 2])
    }

    @Test func scalarCollectionReferenceAndMinimalFieldsDecode() throws {
        let page = try RaindropClient.mapPage(FixtureLoader.data("Raindrop", "item-minimal"), page: 0, perPage: 50)
        let item = try #require(page.items.first)
        #expect(item.id == "raindrop:minimal")
        #expect(item.collectionIDs == ["raindrop:collection:10"])
        #expect(item.title == "example.com")
        #expect(item.kind == .article)
    }

    @Test func fileMimeTypeClassifiesSuffixlessUploadedPDF() throws {
        let data = Data("""
        {"items":[{"_id":42,"link":"https://up.raindrop.io/file/42","title":"Paper","type":"document","file":{"type":"application/pdf"}}]}
        """.utf8)

        let page = try RaindropClient.mapPage(data, page: 0, perPage: 50)
        let item = try #require(page.items.first)

        #expect(item.kind == .pdf)
        #expect(item.pdfRetrieval == .raindropURL(URL(string: "https://up.raindrop.io/file/42")!))
    }

    @Test func malformedSiblingIsTolerated() throws {
        let page = try RaindropClient.mapPage(FixtureLoader.data("Raindrop", "malformed-among-valid"), page: 0, perPage: 50)
        #expect(page.items.count == 1)
        #expect(page.skippedRecordCount == 1)
    }

    @Test func moveItemSendsCollectionReferenceAndAcceptsConfirmedResult() async throws {
        let recorder = RequestRecorder()
        StubURLProtocol.install { request in
            recorder.record(request)
            return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, Data(#"{"result":true}"#.utf8))
        }
        defer { StubURLProtocol.reset() }
        let client = RaindropClient(http: ReadLaterHTTPClient(session: StubURLProtocol.session(), sleeper: NoWaitIntegrationSleeper()))

        try await client.moveItem(token: "secret", itemID: "99", collectionVendorID: "-1")

        let request = try #require(recorder.requests().first)
        #expect(request.httpMethod == "PUT")
        #expect(request.url?.path() == "/rest/v1/raindrop/99")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer secret")
        let body = try JSONSerialization.jsonObject(with: try #require(recorder.bodies().first)) as? [String: [String: Int64]]
        #expect(body == ["collection": ["$id": -1]])
    }

    @Test func moveItemRejectsUnconfirmedResultAndNonNumericCollection() async throws {
        StubURLProtocol.install { request in
            (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, Data(#"{"result":false}"#.utf8))
        }
        defer { StubURLProtocol.reset() }
        let client = RaindropClient(http: ReadLaterHTTPClient(session: StubURLProtocol.session(), sleeper: NoWaitIntegrationSleeper()))

        await #expect(throws: IntegrationError.invalidResponse) {
            try await client.moveItem(token: "secret", itemID: "99", collectionVendorID: "11")
        }
        await #expect(throws: IntegrationError.unsupportedDestination) {
            try await client.moveItem(token: "secret", itemID: "99", collectionVendorID: "not-a-number")
        }
    }
}
