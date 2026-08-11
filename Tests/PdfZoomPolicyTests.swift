import Foundation
import Testing

@testable import Vellum

// Behaviour contract for phone fit-width reading (issue #152, spec #150).
//
// `PdfZoomPolicy` is the whole of that feature that can be stated as
// arithmetic: the viewer only feeds it a page width and a viewport width and
// applies the floor / ceiling / scale it hands back. Everything asserted here
// is therefore a claim about what a reader sees — the page spans the screen
// when a document opens, pinching out cannot shrink it below that, and the iPad
// is left alone — rather than a claim about PDFKit.
//
// The numbers: US Letter is 612 × 792pt, and the 390pt-class viewport is an
// iPhone 15/16/17 in portrait, which is the geometry this phase exists for.

// MARK: - Fixtures

/// The app-wide zoom range (`AppStore.minZoom ... AppStore.maxZoom`), restated
/// as plain numbers so a failure names the value that actually changed rather
/// than pointing back at the store it was read from. `freeMatchesTheStoresZoomRange`
/// below is what keeps the restatement honest.
private let absoluteMinimum = 0.25
private let absoluteMaximum = 4.0

private let letterWidth = 612.0
private let phoneViewport = 390.0
/// The same phone rotated (iPhone 15/16/17 landscape).
private let phoneLandscapeViewport = 844.0

private func fitPolicy(
    pageWidth: Double = letterWidth,
    viewportWidth: Double = phoneViewport,
    horizontalInset: Double = 0
) -> PdfZoomPolicy {
    PdfZoomPolicy.fitWidth(
        pageWidth: pageWidth,
        viewportWidth: viewportWidth,
        horizontalInset: horizontalInset,
        minimumScale: absoluteMinimum,
        maximumScale: absoluteMaximum)
}

private let freePolicy = PdfZoomPolicy.free(
    minimumScale: absoluteMinimum, maximumScale: absoluteMaximum)

// MARK: - Fit-width scale

@Suite("PDF fit-width scale")
struct PdfFitWidthScaleTests {
    @Test("A letter page fills a phone-width viewport exactly")
    func letterPageFillsPhoneViewport() throws {
        let fit = try #require(fitPolicy().fitWidthScale)
        #expect(abs(fit - phoneViewport / letterWidth) < 0.000_001)
        // The point of the whole exercise: the page drawn at this scale is
        // exactly as wide as the screen — not the 612pt (cropped by a third)
        // that an absolute 100% would give.
        #expect(abs(letterWidth * fit - phoneViewport) < 0.000_001)
    }

    @Test("Horizontal padding comes out of the width available to the page")
    func insetReducesTheFit() throws {
        let fit = try #require(fitPolicy(horizontalInset: 30).fitWidthScale)
        #expect(abs(letterWidth * fit - (phoneViewport - 30)) < 0.000_001)
        #expect(try fit < #require(fitPolicy().fitWidthScale))
    }

    @Test("A wider viewport fits at a larger scale")
    func widerViewportFitsLarger() throws {
        let portrait = try #require(fitPolicy().fitWidthScale)
        let landscape = try #require(
            fitPolicy(viewportWidth: phoneLandscapeViewport).fitWidthScale)
        #expect(landscape > portrait)
        #expect(abs(letterWidth * landscape - phoneLandscapeViewport) < 0.000_001)
    }

    @Test("A page too wide to fit at 25% still opens as wide as it legally can")
    func oversizePageStopsAtTheAbsoluteFloor() {
        // 4000pt across would want ~0.098; the app-wide floor wins.
        let policy = fitPolicy(pageWidth: 4000)
        #expect(policy.fitWidthScale == absoluteMinimum)
        #expect(policy.minimumScale == absoluteMinimum)
    }

    @Test("A page too narrow to ever span the viewport keeps normal zoom")
    func undersizePageFallsBackToAbsoluteZoom() {
        // A 50pt-wide page would need 7.8×. Pinning the floor to the 400%
        // ceiling would leave the reader unable to zoom at all, so the policy
        // declines to fit rather than locking the viewer.
        let policy = fitPolicy(pageWidth: 50)
        #expect(policy.fitWidthScale == nil)
        #expect(policy == freePolicy)
    }

    /// One shape of geometry that cannot be fitted against. Named rather than
    /// tupled so a failure reads as the situation it stands for.
    struct DegenerateGeometry: Sendable, CustomTestStringConvertible {
        let what: String
        let pageWidth: Double
        let viewportWidth: Double
        let horizontalInset: Double

        var testDescription: String { what }
    }

    @Test(
        "Degenerate geometry falls back to absolute zoom rather than inventing a scale",
        arguments: [
            DegenerateGeometry(
                what: "no page yet", pageWidth: 0, viewportWidth: phoneViewport,
                horizontalInset: 0),
            DegenerateGeometry(
                what: "pre-layout viewport (bounds are still zero)",
                pageWidth: letterWidth, viewportWidth: 0, horizontalInset: 0),
            DegenerateGeometry(
                what: "padding eats the whole viewport", pageWidth: letterWidth,
                viewportWidth: 30, horizontalInset: 30),
            DegenerateGeometry(
                what: "page width is NaN", pageWidth: .nan,
                viewportWidth: phoneViewport, horizontalInset: 0),
            DegenerateGeometry(
                what: "viewport width is infinite", pageWidth: letterWidth,
                viewportWidth: .infinity, horizontalInset: 0),
        ])
    func degenerateGeometryFallsBack(_ geometry: DegenerateGeometry) {
        let policy = fitPolicy(
            pageWidth: geometry.pageWidth,
            viewportWidth: geometry.viewportWidth,
            horizontalInset: geometry.horizontalInset)
        #expect(policy == freePolicy)
    }
}

// MARK: - The zoom floor

@Suite("PDF zoom floor")
struct PdfZoomFloorTests {
    @Test("The floor IS the fit scale")
    func floorIsTheFitScale() {
        let policy = fitPolicy()
        #expect(policy.minimumScale == policy.fitWidthScale)
        #expect(policy.minimumScale > absoluteMinimum)
    }

    @Test("Zooming out below the fit scale is refused")
    func zoomingOutBelowFitIsRefused() throws {
        let policy = fitPolicy()
        let fit = try #require(policy.fitWidthScale)
        #expect(policy.clamped(absoluteMinimum) == fit)
        #expect(policy.clamped(fit - 0.2) == fit)
        #expect(policy.clamped(0) == fit)
    }

    @Test("Zooming in past the fit scale is untouched, up to the ceiling")
    func zoomingInIsUntouched() {
        let policy = fitPolicy()
        #expect(policy.clamped(1.0) == 1.0)
        #expect(policy.clamped(2.5) == 2.5)
        #expect(policy.clamped(absoluteMaximum) == absoluteMaximum)
        #expect(policy.clamped(99) == absoluteMaximum)
    }

    @Test("A non-finite scale resolves to the floor rather than propagating")
    func nonFiniteScaleResolvesToTheFloor() {
        let policy = fitPolicy()
        #expect(policy.clamped(.nan) == policy.minimumScale)
    }
}

// MARK: - Opening a document

@Suite("PDF opening scale")
struct PdfOpeningScaleTests {
    @Test("Fitting ignores the zoom the tab persisted", arguments: [0.25, 0.5, 1.0, 4.0])
    func fitIgnoresPersistedZoom(_ persisted: Double) {
        let policy = fitPolicy()
        #expect(policy.openingScale(persisted: persisted) == policy.fitWidthScale)
    }

    @Test("Absolute zoom opens at the persisted value, clamped")
    func freeHonoursPersistedZoom() {
        #expect(freePolicy.openingScale(persisted: 1.0) == 1.0)
        #expect(freePolicy.openingScale(persisted: 2.5) == 2.5)
        #expect(freePolicy.openingScale(persisted: 0.1) == absoluteMinimum)
        #expect(freePolicy.openingScale(persisted: 99) == absoluteMaximum)
    }

    @Test("A phone-opened document is never wider than the screen either")
    func openingScaleNeverOverflowsTheViewport() {
        let opening = fitPolicy().openingScale(persisted: absoluteMaximum)
        #expect(letterWidth * opening <= phoneViewport + 0.000_001)
    }
}

// MARK: - Viewport changes

@Suite("PDF scale after a viewport change")
struct PdfAdjustedScaleTests {
    @Test("A reader sitting at fit width follows the new fit width")
    func fitWidthReaderFollowsTheNewFit() throws {
        let portrait = fitPolicy()
        let landscape = fitPolicy(viewportWidth: phoneLandscapeViewport)
        let wasAt = try #require(portrait.fitWidthScale)
        #expect(
            landscape.adjustedScale(current: wasAt, previousFitWidth: wasAt)
                == landscape.fitWidthScale)
    }

    @Test("Being at fit width is judged with tolerance, not bit equality")
    func fitFollowingToleratesRoundTripDrift() throws {
        let portrait = fitPolicy()
        let landscape = fitPolicy(viewportWidth: phoneLandscapeViewport)
        let wasAt = try #require(portrait.fitWidthScale)
        // PDFKit reports back the scale it actually applied, and the value also
        // round-trips through `AppStore.zoom`.
        let drifted = wasAt + PdfZoomPolicy.scaleTolerance / 2
        #expect(
            landscape.adjustedScale(current: drifted, previousFitWidth: wasAt)
                == landscape.fitWidthScale)
    }

    @Test("A reader who zoomed in keeps their magnification")
    func zoomedInReaderKeepsTheirScale() throws {
        let portrait = fitPolicy()
        let landscape = fitPolicy(viewportWidth: phoneLandscapeViewport)
        let wasAt = try #require(portrait.fitWidthScale)
        #expect(landscape.adjustedScale(current: 2.0, previousFitWidth: wasAt) == 2.0)
    }

    @Test("A scale left under the new floor is lifted onto it")
    func staleScaleIsLiftedOntoTheNewFloor() throws {
        let portrait = fitPolicy()
        let landscape = fitPolicy(viewportWidth: phoneLandscapeViewport)
        // 0.3 is a zoom carried in from a roomier viewport (an iPad tab, a
        // rotation) — legal app-wide, below what this screen allows.
        #expect(portrait.adjustedScale(current: 0.3, previousFitWidth: nil)
            == portrait.minimumScale)
        // A scale already above the floor is left exactly where it is.
        let readAt = try #require(landscape.fitWidthScale)
        #expect(landscape.adjustedScale(current: readAt, previousFitWidth: nil) == readAt)
    }

    @Test("Absolute zoom is only ever clamped, never re-fitted")
    func freeModeOnlyClamps() {
        #expect(freePolicy.adjustedScale(current: 1.0, previousFitWidth: 0.637) == 1.0)
        #expect(freePolicy.adjustedScale(current: 0.3, previousFitWidth: nil) == 0.3)
        #expect(
            freePolicy.adjustedScale(current: 0.1, previousFitWidth: nil) == absoluteMinimum)
    }
}

// MARK: - The iPad/mac path

@Suite("PDF absolute-zoom mode is the untouched path")
struct PdfFreeModeTests {
    /// The mechanism by which iPad and macOS are unaffected: `.free` resolves,
    /// for ANY geometry, to precisely the bounds those viewers already install
    /// on their `PDFView` and to "stay where you are".
    @Test("Resolving .free ignores geometry entirely", arguments: [0.0, 200.0, letterWidth])
    func freeIgnoresGeometry(_ pageWidth: Double) {
        let policy = PdfZoomPolicy.resolve(
            mode: .free,
            pageWidth: pageWidth,
            viewportWidth: phoneViewport,
            minimumScale: absoluteMinimum,
            maximumScale: absoluteMaximum)
        #expect(policy == freePolicy)
        #expect(policy.minimumScale == absoluteMinimum)
        #expect(policy.maximumScale == absoluteMaximum)
        #expect(policy.fitWidthScale == nil)
    }

    @MainActor
    @Test("The app-wide bounds the viewers install are the ones .free resolves to")
    func freeMatchesTheStoresZoomRange() {
        #expect(AppStore.minZoom == absoluteMinimum)
        #expect(AppStore.maxZoom == absoluteMaximum)
    }

    @Test("Resolving .fitWidth is the fit-width constructor")
    func resolveRoutesFitWidth() {
        let resolved = PdfZoomPolicy.resolve(
            mode: .fitWidth,
            pageWidth: letterWidth,
            viewportWidth: phoneViewport,
            minimumScale: absoluteMinimum,
            maximumScale: absoluteMaximum)
        #expect(resolved == fitPolicy())
    }
}
