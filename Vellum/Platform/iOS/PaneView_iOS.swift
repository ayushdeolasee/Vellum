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
    @Environment(InkRegistry_iOS.self) private var inkRegistry
    @Environment(\.palette) private var palette
    @State private var activeZone: DropZone?
    @State private var ink = InkController_iOS()

    private var app: AppStore { pane.app }
    private var isFocused: Bool { workspace.focusedPaneId == pane.id }

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
        // Window-global AI singletons the in-panel AI settings read from the
        // environment (OpenRouter catalog for the model selector, ChatGPT OAuth
        // for the sign-in control).
        .environment(workspace.openRouterCatalog)
        .environment(workspace.chatgptAuth)
        .background(PaneFocusCatcher_iOS(isActive: workspace.isSplit) {
            if !isFocused { workspace.focus(pane.id) }
        })
        .task(id: documentIdentity) { await loadDocumentState() }
        .onAppear { inkRegistry.register(ink, for: pane.id) }
        .onDisappear { inkRegistry.remove(pane.id) }
        .onReceive(NotificationCenter.default.publisher(for: .vellumAnnotationsUpdated)) { _ in
            guard app.document != nil else { return }
            Task { await pane.annotations.loadAnnotations() }
        }
        #if DEBUG
        .task(id: app.activeTabId) { await autoInkForTesting() }
        #endif
    }

    @ViewBuilder
    private var content: some View {
        if app.document == nil {
            // Active start tab: the library, inside the pane.
            WelcomeLibrary_iOS(onOpen: requestOpenFile, onAddWebpage: requestAddWebpage, compact: true)
        } else {
            PdfToolbar_iOS(ink: ink, onOpenFile: requestOpenFile, onAddWebpage: requestAddWebpage)

            if app.findVisible {
                FindBar()
            }

            documentViewer
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .ignoresSafeArea(edges: .bottom)
        }
    }

    @ViewBuilder
    private var documentViewer: some View {
        if app.document?.kind == .web {
            WebViewerView_iOS()
                .id(app.activeTabId)
        } else {
            PdfViewerView_iOS(ink: ink)
                .id(app.activeTabId)
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

    // MARK: - Per-pane document lifecycle

    private func loadDocumentState() async {
        pane.annotations.clearAnnotations()
        pane.ai.clearDocumentContext()
        pane.scratchpad.clearDocumentContext()
        guard app.document?.pdfPath != nil else { return }
        await pane.annotations.loadAnnotations()
        guard !Task.isCancelled else { return }
        pane.ai.loadConversationForDocument(app.document)
        pane.scratchpad.loadForDocument(app.document)
    }

    private var documentIdentity: PaneDocumentIdentity_iOS {
        PaneDocumentIdentity_iOS(tabId: app.activeTabId, path: app.document?.pdfPath)
    }

    #if DEBUG
    private func autoInkForTesting() async {
        guard ProcessInfo.processInfo.environment["VELLUM_AUTOINK"] != nil,
              app.document?.kind == .pdf else { return }
        // Wait for the viewer's load() to adopt the document (it resets
        // ink.isActive = false when it finishes, so a fixed delay races a slow
        // cold launch), then activate past that reset.
        for _ in 0..<40 where ink.pdfController?.document == nil {
            try? await Task.sleep(for: .milliseconds(250))
        }
        try? await Task.sleep(for: .milliseconds(500))
        guard !Task.isCancelled else { return }
        ink.isActive = true
    }
    #endif
}

private struct PaneDocumentIdentity_iOS: Hashable {
    var tabId: String?
    var path: String?
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
