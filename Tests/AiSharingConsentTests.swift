import Testing

@testable import Vellum

@Suite("AI sharing consent", .scratchDefaults)
struct AiSharingConsentTests {
    @Test("Consent is provider-specific and revocable")
    func providerSpecificConsent() {
        #expect(AiSharingConsent.needsConsent(for: .gemini))
        #expect(!AiSharingConsent.isGranted(for: .gemini))

        AiSharingConsent.grant(for: .gemini)

        #expect(AiSharingConsent.isGranted(for: .gemini))
        #expect(!AiSharingConsent.needsConsent(for: .gemini))
        #expect(AiSharingConsent.needsConsent(for: .openai))
        #expect(!AiSharingConsent.isGranted(for: .openai))

        AiSharingConsent.revoke(for: .gemini)

        #expect(AiSharingConsent.needsConsent(for: .gemini))
        #expect(!AiSharingConsent.isGranted(for: .gemini))
    }
}
