#if os(iOS)
import SwiftUI

/// Drag-to-crop overlay for `.snapshotRegion` mode on iPad — the touch twin of
/// the macOS `RegionCaptureOverlay`. Draws a dimmed scrim with a clear cut-out
/// over the marquee and reports the final rectangle (viewer top-left
/// coordinates) on release. Because it's a full-viewer, hit-testable layer, the
/// drag never reaches the PDFView / WKWebView underneath, so the marquee can't
/// fight native text selection. A plain tap or a sub-threshold wobble calls
/// `onCancel` instead of cropping, and an explicit 44pt cancel button (also
/// bound to the hardware Escape key) always backs out — so the capture mode can
/// never get stuck behind the scrim.
struct RegionCaptureOverlay_iOS: View {
    let onCapture: (CGRect) -> Void
    let onCancel: () -> Void

    /// Drags smaller than this in either dimension are treated as an accidental
    /// tap and cancel the capture instead of cropping.
    private static let minimumCaptureSize: CGFloat = 4

    @Environment(\.palette) private var palette
    @State private var start: CGPoint?
    @State private var current: CGPoint?

    private var rect: CGRect? {
        guard let start, let current else { return nil }
        return CGRect(
            x: min(start.x, current.x), y: min(start.y, current.y),
            width: abs(current.x - start.x), height: abs(current.y - start.y))
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            // Dimmed scrim with the marquee rect punched clear (destinationOut).
            // `compositingGroup` isolates the blend so only this layer is cut,
            // not the viewer below it.
            Rectangle()
                .fill(.black.opacity(0.28))
                .overlay(alignment: .topLeading) {
                    if let rect {
                        Rectangle()
                            .frame(width: rect.width, height: rect.height)
                            .offset(x: rect.minX, y: rect.minY)
                            .blendMode(.destinationOut)
                    }
                }
                .compositingGroup()

            // Dashed marquee border tracing the live crop rect.
            if let rect {
                Rectangle()
                    .strokeBorder(
                        palette.primary,
                        style: StrokeStyle(lineWidth: 1.5, dash: [5, 3]))
                    .frame(width: rect.width, height: rect.height)
                    .offset(x: rect.minX, y: rect.minY)
                    .allowsHitTesting(false)
            }

        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .contentShape(Rectangle())
        // Explicit escape hatch for touch users (and the hardware Esc key). Sits
        // in an overlay so the button keeps its own 44pt hit target instead of
        // expanding to fill the scrim.
        .overlay(alignment: .topTrailing) {
            cancelButton.padding(16)
        }
        .gesture(
            // minimumDistance 0 so even a plain tap ends the gesture and reaches
            // the cancel path — with a positive threshold a bare tap never fires
            // onEnded and the overlay would stay up forever.
            DragGesture(minimumDistance: 0, coordinateSpace: .local)
                .onChanged { value in
                    if start == nil { start = value.startLocation }
                    current = value.location
                }
                .onEnded { _ in
                    let final = rect
                    start = nil
                    current = nil
                    if let final,
                       final.width >= Self.minimumCaptureSize,
                       final.height >= Self.minimumCaptureSize {
                        onCapture(final)
                    } else {
                        onCancel()
                    }
                }
        )
    }

    private var cancelButton: some View {
        Button {
            start = nil
            current = nil
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
