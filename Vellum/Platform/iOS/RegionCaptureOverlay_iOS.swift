#if os(iOS)
import Observation
import SwiftUI
import UIKit

@MainActor
@Observable
final class RegionCaptureState {
    private(set) var selectionRect: CGRect?
    private(set) var captureGeneration = 0

    func update(rect: CGRect?) {
        selectionRect = rect
    }

    func completeCapture() {
        captureGeneration &+= 1
    }

    func clear() {
        selectionRect = nil
    }
}

/// A one-finger crop gesture that remains simultaneous with the reader's
/// native pan and pinch gestures. While capture is active, native panning needs
/// two fingers; the first finger stays dedicated to the marquee.
@MainActor
final class RegionCaptureGestureRecognizer: UIGestureRecognizer {
    static let minimumCaptureSize: CGFloat = 4
    private static let edgeInset: CGFloat = 48
    private static let maximumScrollSpeed: CGFloat = 280

    var onBegin: ((CGPoint) -> Bool)?
    var onUpdate: ((CGPoint) -> Void)?
    var onFinish: (() -> Bool)?
    var onResetSelection: (() -> Void)?

    private weak var hostView: UIView?
    private weak var nativeScrollView: UIScrollView?
    private var originalPanMinimumTouches: Int?
    private var primaryTouch: UITouch?
    private var activeTouches: Set<ObjectIdentifier> = []
    private var usedAdditionalTouch = false
    private var displayLink: CADisplayLink?

    override init(target: Any?, action: Selector?) {
        super.init(target: target, action: action)
        cancelsTouchesInView = false
        delaysTouchesBegan = false
        delaysTouchesEnded = false
    }

    func configure(hostView: UIView, scrollView: UIScrollView, enabled: Bool) {
        self.hostView = hostView
        nativeScrollView = scrollView
        isEnabled = enabled

        if enabled {
            if originalPanMinimumTouches == nil {
                originalPanMinimumTouches = scrollView.panGestureRecognizer.minimumNumberOfTouches
            }
            scrollView.panGestureRecognizer.minimumNumberOfTouches = 2
        } else {
            restoreNativePan()
            stopDisplayLink()
            onResetSelection?()
        }
    }

    func detach() {
        isEnabled = false
        restoreNativePan()
        stopDisplayLink()
        onResetSelection?()
        if let view { view.removeGestureRecognizer(self) }
        hostView = nil
        nativeScrollView = nil
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
        for touch in touches { activeTouches.insert(ObjectIdentifier(touch)) }
        if primaryTouch != nil, activeTouches.count > 1 {
            usedAdditionalTouch = true
            stopDisplayLink()
            onResetSelection?()
            return
        }

        guard primaryTouch == nil, let touch = touches.first, let hostView else { return }
        primaryTouch = touch
        if activeTouches.count > 1 {
            usedAdditionalTouch = true
            state = .began
            onResetSelection?()
            return
        }
        let point = touch.location(in: hostView)
        guard onBegin?(point) ?? false else {
            state = .failed
            return
        }
        state = .began
        onUpdate?(point)
        startDisplayLink()
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent) {
        guard !usedAdditionalTouch, activeTouches.count == 1,
              let primaryTouch, touches.contains(primaryTouch), let hostView else { return }
        state = .changed
        onUpdate?(primaryTouch.location(in: hostView))
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent) {
        for touch in touches { activeTouches.remove(ObjectIdentifier(touch)) }
        guard let primaryTouch, touches.contains(primaryTouch) else { return }
        guard !usedAdditionalTouch else {
            stopDisplayLink()
            onResetSelection?()
            state = .cancelled
            return
        }
        if let hostView { onUpdate?(primaryTouch.location(in: hostView)) }
        stopDisplayLink()
        state = (onFinish?() ?? false) ? .ended : .cancelled
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent) {
        for touch in touches { activeTouches.remove(ObjectIdentifier(touch)) }
        guard let primaryTouch, touches.contains(primaryTouch) else { return }
        stopDisplayLink()
        onResetSelection?()
        state = .cancelled
    }

    override func reset() {
        super.reset()
        primaryTouch = nil
        activeTouches.removeAll()
        usedAdditionalTouch = false
        stopDisplayLink()
    }

    static func scrollVelocity(at point: CGPoint, in bounds: CGRect) -> CGPoint {
        func component(_ value: CGFloat, minimum: CGFloat, maximum: CGFloat) -> CGFloat {
            if value < minimum + edgeInset {
                return -maximumScrollSpeed * min(1, (minimum + edgeInset - value) / edgeInset)
            }
            if value > maximum - edgeInset {
                return maximumScrollSpeed * min(1, (value - (maximum - edgeInset)) / edgeInset)
            }
            return 0
        }

        return CGPoint(
            x: component(point.x, minimum: bounds.minX, maximum: bounds.maxX),
            y: component(point.y, minimum: bounds.minY, maximum: bounds.maxY))
    }

    private func startDisplayLink() {
        guard displayLink == nil else { return }
        let link = CADisplayLink(target: self, selector: #selector(scrollAtEdge(_:)))
        link.add(to: .main, forMode: .common)
        displayLink = link
    }

    private func stopDisplayLink() {
        displayLink?.invalidate()
        displayLink = nil
    }

    @objc private func scrollAtEdge(_ link: CADisplayLink) {
        guard activeTouches.count == 1,
              let primaryTouch, let hostView,
              let scrollView = nativeScrollView else { return }
        let point = primaryTouch.location(in: hostView)
        let velocity = Self.scrollVelocity(at: point, in: hostView.bounds)
        guard velocity != .zero else { return }

        let elapsed = min(CGFloat(link.targetTimestamp - link.timestamp), 1 / 30)
        let inset = scrollView.adjustedContentInset
        let minimum = CGPoint(x: -inset.left, y: -inset.top)
        let maximum = CGPoint(
            x: max(minimum.x, scrollView.contentSize.width - scrollView.bounds.width + inset.right),
            y: max(minimum.y, scrollView.contentSize.height - scrollView.bounds.height + inset.bottom))
        let proposed = CGPoint(
            x: min(maximum.x, max(minimum.x, scrollView.contentOffset.x + velocity.x * elapsed)),
            y: min(maximum.y, max(minimum.y, scrollView.contentOffset.y + velocity.y * elapsed)))
        guard proposed != scrollView.contentOffset else { return }
        scrollView.contentOffset = proposed
        onUpdate?(point)
    }

    private func restoreNativePan() {
        guard let scrollView = nativeScrollView,
              let originalPanMinimumTouches else { return }
        scrollView.panGestureRecognizer.minimumNumberOfTouches = originalPanMinimumTouches
        self.originalPanMinimumTouches = nil
    }
}

/// Visual-only capture layer. The native PDF/Web view below it owns selection,
/// pan, and pinch gestures; only the explicit Cancel control takes touches here.
struct RegionCaptureOverlay_iOS: View {
    let state: RegionCaptureState
    let onCapture: () -> Void
    let onCancel: () -> Void

    @Environment(\.palette) private var palette

    var body: some View {
        ZStack(alignment: .topTrailing) {
            selectionLayer.allowsHitTesting(false)
            cancelButton.padding(16)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onChange(of: state.captureGeneration) {
            onCapture()
            state.clear()
        }
    }

    private var selectionLayer: some View {
        ZStack(alignment: .topLeading) {
            Rectangle()
                .fill(.black.opacity(0.28))
                .overlay(alignment: .topLeading) {
                    if let rect = state.selectionRect {
                        Rectangle()
                            .frame(width: rect.width, height: rect.height)
                            .offset(x: rect.minX, y: rect.minY)
                            .blendMode(.destinationOut)
                    }
                }
                .compositingGroup()

            if let rect = state.selectionRect {
                Rectangle()
                    .strokeBorder(
                        palette.primary,
                        style: StrokeStyle(lineWidth: 1.5, dash: [5, 3]))
                    .frame(width: rect.width, height: rect.height)
                    .offset(x: rect.minX, y: rect.minY)
            }
        }
    }

    private var cancelButton: some View {
        Button {
            state.clear()
            onCancel()
        } label: {
            Image(systemName: "xmark")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 44, height: 44)
                .background(.black.opacity(0.55), in: Circle())
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .keyboardShortcut(.cancelAction)
        .accessibilityLabel("Cancel region capture")
        .accessibilityIdentifier("regionCapture.cancel")
    }
}
#endif
