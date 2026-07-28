import AppKit
import CoreGraphics
import PDFKit
import XCTest

@MainActor
class VellumUITestCase: XCTestCase {
    private(set) var storageRoot: URL!
    private var applications: [XCUIApplication] = []

    // XCTest declares `setUpWithError`/`tearDownWithError` as nonisolated, so an
    // override cannot carry this class's `@MainActor`. XCTest does run them on
    // the main thread for a synchronous test case (that is what lets XCUITest
    // and AppKit work at all), so recover the isolation explicitly rather than
    // scattering `nonisolated(unsafe)` over the fixture state.
    override func setUpWithError() throws {
        try MainActor.assumeIsolated {
            continueAfterFailure = false
            storageRoot = FileManager.default.temporaryDirectory
                .appendingPathComponent("VellumUITests", isDirectory: true)
                .appendingPathComponent(
                    "\(String(describing: type(of: self))).\(name)", isDirectory: true)
            try? FileManager.default.removeItem(at: storageRoot)
            try FileManager.default.createDirectory(
                at: storageRoot, withIntermediateDirectories: true)
        }
    }

    override func tearDownWithError() throws {
        MainActor.assumeIsolated {
            for application in applications {
                application.terminate()
            }
            applications.removeAll()
            try? FileManager.default.removeItem(at: storageRoot)
        }
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
