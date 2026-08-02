#if os(iOS)
import PDFKit
import SwiftUI
import UIKit

/// Tap-to-toggle for the phone reader's immersive mode (#153 P5).
///
/// ## Why this is UIKit and not `.simultaneousGesture(TapGesture())`
///
/// The reader hosts a `PDFView` (or a `WKWebView`), each of which brings its own
/// recognizers: single-tap for selection dismissal and link activation,
/// double-tap for zoom, long-press for the selection loupe. A SwiftUI
/// `simultaneousGesture` attached above them competes for those touches — most
/// visibly with PDFKit's double-tap zoom, where the first tap of a double-tap
/// toggles the chrome before the second arrives, so a zoom gesture flashes the
/// toolbar. The prototype did exactly that; it is not what ships.
///
/// So this is modelled on `PaneFocusUIView` (`PaneView_iOS.swift`), the same
/// trick the iPad uses to notice a touch without consuming it:
///
///   * the recognizer is installed on the **window**, not on this view, so this
///     view can stay `isUserInteractionEnabled = false` and never sit between
///     the reader's finger and the document. A view that hit-tested would have
///     to swallow the touch to see it;
///   * `cancelsTouchesInView = false` and `delaysTouchesBegan/Ended = false`, so
///     every other recognizer and every hosted control still receives the same
///     touch, on time;
///   * the delegate recognizes simultaneously with everything;
///   * and it explicitly `require(toFail:)`s any multi-tap recognizer found on
///     a hosted `PDFView`, which is the one relationship that cannot be
///     expressed by permissiveness alone: without it, tap #1 of a double-tap
///     fires this before PDFKit's zoom recognizer has had its chance.
///
/// The view itself is only a geometry probe: it reports the reader's bounds and
/// safe-area insets so the tap can be attributed.
struct ChromeTapCatcher_iOS: UIViewRepresentable {
    /// Whether taps should toggle at all. False while the reader is not the
    /// route on screen or a full-screen presentation is over it.
    var isActive: Bool
    /// Whether the chrome is currently showing — decides whether the bar bands
    /// below are live.
    var chromeVisible: Bool
    var action: () -> Void

    func makeUIView(context: Context) -> ChromeTapCatcherUIView {
        ChromeTapCatcherUIView(action: action, isActive: isActive, chromeVisible: chromeVisible)
    }

    func updateUIView(_ uiView: ChromeTapCatcherUIView, context: Context) {
        uiView.action = action
        uiView.isActive = isActive
        uiView.chromeVisible = chromeVisible
        // The hosted PDFView is created after this view is (the live-tab stack
        // builds a host per tab, and a warm tab re-parents), so the failure
        // requirement cannot be a one-shot at `didMoveToWindow`.
        uiView.linkToContentDoubleTaps()
    }
}

final class ChromeTapCatcherUIView: UIView, UIGestureRecognizerDelegate {
    var action: () -> Void
    var isActive: Bool
    var chromeVisible: Bool

    private var recognizer: UITapGestureRecognizer?
    /// Recognizers already made to precede ours. Identity-keyed so re-running
    /// the link pass is idempotent and does not rebuild the relationships on
    /// every SwiftUI update.
    private var linked = Set<ObjectIdentifier>()

    init(action: @escaping () -> Void, isActive: Bool, chromeVisible: Bool) {
        self.action = action
        self.isActive = isActive
        self.chromeVisible = chromeVisible
        super.init(frame: .zero)
        // Never in the touch path: the recognizer lives on the window and this
        // view exists to be measured, not to be hit.
        isUserInteractionEnabled = false
        backgroundColor = .clear
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if let recognizer {
            recognizer.view?.removeGestureRecognizer(recognizer)
            self.recognizer = nil
            linked.removeAll()
        }
        guard let window else { return }
        let tap = UITapGestureRecognizer(target: self, action: #selector(tapped(_:)))
        tap.numberOfTapsRequired = 1
        tap.cancelsTouchesInView = false
        tap.delaysTouchesBegan = false
        tap.delaysTouchesEnded = false
        tap.delegate = self
        window.addGestureRecognizer(tap)
        recognizer = tap
        linkToContentDoubleTaps()
    }

    @objc private func tapped(_ gesture: UITapGestureRecognizer) {
        guard gesture.state == .ended, isActive, window != nil else { return }
        let location = gesture.location(in: self)
        guard bounds.contains(location), !isInChromeBand(location) else { return }
        action()
    }

    /// Whether a point lands where the chrome's bars are.
    ///
    /// The recognizer sees every tap in the window, including the ones a chrome
    /// button is about to handle (`cancelsTouchesInView = false` cuts both
    /// ways). Without this, tapping Bookmark would fire the bookmark AND hide
    /// the chrome that contains it. Geometry rather than view-tree sniffing:
    /// the bands come straight from `PhoneChromeLayout` plus the live safe-area
    /// insets, so they cannot drift from the bars they describe, and they are
    /// empty while the chrome is hidden — which is when a tap anywhere must
    /// bring it back.
    private func isInChromeBand(_ point: CGPoint) -> Bool {
        guard chromeVisible else { return false }
        let insets = safeAreaInsets
        let topBand = insets.top + PhoneChromeLayout.barHeight
        let bottomBand = bounds.height - insets.bottom - PhoneChromeLayout.barHeight
        return point.y <= topBand || point.y >= bottomBand
    }

    /// Make our tap wait for — and lose to — any multi-tap recognizer on a
    /// hosted `PDFView`. Idempotent; safe to call on every update.
    func linkToContentDoubleTaps() {
        guard let recognizer, let window else { return }
        for candidate in Self.multiTapRecognizers(in: window) {
            let key = ObjectIdentifier(candidate)
            guard !linked.contains(key) else { continue }
            linked.insert(key)
            recognizer.require(toFail: candidate)
        }
    }

    /// Every ≥2-tap recognizer attached to a `PDFView` in this hierarchy —
    /// PDFKit's zoom gesture lives on the view's internal scroll view, not on
    /// the `PDFView` itself, so the walk goes all the way down rather than
    /// reading `pdfView.gestureRecognizers`.
    private static func multiTapRecognizers(in root: UIView) -> [UIGestureRecognizer] {
        var found: [UIGestureRecognizer] = []
        var stack: [(view: UIView, insidePdf: Bool)] = [(root, root is PDFView)]
        while let (view, insidePdf) = stack.popLast() {
            if insidePdf {
                for gesture in view.gestureRecognizers ?? [] {
                    guard let tap = gesture as? UITapGestureRecognizer,
                          tap.numberOfTapsRequired >= 2 else { continue }
                    found.append(tap)
                }
            }
            for subview in view.subviews {
                stack.append((subview, insidePdf || subview is PDFView))
            }
        }
        return found
    }

    // Recognize alongside everything: PDFKit's selection and link taps, WebKit's
    // click synthesis, the scroll views' pans. This recognizer observes, it does
    // not arbitrate.
    func gestureRecognizer(
        _ gestureRecognizer: UIGestureRecognizer,
        shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer
    ) -> Bool {
        true
    }
}
#endif
