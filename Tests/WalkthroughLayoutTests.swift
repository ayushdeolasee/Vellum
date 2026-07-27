import AppKit
import SwiftUI
import XCTest

@testable import Vellum

// The walkthrough sheet is a FIXED 620x460 box whose page area is `.clipped()`,
// so copy that grows by one wrapped line does not scroll, does not resize the
// sheet, and does not warn — it silently loses its last bullet off the bottom
// edge. Nothing else in the suite would catch that.
//
// These tests measure the real wrapped height of each page's text off-screen
// (NSHostingView in no window; never visible, never takes focus) and check it
// against the space the sheet actually gives the page. The layout constants
// below are mirrored from WalkthroughSheet — if the sheet's paddings, fonts or
// frame change, change them here too.
@MainActor
final class WalkthroughLayoutTests: XCTestCase {
    // MARK: - Mirrored from WalkthroughSheet

    private let sheetWidth: CGFloat = 620
    private let sheetHeight: CGFloat = 460
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

    /// Title bar + two dividers + footer, i.e. everything the page body does not
    /// get. These are not guesses: each piece was hosted off-screen on its own
    /// and measured at 44pt (title bar) and 50pt (footer) at the sheet's 620pt
    /// width, leaving the page area 364pt of the 460pt sheet.
    ///
    /// That margin is thin on purpose and worth knowing about: the Storage page
    /// currently measures ~361pt, so the sheet has roughly 3pt of slack. One
    /// extra wrapped line of copy anywhere on that page overflows, which is
    /// exactly the regression these tests exist to catch.
    private let chromeHeight: CGFloat = 44 + 2 + 50

    private var availableHeight: CGFloat { sheetHeight - chromeHeight }
    private var contentWidth: CGFloat { sheetWidth - horizontalPadding * 2 }

    // MARK: - Off-screen measurement

    /// Wrapped height of a `Text` at a fixed width, laid out by SwiftUI itself
    /// rather than by a hand-rolled TextKit approximation.
    private func height(of string: String, fontSize: CGFloat, width: CGFloat) -> CGFloat {
        let view = Text(string)
            .font(.system(size: fontSize))
            .lineSpacing(lineSpacing)
            .fixedSize(horizontal: false, vertical: true)
            .frame(width: width, alignment: .leading)
        let host = NSHostingView(rootView: view)
        // The root view is already pinned to `width`, so fittingSize resolves to
        // the natural wrapped height at exactly that width.
        return host.fittingSize.height
    }

    /// Width a Keycap occupies: 11pt monospaced glyphs + 6pt padding a side.
    private func keycapWidth(_ keys: String) -> CGFloat {
        let view = Text(keys).font(.system(size: 11, design: .monospaced))
        let host = NSHostingView(rootView: view)
        return host.fittingSize.width + 12
    }

    private func measuredHeight(of page: WalkthroughPage) -> CGFloat {
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

    // MARK: - Tests

    func testEveryPageFitsTheFixedSheetHeight() {
        for page in WalkthroughPage.all {
            let measured = measuredHeight(of: page)
            XCTAssertLessThanOrEqual(
                measured, availableHeight,
                """
                Walkthrough page "\(page.id)" needs \(Int(measured))pt but the sheet only \
                gives the page area \(Int(availableHeight))pt. The sheet is a fixed \
                \(Int(sheetWidth))x\(Int(sheetHeight)) frame and the page area is clipped, so the \
                overflow would be invisibly cut off rather than scrolled. Shorten the copy or \
                raise WalkthroughSheet's frame height (and this file's constants).
                """)
        }
    }

    func testStoragePageIsStillTheTallestPage() {
        // WalkthroughSheet's frame comment justifies 460pt by saying the height
        // is measured against the Storage page. If some other page overtakes
        // it, that reasoning — and the slack it assumes — no longer holds.
        let heights = WalkthroughPage.all.map { ($0.id, measuredHeight(of: $0)) }
        let tallest = heights.max { $0.1 < $1.1 }
        XCTAssertEqual(
            tallest?.0, "storage",
            "the tallest page is now \(tallest?.0 ?? "?"), not storage: \(heights.map { "\($0.0)=\(Int($0.1))" })")
    }
}
