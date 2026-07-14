import XCTest

// UI test for the scratchpad region-snapshot flow: open a PDF, switch to the
// Scratchpad tab, arm the crop button, drag a rectangle over the page, and
// assert an attachment file lands on disk (the note now references it).
//
// This lives in a UI-testing bundle target (see UITests/README-setup.md for the
// 20-second Xcode step to create it — a UI test cannot run in the unit-test
// target). The pure logic it funnels into is already covered deterministically
// by VellumTests/ScratchpadImportTests; this adds the real drag event stream.
//
// NOT covered here: external image drag-and-drop. XCUITest cannot originate a
// Finder-style file drop, so that path stays a manual check.
//
// Before running: set VELLUM_TEST_PDF (below) to an absolute path of a small
// PDF on this machine, and confirm APP_BUNDLE_ID matches the built app.
final class ScratchpadSnapshotUITests: XCTestCase {
    /// A small on-disk PDF to open. Point this at a real file.
    private let testPDFPath = ProcessInfo.processInfo.environment["VELLUM_TEST_PDF"]
        ?? "UITests/fixtures/sample.pdf"

    /// Must match the built app's bundle identifier (Build Settings →
    /// PRODUCT_BUNDLE_IDENTIFIER of the Vellum target).
    private let appBundleID = "com.vellum.app"

    private var attachmentsDir: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return base.appendingPathComponent(appBundleID, isDirectory: true)
            .appendingPathComponent("scratchpad-attachments", isDirectory: true)
    }

    func testDragCropAddsAttachmentToNote() throws {
        try XCTSkipUnless(
            FileManager.default.fileExists(atPath: testPDFPath),
            "Set VELLUM_TEST_PDF to a real PDF path to run this test.")

        let before = attachmentFileCount()

        let app = XCUIApplication()
        app.launch()

        openPDF(in: app)

        // Open the inspector and switch to the Scratchpad tab. The segmented
        // picker exposes ids via accessibilityIdentifierPrefix "sidebarTab".
        let scratchpadTab = app.descendants(matching: .any)["sidebarTab.scratchpad"]
        if !scratchpadTab.waitForExistence(timeout: 5) {
            // Inspector may be closed; toggle it from the toolbar, then retry.
            app.toolbars.buttons.matching(NSPredicate(format: "identifier CONTAINS[c] 'inspector'"))
                .firstMatch.tap()
        }
        XCTAssertTrue(scratchpadTab.waitForExistence(timeout: 5), "Scratchpad tab not found")
        scratchpadTab.tap()

        // Arm region-snapshot mode.
        let snapButton = app.buttons["scratchpad.snapshotRegion"]
        XCTAssertTrue(snapButton.waitForExistence(timeout: 5), "Snapshot button missing")
        snapButton.tap()

        // Drag a rectangle across the middle of the document area to crop it.
        let window = app.windows.firstMatch
        let start = window.coordinate(withNormalizedOffset: CGVector(dx: 0.35, dy: 0.35))
        let end = window.coordinate(withNormalizedOffset: CGVector(dx: 0.6, dy: 0.6))
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
        (try? FileManager.default.contentsOfDirectory(atPath: attachmentsDir.path))?.count ?? 0
    }

    /// Open `testPDFPath` via the welcome screen's "Open a PDF" button and the
    /// standard open panel (Go-to-folder → path → open).
    private func openPDF(in app: XCUIApplication) {
        let openButton = app.buttons["welcome.openPdf"]
        if openButton.waitForExistence(timeout: 5) {
            openButton.tap()
            let sheet = app.sheets.firstMatch
            _ = sheet.waitForExistence(timeout: 3)
            app.typeKey("g", modifierFlags: [.command, .shift])
            app.typeText(testPDFPath)
            app.typeKey(.return, modifierFlags: [])   // confirm go-to-folder
            app.typeKey(.return, modifierFlags: [])   // confirm open
        }
    }
}
