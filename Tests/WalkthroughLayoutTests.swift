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
// page's content is taller than the space the sheet gives it, because the page
// area clips: anything that does not fit is silently cut off rather than
// announced.
//
// So these tests measure both sides for real, off-screen (NSHostingView with no
// window — never visible, never takes focus): the sheet's own resolved height,
// and each page's naturally wrapped content height. They keep working if
// someone adds a bullet, because the sheet is expected to grow with it.
@MainActor
final class WalkthroughLayoutTests: XCTestCase {
    /// Hosting the real sheet runs its `onAppear`, which calls
    /// `WalkthroughSettings.markSeen()`. The test host shares UserDefaults with
    /// the real app, so restore whatever the developer running the suite had —
    /// otherwise measuring layout would quietly consume their first run.
    private var priorSeen: Any?

    override func setUp() {
        super.setUp()
        priorSeen = UserDefaults.standard.object(forKey: WalkthroughSettings.seenKey)
    }

    override func tearDown() {
        if let priorSeen {
            UserDefaults.standard.set(priorSeen, forKey: WalkthroughSettings.seenKey)
        } else {
            UserDefaults.standard.removeObject(forKey: WalkthroughSettings.seenKey)
        }
        super.tearDown()
    }

    // MARK: - Mirrored from WalkthroughSheet

    private let sheetWidth: CGFloat = 620
    /// The backstop on the sheet's frame. Past this the page area scrolls
    /// instead of growing.
    private let maxSheetHeight: CGFloat = 620
    private let horizontalPadding: CGFloat = 24
    private let topPadding: CGFloat = 22
    private let bottomPadding: CGFloat = 20
    private let blockSpacing: CGFloat = 18
    private let bulletSpacing: CGFloat = 12
    private let gutterWidth: CGFloat = 18
    private let hstackSpacing: CGFloat = 12
    private let heroHeight: CGFloat = 44
    private let bodyFontSize: CGFloat = 13
    private let footnoteFontSize: CGFloat = 12
    private let lineSpacing: CGFloat = 2

    /// Title bar + two dividers + footer — everything the page body does not
    /// get. Each piece was hosted on its own and measured at the sheet's 620pt
    /// width: 44pt title bar, 50pt footer, 1pt per divider.
    private let chromeHeight: CGFloat = 44 + 2 + 50

    private var contentWidth: CGFloat { sheetWidth - horizontalPadding * 2 }

    // MARK: - Off-screen measurement

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
        measuredSheetHeight() - chromeHeight
    }

    /// Wrapped height of a `Text` at a fixed width, laid out by SwiftUI rather
    /// than by a hand-rolled TextKit approximation.
    private func height(of string: String, fontSize: CGFloat, width: CGFloat) -> CGFloat {
        let view = Text(string)
            .font(.system(size: fontSize))
            .lineSpacing(lineSpacing)
            .fixedSize(horizontal: false, vertical: true)
            .frame(width: width, alignment: .leading)
        return NSHostingView(rootView: view).fittingSize.height
    }

    /// Width a Keycap occupies: 11pt monospaced glyphs + 6pt padding a side.
    private func keycapWidth(_ keys: String) -> CGFloat {
        let host = NSHostingView(rootView: Text(keys).font(.system(size: 11, design: .monospaced)))
        return host.fittingSize.width + 12
    }

    /// Height one page's content needs at the sheet's width.
    private func requiredHeight(of page: WalkthroughPage) -> CGFloat {
        var total = topPadding + bottomPadding

        // Hero row: the 44pt glass tile sets the floor; the title is one line.
        total += heroHeight
        total += blockSpacing

        total += height(of: page.summary, fontSize: bodyFontSize, width: contentWidth)
        total += blockSpacing

        for (offset, point) in page.points.enumerated() {
            if offset > 0 { total += bulletSpacing }
            var textWidth = contentWidth - gutterWidth - hstackSpacing
            if let shortcut = point.shortcut {
                // The keycap shares the line with the text, so it eats width.
                textWidth -= keycapWidth(shortcut) + hstackSpacing
            }
            total += height(of: point.text, fontSize: bodyFontSize, width: textWidth)
        }

        if let footnote = page.footnote {
            total += blockSpacing
            total += height(of: footnote, fontSize: footnoteFontSize, width: contentWidth)
        }

        return total
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
                fits under the \(Int(maxSheetHeight))pt backstop.
                """)
        }
    }

    /// The sheet is expected to derive its height from its content. If someone
    /// pins it to a constant again, this fails as soon as the constant and the
    /// copy disagree — which is the state the fixed 460pt frame was in.
    func testSheetHeightTracksTheTallestPage() {
        let tallest = tallestPage()
        let expected = tallest.height + chromeHeight
        let measured = measuredSheetHeight()

        XCTAssertEqual(
            measured, expected, accuracy: 12,
            """
            The sheet resolved to \(Int(measured))pt but its tallest page ("\(tallest.id)", \
            \(Int(tallest.height))pt) plus \(Int(chromeHeight))pt of chrome wants \
            \(Int(expected))pt. The sheet should size to its content, not to a constant.
            """)
    }

    /// Today's copy must fit without the scrolling backstop kicking in — the
    /// scroll exists for large system fonts and long translations, not as the
    /// normal reading experience.
    func testTallestPageFitsUnderTheBackstopWithoutScrolling() {
        let tallest = tallestPage()
        XCTAssertLessThan(
            tallest.height + chromeHeight, maxSheetHeight,
            """
            The tallest page ("\(tallest.id)") plus chrome now needs \
            \(Int(tallest.height + chromeHeight))pt, at or past the \(Int(maxSheetHeight))pt \
            backstop, so the walkthrough would open already scrolling. Shorten the copy or \
            raise the backstop deliberately.
            """)
    }
}
