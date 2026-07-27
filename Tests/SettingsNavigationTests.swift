import XCTest
@testable import Vellum

@MainActor
final class SettingsNavigationTests: XCTestCase {
    func testWorkspaceDefaultsToGeneralSettingsAndCanRouteToAi() {
        let workspace = WorkspaceStore(sessions: DocumentSessionManager())

        XCTAssertEqual(workspace.settingsSection, .general)

        workspace.settingsSection = .ai
        XCTAssertEqual(workspace.settingsSection, .ai)
    }

    func testApiKeyProvidersRequireNonWhitespaceCredentials() {
        let providers: [(AiProvider, WritableKeyPath<AiSettings, String>)] = [
            (.gemini, \.apiKey),
            (.openai, \.openaiApiKey),
            (.openrouter, \.openrouterApiKey),
            (.opencode, \.opencodeApiKey),
            (.opencodeGo, \.opencodeGoApiKey),
        ]

        for (provider, keyPath) in providers {
            var settings = AiSettings()
            settings.provider = provider
            settings[keyPath: keyPath] = " \n "
            XCTAssertFalse(
                settings.isConfigured(chatGPTSignedIn: true),
                "\(provider) should reject whitespace-only credentials")

            settings[keyPath: keyPath] = "credential"
            XCTAssertTrue(
                settings.isConfigured(chatGPTSignedIn: false),
                "\(provider) should accept a non-empty credential")
        }
    }

    func testChatGPTConfigurationUsesSignInState() {
        var settings = AiSettings()
        settings.provider = .chatgpt

        XCTAssertFalse(settings.isConfigured(chatGPTSignedIn: false))
        XCTAssertTrue(settings.isConfigured(chatGPTSignedIn: true))
    }
}
