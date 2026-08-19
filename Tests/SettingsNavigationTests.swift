import XCTest

@testable import Vellum

/// Pins #70's settings routing: which tab the Settings sheet opens on is
/// workspace state, so a caller that presents Settings for a reason — Home's
/// gear button, "Configure AI…", a Storage warning — can land the reader on the
/// right tab instead of on General.
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

    #if os(iOS)
    func testPhoneSettingsRoutesStorageAndIntegrationsThroughActionableMoreRows() {
        XCTAssertEqual(SettingsPhoneTab(section: .storage), .more)
        XCTAssertEqual(SettingsPhoneTab(section: .integrations), .more)
        XCTAssertEqual(SettingsNavigationDestination(section: .storage), .storage)
        XCTAssertEqual(SettingsNavigationDestination(section: .integrations), .integrations)
    }
    #endif

    // One group from main's copy of this file is deliberately absent.
    //
    // `testUpdateCheckerIsWorkspaceOwnedAndAutomaticCheckIsClaimedOnce` is a
    // PERMANENT drop: it asserts `workspace.updateChecker` /
    // `didStartAutomaticUpdateCheck` / `claimAutomaticUpdateCheck()`, and a
    // Sparkle-style self-updater is meaningless in an App Store app.
    //
    // The AI-validation tests below were deferred while `AiSettings` had no
    // iPad home. The AI packet has since landed, so they are restored from main.

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
                settings.isConfigured(),
                "\(provider) should reject whitespace-only credentials")

            settings[keyPath: keyPath] = "credential"
            XCTAssertTrue(
                settings.isConfigured(),
                "\(provider) should accept a credential with a selected model")

            settings[keyPath: modelPath] = " \n "
            XCTAssertFalse(
                settings.isConfigured(),
                "\(provider) should reject a missing model")
        }
    }

    func testOpenRouterKeyWithoutModelIsNotConfigured() {
        var settings = AiSettings()
        settings.provider = .openrouter
        settings.openrouterApiKey = "sk-or-test"
        settings.openrouterModel = ""

        XCTAssertFalse(settings.isConfigured())
    }
}
