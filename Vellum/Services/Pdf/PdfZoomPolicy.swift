import Foundation

// The arithmetic behind "open the page filling the viewport's width" and "never
// let the page end up narrower than the viewport" (issue #152, spec #150).
//
// This lives here, away from PDFKit and SwiftUI, for one reason: it is the only
// part of phone fit-width reading that can be pinned by a test. The viewer's
// job is reduced to feeding it two numbers (the page's displayed width and the
// viewport's width) and applying the three it hands back — a floor, a ceiling
// and a scale — so the policy itself never needs a simulator to verify.
//
// The iPad and macOS viewers pass `.free`, which resolves to exactly the bounds
// those viewers have always used (AppStore.minZoom ... AppStore.maxZoom) and to
// "keep whatever scale you already had". That equivalence is the mechanism by
// which the existing platforms stay untouched; it is asserted in
// `PdfZoomPolicyTests`.

/// How a viewer picks its scale.
enum PdfZoomMode: Equatable, Sendable {
    /// Absolute zoom: the scale is whatever the user (or the tab's persisted
    /// zoom) last asked for, bounded only by the app-wide 25%–400% range.
    /// The iPad and macOS behaviour.
    case free
    /// Fit-to-width reading: the document opens with the page spanning the
    /// viewport, and zooming out cannot take it back below that. What the
    /// compact (iPhone) shell asks for, where a 612pt page in a 390pt-class
    /// viewport at an absolute 100% would be cropped by a third.
    case fitWidth
}

/// The scale bounds and opening scale for one viewport, already resolved
/// against the app-wide zoom range.
struct PdfZoomPolicy: Equatable, Sendable {
    /// Lowest scale the viewer may reach — `PDFView.minScaleFactor`. Under
    /// `.fitWidth` this is the fit scale itself: that is the whole zoom floor.
    let minimumScale: Double
    /// Highest scale the viewer may reach — `PDFView.maxScaleFactor`. Fitting
    /// never touches the ceiling.
    let maximumScale: Double
    /// The scale at which the page spans the viewport, or nil when this policy
    /// does not fit (`.free`, or geometry too degenerate to fit against).
    let fitWidthScale: Double?

    /// How close two scales must be to count as "the same scale". PDFKit
    /// returns the scale it actually applied, which is not always bit-identical
    /// to the one it was handed, and the value additionally round-trips through
    /// `AppStore.zoom`. 0.5% is far below anything a reader can see and far
    /// above that noise.
    static let scaleTolerance = 0.005

    // MARK: - Construction

    /// The absolute-zoom policy: the app-wide range, no fitting.
    static func free(minimumScale: Double, maximumScale: Double) -> PdfZoomPolicy {
        PdfZoomPolicy(
            minimumScale: minimumScale, maximumScale: maximumScale, fitWidthScale: nil)
    }

    /// Fit `pageWidth` (in unzoomed points, as the page is *displayed* — the
    /// caller resolves page rotation) into `viewportWidth`, minus whatever
    /// horizontal padding the viewer adds around the page.
    ///
    /// Two degenerate shapes fall back to `.free` rather than inventing a
    /// scale, because both mean "there is nothing to fit against yet":
    ///
    ///   * a page or viewport of zero/negative/non-finite width — the viewer
    ///     asks before its first layout pass, when bounds are still zero;
    ///   * a page so narrow it cannot span the viewport even at the ceiling.
    ///     The invariant is unsatisfiable there at any legal scale, and pinning
    ///     the floor to 400% would take zooming away entirely, which is a worse
    ///     answer than admitting the page is small.
    static func fitWidth(
        pageWidth: Double,
        viewportWidth: Double,
        horizontalInset: Double = 0,
        minimumScale: Double,
        maximumScale: Double
    ) -> PdfZoomPolicy {
        let available = viewportWidth - horizontalInset
        guard pageWidth.isFinite, available.isFinite, pageWidth > 0, available > 0 else {
            return .free(minimumScale: minimumScale, maximumScale: maximumScale)
        }
        let raw = available / pageWidth
        guard raw <= maximumScale else {
            return .free(minimumScale: minimumScale, maximumScale: maximumScale)
        }
        // A page too WIDE to fit at 25% still fits as well as it can: the fit
        // scale is the floor, which here coincides with the absolute floor.
        let fitted = max(minimumScale, raw)
        return PdfZoomPolicy(
            minimumScale: fitted, maximumScale: maximumScale, fitWidthScale: fitted)
    }

    /// One call for the viewer: pick the policy the mode asks for.
    static func resolve(
        mode: PdfZoomMode,
        pageWidth: Double,
        viewportWidth: Double,
        horizontalInset: Double = 0,
        minimumScale: Double,
        maximumScale: Double
    ) -> PdfZoomPolicy {
        switch mode {
        case .free:
            return .free(minimumScale: minimumScale, maximumScale: maximumScale)
        case .fitWidth:
            return .fitWidth(
                pageWidth: pageWidth,
                viewportWidth: viewportWidth,
                horizontalInset: horizontalInset,
                minimumScale: minimumScale,
                maximumScale: maximumScale)
        }
    }

    // MARK: - Applying

    /// `scale` brought inside this policy's bounds. Under `.fitWidth` this is
    /// the floor doing its work: anything below the fit scale comes back as the
    /// fit scale.
    func clamped(_ scale: Double) -> Double {
        guard scale.isFinite else { return minimumScale }
        return min(maximumScale, max(minimumScale, scale))
    }

    /// The scale a freshly opened document should sit at, given the zoom the
    /// tab persisted.
    ///
    /// Fitting deliberately IGNORES the persisted value. An absolute zoom is a
    /// statement about a viewport the phone does not have — a tab last read at
    /// 100% on an iPad would open cropped, and one last read at 50% would open
    /// as a postage stamp. Width is the thing worth preserving across devices,
    /// not the number.
    func openingScale(persisted: Double) -> Double {
        fitWidthScale ?? clamped(persisted)
    }

    /// The scale to sit at after the viewport changed shape (rotation, a
    /// window resize, the chrome opening) while the document stayed put.
    ///
    /// A reader who was AT the old fit width is reading fit-to-width, so they
    /// follow the new one. A reader who had zoomed in past it keeps their
    /// magnification, and is only lifted if the new floor has risen above it.
    func adjustedScale(current: Double, previousFitWidth: Double?) -> Double {
        guard let fitWidthScale else { return clamped(current) }
        if let previousFitWidth, abs(current - previousFitWidth) <= Self.scaleTolerance {
            return fitWidthScale
        }
        return clamped(current)
    }
}
