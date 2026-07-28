import XCTest

// UI test for the scratchpad region-snapshot flow: open a PDF, switch to the
// Scratchpad tab, arm the crop button, drag a rectangle over the page, and
// assert an attachment file lands on disk (the note now references it).
//
// This lives in the UI-testing bundle target documented in UITests/README.md;
// a UI test cannot run in the unit-test target. The pure logic it funnels into
// is already covered deterministically by VellumTests/ScratchpadImportTests;
// this adds the real drag event stream.
//
// NOT covered here: external image drag-and-drop. XCUITest cannot originate a
// Finder-style file drop, so that path stays a manual check.
//
final class ScratchpadSnapshotUITests: VellumUITestCase {

    func testDragCropAddsAttachmentToNote() throws {
        let before = attachmentFileCount()

        let app = makeApp(opening: try makePDF())
        app.launch()
        waitForDocument(in: app)

        // Open the inspector and switch to the Scratchpad tab. #73's
        // `InspectorTabSwitcher` derives each id from the case name, so the
        // stem is lowercase (`sidebarTab.scratchpad`) in every layout it can
        // reach at the inspector's 280pt minimum width.
        let scratchpadTab = app.descendants(matching: .any)["sidebarTab.scratchpad"].firstMatch
        if !scratchpadTab.waitForExistence(timeout: 5) {
            // Inspector may be closed; toggle it from the toolbar, then retry.
            app.buttons["toolbar.sidebarToggle"].tap()
        }
        XCTAssertTrue(scratchpadTab.waitForExistence(timeout: 5), "Scratchpad tab not found")
        scratchpadTab.tap()

        // Arm region-snapshot mode.
        let snapButton = app.buttons["scratchpad.snapshotRegion"]
        XCTAssertTrue(snapButton.waitForExistence(timeout: 5), "Snapshot button missing")
        snapButton.tap()
        XCTAssertTrue(snapButton.isSelected, "Snapshot mode was not selected")

        // Drag within the app-owned PDF canvas, not the window: toolbar and
        // inspector geometry vary independently of the rendered page.
        let canvas = app.descendants(matching: .any)["pdf.canvas"]
        XCTAssertTrue(canvas.waitForExistence(timeout: 5), "PDF canvas missing")
        let start = canvas.coordinate(withNormalizedOffset: CGVector(dx: 0.35, dy: 0.35))
        let end = canvas.coordinate(withNormalizedOffset: CGVector(dx: 0.6, dy: 0.6))
        start.press(forDuration: 0.4, thenDragTo: end)

        // The capture writes a JPEG to the attachment store; poll for it.
        let deadline = Date().addingTimeInterval(5)
        while attachmentFileCount() <= before, Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        }
        XCTAssertGreaterThan(
            attachmentFileCount(), before,
            "Region snapshot did not produce an attachment file on disk")
    }

    // MARK: - Helpers

    private func attachmentFileCount() -> Int {
        guard let enumerator = FileManager.default.enumerator(
            at: storageRoot,
            includingPropertiesForKeys: [.isRegularFileKey])
        else { return 0 }
        return enumerator.compactMap { $0 as? URL }
            .filter { ["jpg", "jpeg", "png"].contains($0.pathExtension.lowercased()) }
            .count
    }
}
