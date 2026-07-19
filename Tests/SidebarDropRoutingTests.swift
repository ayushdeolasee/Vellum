import AppKit
import SwiftUI
import UniformTypeIdentifiers
import XCTest
@testable import Vellum

// Drives the REAL stacked sidebar hierarchy (ContentView's `SidebarPanelStack`
// with the actual AnnotationSidebar / AiPanel / ScratchpadPanel and real stores)
// the way AppKit routes a live drag, headlessly — the gap that let the
// "Finder-drop onto the AI panel does nothing" bug survive multiple fix rounds.
//
// WHY THIS IS NEEDED (AppKit drag routing, for the reader new to it):
//   • AppKit routes a drop to the single frontmost REGISTERED view under the
//     cursor. It finds it with a front-to-back geometry walk (deepest registered
//     view along the frontmost sibling branch), NOT via `hitTest`.
//   • When that frontmost registered view REFUSES (draggingEntered returns
//     none/[]), AppKit does NOT fall through to a registered view behind it.
//   • Every SwiftUI `.onDrop` installs a hidden `_PlatformDraggingDestinationView`
//     registered for the catch-all `public.data`/`public.item` types REGARDLESS
//     of the `of:` array. In the sidebar's glass-effect hosting view that hidden
//     view sat frontmost and then refused real file drags — so drops died. The
//     definitive fix removes every sidebar `.onDrop` and installs ONE plain
//     AppKit drag-only destination (`SidebarDropView`, via `SidebarDropCatcher`)
//     overlaid on the whole sidebar; it reads the visible tab live and dispatches
//     the payload to that tab's store.
//
// HARNESS FIDELITY (mirrors Tests/AttachmentDropTests.swift): a real offscreen
// window hosts the real views with real stores; `FakeDraggingInfo` is backed by
// a real scratch pasteboard so provider decoding runs for real; the drop
// destination is found by the same front-to-back geometry AppKit uses.
//
// MOUNT-THEN-FLIP ORDERING IS MANDATORY: the app launches on the annotations
// tab, so we mount there first, pump, THEN flip to the tab under test and pump
// again — mirroring the real lifecycle. (A previous test set the tab before
// mounting and passed while the live app was broken.)
@MainActor
final class SidebarDropRoutingTests: XCTestCase {

    private var window: NSWindow?
    private var scratchPasteboards: [NSPasteboard] = []
    private var fixtureDir: URL!

    override func setUp() async throws {
        fixtureDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("sidebar-drop-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: fixtureDir, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        window?.orderOut(nil)
        window = nil
        for pasteboard in scratchPasteboards { pasteboard.releaseGlobally() }
        scratchPasteboards = []
        try? FileManager.default.removeItem(at: fixtureDir)
    }

    // MARK: - Real hierarchy host

    /// Mount the real `SidebarPanelStack` (the three real panels + the single
    /// AppKit drag catcher) in an offscreen window with a real store-triple. The
    /// window is bound to a mutable `sidebarTab` binding so the test can flip the
    /// tab AFTER the view tree is mounted, exactly as the app does when the user
    /// clicks the segmented control. Returns the hosting view, the workspace (to
    /// flip the tab), and the focused pane whose stores the panels read.
    private func hostSidebar(initialTab: WorkspaceStore.SidebarTab)
        -> (host: NSView, workspace: WorkspaceStore, pane: PaneModel) {
        let workspace = WorkspaceStore(sessions: DocumentSessionManager())
        workspace.sidebarOpen = true
        workspace.sidebarTab = initialTab
        let pane = workspace.focusedPane

        let root = SidebarPanelStack()
            .environment(workspace)
            .environment(pane.app)
            .environment(pane.annotations)
            .environment(pane.ai)
            .environment(pane.scratchpad)

        // Borderless so the content view fills the window and window↔view
        // coordinate conversion carries no title-bar inset.
        let host = NSHostingView(rootView: root)
        host.frame = NSRect(x: 0, y: 0, width: 340, height: 700)
        let win = NSWindow(
            contentRect: host.frame, styleMask: [.borderless],
            backing: .buffered, defer: false)
        win.contentView = host
        win.orderOut(nil)
        host.layoutSubtreeIfNeeded()
        pump(0.4)
        window = win
        return (host, workspace, pane)
    }

    /// Flip the visible tab on an already-mounted hierarchy and let SwiftUI push
    /// the change through `updateNSView` (which re-arms the catcher's closures).
    private func flip(_ workspace: WorkspaceStore, to tab: WorkspaceStore.SidebarTab,
                      host: NSView) {
        workspace.sidebarTab = tab
        host.layoutSubtreeIfNeeded()
        pump(0.4)
    }

    /// The registered drag destination AppKit would route a drop at
    /// `windowPoint` to: the deepest registered view along the frontmost sibling
    /// branch containing the point. Front-to-back = `subviews` reversed.
    private func dragDestination(in root: NSView, windowPoint: NSPoint) -> NSView? {
        func search(_ view: NSView) -> NSView? {
            let local = view.convert(windowPoint, from: nil)
            guard view.bounds.contains(local) else { return nil }
            for sub in view.subviews.reversed() {
                if let hit = search(sub) { return hit }
            }
            return view.registeredDraggedTypes.isEmpty ? nil : view
        }
        return search(root)
    }

    // MARK: - Fixtures

    private func scratchPasteboard() -> NSPasteboard {
        let pasteboard = NSPasteboard(name: .init("vellum-sidebar-drop-\(UUID().uuidString)"))
        pasteboard.clearContents()
        scratchPasteboards.append(pasteboard)
        return pasteboard
    }

    /// A Finder drag: file URLs written as pasteboard objects, positioned at a
    /// window point so the AppKit overrides and the geometry search agree on
    /// where it is.
    private func finderDrag(of urls: [URL], at point: NSPoint) -> FakeDraggingInfo {
        let pasteboard = scratchPasteboard()
        XCTAssertTrue(pasteboard.writeObjects(urls as [NSURL]), "fixture sanity")
        return FakeDraggingInfo(pasteboard: pasteboard, location: point)
    }

    private func writeFixture(_ name: String, _ data: Data) throws -> URL {
        let url = fixtureDir.appendingPathComponent(name)
        try data.write(to: url)
        return url
    }

    /// A tiny valid PNG (4×4, opaque red), built in-process.
    private func pngFixtureData() throws -> Data {
        let rep = try XCTUnwrap(NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: 4, pixelsHigh: 4,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
            isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        let context = try XCTUnwrap(NSGraphicsContext(bitmapImageRep: rep))
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        NSColor.red.setFill()
        NSRect(x: 0, y: 0, width: 4, height: 4).fill()
        NSGraphicsContext.restoreGraphicsState()
        return try XCTUnwrap(rep.representation(using: .png, properties: [:]))
    }

    // MARK: - Run loop

    private func pump(_ seconds: TimeInterval) {
        RunLoop.current.run(until: Date().addingTimeInterval(seconds))
    }

    /// Pump the run loop until `condition` holds or the timeout elapses, so the
    /// off-main read/decode → main-actor attach chain can complete.
    private func pump(until condition: @autoclosure () -> Bool, timeout: TimeInterval = 5) {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() && Date() < deadline {
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.02))
        }
    }

    /// The window point at the center of the sidebar — the transcript/empty area,
    /// clear of the bottom composer's own AppKit drop views.
    private func centerPoint(of host: NSView) -> NSPoint {
        host.convert(NSPoint(x: host.bounds.midX, y: host.bounds.midY), to: nil)
    }

    // MARK: - Tests

    /// The destination AppKit would pick over the AI panel must be our AppKit
    /// `SidebarDropView` — and specifically NOT any SwiftUI
    /// `_PlatformDraggingDestinationView` (the class that broke the live app).
    /// Mount on annotations (the launch default), THEN flip to AI.
    func testAiTabDestinationIsTheAppKitCatcherNotSwiftUIPlatformView() throws {
        let (host, workspace, _) = hostSidebar(initialTab: .annotations)
        flip(workspace, to: .ai, host: host)

        let point = centerPoint(of: host)
        let dest = try XCTUnwrap(
            dragDestination(in: host, windowPoint: point),
            "no registered drag destination over the AI panel")

        XCTAssertTrue(
            dest is SidebarDropView,
            "the frontmost drag destination over the AI panel is \(type(of: dest)), " +
            "not the AppKit SidebarDropView")
        XCTAssertFalse(
            String(describing: type(of: dest)).contains("PlatformDraggingDestination"),
            "a SwiftUI _PlatformDraggingDestinationView is frontmost again — it will " +
            "steal and refuse the drag exactly like the original bug")
    }

    /// THE end-to-end test: a Finder image drop over the AI panel must be accepted
    /// (.copy) and attached as an image reference. Mount on annotations, flip to
    /// AI, then drop — the real lifecycle.
    func testAiTabAcceptsAndAttachesFinderImageDrop() throws {
        let file = try writeFixture("dropped.png", try pngFixtureData())
        let (host, workspace, pane) = hostSidebar(initialTab: .annotations)
        flip(workspace, to: .ai, host: host)

        let point = centerPoint(of: host)
        let dest = try XCTUnwrap(
            dragDestination(in: host, windowPoint: point),
            "no registered drag destination over the AI panel")

        let drag = finderDrag(of: [file], at: point)
        XCTAssertEqual(
            dest.draggingEntered(drag), .copy,
            "the sidebar refused a Finder drag over the visible AI panel")
        XCTAssertTrue(dest.performDragOperation(drag), "the drop was not accepted")

        pump(until: !pane.ai.composerReferences.isEmpty)
        // Note on the name: live Finder advertises the item as `public.file-url`,
        // so the real app names the chip after the file. The catcher instead reads
        // the pasteboard directly and (for this Finder fixture) resolves a file
        // URL, so the drop takes the .files branch. Assert on the shape (an image
        // reached the AI store) rather than the name.
        XCTAssertEqual(
            pane.ai.composerReferences.count, 1,
            "the AI panel did not attach exactly one reference for the drop")
        let ref = try XCTUnwrap(pane.ai.composerReferences.first)
        guard case .image = ref.kind else {
            return XCTFail("expected an image reference, got \(ref.kind)")
        }
        XCTAssertNotNil(ref.image, "the attached reference carries no image payload")
    }

    /// Images-only policy at the routing level: a non-image file dropped over
    /// the AI panel is accepted by the catcher (the drag carries a file URL) but
    /// attaches NO composer reference — instead the AI store surfaces the
    /// transient toast notice (NOT the inline transcript `error`).
    func testAiTabTxtDropAttachesNothingAndWarns() throws {
        let file = try writeFixture("notes.txt", Data("hello".utf8))
        let (host, workspace, pane) = hostSidebar(initialTab: .annotations)
        flip(workspace, to: .ai, host: host)

        let point = centerPoint(of: host)
        let dest = try XCTUnwrap(
            dragDestination(in: host, windowPoint: point),
            "no registered drag destination over the AI panel")

        let drag = finderDrag(of: [file], at: point)
        // A non-image FILE still carries an attachment (a file URL), so the drag
        // is accepted; the store reads it, finds no image, and warns.
        XCTAssertEqual(dest.draggingEntered(drag), .copy)
        XCTAssertTrue(dest.performDragOperation(drag))

        pump(until: pane.ai.attachmentNotice != nil)
        XCTAssertTrue(
            pane.ai.composerReferences.isEmpty,
            "a non-image AI-panel drop must not attach a composer reference")
        XCTAssertNotNil(
            pane.ai.attachmentNotice,
            "a non-image AI-panel drop must surface the images-only toast notice")
        XCTAssertTrue(
            pane.ai.attachmentNotice?.contains("notes.txt") == true,
            "the notice must name the declined file (was: \(pane.ai.attachmentNotice ?? "nil"))")
        XCTAssertNil(
            pane.ai.error,
            "the attachment notice must not leak into the inline transcript error")
    }

    /// A mixed multi-file drop (one image + one non-image) must attach exactly
    /// the image and warn once, naming the skipped file — no partial silence.
    func testMixedDropAttachesImagesAndWarnsOnce() throws {
        let png = try writeFixture("pic.png", try pngFixtureData())
        let txt = try writeFixture("notes.txt", Data("hello".utf8))
        let store = AiStore()

        store.attachFiles(at: [png, txt])

        pump(until: store.attachmentNotice != nil && !store.composerReferences.isEmpty)
        XCTAssertEqual(
            store.composerReferences.count, 1,
            "exactly one image reference should attach from the mixed drop")
        guard case .image = try XCTUnwrap(store.composerReferences.first).kind else {
            return XCTFail("the attached reference is not an image")
        }
        XCTAssertEqual(
            store.attachmentNotice,
            "Only image files can be attached. notes.txt wasn't added.",
            "the single toast notice must name the declined non-image file")
        XCTAssertNil(
            store.error,
            "the attachment notice must not leak into the inline transcript error")
    }

    // MARK: - Attachment notice lifecycle

    /// Showing an attachment notice sets it; dismissing clears it immediately;
    /// re-showing replaces the text. The 15-second auto-clear isn't waited on
    /// here (that would make the suite flaky) — it's left to live QA — but the
    /// re-show path exercises the timer-reset (the prior task is cancelled).
    func testAttachmentNoticeShowDismissReplace() {
        let store = AiStore()
        XCTAssertNil(store.attachmentNotice)

        store.showAttachmentNotice("first")
        XCTAssertEqual(store.attachmentNotice, "first")

        // Re-show replaces the text (and resets the auto-clear timer).
        store.showAttachmentNotice("second")
        XCTAssertEqual(store.attachmentNotice, "second")

        // The × button clears it right away.
        store.dismissAttachmentNotice()
        XCTAssertNil(store.attachmentNotice)
    }

    /// On the annotations tab the catcher must REFUSE the drag (empty operation)
    /// and nothing may reach any store. Annotations is the launch default, so no
    /// flip is needed here.
    func testAnnotationsTabRefusesDropAndAttachesNothing() throws {
        let file = try writeFixture("nope.png", try pngFixtureData())
        let (host, _, pane) = hostSidebar(initialTab: .annotations)

        var scratchpadReceived = false
        pane.scratchpad.insertMarkdownHandler = { _ in scratchpadReceived = true }

        let point = centerPoint(of: host)
        let drag = finderDrag(of: [file], at: point)

        if let dest = dragDestination(in: host, windowPoint: point) {
            XCTAssertNotEqual(
                dest.draggingEntered(drag), .copy,
                "the annotations tab must refuse drops")
            _ = dest.performDragOperation(drag)
        }

        pump(0.4)
        XCTAssertTrue(
            pane.ai.composerReferences.isEmpty,
            "an annotations-tab drop must not reach the AI store")
        XCTAssertFalse(
            scratchpadReceived,
            "an annotations-tab drop must not reach the scratchpad store")
    }

    /// A Finder image drop over the scratchpad panel attaches to the scratchpad
    /// (its `insertMarkdownHandler` fires with a `vellum-scratchpad://…` ref) and
    /// nothing leaks to the AI store. Mount on annotations, flip to scratchpad.
    func testScratchpadTabAttachesFinderImageDrop() throws {
        let file = try writeFixture("scratch.png", try pngFixtureData())
        let (host, workspace, pane) = hostSidebar(initialTab: .annotations)
        flip(workspace, to: .scratchpad, host: host)

        var inserted: [String] = []
        pane.scratchpad.insertMarkdownHandler = { inserted.append($0) }

        let point = centerPoint(of: host)
        let dest = try XCTUnwrap(
            dragDestination(in: host, windowPoint: point),
            "no registered drag destination over the scratchpad panel")

        let drag = finderDrag(of: [file], at: point)
        XCTAssertEqual(dest.draggingEntered(drag), .copy, "scratchpad refused a Finder image drag")
        XCTAssertTrue(dest.performDragOperation(drag), "the drop was not accepted")

        pump(until: !inserted.isEmpty)
        XCTAssertTrue(
            inserted.contains { $0.contains(ScratchpadAttachmentStore.scheme) },
            "the scratchpad did not attach the dropped image (inserted: \(inserted))")
        XCTAssertTrue(
            pane.ai.composerReferences.isEmpty,
            "a scratchpad drop must not reach the AI store")
    }

    /// DIAGNOSTIC (regression guard): after the real mount-then-flip lifecycle,
    /// the REAL scratchpad editor must have installed its `insertMarkdownHandler`
    /// and nothing may have nil'd it. The other scratchpad tests overwrite this
    /// handler with their own probe, so they pass even when the editor's real
    /// handler was wiped by a make/dismantle ordering issue — which is exactly the
    /// live regression (drop saved, image never appeared). We assert on the REAL
    /// handler here without replacing it.
    func testScratchpadEditorHandlerSurvivesMountThenFlip() throws {
        let (host, workspace, pane) = hostSidebar(initialTab: .annotations)
        // Mounted on annotations first. The editor is mounted (ZStack) but has not
        // yet been asked to become the drop target.
        flip(workspace, to: .scratchpad, host: host)
        pump(0.4)

        XCTAssertNotNil(
            pane.scratchpad.insertMarkdownHandler,
            "the real scratchpad editor's insertMarkdownHandler is nil after " +
            "mount-then-flip — a drop routed to addImage would be silently lost")
    }

    /// END-TO-END through the REAL editor handler (no probe overwrite): drop an
    /// image on the scratchpad tab and assert the REAL handler chain fires. We
    /// wrap (not replace) the editor's handler so the real coordinator still
    /// receives the insert while we observe it. If the real handler was nil, the
    /// wrapper's `previous` is nil and the assertion below catches the loss.
    func testScratchpadDropReachesRealEditorHandler() throws {
        let file = try writeFixture("real.png", try pngFixtureData())
        let (host, workspace, pane) = hostSidebar(initialTab: .annotations)
        flip(workspace, to: .scratchpad, host: host)
        pump(0.4)

        let previous = pane.scratchpad.insertMarkdownHandler
        XCTAssertNotNil(
            previous,
            "the real editor handler must be installed before the drop; nil means " +
            "the drop would vanish after save")
        var inserted: [String] = []
        pane.scratchpad.insertMarkdownHandler = { markdown in
            inserted.append(markdown)
            previous?(markdown)
        }

        let point = centerPoint(of: host)
        let dest = try XCTUnwrap(dragDestination(in: host, windowPoint: point))
        let drag = finderDrag(of: [file], at: point)
        XCTAssertEqual(dest.draggingEntered(drag), .copy)
        XCTAssertTrue(dest.performDragOperation(drag))

        pump(until: !inserted.isEmpty)
        XCTAssertTrue(
            inserted.contains { $0.contains(ScratchpadAttachmentStore.scheme) },
            "the real editor handler never received the dropped image markdown " +
            "(inserted: \(inserted))")
    }

    /// THE regression proof (deterministic, no `.inspector` internals needed):
    /// SwiftUI recreates an `NSViewRepresentable` by building the replacement
    /// (fresh `makeNSView`, which installs the store's `insertMarkdownHandler`)
    /// and only THEN dismantling the old one. The live sidebar sits inside an
    /// `.inspector`, whose glass hosting churns exactly this make-new-then-
    /// dismantle-old cycle. If `dismantleNSView` nils the handler unconditionally,
    /// it wipes the FRESH handler the replacement just installed — leaving the
    /// store with a nil handler, so a dropped image saves to disk but never
    /// reaches the editor and vanishes with no warning (the reported bug).
    ///
    /// We reproduce the ordering directly: mount editor A over a store, mount a
    /// second editor B over the SAME store (B's makeNSView installs the fresh
    /// handler), THEN tear A down (its dismantle runs last). The store's handler
    /// must still be live afterwards.
    func testEditorRemountKeepsFreshInsertHandler() throws {
        let workspace = WorkspaceStore(sessions: DocumentSessionManager())
        workspace.sidebarOpen = true
        workspace.sidebarTab = .scratchpad
        let pane = workspace.focusedPane
        let store = pane.scratchpad

        func editorHost() -> NSHostingView<AnyView> {
            let root = AnyView(
                ScratchpadPanel()
                    .environment(workspace)
                    .environment(pane.app)
                    .environment(pane.annotations)
                    .environment(pane.ai)
                    .environment(store))
            let host = NSHostingView(rootView: root)
            host.frame = NSRect(x: 0, y: 0, width: 340, height: 700)
            let win = NSWindow(
                contentRect: host.frame, styleMask: [.borderless],
                backing: .buffered, defer: false)
            win.contentView = host
            win.orderOut(nil)
            host.layoutSubtreeIfNeeded()
            return host
        }

        // A mounts first and installs its handler.
        let hostA = editorHost()
        pump(0.4)
        XCTAssertNotNil(store.insertMarkdownHandler, "editor A never installed a handler")

        // B mounts over the SAME store — its makeNSView installs the fresh handler.
        let hostB = editorHost()
        pump(0.4)
        XCTAssertNotNil(store.insertMarkdownHandler, "editor B never installed a handler")

        // Now tear A down. SwiftUI dismantles A's editor; a naive dismantle nils
        // the store's handler even though B is the live owner.
        hostA.rootView = AnyView(EmptyView())
        hostA.layoutSubtreeIfNeeded()
        pump(0.6)

        XCTAssertNotNil(
            store.insertMarkdownHandler,
            "dismantling the replaced editor wiped the live editor's insert handler " +
            "— a scratchpad image drop would save but never appear in the note")

        hostB.rootView = AnyView(EmptyView())
        pump(0.2)
    }

    /// A non-image dropped on the scratchpad must trigger the "unsupported drop"
    /// warning rather than silently vanishing (the drop is still "handled").
    func testScratchpadTabWarnsOnNonImageDrop() throws {
        let file = try writeFixture("notes.txt", Data("hello".utf8))
        let (host, workspace, pane) = hostSidebar(initialTab: .annotations)
        flip(workspace, to: .scratchpad, host: host)

        var inserted: [String] = []
        pane.scratchpad.insertMarkdownHandler = { inserted.append($0) }

        let point = centerPoint(of: host)
        let dest = try XCTUnwrap(dragDestination(in: host, windowPoint: point))

        let drag = finderDrag(of: [file], at: point)
        // A non-image FILE still carries an attachment (a file URL), so the drag
        // is accepted; the store reads it, fails to decode an image, and warns.
        XCTAssertEqual(dest.draggingEntered(drag), .copy)
        XCTAssertTrue(dest.performDragOperation(drag))

        pump(until: pane.scratchpad.dropWarning != nil)
        XCTAssertNotNil(
            pane.scratchpad.dropWarning,
            "a non-image scratchpad drop must surface the unsupported-drop warning")
        XCTAssertTrue(inserted.isEmpty, "a non-image drop must not insert markdown")
    }

    /// The critical click-through guard: `SidebarDropView.hitTest` must return nil
    /// for points inside its bounds so clicks and typing pass through to the
    /// composer/editor beneath it. Without this the whole sidebar is unclickable.
    func testCatcherHitTestReturnsNilSoClicksPassThrough() throws {
        let (host, workspace, _) = hostSidebar(initialTab: .annotations)
        flip(workspace, to: .ai, host: host)

        let point = centerPoint(of: host)
        let dest = try XCTUnwrap(dragDestination(in: host, windowPoint: point))
        let catcher = try XCTUnwrap(dest as? SidebarDropView)

        // A point squarely inside the catcher's bounds, in its own coordinates.
        let inside = NSPoint(x: catcher.bounds.midX, y: catcher.bounds.midY)
        XCTAssertTrue(catcher.bounds.contains(inside), "test point must be inside bounds")
        XCTAssertNil(
            catcher.hitTest(inside),
            "SidebarDropView.hitTest must return nil so clicks reach the composer beneath")
    }
}
