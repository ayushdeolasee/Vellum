import Foundation
import Testing
import UIKit

@testable import Vellum

// The compact (iPhone) workspace: one pane, enforced by the STORE rather than by
// the phone's chrome simply not offering a split button (#153 D4).
//
// Why the store and not the view. The split paths are reachable with no chrome
// at all — a hardware keyboard's ⌃⌘D, a tab drag, and above all a workspace
// restored from disk after the same user's last iPad session, since both idioms
// share one persisted layout blob. A view-layer omission leaves those paths
// live, and a split that gets built but never drawn is not cosmetic: the second
// pane's tabs are unreachable and its residency pin never drops, so whatever it
// was showing is exempt from eviction for the life of the process.
//
// So the contract under test is a platform-neutral one — "a `.singlePane`
// workspace is a single leaf, always" — plus the oracle that decides which
// capability a process gets. No views anywhere in this file.

@MainActor
@Suite(.scratchDefaults)
struct CompactWorkspaceTests {

    // MARK: - The idiom oracle

    /// The gate is the IDIOM, not the size class. The two cases that make that
    /// matter are asserted directly: a Max/Plus phone in landscape reports
    /// REGULAR width and must still get the phone shell, and an iPad in Slide
    /// Over reports COMPACT width and must still get the iPad shell. Neither
    /// device is asked about its width here, which is precisely the point —
    /// `resolve` has no width input to consult.
    @Test func theShellIsChosenByIdiomAloneAndNotByWidth() {
        #expect(ShellIdiom_iOS.resolve(environment: [:], deviceIdiom: .phone) == .phone)
        #expect(ShellIdiom_iOS.resolve(environment: [:], deviceIdiom: .pad) == .pad)
        // Everything that is not a phone gets the roomier shell — the safer of
        // the two wrong answers for an idiom this app does not build for.
        #expect(ShellIdiom_iOS.resolve(environment: [:], deviceIdiom: .mac) == .pad)
        #expect(ShellIdiom_iOS.resolve(environment: [:], deviceIdiom: .unspecified) == .pad)
    }

    @Test func eachIdiomCarriesItsOwnPaneLayoutCapability() {
        #expect(ShellIdiom_iOS.phone.paneLayout == .singlePane)
        #expect(ShellIdiom_iOS.pad.paneLayout == .splitScreen)
    }

    #if DEBUG
    /// `VELLUM_FORCE_SHELL` is what lets a QA run drive the phone shell on an
    /// iPad simulator (and lets this suite exercise the branch the host device
    /// is not). It is DEBUG-only, so a shipped build cannot be talked out of its
    /// real idiom; the `#if` here mirrors the `#if` around the implementation.
    @Test func theDebugOverrideForcesEitherShellRegardlessOfTheDevice() {
        #expect(
            ShellIdiom_iOS.resolve(
                environment: ["VELLUM_FORCE_SHELL": "phone"], deviceIdiom: .pad) == .phone)
        #expect(
            ShellIdiom_iOS.resolve(
                environment: ["VELLUM_FORCE_SHELL": "pad"], deviceIdiom: .phone) == .pad)
        // Case and stray whitespace are a launch-argument reality, not a typo
        // worth failing a QA run over.
        #expect(
            ShellIdiom_iOS.resolve(
                environment: ["VELLUM_FORCE_SHELL": " Phone "], deviceIdiom: .pad) == .phone)
        // Anything unparseable falls through to the device rather than picking
        // a shell at random.
        #expect(
            ShellIdiom_iOS.resolve(
                environment: ["VELLUM_FORCE_SHELL": "tablet"], deviceIdiom: .phone) == .phone)
    }
    #endif

    // MARK: - The split operations are refusals

    @Test func splitFocusedIsIgnoredUnderSinglePane() {
        let ws = makeWorkspace(layout: .singlePane)
        let paneId = ws.focusedPaneId

        ws.splitFocused(.horizontal)

        #expect(!ws.isSplit)
        #expect(ws.root.allLeaves().count == 1)
        // A refused split must not move focus, and must not leave a stray
        // "New Tab" behind from the pane it declined to build.
        #expect(ws.focusedPaneId == paneId)
        #expect(ws.focusedPane.app.tabs.isEmpty)
    }

    @Test func splitWithTabLeavesTheTabInItsOwnPaneUnderSinglePane() {
        let ws = makeWorkspace(layout: .singlePane)
        let pane = ws.focusedPane
        pane.app.newStartTab()
        pane.app.newStartTab()
        let tabIds = pane.app.tabs.map(\.id)

        // Dragging one of two tabs onto its own pane's edge: the one shape of
        // this call a single-pane window can actually produce, and the one the
        // early `tabs.count <= 1` return does NOT already cover.
        ws.splitWithTab(
            tabId: tabIds[0], from: pane.id, target: pane.id,
            direction: .horizontal, before: false)

        #expect(!ws.isSplit)
        // The capability guard runs before `detachTab`, so the tab is still
        // where it was rather than detached into a pane that was never built.
        #expect(pane.app.tabs.map(\.id) == tabIds)
    }

    @Test func moveTabIsRefusedBeforeItCanDetachAnythingUnderSinglePane() {
        let ws = makeWorkspace(layout: .singlePane)
        let pane = ws.focusedPane
        pane.app.newStartTab()
        pane.app.newStartTab()
        let tabIds = pane.app.tabs.map(\.id)

        // There is no second pane to move into — that is the whole point of
        // `.singlePane` — so the only way this call arrives is with a stale
        // destination id, e.g. a drag payload minted before a flatten. It has to
        // be a no-op that keeps the tab, not a detach into nowhere.
        ws.moveTab(tabId: tabIds[0], from: pane.id, to: "pane-that-no-longer-exists")

        #expect(!ws.isSplit)
        #expect(pane.app.tabs.map(\.id) == tabIds)
        #expect(pane.app.activeTabId == tabIds[1])
    }

    /// The control. Three refusals are only meaningful if the same store still
    /// splits when it is allowed to — otherwise this suite would pass with the
    /// split operations deleted outright, and the iPad would be broken.
    @Test func theSplitScreenWorkspaceStillSplits() {
        let ws = makeWorkspace(layout: .splitScreen)

        ws.splitFocused(.horizontal)

        #expect(ws.isSplit)
        #expect(ws.root.allLeaves().count == 2)
    }

    // MARK: - Restoring an iPad's split onto a phone

    /// The path that actually matters in production: one persisted workspace
    /// blob serves both idioms, so a phone launching after an iPad session finds
    /// a split on disk. It must come back as ONE pane holding every tab, in the
    /// order the tree had them, still on the document the user was reading.
    @Test func aPersistedSplitRestoresToOneLeafUnderSinglePane() async throws {
        let fixture = try PdfFixtures()
        defer { fixture.cleanUp() }
        let left = try fixture.pdf(named: "left")
        let middle = try fixture.pdf(named: "middle")
        let right = try fixture.pdf(named: "right")
        WorkspaceService.save(splitState(first: [left, middle], second: [right]))

        let ws = makeWorkspace(layout: .singlePane)
        await ws.restoreFromDisk()

        #expect(!ws.isSplit)
        #expect(ws.root.allLeaves().count == 1)
        // Tree order, not "the focused pane's tabs then the rest": the merge
        // keeps the FIRST leaf and migrates the others into it, so the persisted
        // left-to-right reading order survives the flatten.
        #expect(ws.focusedPane.app.tabs.compactMap(\.document?.pdfPath) == [left, middle, right])
        // `focusedLeafIndex: 1` — the user was reading the right-hand pane's
        // document, and that is what they must still be looking at.
        #expect(ws.focusedPane.app.document?.pdfPath == right)
        // Serializing afterwards writes a LEAF, so the next launch (on either
        // device) no longer carries a split the phone would have to re-flatten.
        if case .split = ws.serialize().root {
            Issue.record("a flattened workspace serialized itself back into a split")
        }
        // No orphaned residency owner survived the flatten. `hotTabIds` is
        // `pinned ∪ recent`, and nothing is resident here, so it is exactly the
        // set of pins — one, for the single surviving pane. A donor pane whose
        // pin outlived it would show up here as a second id, and whatever it was
        // showing would then be exempt from eviction forever.
        #expect(ws.residency.hotTabIds == Set([ws.focusedPane.app.activeTabId].compactMap { $0 }))

        await joinDebouncedSave()
    }

    /// The iPad control for the same blob: `.splitScreen` must restore the split
    /// exactly as it always has. This is the assertion that would catch the
    /// flatten leaking into the iPad path.
    @Test func theSamePersistedSplitRestoresAsASplitUnderSplitScreen() async throws {
        let fixture = try PdfFixtures()
        defer { fixture.cleanUp() }
        let left = try fixture.pdf(named: "left")
        let middle = try fixture.pdf(named: "middle")
        let right = try fixture.pdf(named: "right")
        WorkspaceService.save(splitState(first: [left, middle], second: [right]))

        let ws = makeWorkspace(layout: .splitScreen)
        await ws.restoreFromDisk()

        #expect(ws.isSplit)
        let leaves = ws.root.allLeaves()
        #expect(leaves.count == 2)
        #expect(leaves.first?.app.tabs.compactMap(\.document?.pdfPath) == [left, middle])
        #expect(leaves.last?.app.tabs.compactMap(\.document?.pdfPath) == [right])
        #expect(ws.focusedPaneId == leaves.last?.id)
        // Both panes are on screen, so both pin their visible document.
        #expect(ws.residency.hotTabIds.count == 2)

        await joinDebouncedSave()
    }

    // MARK: - Fixtures

    private func makeWorkspace(layout: PaneLayoutCapability) -> WorkspaceStore {
        WorkspaceStore(sessions: DocumentSessionManager(), layout: layout)
    }

    /// A two-leaf persisted workspace, focused on the SECOND leaf so the flatten
    /// has to carry an active tab across a pane that stops existing.
    private func splitState(first: [String], second: [String]) -> WorkspaceState {
        func leaf(_ paths: [String]) -> PaneNodeDTO {
            .leaf(
                tabs: paths.map { path in
                    TabDescriptor(
                        document: DocumentInfo(
                            kind: .pdf, pdfPath: path,
                            title: (path as NSString).lastPathComponent,
                            pageCount: 1, lastPage: 1),
                        currentPage: 1, zoom: 1, mode: .view)
                },
                activeTabIndex: 0)
        }
        return WorkspaceState(
            root: .split(
                direction: .horizontal,
                children: [leaf(first), leaf(second)],
                sizes: [50, 50]),
            focusedLeafIndex: 1)
    }

    /// `restoreFromDisk` ends by arming `scheduleSave`'s 800 ms debounce. The
    /// `.scratchDefaults` domain is torn down the moment the test body returns,
    /// so a write still in flight would land after teardown and recreate the
    /// suite's plist. Joining it here keeps the scratch domain's lifetime
    /// honest — see `ScratchDefaultsTrait`.
    private func joinDebouncedSave() async {
        try? await Task.sleep(for: .milliseconds(900))
    }
}

/// A throwaway directory of real, openable one-page PDFs. `restoreTabs` goes
/// through the actual session service, so a fabricated path would simply be
/// dropped and every assertion about tab order would pass vacuously.
@MainActor
private struct PdfFixtures {
    let directory: URL

    init() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("vellum-compact-workspace-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true)
    }

    func pdf(named name: String) throws -> String {
        let url = directory.appendingPathComponent("\(name).pdf")
        let bounds = CGRect(x: 0, y: 0, width: 612, height: 792)
        let data = UIGraphicsPDFRenderer(bounds: bounds).pdfData { context in
            context.beginPage()
            UIColor.white.setFill()
            UIRectFill(bounds)
        }
        try data.write(to: url)
        return url.path
    }

    func cleanUp() {
        try? FileManager.default.removeItem(at: directory)
    }
}
