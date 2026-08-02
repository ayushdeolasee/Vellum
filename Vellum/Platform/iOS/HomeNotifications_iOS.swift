#if os(iOS)
import Foundation

// iOS-only notification names for the home screen and the help surfaces.
//
// These live here rather than in `WalkthroughSettings.swift` so that file stays
// byte-identical to main's — it is a [VERBATIM] port, and the iPad-only names
// below have no macOS counterpart (the Mac routes both through menu commands
// and a `Window` scene, neither of which exists here).

extension Notification.Name {
    /// Asks the home screen to put the keyboard in its search field. Posted by
    /// the shortcut router when ⌘F arrives with no document open, which is
    /// exactly when "Find…" has nothing to find and "search my library" is the
    /// only sensible reading of the chord.
    static let vellumFocusHomeSearch = Notification.Name("vellum.focus-home-search")

    /// Asks the root scene to present the searchable Help centre. macOS opens a
    /// `Window` scene for this; iOS has no extra scenes, so it is a sheet
    /// presented from the app root — which is why this has to travel as a
    /// notification rather than as a binding.
    static let vellumShowHelp = Notification.Name("vellum.show-help")
}
#endif
