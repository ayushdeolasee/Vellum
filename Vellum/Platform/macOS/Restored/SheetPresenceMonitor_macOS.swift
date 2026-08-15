#if os(macOS)
import AppKit
import SwiftUI

/// Whether the main window currently has a sheet attached — asked of AppKit,
/// not inferred from SwiftUI's presentation flags.
///
/// #71 moved the document commands' target from `.focusedValue` to
/// `.focusedSceneValue` so a first-responder PDFView/WKWebView could no longer
/// grey out the whole menu. A sheet belongs to the scene that presents it, so
/// unlike the view-focused value it displaced, the scene value stayed published
/// behind a sheet and every document command stayed live: ⌘W, pressed to get rid
/// of the sheet, closed the tab underneath (issue #98).
///
/// `ContentView` publishes a nil focus value while `sheetPresented`, which
/// disables those commands. A disabled menu item does not claim its key
/// equivalent, so the chord no longer reaches "Close Tab" — the pre-#71
/// behaviour, restored for sheets and nothing else.
///
/// WHY APPKIT RATHER THAN A SET OF `isPresented` FLAGS. A presentation flag
/// records what the app *asked for*, which is not the same as what is on screen:
///
///   • macOS will not put a second sheet on a window that already has one. Help
///     ▸ Vellum Walkthrough is deliberately never disabled (`VellumCommands`),
///     and the Help centre — a scene of its own, fully live while the main
///     window is sheeted — posts the same notification. Setting that flag behind
///     an open sheet latches it true with nothing ever presented, and a gate
///     built on it would disable the document menu until relaunch. Trading a
///     mis-enabled ⌘W for a permanently dead File menu is a bad trade.
///   • It takes one flag per sheet, and Vellum does not present all of its own
///     sheets. `.fileImporter` (the AI panel's image picker) and PDFKit's print
///     panel are window-modal sheets too, and ⌘W behind them closed the tab just
///     the same.
///
/// `NSWindow.attachedSheet` has neither problem: it is AppKit's own answer, it
/// covers every sheet whoever presented it, and it cannot describe a sheet that
/// is not there.
///
/// The two notifications are not symmetric, which is why they get separate
/// entry points. Both were measured against a real hosted SwiftUI `.sheet` (see
/// `SheetPresenceTests`): `willBeginSheet` arrives BEFORE `attachedSheet` is
/// set, so a begin is taken at its word; `didEndSheet` arrives AFTER it is
/// cleared, so an end re-reads the window instead — which also keeps the gate
/// closed if some other sheet is still attached.
@MainActor
@Observable
final class SheetPresenceMonitor {
    private(set) var sheetPresented = false

    /// `NSWindow.willBeginSheetNotification`. The notification's object is the
    /// window the sheet is being attached TO, not the sheet.
    func noteSheetBegan(on window: NSWindow?, host: NSWindow?) {
        guard let host, window === host else { return }
        sheetPresented = true
    }

    /// `NSWindow.didEndSheetNotification`, same object convention.
    func noteSheetEnded(on window: NSWindow?, host: NSWindow?) {
        guard let host, window === host else { return }
        sheetPresented = host.attachedSheet != nil
    }
}
#endif
