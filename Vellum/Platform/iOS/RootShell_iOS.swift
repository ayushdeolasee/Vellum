#if os(iOS)
import SwiftUI
import UIKit

/// Root gate for the now-universal iOS target (spec #150, phase 0 #151).
///
/// `TARGETED_DEVICE_FAMILY` is `1,2`, so one binary has to serve two shells:
/// the existing iPad split-screen shell (`ContentView_iOS`) and the phone shell
/// being built out in later phases. This view is the only place that decides
/// between them, so the choice stays in one readable spot instead of leaking
/// idiom checks into every screen.
///
/// The test is the IDIOM, and deliberately not the horizontal size class:
///
///   * A phone is a phone in both orientations. Gating on `.compact` width
///     instead would hand the Max/Plus bodies — which report REGULAR width in
///     landscape — the iPad shell, so the same device would be "not built yet"
///     held one way and a full two-pane reader held the other. Worse, the two
///     branches are different view types, so every rotation would change the
///     subtree's structural identity and SwiftUI would destroy and rebuild the
///     whole shell: split-view column state, pane focus, presented sheets and
///     scroll positions all reset on a turn of the wrist.
///   * An iPad stays on `ContentView_iOS` at every width. Slide Over and a
///     narrow Split View are compact-width too, and they have always rendered
///     the iPad shell; keeping the idiom as the only input is what makes "the
///     iPad path is untouched" true by construction rather than by argument.
///
/// The idiom cannot change for the life of the process, so this `if` is decided
/// once — the branch never flips at runtime and neither shell is ever rebuilt
/// by this view.
///
/// Each branch also declares how a PDF viewer beneath it should scale (#152).
/// The phone reader fits the page to the viewport's width and floors zoom-out
/// there — in landscape as well, where "fit the width" simply resolves to a
/// larger scale. Everything else keeps absolute zoom. Declaring BOTH sides
/// here, next to the shell choice itself, is what keeps fit-width from leaking
/// into the iPad's compact-width multitasking layouts.
struct RootShell_iOS: View {
    /// Cached because the idiom cannot change for the life of the process,
    /// while `body` re-evaluates on every rotation and resize.
    private let idiom = UIDevice.current.userInterfaceIdiom

    var body: some View {
        if idiom == .phone {
            PhoneShell_iOS()
                .environment(\.pdfZoomMode, .fitWidth)
        } else {
            ContentView_iOS()
                .environment(\.pdfZoomMode, .free)
        }
    }
}
#endif
