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
