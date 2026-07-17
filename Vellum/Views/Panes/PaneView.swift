import AppKit
import SwiftUI

// One leaf pane: injects its own store-triple into its subtree, renders its tab
// strip + document viewer, and hosts the per-pane document-load / autosave tasks
// that used to live on ContentView. A click anywhere in the pane focuses it (via
// a non-consuming mouse monitor, so PDF/web interaction still works).

struct PaneView: View {
    let pane: PaneModel

    @Environment(WorkspaceStore.self) private var workspace
    @Environment(\.palette) private var palette
    @State private var activeZone: DropZone?

    private var app: AppStore { pane.app }
    private var isFocused: Bool { workspace.focusedPaneId == pane.id }

    var body: some View {
        GeometryReader { geo in
            VStack(spacing: 0) {
                if !app.tabs.isEmpty {
                    TabBarView(paneId: pane.id)
                }
                content
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .clipped()
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(palette.background)
            .overlay(alignment: .topLeading) {
                // Focus ring only when the window is actually split — a lone pane
                // never needs the "which pane is active" affordance.
                if workspace.isSplit {
                    RoundedRectangle(cornerRadius: Radius.md)
                        .strokeBorder(
                            isFocused ? palette.primary.opacity(0.55) : Color.clear,
                            lineWidth: 2)
                        .allowsHitTesting(false)
                }
            }
            // Transparent drop catcher. A web pane hosts a WKWebView, which
            // registers its own dragged types and would otherwise swallow a tab
            // drop before this pane's DropDelegate sees it (a PDFView doesn't,
            // which is why splitting worked against a PDF but not another web
            // page). Floating the drop target as an overlay puts it above the
            // web content, and gating hit testing on an in-flight drag keeps
            // normal web interaction untouched the rest of the time.
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
            // Only show the drop preview while a tab is actually being dragged;
            // `draggingTab` clears reliably on mouse-up, so no highlight lingers
            // after a cancelled drag even if the DropDelegate's exit never fires.
            .overlay { DropZoneOverlay(zone: workspace.draggingTab == nil ? nil : activeZone, palette: palette) }
        }
        .environment(app)
        .environment(pane.annotations)
        .environment(pane.ai)
        .environment(pane.scratchpad)
        .background(PaneFocusCatcher(isActive: workspace.isSplit) {
            if !isFocused { workspace.focus(pane.id) }
        })
        .task(id: documentIdentity) { await loadDocumentState() }
        .task(id: autosaveIdentity) { await runAutosave() }
        .onReceive(NotificationCenter.default.publisher(for: .vellumAnnotationsUpdated)) { _ in
            guard app.document != nil else { return }
            Task { await pane.annotations.loadAnnotations() }
        }
    }

    @ViewBuilder
    private var content: some View {
        if app.document == nil {
            WelcomeScreen()
        } else if app.document?.kind == .web {
            WebViewerView()
                .id(app.activeTabId)
        } else {
            PdfViewerView()
                .id(app.activeTabId)
        }
    }

    // MARK: - Per-pane document lifecycle (moved from ContentView)

    private func loadDocumentState() async {
        pane.annotations.clearAnnotations()
        pane.ai.clearDocumentContext()
        pane.scratchpad.clearDocumentContext()
        guard let document = app.document else { return }
        await pane.annotations.loadAnnotations()
        guard !Task.isCancelled else { return }
        // In iCloud mode the document's notes/conversations may be evicted
        // placeholders — download them off-main before the sync reads below so
        // they load real bytes rather than degrading to empty.
        await DocumentDataStore.materializeIfNeeded(
            forKey: DocumentIdentity.storageKey(for: document))
        guard !Task.isCancelled else { return }
        pane.ai.loadConversationForDocument(app.document)
        pane.scratchpad.loadForDocument(app.document)
    }

    private func runAutosave() async {
        guard let identity = autosaveIdentity else { return }
        while !Task.isCancelled {
            do {
                try await Task.sleep(for: .seconds(30))
            } catch {
                return
            }
            guard !Task.isCancelled,
                  app.activeTabId == identity.tabId,
                  app.document != nil else { return }
            try? await app.sessions.saveFile(sessionId: identity.tabId)
        }
    }

    private var documentIdentity: PaneDocumentIdentity {
        PaneDocumentIdentity(tabId: app.activeTabId, path: app.document?.pdfPath)
    }

    private var autosaveIdentity: PaneAutosaveIdentity? {
        guard let tabId = app.activeTabId, app.document != nil else { return nil }
        return PaneAutosaveIdentity(tabId: tabId, path: app.document?.pdfPath)
    }
}

private struct PaneDocumentIdentity: Hashable {
    var tabId: String?
    var path: String?
}

private struct PaneAutosaveIdentity: Hashable {
    var tabId: String
    var path: String?
}

/// Invisible view that focuses the pane on any mouse-down inside its bounds
/// without consuming the event — so a click that selects PDF text or follows a
/// web link also makes that pane focused. Modeled on `MiddleClickView`.
private struct PaneFocusCatcher: NSViewRepresentable {
    let isActive: Bool
    let action: () -> Void

    func makeNSView(context: Context) -> PaneFocusNSView {
        PaneFocusNSView(action: action, isActive: isActive)
    }

    func updateNSView(_ nsView: PaneFocusNSView, context: Context) {
        nsView.action = action
        nsView.isActive = isActive
    }
}

private final class PaneFocusNSView: NSView {
    var action: () -> Void
    var isActive: Bool

    init(action: @escaping () -> Void, isActive: Bool) {
        self.action = action
        self.isActive = isActive
        super.init(frame: .zero)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private var monitor: Any?

    /// Invisible to hit testing — a local monitor observes the mouse-down.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let monitor {
            NSEvent.removeMonitor(monitor)
            self.monitor = nil
        }
        guard window != nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
            guard let self, self.isActive,
                  event.window === self.window,
                  self.bounds.contains(self.convert(event.locationInWindow, from: nil))
            else { return event }
            self.action()
            return event   // never consume — the click still reaches the viewer
        }
    }
}
