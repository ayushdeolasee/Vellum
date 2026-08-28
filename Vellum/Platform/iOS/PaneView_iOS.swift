#if os(iOS)
import SwiftUI
import UIKit

// One leaf pane of the iPad split-screen layout: injects its own store-triple
// into its subtree and renders self-contained reading chrome (tab strip,
// Liquid Glass toolbar, find bar, viewer / compact library). The iPad analogue
// of the macOS `PaneView` — but where the Mac keeps one window toolbar bound to
// the focused pane, the iPad toolbar is in-content, so each pane carries its
// own and only the inspector sidebar retargets on focus change.

/// Window-level lookup of each pane's ink controller. The controller is owned
/// by the pane (its viewer wires `pdfController` into it), but the shared
/// inspector sidebar needs the *focused* pane's controller for the Handwriting
/// section, so panes register here keyed by pane id.
@MainActor
@Observable
final class InkRegistry_iOS {
    private(set) var controllers: [String: InkController_iOS] = [:]

    func register(_ controller: InkController_iOS, for paneId: String) {
        controllers[paneId] = controller
    }

    func remove(_ paneId: String) {
        controllers.removeValue(forKey: paneId)
    }
}

struct PaneView_iOS: View {
    let pane: PaneModel

    @Environment(WorkspaceStore.self) private var workspace
    @Environment(IntegrationsStore.self) private var integrations
    @Environment(InkRegistry_iOS.self) private var inkRegistry
    @Environment(\.palette) private var palette
    @State private var activeZone: DropZone?

    private var app: AppStore { pane.app }
    private var isFocused: Bool { workspace.focusedPaneId == pane.id }

    /// The ACTIVE tab's ink controller. Ink is per-DOCUMENT state and lives on
    /// the tab's `LiveTabRuntime` (see `LiveTabRuntime.ink`), because several
    /// tabs' `PDFView`s are mounted at once now and each installs its
    /// `ink.inkProvider` as `pageOverlayViewProvider` — one pane-owned
    /// controller would hand tab B's page-3 canvas to tab A's page 3.
    private var activeInk: InkController_iOS? {
        app.activeTabId.map { workspace.liveTabRuntime(for: $0).ink }
    }

    var body: some View {
        GeometryReader { geo in
            VStack(spacing: 0) {
                if !app.tabs.isEmpty {
                    TabStrip_iOS(paneId: pane.id, onNewTab: { app.newStartTab() })
                }
                content
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .clipped()
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(palette.background)
            .overlay(alignment: .topLeading) {
                // Focus ring only when the window is actually split — a lone
                // pane never needs the "which pane is active" affordance.
                if workspace.isSplit {
                    RoundedRectangle(cornerRadius: Radius.md)
                        .strokeBorder(
                            isFocused ? palette.primary.opacity(0.55) : Color.clear,
                            lineWidth: 2)
                        .allowsHitTesting(false)
                }
            }
            // Transparent drop catcher floated above the content so a hosted
            // WKWebView (which registers its own dragged types) can't swallow a
            // tab drop first. Hit testing is gated on an in-flight drag so
            // normal touch interaction is untouched the rest of the time.
            .overlay {
                Color.clear
                    .contentShape(Rectangle())
                    .allowsHitTesting(workspace.draggingTab != nil)
                    .onDrop(
                        of: [.vellumTab],
                        delegate: PaneDropDelegate(
                            paneId: pane.id, size: geo.size, workspace: workspace,
                            activeZone: $activeZone))
            }
            .overlay { DropZoneOverlay(zone: workspace.draggingTab == nil ? nil : activeZone, palette: palette) }
        }
        .environment(app)
        .environment(pane.annotations)
        .environment(pane.ai)
        .environment(pane.scratchpad)
        // Window-global model catalog read by the in-panel AI settings.
        .environment(workspace.openRouterCatalog)
        .background(PaneFocusCatcher_iOS(isActive: workspace.isSplit) {
            if !isFocused { workspace.focus(pane.id) }
        })
        // Document-scoped store loading + the sidecar-import / data-deleted
        // invalidation handlers (`PaneDocumentState_iOS`), shared with the
        // phone shell.
        .paneDocumentState(pane: pane)
        // The registry is the shared inspector's pane -> controller lookup for
        // its Handwriting section. It now holds the ACTIVE TAB's controller and
        // re-registers whenever the pane changes tabs; the controllers
        // themselves are owned by the runtimes.
        .onChange(of: app.activeTabId, initial: true) { _, _ in
            if let activeInk { inkRegistry.register(activeInk, for: pane.id) }
        }
        .onDisappear {
            // Flush BEFORE deregistering. The scene-background flush drains the
            // registry, so a controller with debounced ink that has already been
            // removed would never be reached — closing a split pane moments
            // before pressing Home would drop the last strokes.
            activeInk?.flushPendingInk()
            inkRegistry.remove(pane.id)
        }
        #if DEBUG
        .task(id: app.activeTabId) { await autoInkForTesting() }
        #endif
    }

    @ViewBuilder
    private var content: some View {
        if app.tabs.isEmpty {
            // No tab at all: closing the last tab in a lone pane leaves the pane
            // open on the library (`AppStore.closeTab` -> `paneDidEmpty`). The
            // ForEach below would render an empty ZStack here, so this case has
            // to be spelled out — there is no tab to host it.
            WelcomeLibrary_iOS(
                onOpen: requestOpenFile,
                onAddWebpage: requestAddWebpage,
                compact: true,
                store: pane.homeSearch)
        } else if app.document == nil {
            // Active start tab: the library, inside the pane.
            //
            // Differs from macOS on purpose. There, `LiveTabHost` renders a
            // per-tab `WelcomeScreen` because that screen grabs first responder
            // and an invisible one must not. On iPad the start tab's home
            // surface is the full-pane library, which is pane-scoped rather than
            // tab-scoped, so it stays here and no host is built for a start tab.
            WelcomeLibrary_iOS(
                onOpen: requestOpenFile,
                onAddWebpage: requestAddWebpage,
                compact: true,
                store: pane.homeSearch)
        } else {
            // Keep the reader chrome as one layout unit. Returning these views
            // as separate ViewBuilder children caused the outer max-height
            // frame to expand the toolbar and viewer independently, giving the
            // toolbar roughly half of the pane.
            //
            // The chrome stays OUTSIDE the per-tab ZStack: the tab strip,
            // toolbar and find bar are pane-scoped and read the pane's active
            // projection. Only the viewer is multiplexed.
            reader(ink: activeInk ?? InkController_iOS())
        }
    }

    /// `ink` is the ACTIVE tab's controller. It is passed in rather than read
    /// here so the toolbar keeps its non-optional contract; the `??` at the call
    /// site is unreachable (this branch requires `app.document != nil`, which
    /// requires an active tab) and exists only to keep that fact local.
    @ViewBuilder
    private func reader(ink: InkController_iOS) -> some View {
            VStack(spacing: 0) {
                PdfToolbar_iOS(
                    ink: ink,
                    onOpenFile: requestOpenFile,
                    onAddWebpage: requestAddWebpage)

                if app.findVisible {
                    FindBar()
                }

                LiveTabStack_iOS(app: app)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .ignoresSafeArea(edges: .bottom)
                .overlay(alignment: .bottomTrailing) { readLaterNotice }
            }
    }

    /// Download/move progress for the read-later item this document came from,
    /// shown over the reader so a sync started elsewhere is still visible while
    /// the user is reading.
    @ViewBuilder
    private var readLaterNotice: some View {
        if let path = app.document?.pdfPath,
           let item = integrations.readLaterItem(forOpenDocumentPath: path),
           let notice = integrations.notice(forItem: item.id) {
            FloatingNotice(
                message: notice.state.message, progress: notice.state.progress,
                isActive: notice.state.isActive, isSuccess: notice.state.isSuccess,
                accessibilityID: notice.isMove ? "integrations.notice" : "integrations.downloadNotice",
                actionTitle: integrations.previousRevisionURL(for: item.id) == nil ? nil : "Open Previous",
                action: {
                    guard let url = integrations.takePreviousRevision(for: item.id) else { return }
                    Task { await app.openFile(path: url.path) }
                }
            ) {
                if notice.isMove { integrations.dismissMoveNotice(item.id) } else { integrations.dismissDownloadNotice(item.id) }
            }
            // Inset far enough to clear the ink palette's bottom-trailing well.
            .padding(.trailing, 18)
            .padding(.bottom, 96)
        }
    }

    /// File pickers and sheets are presented once, at the shell — focus this
    /// pane first so the shell routes the opened document here.
    private func requestOpenFile() {
        workspace.focus(pane.id)
        NotificationCenter.default.post(name: .vellumOpenFile, object: nil)
    }

    private func requestAddWebpage() {
        workspace.focus(pane.id)
        NotificationCenter.default.post(name: .vellumAddWebpage, object: nil)
    }

    #if DEBUG
    private func autoInkForTesting() async {
        guard ProcessInfo.processInfo.environment["VELLUM_AUTOINK"] != nil,
              app.document?.kind == .pdf else { return }
        // Wait for the viewer's load() to adopt the document (it resets
        // ink.isActive = false when it finishes, so a fixed delay races a slow
        // cold launch), then activate past that reset.
        for _ in 0..<40 where activeInk?.pdfController?.document == nil {
            try? await Task.sleep(for: .milliseconds(250))
        }
        try? await Task.sleep(for: .milliseconds(500))
        guard !Task.isCancelled else { return }
        activeInk?.isActive = true
    }
    #endif
}

// MARK: - Touch focus catcher

/// Focuses the pane on any touch-down inside its bounds without consuming the
/// touch — so the tap that selects PDF text or follows a web link also makes
/// that pane focused. The iOS analogue of the macOS `PaneFocusCatcher`: since
/// UIKit has no local event monitor, an instant, non-cancelling long-press
/// recognizer is installed on the *window* and hit-checked against this view's
/// frame; hosted PDFView/WKWebView/PKCanvasView gestures all still run.
private struct PaneFocusCatcher_iOS: UIViewRepresentable {
    let isActive: Bool
    let action: () -> Void

    func makeUIView(context: Context) -> PaneFocusUIView {
        PaneFocusUIView(action: action, isActive: isActive)
    }

    func updateUIView(_ uiView: PaneFocusUIView, context: Context) {
        uiView.action = action
        uiView.isActive = isActive
    }
}

final class PaneFocusUIView: UIView, UIGestureRecognizerDelegate {
    var action: () -> Void
    var isActive: Bool

    private var recognizer: UILongPressGestureRecognizer?

    init(action: @escaping () -> Void, isActive: Bool) {
        self.action = action
        self.isActive = isActive
        super.init(frame: .zero)
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
        }
        guard let window else { return }
        // minimumPressDuration 0 fires on touch-down; never cancels or delays
        // the touches it observes, so every other recognizer runs untouched.
        let press = UILongPressGestureRecognizer(target: self, action: #selector(touchDown(_:)))
        press.minimumPressDuration = 0
        press.cancelsTouchesInView = false
        press.delaysTouchesBegan = false
        press.delaysTouchesEnded = false
        press.delegate = self
        window.addGestureRecognizer(press)
        recognizer = press
    }

    @objc private func touchDown(_ gesture: UILongPressGestureRecognizer) {
        guard gesture.state == .began, isActive, window != nil else { return }
        let location = gesture.location(in: self)
        guard bounds.contains(location) else { return }
        action()
    }

    func gestureRecognizer(
        _ gestureRecognizer: UIGestureRecognizer,
        shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer
    ) -> Bool {
        true
    }
}
#endif
