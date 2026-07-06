import SwiftUI

// Cross-platform value types + overlay-positioning helper shared by the macOS
// and iPad PDF viewers. The controllers and PDFView wrappers are platform
// specific (mouse vs. touch), but the selection payload, context-menu state,
// and the "anchor above a point" layout are identical on both.

/// In-memory text selection (useTextSelection's TextSelection).
struct PdfTextSelection {
    var text: String
    var positionData: PositionData
    var pageNumber: Int
}

/// "Add note here" contextual placement state (right-click on macOS, long-press
/// on iPad). Coordinates are normalized to zoom = 1, top-left page origin.
struct PdfContextMenuState {
    /// Menu anchor in viewer (top-left origin) coordinates.
    var location: CGPoint
    var pageNumber: Int
    var clickX: Double
    var clickY: Double
    var pageWidth: Double
    var pageHeight: Double
}

/// Positions content so its bottom-center sits at `point` — the CSS
/// `translate(-50%, -100%)` used by the selection and highlight-edit popovers.
struct AnchoredAbove<Content: View>: View {
    var point: CGPoint
    @ViewBuilder var content: () -> Content

    @State private var size: CGSize = .zero

    var body: some View {
        content()
            .onGeometryChange(for: CGSize.self) { proxy in
                proxy.size
            } action: { newSize in
                size = newSize
            }
            // Clamp away from the leading/top edges so a highlight at the page
            // margin can't push the popover off-screen.
            .offset(x: max(8, point.x - size.width / 2), y: max(8, point.y - size.height))
    }
}
