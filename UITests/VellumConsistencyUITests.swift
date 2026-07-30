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

    /// Regression for the side panel that could not be resized.
    ///
    /// `.inspectorColumnWidth` was applied *inside* `.onGeometryChange` on the
    /// inspector content. The column-width envelope is a view trait the
    /// inspector host reads off the root of that content, and it does not
    /// survive being wrapped — so the host saw nothing, fell back to its
    /// built-in 270pt column, and registered no min/max range for AppKit to
    /// resize between. The divider was inert.
    ///
    /// What this pins is the observable signature of that fallback: the column
    /// must open at its declared 360pt ideal, and expose a seam. 270pt here
    /// means the trait got swallowed again and the panel is stuck.
    ///
    /// The seam drag itself is deliberately NOT driven here. XCUITest's
    /// synthesized press-and-drag does not drive AppKit's divider tracking
    /// loop — it reports success and the splitter never moves, on fixed and
    /// broken builds alike, so an assertion on it would pass vacuously or fail
    /// for the wrong reason. Dragging was verified out of band against the
    /// splitter's settable `AXValue`: on this code it moves (360pt -> 500pt and
    /// stays); with `.inspectorColumnWidth` back inside `.onGeometryChange` the
    /// same write is refused and the column holds at 270pt.
    func testInspectorColumnUsesItsDeclaredWidthEnvelope() throws {
        let app = makeApp(opening: try makePDF())
        app.launch()
        waitForDocument(in: app)

        let annotations = app.descendants(matching: .any)["sidebarTab.annotations"].firstMatch
        let scratchpad = app.descendants(matching: .any)["sidebarTab.scratchpad"].firstMatch
        if !annotations.waitForExistence(timeout: 3) {
            app.buttons["toolbar.sidebarToggle"].tap()
        }
        XCTAssertTrue(annotations.waitForExistence(timeout: 5))
        XCTAssertTrue(scratchpad.waitForExistence(timeout: 5))

        // AppKit exposes the inspector seam as the window's one AXSplitter, so
        // the column is exactly the strip to its right. Measuring off the
        // splitter (rather than the switcher's insets) keeps this honest if the
        // panel's padding ever changes.
        let window = app.windows.firstMatch
        let splitter = app.splitters.firstMatch
        XCTAssertTrue(
            splitter.waitForExistence(timeout: 5),
            "The inspector column exposed no splitter to drag")
        func columnWidth() -> CGFloat {
            window.frame.maxX - splitter.frame.midX
        }

        let opened = columnWidth()
        XCTAssertEqual(
            opened, 360, accuracy: 6,
            "Inspector opened at ~\(Int(opened))pt. Expected the declared 360pt ideal; "
            + "~270pt means .inspectorColumnWidth stopped reaching the inspector host, "
            + "which also leaves the seam with no range to drag between.")

        // The seam must sit inside the declared envelope, not against the
        // window edge — a column pinned at a framework default would still
        // expose a splitter, so existence alone is not enough.
        XCTAssertGreaterThan(
            splitter.frame.midX, window.frame.minX,
            "The inspector seam is not inside the window")
        XCTAssertLessThanOrEqual(opened, 700, "The column overran its declared maximum")
        XCTAssertGreaterThanOrEqual(opened, 280, "The column undercut its declared minimum")
    }
}
