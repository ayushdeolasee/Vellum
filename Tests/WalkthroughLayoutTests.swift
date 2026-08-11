import SwiftUI
import UIKit
import XCTest

@testable import Vellum

// Layout safety net for the walkthrough sheet.
//
// The sheet sizes itself to its tallest page and scrolls if it ever cannot, but
// both of those are easy to undo by accident — pinning the frame back to a
// constant, or adding copy that pushes the tallest page past the maxHeight
// backstop. At the default text size every page should fit without scrolling;
// at accessibility sizes the sheet stays bounded and its page area scrolls.
//
// Both sides are measured for real, off-screen: a UIHostingController that is
// never added to a window is never visible and never takes focus, so this runs
// headless. `sizeThatFits(in:)` is the UIKit analogue of AppKit's
// `NSHostingView.fittingSize`, which is what main measures with. Nothing here
// re-derives a height from padding and font constants — an earlier version of
// this file mirrored a dozen of them, and the moment the title bar gained a
// close button the mirror was two points wrong and the test failed pointing at
// the copy rather than at the chrome. The sheet now names its minimum chrome
// geometry and the page body is a real
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
    private var pageWidth: CGFloat { WalkthroughSheet_iOS.sheetWidth }

    /// Ask SwiftUI for a view's intrinsic height at a fixed width. The
    /// unconstrained (`layoutFittingCompressedSize`) height is what makes this
    /// the intrinsic answer rather than a clamped one.
    private func measure(_ view: some View, width: CGFloat) -> CGFloat {
        let host = UIHostingController(rootView: view)
        host.view.frame = CGRect(x: 0, y: 0, width: width, height: .greatestFiniteMagnitude)
        return host.sizeThatFits(
            in: CGSize(width: width, height: UIView.layoutFittingCompressedSize.height)
        ).height
    }

    /// The height the real sheet resolves to, laid out by SwiftUI itself.
    private func measuredSheetHeight() -> CGFloat {
        measure(
            WalkthroughSheet_iOS()
                .environment(\.palette, .light)
                .tint(ThemePalette.light.primary)
                .dynamicTypeSize(.large),
            width: WalkthroughSheet_iOS.sheetWidth)
    }

    /// Vertical space available before the scrolling backstop is needed at the
    /// default text size. The chrome may grow at accessibility sizes; overflow
    /// then remains inside `pageContent`'s ScrollView.
    private func availableHeight() -> CGFloat {
        WalkthroughSheet_iOS.maxSheetHeight - minimumChromeHeight
    }

    private var minimumChromeHeight: CGFloat {
        WalkthroughSheet_iOS.minimumTitleBarHeight
            + WalkthroughSheet_iOS.minimumFooterHeight
            + WalkthroughSheet_iOS.dividerHeight * 2
    }

    /// Height one page's real content needs at the sheet's width, wrapped by
    /// SwiftUI rather than approximated.
    private func requiredHeight(
        of page: WalkthroughPage,
        width: CGFloat? = nil,
        dynamicTypeSize: DynamicTypeSize = .large
    ) -> CGFloat {
        let width = width ?? pageWidth
        return measure(
            WalkthroughPageBody(page: page)
                .environment(\.palette, .light)
                .tint(ThemePalette.light.primary)
                .dynamicTypeSize(dynamicTypeSize)
                .frame(width: width),
            width: width)
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
                fits under the \(Int(WalkthroughSheet_iOS.maxSheetHeight))pt backstop.
                """)
        }
    }

    /// The sheet is expected to derive its height from its content. If someone
    /// pins it to a constant again, this fails as soon as the constant and the
    /// copy disagree — which is the state the original fixed 460pt frame was in.
    func testSheetHeightTracksTheTallestPage() {
        let tallest = tallestPage()
        let expected = tallest.height + minimumChromeHeight
        let measured = measuredSheetHeight()

        XCTAssertEqual(
            measured, expected, accuracy: 1,
            """
            The sheet resolved to \(Int(measured))pt but its tallest page ("\(tallest.id)", \
            \(Int(tallest.height))pt) plus \(Int(minimumChromeHeight))pt of chrome \
            wants \(Int(expected))pt. The sheet should size to its content, not to a constant.
            """)
    }

    /// Today's copy must fit without the scrolling backstop kicking in — the
    /// scroll exists for large system fonts and long translations, not as the
    /// normal reading experience.
    func testTallestPageFitsUnderTheBackstopWithoutScrolling() {
        let tallest = tallestPage()
        XCTAssertLessThan(
            tallest.height + minimumChromeHeight, WalkthroughSheet_iOS.maxSheetHeight,
            """
            The tallest page ("\(tallest.id)") plus chrome now needs \
            \(Int(tallest.height + minimumChromeHeight))pt, at or past the \
            \(Int(WalkthroughSheet_iOS.maxSheetHeight))pt backstop, so the walkthrough would open \
            already scrolling. Shorten the copy or raise the backstop deliberately.
            """)
    }

    /// At the default text size both adaptive bars should settle at their named
    /// minimums. Accessibility sizes are allowed to grow them and are covered
    /// separately below.
    func testChromeHeightIsTheSheetMinusItsTallestPage() {
        let tallest = tallestPage()
        XCTAssertEqual(
            measuredSheetHeight() - tallest.height,
            minimumChromeHeight,
            accuracy: 1,
            "the title bar and footer no longer measure their declared heights")
    }

    /// A form sheet is full-width on iPhone. The walkthrough's reading-width
    /// cap must yield to that compact proposal or the footer's Done button is
    /// laid out hundreds of points beyond the trailing edge.
    func testSheetDoesNotOverflowPhoneWidth() {
        let phoneWidth: CGFloat = 368
        let host = UIHostingController(
            rootView: WalkthroughSheet_iOS()
                .environment(\.palette, .light)
                .tint(ThemePalette.light.primary))
        host.view.frame = CGRect(
            x: 0, y: 0, width: phoneWidth, height: WalkthroughSheet_iOS.maxSheetHeight)
        let measured = host.sizeThatFits(
            in: CGSize(width: phoneWidth, height: WalkthroughSheet_iOS.maxSheetHeight))

        XCTAssertLessThanOrEqual(
            measured.width,
            phoneWidth + 0.5,
            "the only allowed overage is one physical-pixel rounding step")
    }

    func testLargestAccessibilitySizeStaysInsideAPhoneAndScrollsItsPageArea() {
        let phoneSize = CGSize(width: 368, height: 640)
        let host = UIHostingController(
            rootView: WalkthroughSheet_iOS()
                .environment(\.palette, .light)
                .tint(ThemePalette.light.primary)
                .dynamicTypeSize(.accessibility5))
        host.view.frame = CGRect(origin: .zero, size: phoneSize)
        let measured = host.sizeThatFits(in: phoneSize)

        XCTAssertLessThanOrEqual(measured.width, phoneSize.width + 0.5)
        XCTAssertLessThanOrEqual(measured.height, phoneSize.height + 0.5)

        let page = WalkthroughPage.all[0]
        let normal = requiredHeight(of: page, width: phoneSize.width, dynamicTypeSize: .large)
        let accessible = requiredHeight(
            of: page, width: phoneSize.width, dynamicTypeSize: .accessibility5)
        XCTAssertGreaterThan(
            accessible, normal,
            "walkthrough copy is not responding to the user's Dynamic Type setting")
    }

    func testCompactLandscapeKeepsPersistentChromeInsideTheScreen() {
        let landscapeSize = CGSize(width: 720, height: 320)
        let host = UIHostingController(
            rootView: WalkthroughSheet_iOS()
                .environment(\.palette, .light)
                .environment(\.verticalSizeClass, .compact)
                .tint(ThemePalette.light.primary)
                .dynamicTypeSize(.large))
        host.view.frame = CGRect(origin: .zero, size: landscapeSize)

        let measured = host.sizeThatFits(in: landscapeSize)
        XCTAssertLessThanOrEqual(measured.width, landscapeSize.width + 0.5)
        XCTAssertLessThanOrEqual(measured.height, landscapeSize.height + 0.5)
    }

    func testEveryWalkthroughControlKeepsTheTouchTargetFloor() {
        XCTAssertGreaterThanOrEqual(WalkthroughSheet_iOS.controlSide, 44)
    }
}
