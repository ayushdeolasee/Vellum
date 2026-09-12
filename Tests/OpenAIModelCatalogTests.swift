import Foundation
import Testing
import XCTest
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

// XCTest runs separately from the Swift Testing suites that override KeychainStore
// and StubURLProtocol. All stores use a scratch defaults domain and the hosted
// test process's in-memory keychain; restore its settings before leaving.
@MainActor
final class OpenAIModelCatalogStateTests: XCTestCase {
    nonisolated func testCredentialChangesInvalidateEveryCatalogWithoutReopeningPicker() async throws {
        let suiteName = "com.vellum.tests.catalog.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        await AppDefaults.withDefaults(defaults) { @MainActor in
            let original = AiPersistence.loadSettings()
            defer { AiPersistence.saveSettings(original) }
            let settingsStore = AiStore()
            let inspectorStore = AiStore()
            for editor in [settingsStore, inspectorStore] {
                for nextKey in ["key-b", "   "] {
                    var settings = editor.settings
                    settings.openaiApiKey = "key-a"
                    editor.setSettings(settings)
                    let catalogs = [
                        OpenAIModelCatalog(apiKey: settingsStore.settings.openaiApiKey),
                        OpenAIModelCatalog(apiKey: inspectorStore.settings.openaiApiKey),
                    ]
                    StubURLProtocol.installStreaming { request in
                        let isOld = request.value(forHTTPHeaderField: "Authorization") == "Bearer key-a"
                        return StubStreamingResponse(
                            response: HTTPURLResponse(url: request.url!, statusCode: 200,
                                                      httpVersion: nil, headerFields: nil)!,
                            chunks: [StubStreamingChunk(
                                Data((isOld ? #"{"data":[{"id":"gpt-5"}]}"#
                                      : #"{"data":[{"id":"gpt-6"}]}"#).utf8),
                                delay: .milliseconds(50))])
                    }
                    let session = StubURLProtocol.session()
                    let requests = catalogs.map { catalog in
                        Task { await catalog.refresh(session: session) }
                    }
                    while !catalogs.allSatisfy({ $0.isLoading }) { await Task.yield() }
                    settings.openaiApiKey = nextKey
                    editor.setSettings(settings)
                    XCTAssertEqual(settingsStore.settings.openaiApiKey, nextKey.trimmingCharacters(in: .whitespacesAndNewlines))
                    XCTAssertEqual(inspectorStore.settings.openaiApiKey, nextKey.trimmingCharacters(in: .whitespacesAndNewlines))
                    for catalog in catalogs {
                        XCTAssertTrue(catalog.models.isEmpty)
                        XCTAssertFalse(catalog.isLoading)
                    }
                    // Let successful old responses finish without starting another refresh.
                    for request in requests { await request.value }
                    for catalog in catalogs {
                        XCTAssertTrue(catalog.models.isEmpty)
                        XCTAssertNil(catalog.error)
                        XCTAssertFalse(catalog.isLoading)
                        await catalog.refresh(session: session)
                        XCTAssertEqual(catalog.models, nextKey == "key-b" ? ["gpt-6"] : [])
                    }
                    // Clear already-loaded models synchronously as well.
                    settings.openaiApiKey = ""
                    editor.setSettings(settings)
                    XCTAssertTrue(catalogs.allSatisfy { $0.models.isEmpty })
                    session.invalidateAndCancel()
                    StubURLProtocol.reset()
                }
            }
        }
    }
}
