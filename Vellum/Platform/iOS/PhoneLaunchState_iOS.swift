#if os(iOS)
import Foundation

/// The phone surface a QA run wants to land on (#153 P8).
///
/// The sanctioned successor to the prototype's `VELLUM_PROTO_STATE`: a headless
/// screenshot run cannot drive a document picker, cannot tap a glass capsule to
/// dismiss the chrome, and cannot swipe up a sheet — so the four states that are
/// otherwise only reachable by touch are reachable by launch environment
/// instead. DEBUG only, at the one place the environment is read
/// (`PhoneShell_iOS`); everything in this file is pure data so the composition
/// rules below are unit-testable without a simulator.
enum PhoneLaunchState: String, Sendable, Hashable, CaseIterable {
    /// The library. The shell's own default, but spelled out so a run can force
    /// Home *past* a restored session that would otherwise land in the reader.
    case home
    /// The document, chrome up.
    case reader
    /// The document, chrome down — the immersive reading state reached by a
    /// document tap or by scrolling toward later content.
    case immersive
    /// The document with the inspector sheet presented, on whatever panel the
    /// workspace last selected.
    case inspector
    /// The tab switcher, over the document.
    case tabs

    /// Whether landing here needs a document to land *on*.
    ///
    /// Home is the only state that reads correctly with an empty library. The
    /// other four are all "…over the document", and a reader route with no
    /// document is a blank screen with a back button — which is a worse QA
    /// artefact than an honest Home.
    var requiresDocument: Bool { self != .home }
}

/// What a document a QA run asked to be opened at launch.
///
/// Mutually exclusive by construction rather than by two optionals, because the
/// two variables have always been read in a fixed order and a plan that carried
/// both would have to re-litigate that at every call site.
enum PhoneLaunchOpen: Sendable, Hashable {
    /// `VELLUM_AUTOOPEN_URL` — a webpage, opened through `AppStore.openUrl`.
    case url(String)
    /// `VELLUM_AUTOOPEN_PDF` — a path on disk, imported then opened.
    case pdf(path: String)
}

/// The whole launch-environment contract, parsed once into a value.
///
/// `VELLUM_PHONE_STATE` composes with the pre-existing `VELLUM_AUTOOPEN_*`
/// variables rather than replacing them: "open this PDF and show me the
/// inspector over it" is one launch, not two. Composition is the interesting
/// part and therefore the tested part — see `resolvedState(hasDocument:)`.
struct PhoneLaunchPlan: Sendable, Hashable {
    /// The document to open, if the run asked for one.
    var open: PhoneLaunchOpen?
    /// The surface to land on, if the run asked for one. `nil` for an
    /// unrecognised `VELLUM_PHONE_STATE` value — an unknown state is a typo, and
    /// silently landing somewhere arbitrary is how a screenshot suite starts
    /// lying.
    var state: PhoneLaunchState?

    /// True when the environment carried nothing for us, which is every real
    /// launch. The shell checks this first so a normal run does no work.
    var isEmpty: Bool { open == nil && state == nil }

    /// Reads the three `VELLUM_*` variables. A pure function of its input: no
    /// `ProcessInfo`, no file system (the PDF path's existence is checked by the
    /// caller, which is the only one that can do anything about a miss).
    ///
    /// Values are trimmed, and an all-whitespace value counts as absent — the
    /// shape `xcodebuild`'s `-e` flags and Xcode's scheme editor produce when a
    /// row is left blank.
    static func parse(environment: [String: String]) -> PhoneLaunchPlan {
        PhoneLaunchPlan(
            open: parseOpen(environment: environment),
            state: parseState(environment: environment))
    }

    /// URL wins over PDF when both are set. Not arbitrary: it is the order the
    /// shell has read them in since the iPad's QA hook, and only one document
    /// can be the one on screen.
    private static func parseOpen(environment: [String: String]) -> PhoneLaunchOpen? {
        if let url = value(environment["VELLUM_AUTOOPEN_URL"]) { return .url(url) }
        if let path = value(environment["VELLUM_AUTOOPEN_PDF"]) { return .pdf(path: path) }
        return nil
    }

    private static func parseState(environment: [String: String]) -> PhoneLaunchState? {
        guard let raw = value(environment["VELLUM_PHONE_STATE"]) else { return nil }
        return PhoneLaunchState(rawValue: raw.lowercased())
    }

    private static func value(_ raw: String?) -> String? {
        guard let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty
        else { return nil }
        return trimmed
    }

    /// The state to actually apply, given what the shell has on screen by the
    /// time the plan runs.
    ///
    /// `hasDocument` is asked *after* any auto-open has been awaited, so a plan
    /// that opens a PDF and asks for `.immersive` gets it. The fallback is the
    /// composition rule that matters: a document-requiring state with no
    /// document anywhere — no auto-open, no restored session — degrades to
    /// `.home` rather than routing the reader at a blank viewer. A run that
    /// asked for the inspector and got Home is obviously wrong in a screenshot;
    /// a run that got an empty reader looks like the inspector failed to
    /// present, which is a bug report against the wrong thing.
    func resolvedState(hasDocument: Bool) -> PhoneLaunchState? {
        guard let state else { return nil }
        guard state.requiresDocument, !hasDocument else { return state }
        return .home
    }
}
#endif
