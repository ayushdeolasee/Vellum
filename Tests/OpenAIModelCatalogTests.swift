import Foundation
import Testing
@testable import Vellum

struct OpenAIModelCatalogTests {
    @Test func parsesOnlyModelsCompatibleWithVellumsResponsesClient() throws {
        let data = try JSONSerialization.data(withJSONObject: [
            "data": [
                ["id": "gpt-5.6-sol"],
                ["id": "gpt-5.6-sol"],
                ["id": "gpt-6"],
                ["id": "gpt-4.1"],
                ["id": "gpt-4o"],
                ["id": "o3"],
                ["id": "gpt-3.5-turbo"],
                ["id": "gpt-4-turbo"],
                ["id": "o1-mini"],
                ["id": "gpt-4o-mini-transcribe"],
                ["id": "gpt-image-2"],
                ["id": "text-embedding-3-large"],
            ],
        ])

        #expect(OpenAIModelCatalog.parse(data) == [
            "gpt-4.1", "gpt-4o", "gpt-5.6-sol", "gpt-6", "o3",
        ])
    }

    @Test func malformedResponsesProduceNoModels() {
        #expect(OpenAIModelCatalog.parse(Data("{}".utf8)).isEmpty)
        #expect(OpenAIModelCatalog.parse(Data("not json".utf8)).isEmpty)
    }
}

extension StubbedTransportSuites {
    @Suite(.serialized)
    @MainActor
    struct OpenAIModelCatalogStateTests {
        @Test func emptyKeyClearsLoadedCatalog() async throws {
            StubURLProtocol.install { request in
                (
                    HTTPURLResponse(
                        url: request.url!,
                        statusCode: 200,
                        httpVersion: nil,
                        headerFields: nil
                    )!,
                    Data(#"{"data":[{"id":"gpt-5"}]}"#.utf8)
                )
            }
            defer { StubURLProtocol.reset() }
            let catalog = OpenAIModelCatalog()

            await catalog.refresh(apiKey: "key-a", session: StubURLProtocol.session())
            #expect(catalog.models == ["gpt-5"])

            await catalog.refresh(apiKey: "   ", session: StubURLProtocol.session())

            #expect(catalog.models.isEmpty)
            #expect(catalog.error == nil)
            #expect(catalog.isLoading == false)
        }

        @Test func newCredentialSupersedesInFlightRequest() async {
            StubURLProtocol.installStreaming { request in
                let isFirstCredential = request.value(forHTTPHeaderField: "Authorization") == "Bearer key-a"
                let response = HTTPURLResponse(
                    url: request.url!,
                    statusCode: isFirstCredential ? 401 : 200,
                    httpVersion: nil,
                    headerFields: nil
                )!
                let data = isFirstCredential
                    ? Data()
                    : Data(#"{"data":[{"id":"gpt-6"}]}"#.utf8)
                return StubStreamingResponse(
                    response: response,
                    chunks: [
                        StubStreamingChunk(
                            data,
                            delay: isFirstCredential ? .milliseconds(50) : nil
                        ),
                    ]
                )
            }
            defer { StubURLProtocol.reset() }
            let session = StubURLProtocol.session()
            let catalog = OpenAIModelCatalog()

            let firstRefresh = Task {
                await catalog.refresh(apiKey: "key-a", session: session)
            }
            while catalog.isLoading == false {
                await Task.yield()
            }

            let secondRefresh = Task {
                await catalog.refresh(apiKey: "key-b", session: session)
            }
            await secondRefresh.value
            await firstRefresh.value

            #expect(catalog.models == ["gpt-6"])
            #expect(catalog.error == nil)
            #expect(catalog.isLoading == false)
        }
    }
}
