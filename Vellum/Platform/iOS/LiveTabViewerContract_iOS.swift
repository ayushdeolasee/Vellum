#if os(iOS)
import PDFKit
import UIKit

// Cross-packet contract for the live-tab viewers — packet 4 §2.0, the C3 cycle
// break.
//
// Packet 4 owns tab residency and needs the viewers to stop owning their own
// controllers; packet 7 owns the viewers and needs residency to exist before it
// can rebuild them. Neither could start. This file cuts the shared surface out
// of both and lands it on its own, with NO-OP implementations: types, protocol
// requirements and no-op defaults, nothing behavioural. Everything declared
// here is currently unreferenced by the running app, deliberately.
//
// What the two packets fill in afterwards:
//
//   1. `RetainedViewOwner` — `PdfKitView_iOS.makeUIView` must hand a new host
//      the controller's EXISTING `PDFView` (parentless), instead of building a
//      fresh one. Packet 7. Today `makeUIView` still builds a fresh view.
//   2. `LiveTabViewerController.documentAttached()` — declared here with a
//      no-op default so both controllers satisfy it; the PDF controller already
//      has a real implementation, the web controller inherits the no-op.
//   3. The `(tabId:document:isActive:runtime:)` mount initializers on
//      `PdfViewerView_iOS` / `WebViewerView_iOS` (in their own files), whose
//      arguments are accepted and ignored until packet 7 honours them.

/// A viewer controller that owns a UIKit view outliving the SwiftUI host which
/// mounts it.
///
/// A tab's native view belongs to its `LiveTabRuntime`, not to the pane that
/// happens to be showing it: dragging a tab between panes, or coming back from
/// an eviction, remounts the host, and rebuilding PDFKit/WebKit on every such
/// remount is exactly what live tabs exist to avoid.
///
/// - Important: **Not yet true of any conformer.**
///   `PdfViewerControlleriOS.pdfView` is still a `weak` reference, so the view
///   is retained by its superview and dies with the host. Flipping it to a
///   strong reference changes object lifetimes, which is behavioural, so it is
///   packet 7's to make — not this interface-only commit's.
@MainActor
protocol RetainedViewOwner: AnyObject {
    associatedtype RetainedView: UIView

    /// The retained native view, or `nil` when none has been built yet.
    var retainedView: RetainedView? { get }
}

extension RetainedViewOwner {
    /// Hand the retained view to a (possibly new) host, parentless.
    ///
    /// A `UIView` may have only one superview, and a tab that migrates panes is
    /// mounted at its destination before the donor pane's subtree is torn down
    /// — `mergeAll` can transiently leave two hosts claiming one tab. Detaching
    /// first means the new host always adopts a parentless view, exactly as it
    /// would a freshly created one.
    ///
    /// - Parameter isReusable: Rejects a retained view the caller cannot adopt
    ///   (`PdfKitView_iOS` uses it to require the view already show *this*
    ///   document). Returning `nil` means "build a fresh one".
    func adoptRetainedView(
        where isReusable: (RetainedView) -> Bool = { _ in true }
    ) -> RetainedView? {
        guard let view = retainedView, isReusable(view) else { return nil }
        view.removeFromSuperview()
        return view
    }
}

/// Callbacks a live-tab viewer controller receives from the representable that
/// hosts its native view.
@MainActor
protocol LiveTabViewerController: AnyObject {
    /// The host has attached a document to the native view — either on first
    /// mount or after swapping the document underneath an already-mounted view.
    ///
    /// A default no-op is provided: a controller with nothing to do on attach
    /// (the web side, whose loads are driven by WebKit's own navigation
    /// delegate) conforms without writing anything.
    func documentAttached()
}

extension LiveTabViewerController {
    func documentAttached() {}
}

// MARK: - Conformances

// Surfacing the existing `pdfView`; the weak → strong flip that makes the name
// truthful is packet 7's (see `RetainedViewOwner`'s note). `documentAttached()`
// is already implemented on the controller and satisfies the requirement as-is.
extension PdfViewerControlleriOS: RetainedViewOwner, LiveTabViewerController {
    var retainedView: PDFView? { pdfView }
}

// The web controller takes the no-op `documentAttached()`. It is deliberately
// NOT a `RetainedViewOwner` yet: its `webView` is built lazily, so a
// `retainedView` accessor would construct a `WKWebView` — and its whole content
// process — just by being read. Packet 7 adds the conformance together with the
// `didCreateWebView` flag that lets it answer without side effects.
extension WebViewerController_iOS: LiveTabViewerController {}
#endif
