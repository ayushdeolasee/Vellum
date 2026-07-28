import AppKit
import CoreGraphics
import PDFKit
import XCTest

@MainActor
class VellumUITestCase: XCTestCase {
    // XCTest's `setUpWithError`/`tearDownWithError` are nonisolated, so an
    // override cannot inherit this class's `@MainActor` — but the class
    // annotation is what keeps the ~90 XCUI calls in the tests themselves
    // isolation-clean. Keep the fixture state reachable from both by declaring
    // it nonisolated; only XCTest touches it, one test method at a time.
    nonisolated(unsafe) private(set) var storageRoot: URL!
    nonisolated(unsafe) private var applications: [XCUIApplication] = []

    nonisolated override func setUpWithError() throws {
        continueAfterFailure = false
        storageRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("VellumUITests", isDirectory: true)
            .appendingPathComponent(
                "\(String(describing: type(of: self))).\(name)", isDirectory: true)
        try? FileManager.default.removeItem(at: storageRoot)
        try FileManager.default.createDirectory(
            at: storageRoot, withIntermediateDirectories: true)
    }

    nonisolated override func tearDownWithError() throws {
        let launched = applications
        applications = []
        // XCTest runs teardown on the main thread for a synchronous test case,
        // which is what makes the XCUI calls above legal in the first place.
        MainActor.assumeIsolated {
            for application in launched {
                application.terminate()
            }
        }
        try? FileManager.default.removeItem(at: storageRoot)
    }

    func makeApp(
        opening document: URL? = nil,
        corruptRestoration: Bool = false
    ) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = [
            "--ui-testing",
            "--ui-test-reset-state",
            "--ui-test-storage-root", storageRoot.path,
            "-ApplePersistenceIgnoreState", "YES",
        ]
        if let document {
            app.launchArguments += ["--ui-test-open-document", document.path]
        }
        if corruptRestoration {
            app.launchArguments.append("--ui-test-corrupt-restoration")
        }
        applications.append(app)
        return app
    }

    /// Creates a one-page PDF without relying on a developer-local fixture.
    func makePDF(named name: String = "Vellum UI Test.pdf") throws -> URL {
        let url = storageRoot.appendingPathComponent(name)
        var mediaBox = CGRect(x: 0, y: 0, width: 612, height: 792)
        guard let context = CGContext(url as CFURL, mediaBox: &mediaBox, nil) else {
            throw FixtureError.couldNotCreatePDF
        }
        context.beginPDFPage(nil)
        context.setFillColor(NSColor.white.cgColor)
        context.fill(mediaBox)
        context.endPDFPage()
        context.closePDF()
        guard PDFDocument(url: url)?.pageCount == 1 else {
            throw FixtureError.couldNotCreatePDF
        }
        return url
    }

    func waitForDocument(in app: XCUIApplication) {
        XCTAssertTrue(
            app.descendants(matching: .any)["toolbar.documentTitle"]
                .waitForExistence(timeout: 10),
            "The deterministic PDF did not open")
    }

    private enum FixtureError: Error {
        case couldNotCreatePDF
    }
}
