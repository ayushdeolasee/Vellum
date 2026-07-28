import XCTest
@testable import Vellum

@MainActor
final class SettingsNavigationTests: XCTestCase {
    func testWorkspaceDefaultsToGeneralSettingsAndCanRouteToAi() {
        let workspace = WorkspaceStore(sessions: DocumentSessionManager())

        XCTAssertEqual(workspace.settingsSection, .general)

        workspace.settingsSection = .ai
        XCTAssertEqual(workspace.settingsSection, .ai)

        workspace.settingsSection = .storage
        XCTAssertEqual(workspace.settingsSection, .storage)
    }

    func testUpdateCheckerIsWorkspaceOwnedAndAutomaticCheckIsClaimedOnce() {
        let workspace = WorkspaceStore(sessions: DocumentSessionManager())
        let sameChecker = workspace.updateChecker

        XCTAssertTrue(workspace.updateChecker === sameChecker)
        XCTAssertFalse(workspace.didStartAutomaticUpdateCheck)
        XCTAssertTrue(workspace.claimAutomaticUpdateCheck())
        XCTAssertTrue(workspace.didStartAutomaticUpdateCheck)
        XCTAssertFalse(workspace.claimAutomaticUpdateCheck())
    }

    func testApiKeyProvidersRequireCredentialsAndModels() {
        let providers: [(
            AiProvider,
            WritableKeyPath<AiSettings, String>,
            WritableKeyPath<AiSettings, String>
        )] = [
            (.gemini, \.apiKey, \.model),
            (.openai, \.openaiApiKey, \.openaiModel),
            (.openrouter, \.openrouterApiKey, \.openrouterModel),
            (.opencode, \.opencodeApiKey, \.opencodeModel),
            (.opencodeGo, \.opencodeGoApiKey, \.opencodeGoModel),
        ]

        for (provider, keyPath, modelPath) in providers {
            var settings = AiSettings()
            settings.provider = provider
            settings[keyPath: modelPath] = "model"
            settings[keyPath: keyPath] = " \n "
            XCTAssertFalse(
                settings.isConfigured(chatGPTSignedIn: true),
                "\(provider) should reject whitespace-only credentials")

            settings[keyPath: keyPath] = "credential"
            XCTAssertTrue(
                settings.isConfigured(chatGPTSignedIn: false),
                "\(provider) should accept a credential with a selected model")

            settings[keyPath: modelPath] = " \n "
            XCTAssertFalse(
                settings.isConfigured(chatGPTSignedIn: true),
                "\(provider) should reject a missing model")
        }
    }

    func testOpenRouterKeyWithoutModelIsNotConfigured() {
        var settings = AiSettings()
        settings.provider = .openrouter
        settings.openrouterApiKey = "sk-or-test"
        settings.openrouterModel = ""

        XCTAssertFalse(settings.isConfigured(chatGPTSignedIn: false))
    }

    func testChatGPTConfigurationUsesSignInStateAndModel() {
        var settings = AiSettings()
        settings.provider = .chatgpt

        XCTAssertFalse(settings.isConfigured(chatGPTSignedIn: false))
        XCTAssertTrue(settings.isConfigured(chatGPTSignedIn: true))

        settings.chatgptModel = " "
        XCTAssertFalse(settings.isConfigured(chatGPTSignedIn: true))
    }
}
