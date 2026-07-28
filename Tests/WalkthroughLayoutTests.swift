import AppKit
import SwiftUI
import XCTest

@testable import Vellum

// Layout safety net for the walkthrough sheet.
//
// The sheet sizes itself to its tallest page and scrolls if it ever cannot, but
// both of those are easy to undo by accident — pinning the frame back to a
// constant, or adding copy that pushes the tallest page past the maxHeight
// backstop. The invariant that actually matters to a reader is simply that no
// page's content is taller than the space the sheet gives it, because anything
// that does not fit is silently cut off rather than announced.
//
// Both sides are measured for real, off-screen: an NSHostingView with no window
// is never visible and never takes focus, so this runs headless. Nothing here
// re-derives a height from padding and font constants — an earlier version of
// this file mirrored a dozen of them, and the moment the title bar gained a
// close button the mirror was two points wrong and the test failed pointing at
// the copy rather than at the chrome. The sheet now names its own geometry
// (`WalkthroughSheet.chromeHeight` and friends) and the page body is a real
// view (`WalkthroughPageBody`) that can be hosted directly, so there is exactly
// one definition of every number involved.
@MainActor
final class WalkthroughLayoutTests: XCTestCase {
    /// Hosting the real sheet runs its `onAppear`, which calls
    /// `WalkthroughSettings.markSeen()`. The test host shares UserDefaults with
    /// the real app, so restore whatever the developer running the suite had —
    /// otherwise measuring layout would quietly consume their first run.
    private var priorSeen: Any?

    // The async overrides, not the plain ones: `setUp()`/`tearDown()` are
    // nonisolated, so touching a property of this @MainActor class from them
    // warns under strict concurrency. The async pair inherits the class's
    // isolation.
    override func setUp() async throws {
        try await super.setUp()
        priorSeen = UserDefaults.standard.object(forKey: WalkthroughSettings.seenKey)
    }

    override func tearDown() async throws {
        if let priorSeen {
            UserDefaults.standard.set(priorSeen, forKey: WalkthroughSettings.seenKey)
        } else {
            UserDefaults.standard.removeObject(forKey: WalkthroughSettings.seenKey)
        }
        try await super.tearDown()
    }

    // MARK: - Off-screen measurement

    /// Horizontal space a page body is laid out in. The body spans the sheet's
    /// full width; its own 24pt side padding is inside the view being measured.
    private var pageWidth: CGFloat { WalkthroughSheet.sheetWidth }

    /// The height the real sheet resolves to, laid out by SwiftUI itself.
    private func measuredSheetHeight() -> CGFloat {
        let host = NSHostingView(
            rootView: WalkthroughSheet()
                .environment(\.palette, .light)
                .tint(ThemePalette.light.primary))
        return host.fittingSize.height
    }

    /// Vertical space the sheet actually hands the page body.
    private func availableHeight() -> CGFloat {
        measuredSheetHeight() - WalkthroughSheet.chromeHeight
    }

    /// Height one page's real content needs at the sheet's width, wrapped by
    /// SwiftUI rather than approximated.
    private func requiredHeight(of page: WalkthroughPage) -> CGFloat {
        let host = NSHostingView(
            rootView: WalkthroughPageBody(page: page)
                .environment(\.palette, .light)
                .tint(ThemePalette.light.primary)
                .frame(width: pageWidth))
        return host.fittingSize.height
    }

    private func tallestPage() -> (id: String, height: CGFloat) {
        let measured = WalkthroughPage.all.map { (id: $0.id, height: requiredHeight(of: $0)) }
        return measured.max { $0.height < $1.height } ?? (id: "", height: 0)
    }

    // MARK: - Tests

    /// The invariant that matters: nothing a reader is shown gets cut off.
    func testNoPageIsClipped() {
        let available = availableHeight()
        for page in WalkthroughPage.all {
            let required = requiredHeight(of: page)
            XCTAssertLessThanOrEqual(
                required, available,
                """
                Walkthrough page "\(page.id)" needs \(Int(required))pt but the sheet gives its \
                page area only \(Int(available))pt, so the overflow is clipped. The sheet is \
                supposed to size itself to its tallest page — check that WalkthroughSheet's \
                frame has not been pinned back to a constant, and that the tallest page still \
                fits under the \(Int(WalkthroughSheet.maxSheetHeight))pt backstop.
                """)
        }
    }

    /// The sheet is expected to derive its height from its content. If someone
    /// pins it to a constant again, this fails as soon as the constant and the
    /// copy disagree — which is the state the original fixed 460pt frame was in.
    func testSheetHeightTracksTheTallestPage() {
        let tallest = tallestPage()
        let expected = tallest.height + WalkthroughSheet.chromeHeight
        let measured = measuredSheetHeight()

        XCTAssertEqual(
            measured, expected, accuracy: 1,
            """
            The sheet resolved to \(Int(measured))pt but its tallest page ("\(tallest.id)", \
            \(Int(tallest.height))pt) plus \(Int(WalkthroughSheet.chromeHeight))pt of chrome \
            wants \(Int(expected))pt. The sheet should size to its content, not to a constant.
            """)
    }

    /// Today's copy must fit without the scrolling backstop kicking in — the
    /// scroll exists for large system fonts and long translations, not as the
    /// normal reading experience.
    func testTallestPageFitsUnderTheBackstopWithoutScrolling() {
        let tallest = tallestPage()
        XCTAssertLessThan(
            tallest.height + WalkthroughSheet.chromeHeight, WalkthroughSheet.maxSheetHeight,
            """
            The tallest page ("\(tallest.id)") plus chrome now needs \
            \(Int(tallest.height + WalkthroughSheet.chromeHeight))pt, at or past the \
            \(Int(WalkthroughSheet.maxSheetHeight))pt backstop, so the walkthrough would open \
            already scrolling. Shorten the copy or raise the backstop deliberately.
            """)
    }

    /// The chrome bars are pinned, not intrinsically sized, so the space left
    /// for a page is exactly derivable. If someone swaps a `.frame(height:)`
    /// back for padding, the page area silently changes size and the two tests
    /// above start failing for a reason that points at the wrong file.
    func testChromeHeightIsTheSheetMinusItsTallestPage() {
        let tallest = tallestPage()
        XCTAssertEqual(
            measuredSheetHeight() - tallest.height,
            WalkthroughSheet.chromeHeight,
            accuracy: 1,
            "the title bar and footer no longer measure their declared heights")
    }
}
