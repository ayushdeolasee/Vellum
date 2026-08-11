#if os(iOS)
import SwiftUI
import UIKit

/// A normalized direct document interaction from PDFKit/WebKit. Scroll changes
/// are accepted only while the native pan is active, so programmatic offsets
/// never produce one; taps come from a simultaneous, non-cancelling recognizer.
enum ReaderChromeScrollEvent {
    case tapped(sourceInteractionBlocked: Bool)
    case began(sourceInteractionBlocked: Bool)
    case changed(deltaY: CGFloat, sourceInteractionBlocked: Bool)
    /// A normal finger lift. Policy progress survives so short direct pans can
    /// accumulate toward the same threshold.
    case ended
    /// Invalidates accumulated travel (pinch, horizontal pan, or bounce).
    case reset
}

/// The optional phone-shell callback carried through the SwiftUI environment.
/// It is absent under the iPad shell, so the shared viewers retain their
/// existing behavior without an idiom check or a second viewer implementation.
struct ReaderChromeScrollAction: @unchecked Sendable {
    var handler: (@MainActor (ReaderChromeScrollEvent) -> Void)?

    @MainActor
    func callAsFunction(_ event: ReaderChromeScrollEvent) {
        handler?(event)
    }
}

private struct ReaderChromeScrollActionKey: EnvironmentKey {
    static let defaultValue = ReaderChromeScrollAction()
}

extension EnvironmentValues {
    var readerChromeScrollAction: ReaderChromeScrollAction {
        get { self[ReaderChromeScrollActionKey.self] }
        set { self[ReaderChromeScrollActionKey.self] = newValue }
    }
}

/// Persistent preference shared by the Settings toggle and the phone shell.
enum ReaderControlPreferences {
    static let alwaysShowReaderControlsKey = "alwaysShowReaderControls"
}

/// Observes the native scroll view's own pan and adds the phone reader's
/// non-cancelling single-tap recognizer. The tap recognizes simultaneously with
/// document gestures and waits for native multi-taps to fail, so double-tap
/// zoom still wins; links and selection receive the same touch even though a
/// completed single tap now also toggles the reader bars.
///
/// Content-offset KVO supplies movement only while that native pan is actively
/// `.began`/`.changed`. This avoids PDFKit target-order differences while still
/// excluding deceleration, restored positions, page/annotation jumps, Find
/// results, and every other app-driven offset change.
@MainActor
final class ReaderChromeNativeScrollObserver: NSObject, UIGestureRecognizerDelegate {
    private weak var scrollView: UIScrollView?
    private var tapRecognizer: UITapGestureRecognizer?
    private var tapSourceInteractionBlocked = false
    private var action = ReaderChromeScrollAction()
    private var sourceInteractionBlocked: @MainActor () -> Bool = { false }
    private var previousOffset = CGPoint.zero
    private var previousTranslation = CGPoint.zero
    private var suppressUntilNextPan = false
    private var panIsActive = false
    private var offsetObservation: NSKeyValueObservation?

    func configure(
        scrollView: UIScrollView,
        action: ReaderChromeScrollAction,
        sourceInteractionBlocked: @escaping @MainActor () -> Bool
    ) {
        self.action = action
        self.sourceInteractionBlocked = sourceInteractionBlocked
        // The iPad shell leaves the environment action empty. Do not even add
        // a target there: shared viewer behavior stays byte-for-byte native.
        guard action.handler != nil else {
            detach()
            return
        }
        if self.scrollView === scrollView { return }
        detach()
        self.scrollView = scrollView
        scrollView.panGestureRecognizer.addTarget(self, action: #selector(panChanged(_:)))
        scrollView.pinchGestureRecognizer?.addTarget(self, action: #selector(pinchChanged(_:)))
        installTapRecognizer(on: scrollView)
        offsetObservation = scrollView.observe(\.contentOffset, options: [.new]) {
            [weak self] scrollView, _ in
            MainActor.assumeIsolated {
                self?.contentOffsetChanged(in: scrollView)
            }
        }
    }

    func detach() {
        scrollView?.panGestureRecognizer.removeTarget(self, action: #selector(panChanged(_:)))
        scrollView?.pinchGestureRecognizer?.removeTarget(self, action: #selector(pinchChanged(_:)))
        if let tapRecognizer {
            tapRecognizer.view?.removeGestureRecognizer(tapRecognizer)
        }
        tapRecognizer = nil
        tapSourceInteractionBlocked = false
        offsetObservation?.invalidate()
        offsetObservation = nil
        scrollView = nil
        panIsActive = false
        // Viewer teardown is lifecycle, not document movement. The shell owns
        // navigation resets; an inactive tab must never reset the active tab's
        // in-flight policy state.
    }

    private func installTapRecognizer(on scrollView: UIScrollView) {
        let tap = UITapGestureRecognizer(target: self, action: #selector(documentTapped(_:)))
        tap.cancelsTouchesInView = false
        tap.delaysTouchesBegan = false
        tap.delaysTouchesEnded = false
        tap.delegate = self
        scrollView.addGestureRecognizer(tap)
        tapRecognizer = tap
    }

    @objc private func documentTapped(_ tap: UITapGestureRecognizer) {
        guard tap.state == .ended else { return }
        action(.tapped(sourceInteractionBlocked: tapSourceInteractionBlocked))
        tapSourceInteractionBlocked = false
    }

    /// Snapshot interaction state before PDFKit/WebKit receives the touch.
    /// Their own simultaneous tap handlers can clear a selection before our
    /// recognizer reaches `.ended`; using the end-state would let that same
    /// selection-dismissal tap also hide the reader bars.
    nonisolated func gestureRecognizer(
        _ gestureRecognizer: UIGestureRecognizer,
        shouldReceive touch: UITouch
    ) -> Bool {
        MainActor.assumeIsolated {
            tapSourceInteractionBlocked = sourceInteractionBlocked()
        }
        return true
    }

    nonisolated func gestureRecognizer(
        _ gestureRecognizer: UIGestureRecognizer,
        shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer
    ) -> Bool {
        true
    }

    /// UIKit asks this dynamically when recognizers compete, including native
    /// recognizers installed lazily or attached above the scroll view. Waiting
    /// for every same-finger-count multi-tap prevents a double-tap zoom or word
    /// selection from also completing our single-tap chrome toggle.
    nonisolated func gestureRecognizer(
        _ gestureRecognizer: UIGestureRecognizer,
        shouldRequireFailureOf otherGestureRecognizer: UIGestureRecognizer
    ) -> Bool {
        MainActor.assumeIsolated {
            guard let tap = gestureRecognizer as? UITapGestureRecognizer,
                  let competingTap = otherGestureRecognizer as? UITapGestureRecognizer
            else { return false }
            return tap.numberOfTouchesRequired == competingTap.numberOfTouchesRequired
                && competingTap.numberOfTapsRequired > tap.numberOfTapsRequired
        }
    }

    /// A centered pinch can change zoom without moving contentOffset or starting
    /// the scroll view's pan recognizer. Listen to the pinch directly so it
    /// always invalidates partial reading travel from an earlier short pan.
    @objc private func pinchChanged(_ pinch: UIPinchGestureRecognizer) {
        guard pinch.state == .began else { return }
        suppressUntilNextPan = true
        action(.reset)
    }

    @objc private func panChanged(_ pan: UIPanGestureRecognizer) {
        guard let scrollView else { return }

        switch pan.state {
        case .began:
            suppressUntilNextPan = false
            panIsActive = true
            previousOffset = scrollView.contentOffset
            previousTranslation = pan.translation(in: scrollView)
            action(.began(sourceInteractionBlocked: sourceInteractionBlocked()))

        case .changed:
            // Movement is sampled by content-offset KVO below. PDFKit can run
            // added pan targets before applying its offset; KVO always runs
            // after the offset has actually changed. Invalidation cannot wait
            // for KVO, though: a horizontal pan may move no contentOffset at
            // all, and must still clear travel left by an earlier short pan.
            let translation = pan.translation(in: scrollView)
            let fingerDelta = CGPoint(
                x: translation.x - previousTranslation.x,
                y: translation.y - previousTranslation.y)
            if !suppressUntilNextPan,
               (scrollView.isZooming || isPinching(scrollView)
                || abs(fingerDelta.x) > abs(fingerDelta.y)) {
                suppressCurrentPan()
            }

        case .ended:
            panIsActive = false
            action(.ended)

        case .cancelled, .failed:
            panIsActive = false
            action(.reset)

        case .possible:
            break

        @unknown default:
            panIsActive = false
            action(.reset)
        }
    }

    private func contentOffsetChanged(in scrollView: UIScrollView) {
        let pan = scrollView.panGestureRecognizer
        guard panIsActive,
              !suppressUntilNextPan,
              pan.state == .began || pan.state == .changed else { return }

        let offset = scrollView.contentOffset
        let translation = pan.translation(in: scrollView)
        defer {
            previousOffset = offset
            previousTranslation = translation
        }

        // A pinch can move contentOffset as PDFKit/WebKit keeps the focal point
        // under the fingers. It is zoom geometry, not reading travel.
        if scrollView.isZooming || isPinching(scrollView) {
            suppressCurrentPan()
            return
        }

        let fingerDelta = CGPoint(
            x: translation.x - previousTranslation.x,
            y: translation.y - previousTranslation.y)
        // Horizontal pans can carry a small vertical wobble. Reject the whole
        // pan whenever horizontal finger travel dominates a moving sample.
        guard abs(fingerDelta.y) >= abs(fingerDelta.x) else {
            suppressCurrentPan()
            return
        }

        let deltaY = offset.y - previousOffset.y
        guard abs(deltaY) > 0.01,
              isInsideScrollableRange(previousOffset.y, in: scrollView),
              isInsideScrollableRange(offset.y, in: scrollView)
        else {
            if !isInsideScrollableRange(offset.y, in: scrollView) {
                suppressCurrentPan()
            }
            return
        }

        action(.changed(
            deltaY: deltaY,
            sourceInteractionBlocked: sourceInteractionBlocked()))
    }

    private func suppressCurrentPan() {
        suppressUntilNextPan = true
        action(.reset)
    }

    private func isPinching(_ scrollView: UIScrollView) -> Bool {
        guard let state = scrollView.pinchGestureRecognizer?.state else { return false }
        return state == .began || state == .changed
    }

    private func isInsideScrollableRange(_ offsetY: CGFloat, in scrollView: UIScrollView) -> Bool {
        let minimum = -scrollView.adjustedContentInset.top
        let maximum = max(
            minimum,
            scrollView.contentSize.height - scrollView.bounds.height
                + scrollView.adjustedContentInset.bottom)
        // Half a point absorbs PDFKit/WebKit's subpixel settling at the edge
        // without admitting visible rubber-band movement.
        return offsetY >= minimum - 0.5 && offsetY <= maximum + 0.5
    }
}
#endif
