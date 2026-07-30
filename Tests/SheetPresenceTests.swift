import AppKit
import SwiftUI
import XCTest
@testable import Vellum

/// The gate behind issue #98: `ContentView` publishes its scene focus value
/// only while `sheetPresented` is false, so these are the conditions under
/// which the document menu commands are live.
///
/// These drive REAL windows and a REAL hosted SwiftUI `.sheet` rather than
/// poking the model's setters, because every interesting claim here is a claim
/// about AppKit: that a SwiftUI sheet is an attached AppKit sheet at all, that
/// the begin/end notifications name the presenting window, and that
/// `attachedSheet` is not yet set at begin but already cleared at end. Asserting
/// those against the real thing is the whole point — a hand-rolled fake would
/// only re-state what this file assumes.
///
/// What is NOT covered: the `.focusedSceneValue` plumbing that consumes this
/// state, and the AppKit key-equivalent behaviour that follows from it (a
/// disabled menu item declining ⌘W). Both need a running scene with a real menu
/// bar and a real key event; neither is reachable from a unit test.
@MainActor
final class SheetPresenceTests: XCTestCase {
    private var windows: [NSWindow] = []

    override func tearDown() async throws {
        for window in windows { window.orderOut(nil) }
        windows = []
    }

    // MARK: - Harness

    /// A real window, positioned far offscreen so a test run never puts
    /// anything on the developer's desktop, and ordered in — an unordered
    /// window cannot take a sheet.
    private func makeWindow(_ content: NSView? = nil) -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 300),
            styleMask: [.titled, .closable], backing: .buffered, defer: false)
        if let content { window.contentView = content }
        window.setFrameOrigin(NSPoint(x: -30_000, y: -30_000))
        window.orderFront(nil)
        windows.append(window)
        return window
    }

    private func pump(_ seconds: TimeInterval = 0.6) {
        RunLoop.current.run(until: Date().addingTimeInterval(seconds))
    }

    private func pump(until condition: @autoclosure () -> Bool, timeout: TimeInterval = 5) {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() && Date() < deadline {
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.02))
        }
    }

    // MARK: - The AppKit contract this fix rests on

    /// The load-bearing assumption: SwiftUI's `.sheet` on macOS really does
    /// attach an AppKit sheet to the presenting window and really does emit the
    /// begin/end notifications naming that window. If a future SwiftUI ever
    /// presents sheets some other way, the gate would silently stop working and
    /// #98 would come back with no other test noticing — so this asserts it
    /// directly, and asserts the asymmetry the monitor is written around:
    /// `attachedSheet` is NOT yet set when the begin notification lands, and IS
    /// already cleared when the end notification lands.
    func testSwiftUISheetIsAnAttachedAppKitSheetWithTheExpectedNotifications() throws {
        let box = SheetProbeBox()
        let host = NSHostingView(rootView: SheetProbeView(box: box))
        host.frame = NSRect(x: 0, y: 0, width: 400, height: 300)
        let window = makeWindow(host)

        var beginAttachedStates: [Bool] = []
        var endAttachedStates: [Bool] = []
        let began = NotificationCenter.default.addObserver(
            forName: NSWindow.willBeginSheetNotification, object: window, queue: .main
        ) { note in
            beginAttachedStates.append((note.object as? NSWindow)?.attachedSheet != nil)
        }
        let ended = NotificationCenter.default.addObserver(
            forName: NSWindow.didEndSheetNotification, object: window, queue: .main
        ) { note in
            endAttachedStates.append((note.object as? NSWindow)?.attachedSheet != nil)
        }
        defer {
            NotificationCenter.default.removeObserver(began)
            NotificationCenter.default.removeObserver(ended)
        }

        host.layoutSubtreeIfNeeded()
        pump()
        XCTAssertNil(window.attachedSheet, "precondition: nothing attached yet")

        box.presented = true
        host.layoutSubtreeIfNeeded()
        pump(until: window.attachedSheet != nil)
        XCTAssertNotNil(
            window.attachedSheet,
            "a SwiftUI .sheet did not attach an AppKit sheet to the presenting window")
        XCTAssertEqual(
            beginAttachedStates, [false],
            "expected exactly one begin notification, with attachedSheet not yet set")

        box.presented = false
        host.layoutSubtreeIfNeeded()
        pump(until: window.attachedSheet == nil)
        XCTAssertNil(window.attachedSheet, "the sheet stayed attached after dismissal")
        XCTAssertEqual(
            endAttachedStates, [false],
            "expected exactly one end notification, with attachedSheet already cleared")
    }

    // MARK: - The gate

    /// The gate against a real SwiftUI sheet on a real window, fed the calls
    /// `ContentView`'s two `.onReceive` handlers make. The test above pins that
    /// those notifications actually arrive, with these objects, at these
    /// moments; this pins what the monitor does with them — including that the
    /// end path's re-read of a real `attachedSheet` returns the window to a
    /// live menu rather than leaving it dead until relaunch.
    ///
    /// The `.onReceive` subscription itself is the seam neither test can cross:
    /// it needs a mounted scene.
    func testGateClosesWhileARealSheetIsUpAndReopensAfter() throws {
        let monitor = SheetPresenceMonitor()
        let box = SheetProbeBox()
        let host = NSHostingView(rootView: SheetProbeView(box: box))
        host.frame = NSRect(x: 0, y: 0, width: 400, height: 300)
        let window = makeWindow(host)

        host.layoutSubtreeIfNeeded()
        pump()
        XCTAssertFalse(monitor.sheetPresented, "the gate started closed with no sheet")

        box.presented = true
        host.layoutSubtreeIfNeeded()
        pump(until: window.attachedSheet != nil)
        monitor.noteSheetBegan(on: window, host: window)
        XCTAssertTrue(
            monitor.sheetPresented,
            "the document commands stayed live behind a presented sheet — issue #98")

        box.presented = false
        host.layoutSubtreeIfNeeded()
        pump(until: window.attachedSheet == nil)
        monitor.noteSheetEnded(on: window, host: window)
        XCTAssertFalse(
            monitor.sheetPresented,
            "the gate stayed shut after the sheet closed — the menu would be dead until relaunch")
    }

    /// A sheet on some OTHER window (Settings, the Help centre, a save panel
    /// run on a different window) must not disable the main window's commands.
    /// `object:` filtering in the app's own subscription is on the whole
    /// notification stream, so the window check has to live in the monitor.
    func testASheetOnAnotherWindowLeavesTheGateOpen() throws {
        let monitor = SheetPresenceMonitor()
        let host = makeWindow()
        let other = makeWindow()

        monitor.noteSheetBegan(on: other, host: host)
        XCTAssertFalse(
            monitor.sheetPresented,
            "another window's sheet disabled this window's document commands")

        // And the symmetric case: another window's sheet ending must not
        // re-enable them while this window is genuinely sheeted.
        monitor.noteSheetBegan(on: host, host: host)
        monitor.noteSheetEnded(on: other, host: host)
        XCTAssertTrue(
            monitor.sheetPresented,
            "another window's sheet ending re-enabled ⌘W behind a live sheet")
    }

    /// The end notification re-reads the window rather than assuming "ended
    /// means nothing left", so a sheet still attached at that moment keeps the
    /// gate shut. Driven through a real `beginSheet` because the assertion is
    /// about what `attachedSheet` reports, not about bookkeeping.
    func testEndRereadsTheWindowSoARemainingSheetKeepsTheGateShut() throws {
        let monitor = SheetPresenceMonitor()
        let host = makeWindow()
        let sheet = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 200, height: 120),
            styleMask: [.titled], backing: .buffered, defer: false)

        host.beginSheet(sheet)
        pump(until: host.attachedSheet != nil)
        XCTAssertNotNil(host.attachedSheet, "precondition: the sheet attached")

        // An end notification that arrives while a sheet is still attached (a
        // stacked presentation) must leave the gate shut.
        monitor.noteSheetBegan(on: host, host: host)
        monitor.noteSheetEnded(on: host, host: host)
        XCTAssertTrue(
            monitor.sheetPresented,
            "the gate reopened while a sheet was still attached to the window")

        host.endSheet(sheet)
        pump(until: host.attachedSheet == nil)
        monitor.noteSheetEnded(on: host, host: host)
        XCTAssertFalse(monitor.sheetPresented, "the gate stayed shut with nothing attached")
    }

    /// Before `WindowAccessor` reports the host window there is nothing to
    /// compare against, so notifications are ignored rather than guessed at.
    func testNotificationsBeforeTheHostWindowIsKnownAreIgnored() {
        let monitor = SheetPresenceMonitor()
        let some = makeWindow()

        monitor.noteSheetBegan(on: some, host: nil)
        XCTAssertFalse(monitor.sheetPresented)
        monitor.noteSheetBegan(on: nil, host: nil)
        XCTAssertFalse(monitor.sheetPresented)
    }

}

/// Drives a real SwiftUI sheet from the test body.
@MainActor
@Observable
private final class SheetProbeBox {
    var presented = false
}

private struct SheetProbeView: View {
    @Bindable var box: SheetProbeBox

    var body: some View {
        Color.gray
            .sheet(isPresented: $box.presented) {
                Text("Sheet").frame(width: 200, height: 120)
            }
    }
}
