#if os(iOS)
import PDFKit
import Testing
import UIKit

@testable import Vellum

// The half of phone fit-width reading that `PdfZoomPolicyTests` cannot reach:
// what a REAL `PDFView` does once the policy is applied to it (issue #152,
// spec #150).
//
// `PdfZoomPolicyTests` pins the arithmetic — given a page width and a viewport
// width, here is the scale. That leaves two claims resting on PDFKit itself and
// therefore unverified by arithmetic alone:
//
//   * that the page drawn at the fit scale really does span the viewport, i.e.
//     that `horizontalInset` (currently just `pageBreakMargins`) names ALL the
//     horizontal padding PDFKit adds. If PDFKit inset pages further, the fit
//     would leave the page wider than the screen and horizontally scrollable
//     at the floor, and no policy test would notice;
//   * that `VellumPDFView` applies the policy at the right moments — on the
//     first layout, on a mode change, and never from a background tab.
//
// These drive an off-screen `VellumPDFView` directly rather than through
// SwiftUI: the representable's job is to hand the view a document, a mode and
// an `isActive` flag, so doing exactly that is a faithful stand-in and needs no
// window, no shell and no simulator interaction.

// MARK: - Fixtures

private let letterWidth = 612.0
private let letterHeight = 792.0
/// iPhone 15/16/17-class portrait width, the geometry this phase exists for.
private let phoneViewport = 390.0

/// A one-page US Letter PDF, rendered in memory. A synthesized document keeps
/// the geometry exact — the assertions below are about a 612pt page fitting a
/// 390pt viewport, and a fixture file could quietly not be Letter-sized.
private func letterDocument(pages: Int = 1) -> PDFDocument {
    let bounds = CGRect(x: 0, y: 0, width: letterWidth, height: letterHeight)
    let data = UIGraphicsPDFRenderer(bounds: bounds).pdfData { context in
        for page in 0..<pages {
            context.beginPage()
            UIColor.black.setFill()
            UIRectFill(CGRect(x: 40, y: 40 + page, width: 200, height: 20))
        }
    }
    return PDFDocument(data: data)!
}

/// A `VellumPDFView` configured exactly as `PdfKitView_iOS.makeUIView` does,
/// then laid out at `viewport` × 844 holding `document`.
///
/// The zero starting frame is not incidental: `makeUIView` builds the view
/// before SwiftUI has sized it, so the document and the persisted scale are
/// both assigned while bounds are still empty and the FIRST LAYOUT is what
/// fits. Building it pre-sized here would let the fit happen mid-configuration
/// and then be overwritten, which is not the order the app runs in.
///
/// `persistedScale` stands in for the `app.zoom` the representable pushes in
/// after the document — the scale a tab carries over from another device.
@MainActor
private func makeViewer(
    mode: PdfZoomMode,
    document: PDFDocument,
    viewport: Double = phoneViewport,
    persistedScale: Double = 1.0,
    isActive: Bool = true
) -> VellumPDFView {
    let view = VellumPDFView(frame: .zero)
    view.displayMode = .singlePageContinuous
    view.displayDirection = .vertical
    view.autoScales = false
    view.displaysPageBreaks = true
    view.pageBreakMargins = UIEdgeInsets(top: 6, left: 0, bottom: 6, right: 0)
    view.absoluteScaleRange = AppStore.minZoom...AppStore.maxZoom
    view.minScaleFactor = CGFloat(AppStore.minZoom)
    view.maxScaleFactor = CGFloat(AppStore.maxZoom)
    view.isActive = isActive
    view.zoomMode = mode
    view.document = document
    view.scaleFactor = CGFloat(persistedScale)
    layOut(view, width: viewport)
    return view
}

/// One layout pass at `width`, the way UIKit runs one after a bounds change
/// (the first sizing, a rotation, a split-view resize).
@MainActor
private func layOut(_ view: VellumPDFView, width: Double) {
    view.frame = CGRect(x: 0, y: 0, width: width, height: 844)
    view.setNeedsLayout()
    view.layoutIfNeeded()
}

/// The width of page one AS DRAWN, in view coordinates — the number the reader
/// actually sees, PDFKit's own insets and all.
@MainActor
private func drawnPageWidth(of view: VellumPDFView) throws -> Double {
    let page = try #require(view.document?.page(at: 0))
    return Double(view.convert(page.bounds(for: view.displayBox), from: page).width)
}

// MARK: - Fit-width against a real PDFView

@MainActor
@Suite("PDFView fit-width")
struct PdfKitFitWidthTests {
    @Test("A letter page opens spanning the phone viewport")
    func fitWidthSpansTheViewport() throws {
        let view = makeViewer(mode: .fitWidth, document: letterDocument())
        #expect(abs(Double(view.scaleFactor) - phoneViewport / letterWidth) < 0.001)
        // The claim the arithmetic cannot make: nothing PDFKit adds around the
        // page eats into the width. A failure here means `horizontalInset` in
        // `applyZoomPolicy` is missing a term, not that the policy is wrong.
        let drawn = try drawnPageWidth(of: view)
        #expect(abs(drawn - phoneViewport) < 1.0)
    }

    @Test("The persisted zoom from a roomier device does not survive the fit")
    func persistedZoomIsIgnoredWhenFitting() {
        let view = makeViewer(
            mode: .fitWidth, document: letterDocument(), persistedScale: 1.0)
        #expect(Double(view.scaleFactor) < 1.0)
    }

    @Test("Zooming out cannot leave the page narrower than the screen")
    func theFitScaleIsTheFloor() throws {
        let view = makeViewer(mode: .fitWidth, document: letterDocument())
        let fit = Double(view.scaleFactor)
        // What a pinch-out past the floor asks for; PDFKit clamps to
        // minScaleFactor, which fit-width raised to the fit scale.
        view.scaleFactor = CGFloat(AppStore.minZoom)
        #expect(abs(Double(view.scaleFactor) - fit) < 0.001)
        let drawn = try drawnPageWidth(of: view)
        #expect(abs(drawn - phoneViewport) < 1.0)
    }

    @Test("Rotating a fitted reader re-fits to the new width")
    func rotationRefitsAReaderAtTheFitWidth() throws {
        let view = makeViewer(mode: .fitWidth, document: letterDocument())
        layOut(view, width: 844)
        #expect(abs(Double(view.scaleFactor) - 844 / letterWidth) < 0.001)
        let drawn = try drawnPageWidth(of: view)
        #expect(abs(drawn - 844) < 1.0)
    }

    @Test("Rotating a reader who had zoomed in keeps their magnification")
    func rotationKeepsAZoomedInReadersScale() {
        let view = makeViewer(mode: .fitWidth, document: letterDocument())
        view.scaleFactor = 2.0
        layOut(view, width: 844)
        #expect(abs(Double(view.scaleFactor) - 2.0) < 0.001)
    }
}

// MARK: - Mode changes and background tabs

@MainActor
@Suite("PDFView zoom mode")
struct PdfKitZoomModeTests {
    @Test("Adopting a tab into the phone reader re-fits its absolute scale")
    func switchingIntoFitWidthRefits() throws {
        // A tab read at 200% under the iPad's absolute zoom, then moved to a
        // shell that fits — the retained-view adoption path in `makeUIView`,
        // reduced to the one assignment `updateUIView` makes for it.
        let view = makeViewer(
            mode: .free, document: letterDocument(), persistedScale: 2.0)
        #expect(abs(Double(view.scaleFactor) - 2.0) < 0.001)

        view.zoomMode = .fitWidth
        #expect(abs(Double(view.scaleFactor) - phoneViewport / letterWidth) < 0.001)
        let drawn = try drawnPageWidth(of: view)
        #expect(abs(drawn - phoneViewport) < 1.0)
    }

    @Test("Leaving fit-width restores the app-wide floor and keeps the scale")
    func switchingOutOfFitWidthKeepsTheScale() {
        let view = makeViewer(mode: .fitWidth, document: letterDocument())
        view.scaleFactor = 1.5
        view.zoomMode = .free
        #expect(abs(Double(view.scaleFactor) - 1.5) < 0.001)
        #expect(abs(Double(view.minScaleFactor) - AppStore.minZoom) < 0.001)
    }

    @Test("A background tab never moves its own scale")
    func inactiveMountsDoNotFit() {
        // The hazard this guards: PDFKit answers a scale assignment with
        // .PDFViewScaleChanged, whose observer writes the new scale into the
        // PANE-WIDE store — so a background tab fitting itself would drag the
        // visible tab down with it.
        let view = makeViewer(
            mode: .fitWidth, document: letterDocument(), persistedScale: 1.5,
            isActive: false)
        #expect(abs(Double(view.scaleFactor) - 1.5) < 0.001)
        layOut(view, width: 844)
        #expect(abs(Double(view.scaleFactor) - 1.5) < 0.001)
    }

    @Test("A background tab fits when it becomes the active one")
    func becomingActiveFits() {
        let view = makeViewer(
            mode: .fitWidth, document: letterDocument(), persistedScale: 1.5,
            isActive: false)
        view.isActive = true
        #expect(abs(Double(view.scaleFactor) - phoneViewport / letterWidth) < 0.001)
    }

    @Test("The iPad's absolute zoom is untouched by any of this")
    func freeModeLeavesEverythingAlone() {
        let view = makeViewer(
            mode: .free, document: letterDocument(), viewport: 1024,
            persistedScale: 1.0)
        #expect(abs(Double(view.scaleFactor) - 1.0) < 0.001)
        #expect(abs(Double(view.minScaleFactor) - AppStore.minZoom) < 0.001)
        #expect(abs(Double(view.maxScaleFactor) - AppStore.maxZoom) < 0.001)
        // Rotation, a split-view resize: none of it moves an absolute scale.
        layOut(view, width: 500)
        #expect(abs(Double(view.scaleFactor) - 1.0) < 0.001)
    }
}
#endif
