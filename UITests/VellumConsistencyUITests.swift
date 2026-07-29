import XCTest

final class VellumConsistencyUITests: VellumUITestCase {
    func testFreshHomeCanOpenSettings() {
        let app = makeApp()
        app.launch()

        XCTAssertTrue(app.buttons["welcome.openPdf"].firstMatch.waitForExistence(timeout: 8))
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

        XCTAssertTrue(app.buttons["tabBar.newTab"].waitForExistence(timeout: 5))
        let sidebarToggle = app.buttons["toolbar.sidebarToggle"]
        XCTAssertTrue(sidebarToggle.waitForExistence(timeout: 5))
        let aiTab = app.descendants(matching: .any)["sidebarTab.ai"].firstMatch
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

    /// `AddWebpageSheet` reads `@Environment(AppStore.self)`, and the `.sheet`
    /// presenting it was chained AFTER ContentView's `.environment(focused.app)`
    /// write. Modifiers compose outside-in, so the presentation sat above that
    /// write, resolved no `AppStore`, and SwiftUI trapped the instant the sheet
    /// appeared — clicking "Add Webpage" killed the app. Only presenting the
    /// sheet catches this: it is view-tree wiring with no non-UI seam.
    func testAddWebpageFromHomePresentsUrlSheet() {
        let app = makeApp()
        app.launch()

        let addWebpage = app.buttons["welcome.addWebpage"].firstMatch
        XCTAssertTrue(addWebpage.waitForExistence(timeout: 8))
        addWebpage.tap()

        XCTAssertTrue(
            app.textFields["addWebpage.urlField"].waitForExistence(timeout: 5),
            "Add Webpage must present its URL sheet, not trap on a missing AppStore")
        XCTAssertEqual(
            app.state, .runningForeground,
            "The app must survive presenting the Add Webpage sheet")
    }

    func testCorruptedRestorationRecoversToUsableHome() {
        let app = makeApp(corruptRestoration: true)
        app.launch()

        XCTAssertTrue(
            app.buttons["welcome.openPdf"].firstMatch.waitForExistence(timeout: 8),
            "A corrupt persisted workspace must recover to a usable Home screen")
        // `welcome.urlField` belongs to the first-run hero, which #68 shows only
        // once the library search has finished loading and come back empty —
        // `welcome.openPdf` is in both Home layouts, so its appearance does not
        // imply the hero is up yet. Wait for the field rather than probing it.
        XCTAssertTrue(
            app.textFields["welcome.urlField"].waitForExistence(timeout: 8),
            "The first-run hero should offer the URL field on an empty library")
    }
}
