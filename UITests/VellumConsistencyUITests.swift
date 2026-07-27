import XCTest

final class VellumConsistencyUITests: VellumUITestCase {
    func testFreshHomeCanOpenSettings() {
        let app = makeApp()
        app.launch()

        XCTAssertTrue(app.buttons["welcome.openPdf"].waitForExistence(timeout: 8))
        app.typeKey(",", modifierFlags: .command)

        XCTAssertTrue(
            app.windows["com_apple_SwiftUI_Settings_window"]
                .waitForExistence(timeout: 5),
            "Command-comma should expose global settings from Home")
    }

    func testDocumentExposesCommandSidebarAndTabAffordances() throws {
        let app = makeApp(opening: try makePDF())
        app.launch()
        waitForDocument(in: app)

        XCTAssertTrue(app.buttons["tabBar.newTab"].exists)
        let sidebarToggle = app.buttons["toolbar.sidebarToggle"]
        XCTAssertTrue(sidebarToggle.exists)
        let aiTab = app.descendants(matching: .any)["sidebarTab.AI"]
        if !aiTab.waitForExistence(timeout: 2) {
            sidebarToggle.tap()
        }
        XCTAssertTrue(aiTab.waitForExistence(timeout: 3))

        app.menuBars.menuBarItems["File"].click()
        XCTAssertTrue(app.menuItems["New Tab"].exists)
        XCTAssertTrue(app.menuItems["Open…"].exists)
        app.typeKey(.escape, modifierFlags: [])
    }

    func testCorruptedRestorationRecoversToUsableHome() {
        let app = makeApp(corruptRestoration: true)
        app.launch()

        XCTAssertTrue(
            app.buttons["welcome.openPdf"].waitForExistence(timeout: 8),
            "A corrupt persisted workspace must recover to a usable Home screen")
        XCTAssertTrue(app.textFields["welcome.urlField"].exists)
    }
}
