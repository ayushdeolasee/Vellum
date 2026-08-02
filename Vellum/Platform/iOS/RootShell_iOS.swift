#if os(iOS)
import SwiftUI

/// Root gate for the now-universal iOS target (spec #150, phase 0 #151).
///
/// `TARGETED_DEVICE_FAMILY` is `1,2`, so one binary has to serve two shells: the
/// existing iPad split-screen shell (`ContentView_iOS`) and the phone shell
/// (`PhoneShell_iOS`, #153). This view is the only place that decides between
/// them, so the choice stays in one readable spot instead of leaking idiom
/// checks into every screen.
///
/// It does not decide anything itself — it asks `ShellIdiom_iOS.current`, the
/// single oracle that also picks the residency budget and the pane-layout
/// capability. That indirection is the point: the shell on screen and the
/// workspace's idea of whether it may split have to be the same answer, and
/// `ShellIdiom_iOS` documents why that answer is the idiom rather than the
/// horizontal size class (Max/Plus phones report regular width in landscape;
/// an iPad in Slide Over reports compact).
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
    var body: some View {
        // `ShellIdiom_iOS.current` is itself a cached `let`, so re-reading it on
        // every rotation and resize costs nothing.
        if ShellIdiom_iOS.current == .phone {
            PhoneShell_iOS()
                .environment(\.pdfZoomMode, .fitWidth)
        } else {
            ContentView_iOS()
                .environment(\.pdfZoomMode, .free)
        }
    }
}
#endif
