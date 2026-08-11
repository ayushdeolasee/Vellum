#if os(iOS)
import Foundation
import Testing

@testable import Vellum

// The phone's launch-environment contract (#153 P8).
//
// `VELLUM_PHONE_STATE` is the sanctioned successor to the prototype's
// `VELLUM_PROTO_STATE`, and it does not replace `VELLUM_AUTOOPEN_PDF` /
// `VELLUM_AUTOOPEN_URL` — it composes with them, because "open this PDF and show
// me the inspector over it" is one launch. Composition is the part that can be
// got subtly wrong, so parsing lives in a pure function over a dictionary and
// this suite is the whole proof: no shell, no simulator, no ProcessInfo.

@Suite
struct PhoneLaunchStateTests {

    // MARK: - Nothing set

    @Test("A real launch carries nothing and the hook does no work")
    func emptyEnvironmentProducesAnEmptyPlan() {
        let plan = PhoneLaunchPlan.parse(environment: [:])

        #expect(plan.isEmpty)
        #expect(plan.open == nil)
        #expect(plan.state == nil)
        // Even asked directly, an empty plan has no opinion about the route —
        // the shell's own default (Home, or the reader once a session restores)
        // must survive a launch that never mentioned QA.
        #expect(plan.resolvedState(hasDocument: false) == nil)
        #expect(plan.resolvedState(hasDocument: true) == nil)
    }

    @Test("Unrelated VELLUM_ variables are not mistaken for this contract")
    func otherVellumVariablesAreIgnored() {
        let plan = PhoneLaunchPlan.parse(environment: [
            "VELLUM_FORCE_SHELL": "phone",
            "VELLUM_PROTO_STATE": "immersive",
        ])

        #expect(plan.isEmpty)
    }

    // MARK: - The state variable

    @Test("Every state spelled in the contract parses", arguments: PhoneLaunchState.allCases)
    func everyStateParses(state: PhoneLaunchState) {
        let plan = PhoneLaunchPlan.parse(environment: ["VELLUM_PHONE_STATE": state.rawValue])

        #expect(plan.state == state)
        #expect(!plan.isEmpty)
    }

    @Test("Case and surrounding whitespace are forgiven")
    func stateIsNormalized() {
        #expect(
            PhoneLaunchPlan.parse(environment: ["VELLUM_PHONE_STATE": "  Immersive\n"]).state
                == .immersive)
        #expect(
            PhoneLaunchPlan.parse(environment: ["VELLUM_PHONE_STATE": "TABS"]).state == .tabs)
    }

    @Test("An unrecognised state is dropped rather than guessed at")
    func unknownStateIsNil() {
        // A typo must not land the run somewhere arbitrary and then be
        // screenshotted as if it were the state that was asked for.
        #expect(PhoneLaunchPlan.parse(environment: ["VELLUM_PHONE_STATE": "readerr"]).state == nil)
        #expect(PhoneLaunchPlan.parse(environment: ["VELLUM_PHONE_STATE": "switcher"]).state == nil)
    }

    @Test("A blank value counts as absent")
    func blankStateIsAbsent() {
        // The shape an Xcode scheme row or an `xcodebuild -e` flag leaves behind
        // when someone clears it but does not delete it.
        let plan = PhoneLaunchPlan.parse(environment: ["VELLUM_PHONE_STATE": "   "])

        #expect(plan.state == nil)
        #expect(plan.isEmpty)
    }

    // MARK: - Composition with the auto-open variables

    @Test("A PDF path and a state travel together")
    func pdfComposesWithState() {
        let plan = PhoneLaunchPlan.parse(environment: [
            "VELLUM_AUTOOPEN_PDF": "/tmp/paper.pdf",
            "VELLUM_PHONE_STATE": "inspector",
        ])

        #expect(plan.open == .pdf(path: "/tmp/paper.pdf"))
        #expect(plan.state == .inspector)
        #expect(plan.resolvedState(hasDocument: true) == .inspector)
    }

    @Test("A URL and a state travel together")
    func urlComposesWithState() {
        let plan = PhoneLaunchPlan.parse(environment: [
            "VELLUM_AUTOOPEN_URL": "https://example.com/article",
            "VELLUM_PHONE_STATE": "immersive",
        ])

        #expect(plan.open == .url("https://example.com/article"))
        #expect(plan.resolvedState(hasDocument: true) == .immersive)
    }

    @Test("With both set the URL wins, as the shell has always read them")
    func urlTakesPrecedenceOverPdf() {
        let plan = PhoneLaunchPlan.parse(environment: [
            "VELLUM_AUTOOPEN_URL": "https://example.com",
            "VELLUM_AUTOOPEN_PDF": "/tmp/paper.pdf",
        ])

        #expect(plan.open == .url("https://example.com"))
    }

    @Test("An auto-open with no state still opens, and still says nothing about the route")
    func autoOpenAloneKeepsWorking() {
        // The pre-#153 contract: `VELLUM_AUTOOPEN_PDF` on its own opened the
        // document and let the shell route itself. Adding the state variable
        // must not have changed that for any existing script.
        let plan = PhoneLaunchPlan.parse(environment: ["VELLUM_AUTOOPEN_PDF": "/tmp/paper.pdf"])

        #expect(plan.open == .pdf(path: "/tmp/paper.pdf"))
        #expect(!plan.isEmpty)
        #expect(plan.resolvedState(hasDocument: true) == nil)
    }

    // MARK: - The fallback rule

    @Test(
        "A state that needs a document degrades to Home when there is none",
        arguments: PhoneLaunchState.allCases.filter(\.requiresDocument))
    func documentStatesFallBackToHome(state: PhoneLaunchState) {
        let plan = PhoneLaunchPlan(open: nil, state: state)

        // No auto-open and no restored session: the reader would be a blank
        // viewer with a back button, which reads as "the inspector failed to
        // present" rather than as "nothing was open".
        #expect(plan.resolvedState(hasDocument: false) == .home)
        #expect(plan.resolvedState(hasDocument: true) == state)
    }

    @Test("Home is reachable with an empty library and past a restored session")
    func homeNeverFallsBack() {
        let plan = PhoneLaunchPlan(open: nil, state: .home)

        #expect(!PhoneLaunchState.home.requiresDocument)
        #expect(plan.resolvedState(hasDocument: false) == .home)
        // The interesting half: forcing Home over a session that restored
        // straight into the reader is the only way to photograph the library
        // with a real corpus behind it.
        #expect(plan.resolvedState(hasDocument: true) == .home)
    }

    @Test("The four document states are exactly the ones that need a document")
    func onlyHomeSurvivesWithoutADocument() {
        let needy = Set(PhoneLaunchState.allCases.filter(\.requiresDocument))

        #expect(needy == [.reader, .immersive, .inspector, .tabs])
    }
}
#endif
