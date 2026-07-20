import XCTest
@testable import Vellum

// Regression tests for the zoom-button routing in AppStore. The zoom buttons
// call AppStore.zoomIn()/zoomOut(), which route through `zoomToHandler` when a
// viewer has registered one. The dead-buttons bug: only the PDF viewer claimed
// that slot, so after its controller went away (tab switched or closed) every
// zoom press ran a stale closure whose weak controller was nil — no setZoom,
// frozen % label. The web viewer must claim the slot on attach.

@MainActor
final class ZoomHandlerTests: XCTestCase {
    private func makeApp() -> AppStore {
        AppStore(sessions: DocumentSessionManager())
    }

    func testZoomInWithoutHandlerUpdatesZoom() {
        let app = makeApp()
        app.zoomIn()
        XCTAssertEqual(app.zoom, 1.1, accuracy: 0.0001)
        app.zoomOut()
        XCTAssertEqual(app.zoom, 1.0, accuracy: 0.0001)
    }

    /// The dead-buttons scenario: a stale handler (weak controller already
    /// gone, so the closure is a no-op) swallows every zoom press.
    func testStaleHandlerSwallowsZoomPresses() {
        let app = makeApp()
        app.zoomToHandler = { _ in /* dead PDF controller: nothing happens */ }
        app.zoomIn()
        XCTAssertEqual(app.zoom, 1.0, accuracy: 0.0001,
                       "documents the failure mode the web viewer must displace")
    }

    /// The fix: WebViewerController_iOS.attach overwrites the stale slot with
    /// a live handler that drives AppStore.setZoom, so zoomIn works again.
    func testWebViewerAttachDisplacesStaleZoomHandler() {
        let app = makeApp()
        let annotations = AnnotationStore(app: app)
        let ai = AiStore()

        // Stale slot left behind by a dead PDF viewer.
        app.zoomToHandler = { _ in }

        let controller = WebViewerController_iOS()
        controller.attach(app: app, annotationStore: annotations, aiStore: ai)

        app.zoomIn()
        XCTAssertEqual(app.zoom, 1.1, accuracy: 0.0001,
                       "web viewer's handler must reach setZoom (label + viewScale)")
        app.zoomIn()
        XCTAssertEqual(app.zoom, 1.2, accuracy: 0.0001)
        app.zoomOut()
        XCTAssertEqual(app.zoom, 1.1, accuracy: 0.0001)
        app.resetZoom()
        XCTAssertEqual(app.zoom, 1.0, accuracy: 0.0001)
        controller.detach()
    }

    /// Handler routing must clamp exactly like plain setZoom.
    func testWebZoomHandlerClamps() {
        let app = makeApp()
        let annotations = AnnotationStore(app: app)
        let ai = AiStore()
        let controller = WebViewerController_iOS()
        controller.attach(app: app, annotationStore: annotations, aiStore: ai)

        app.zoomToHandler?(99)
        XCTAssertEqual(app.zoom, AppStore.maxZoom, accuracy: 0.0001)
        app.zoomToHandler?(0.01)
        XCTAssertEqual(app.zoom, AppStore.minZoom, accuracy: 0.0001)
        controller.detach()
    }
}
