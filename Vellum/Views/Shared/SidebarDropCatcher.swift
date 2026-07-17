import AppKit
import SwiftUI

/// A drag-only AppKit destination overlaid on the whole sidebar.
///
/// WHY THIS EXISTS (the short version of a long investigation):
/// SwiftUI's `.onDrop` proved unreliable in the sidebar's hosting hierarchy.
/// Every `.onDrop` installs a hidden `_PlatformDraggingDestinationView` that is
/// registered for the catch-all `public.data`/`public.item` types *regardless*
/// of the `of:` array you pass, and — inside the inspector's glass-effect
/// hosting view — that hidden view wins AppKit's drag-destination search over
/// the panels' own AppKit views yet then *refuses* real file drags
/// (`draggingEntered`/`Updated` fire, `performDragOperation` never does), so the
/// drop dies with no highlight. Minimal reproductions of the same
/// `@Observable`/dynamic-types pattern work, so the cause is specific to this
/// view tree and resisted safe introspection. The conclusion we ship:
/// `.onDrop` is not trustworthy here — the sidebar uses ONE plain AppKit
/// drag-only overlay instead, and there must be NO `.onDrop` anywhere in the
/// sidebar subtree (any new one re-installs that catch-all view and steals —
/// then kills — every sidebar drag).
///
/// This NSView is deliberately *drag-only*: `hitTest(_:)` always returns nil, so
/// clicks and typing pass straight through to the composer / editor beneath it,
/// while AppKit still offers it drags (the drag-destination search uses
/// registered types + geometry, not `hitTest`). Without that override the whole
/// sidebar becomes unclickable.
final class SidebarDropView: NSView {
    /// Decides the drag operation at event time. Supplied by SwiftUI and read
    /// LIVE on each callback so it reflects the current `workspace.sidebarTab`
    /// (annotations → none; AI/scratchpad → copy iff the drag carries an
    /// attachment). Optional so registration can be withdrawn when absent.
    var resolveOperation: ((NSDraggingInfo) -> NSDragOperation)?

    /// Drives the sidebar's dashed drop outline: true when a drag is accepted
    /// (hover), false when it leaves, ends, or is performed.
    var onTargeted: ((Bool) -> Void)?

    /// Builds the payload and dispatches it to the current tab's store. Returns
    /// true when the drop was handled.
    var onDrop: ((AttachmentDropPayload) -> Bool)?

    /// Register the attachment types only when there is a handler and we are in a
    /// window — an unregistered view is invisible to AppKit's destination search,
    /// which is exactly what we want when the catcher isn't wired.
    func updateDragRegistration() {
        if resolveOperation == nil || window == nil {
            unregisterDraggedTypes()
        } else {
            registerForDraggedTypes(AttachmentDrop.draggedTypes)
        }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        updateDragRegistration()
        raiseAboveSiblings()
    }

    /// Ensure this view is frontmost among its siblings so AppKit's front-to-back
    /// destination search reaches it before the panels' own AppKit drop views
    /// (the composer text views, the scratchpad WebView). SwiftUI's `.overlay`
    /// normally already orders the overlay's backing view last (= frontmost), but
    /// we assert it explicitly rather than depend on that. `addSubview(_:positioned:
    /// relativeTo:)` on a view that is already a subview just reorders it — it does
    /// not detach/reattach, so it is safe under SwiftUI's hosting view.
    private func raiseAboveSiblings() {
        guard let superview, superview.subviews.last !== self else { return }
        superview.addSubview(self, positioned: .above, relativeTo: nil)
    }

    // CRITICAL: drag-only. Returning nil for every point keeps the overlay from
    // swallowing clicks/typing meant for the composer or editor underneath.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        let operation = resolveOperation?(sender) ?? []
        onTargeted?(!operation.isEmpty)
        return operation
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        resolveOperation?(sender) ?? []
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        onTargeted?(false)
    }

    override func draggingEnded(_ sender: NSDraggingInfo) {
        onTargeted?(false)
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        onTargeted?(false)
        guard let onDrop, let payload = AttachmentDrop.payload(sender) else { return false }
        return onDrop(payload)
    }
}

/// SwiftUI wrapper that hosts `SidebarDropView` as a sidebar-wide, click-through
/// drag destination. Place it in an `.overlay { }` on the sidebar's panel stack
/// so its NSView sits in front of the panels' AppKit drop views in AppKit's
/// destination search — one destination for the whole sidebar, no per-panel
/// stacking games.
struct SidebarDropCatcher: NSViewRepresentable {
    /// Read live at event time — must consult `workspace.sidebarTab` when the
    /// callback fires, never a snapshot taken when the closure was built.
    let resolveOperation: (NSDraggingInfo) -> NSDragOperation
    let onTargeted: (Bool) -> Void
    let onDrop: (AttachmentDropPayload) -> Bool

    func makeNSView(context: Context) -> SidebarDropView {
        let view = SidebarDropView()
        view.resolveOperation = resolveOperation
        view.onTargeted = onTargeted
        view.onDrop = onDrop
        view.updateDragRegistration()
        return view
    }

    func updateNSView(_ view: SidebarDropView, context: Context) {
        // Re-assign every update so the closures capture the freshest environment
        // (the tab may have changed); the closures themselves still read state
        // live when a real drag callback invokes them.
        view.resolveOperation = resolveOperation
        view.onTargeted = onTargeted
        view.onDrop = onDrop
        view.updateDragRegistration()
    }
}
