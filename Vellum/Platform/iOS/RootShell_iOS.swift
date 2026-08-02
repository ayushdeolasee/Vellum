#if os(iOS)
import SwiftUI
import UIKit

/// Root gate for the now-universal iOS target (spec #150, phase 0 #151).
///
/// `TARGETED_DEVICE_FAMILY` is `1,2`, so one binary has to serve two shells:
/// the existing iPad split-screen shell (`ContentView_iOS`) and the phone shell
/// being built out in later phases. This view is the only place that decides
/// between them, so the choice stays in one readable spot instead of leaking
/// size-class checks into every screen.
///
/// The test is deliberately BOTH halves of "is this an iPhone-shaped scene":
///
///   * `horizontalSizeClass == .compact` — the real signal for "there is only
///     room for one column". Phones report compact width in portrait and, on
///     everything narrower than the Max/Plus bodies, in landscape too.
///   * `userInterfaceIdiom == .phone` — a guard for the iPad, NOT a redundant
///     check. An iPad in Slide Over or a narrow Split View / windowed scene is
///     also compact-width, and it has always rendered `ContentView_iOS` there.
///     Gating on size class alone would swap the iPad's multitasking layout for
///     the phone skeleton, which is exactly the "iPad path untouched" rule this
///     phase is not allowed to break.
///
/// The consequence is that a Max/Plus phone in landscape (regular width) still
/// lands on `ContentView_iOS` for now. That is the honest phase-0 answer —
/// the app it already is, rather than a placeholder — and the phone shell takes
/// over both orientations once it is real (#153).
struct RootShell_iOS: View {
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    /// Cached because the idiom cannot change for the life of the process,
    /// while `body` re-evaluates on every rotation and resize.
    private let idiom = UIDevice.current.userInterfaceIdiom

    var body: some View {
        if horizontalSizeClass == .compact, idiom == .phone {
            PhoneShell_iOS()
        } else {
            ContentView_iOS()
        }
    }
}
#endif
