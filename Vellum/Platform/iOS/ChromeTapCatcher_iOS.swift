#if os(iOS)
import SwiftUI
import UIKit

/// Direct finger travel from PDFKit/WebKit, positive toward later content.
enum ReaderChromeScrollEvent {
    case tapped(sourceInteractionBlocked: Bool)
    case began(sourceInteractionBlocked: Bool)
    case changed(deltaY: CGFloat, sourceInteractionBlocked: Bool)
    /// A finger lift clears partial travel; each swipe must be deliberate.
    case ended
    /// Invalidates accumulated travel (pinch or horizontal pan).
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

/// Observes taps and finger travel without consuming native document gestures.
/// Translation works at document edges and on short pages, and excludes inertia
/// and programmatic scrolling. The iPad installs no observer.
@MainActor
final class ReaderChromeNativeScrollObserver: NSObject, UIGestureRecognizerDelegate {
    private var travelRecognizer: UIPanGestureRecognizer?
    private var tapRecognizer: UITapGestureRecognizer?
    private weak var scrollView: UIScrollView?
    private var action = ReaderChromeScrollAction()
    private var sourceInteractionBlocked: @MainActor () -> Bool = { false }
    private var previousTranslation = CGPoint.zero
    private var suppressUntilNextPan = false

    func configure(
        scrollView: UIScrollView,
        action: ReaderChromeScrollAction,
        sourceInteractionBlocked: @escaping @MainActor () -> Bool
    ) {
        self.action = action
        self.sourceInteractionBlocked = sourceInteractionBlocked
        guard action.handler != nil else {
            detach()
            return
        }
        if self.scrollView === scrollView { return }
        detach()
        self.scrollView = scrollView
        let pan = UIPanGestureRecognizer(target: self, action: #selector(panChanged(_:)))
        pan.cancelsTouchesInView = false
        pan.maximumNumberOfTouches = 1
        pan.delegate = self
        scrollView.addGestureRecognizer(pan)
        travelRecognizer = pan
        let tap = UITapGestureRecognizer(target: self, action: #selector(tapped(_:)))
        tap.cancelsTouchesInView = false
        tap.delaysTouchesBegan = false
        tap.delaysTouchesEnded = false
        tap.allowedTouchTypes = [NSNumber(value: UITouch.TouchType.direct.rawValue)]
        tap.delegate = self
        scrollView.addGestureRecognizer(tap)
        tapRecognizer = tap
        scrollView.pinchGestureRecognizer?.addTarget(self, action: #selector(pinchChanged(_:)))
    }

    func detach() {
        if let travelRecognizer {
            travelRecognizer.view?.removeGestureRecognizer(travelRecognizer)
        }
        travelRecognizer = nil
        if let tapRecognizer {
            tapRecognizer.view?.removeGestureRecognizer(tapRecognizer)
        }
        tapRecognizer = nil
        scrollView?.pinchGestureRecognizer?.removeTarget(self, action: #selector(pinchChanged(_:)))
        scrollView = nil
    }

    nonisolated func gestureRecognizer(
        _ gestureRecognizer: UIGestureRecognizer,
        shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer
    ) -> Bool {
        true
    }

    func gestureRecognizer(
        _ gestureRecognizer: UIGestureRecognizer,
        shouldReceive touch: UITouch
    ) -> Bool {
        guard gestureRecognizer === tapRecognizer else { return true }
        guard !sourceInteractionBlocked() else { return false }
        var view = touch.view
        while let current = view {
            if current is UIControl { return false }
            view = current.superview
        }
        return true
    }

    func gestureRecognizer(
        _ gestureRecognizer: UIGestureRecognizer,
        shouldRequireFailureOf otherGestureRecognizer: UIGestureRecognizer
    ) -> Bool {
        gestureRecognizer === tapRecognizer
            && ((otherGestureRecognizer as? UITapGestureRecognizer)?.numberOfTapsRequired ?? 0) > 1
    }

    @objc private func tapped(_ tap: UITapGestureRecognizer) {
        guard tap.state == .ended else { return }
        action(.tapped(sourceInteractionBlocked: sourceInteractionBlocked()))
    }

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
            previousTranslation = pan.translation(in: scrollView)
            action(.began(sourceInteractionBlocked: sourceInteractionBlocked()))
        case .changed:
            let translation = pan.translation(in: scrollView)
            let delta = CGPoint(
                x: translation.x - previousTranslation.x,
                y: translation.y - previousTranslation.y)
            previousTranslation = translation
            guard !suppressUntilNextPan else { return }
            let pinchState = scrollView.pinchGestureRecognizer?.state
            guard !scrollView.isZooming,
                  pinchState != .began, pinchState != .changed,
                  pan.numberOfTouches == 1,
                  abs(translation.y) >= abs(translation.x) else {
                suppressUntilNextPan = true
                action(.reset)
                return
            }
            action(.changed(
                deltaY: -delta.y,
                sourceInteractionBlocked: sourceInteractionBlocked()))
        case .ended:
            action(.ended)
        case .cancelled, .failed:
            action(.reset)
        case .possible:
            break
        @unknown default:
            action(.reset)
        }
    }
}
#endif
