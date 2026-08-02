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

    // Two groups from main's copy of this file are deliberately absent.
    //
    // `testUpdateCheckerIsWorkspaceOwnedAndAutomaticCheckIsClaimedOnce` is a
    // PERMANENT drop: it asserts `workspace.updateChecker` /
    // `didStartAutomaticUpdateCheck` / `claimAutomaticUpdateCheck()`, and a
    // Sparkle-style self-updater is meaningless in an App Store app.
    //
    // The four AI-validation tests (`testApiKeyProvidersRequireCredentialsAndModels`,
    // `testOpenRouterKeyWithoutModelIsNotConfigured`,
    // `testChatGPTConfigurationUsesSignInStateAndModel`) are a DEFERRAL, not a
    // drop: they need `AiSettings.isConfigured(chatGPTSignedIn:)`, which does
    // not exist on iPad until the AI packet lands. That packet also claims this
    // file — it should add them back rather than treat their absence as intent.
}
