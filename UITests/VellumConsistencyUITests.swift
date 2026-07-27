import XCTest

final class VellumConsistencyUITests: VellumUITestCase {
    func testFreshHomeCanOpenSettings() {
        let app = makeApp()
        app.launch()

        XCTAssertTrue(app.buttons["welcome.openPdf"].waitForExistence(timeout: 8))
        app.typeKey(",", modifierFlags: .command)

        XCTAssertTrue(
            app.descendants(matching: .any)["settings.content"]
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

        // The custom View command must change the actual inspector content,
        // rather than merely exposing a menu item.
        app.menuBars.menuBarItems["View"].click()
        let hideInspector = app.menuItems["Hide Inspector"]
        XCTAssertTrue(hideInspector.exists)
        hideInspector.click()
        XCTAssertTrue(aiTab.waitForNonExistence(timeout: 3), "Inspector did not hide")

        app.menuBars.menuBarItems["View"].click()
        let showInspector = app.menuItems["Show Inspector"]
        XCTAssertTrue(showInspector.exists)
        showInspector.click()
        XCTAssertTrue(aiTab.waitForExistence(timeout: 3), "Inspector did not reappear")

        let tabs = app.buttons.matching(
            NSPredicate(format: "identifier BEGINSWITH %@", "tabBar.tab."))
        let initialTabCount = tabs.count
        app.menuBars.menuBarItems["File"].click()
        let newTab = app.menuItems["New Tab"]
        XCTAssertTrue(newTab.exists)
        XCTAssertTrue(app.menuItems["Open…"].exists)
        newTab.click()
        XCTAssertTrue(
            tabs.element(boundBy: initialTabCount).waitForExistence(timeout: 3),
            "New Tab did not add a tab")
        XCTAssertEqual(tabs.count, initialTabCount + 1)
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
