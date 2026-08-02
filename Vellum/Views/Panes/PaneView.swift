#if os(macOS)
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
                    // Feedback for read-later actions (move to folder, download
                    // errors) taken from the toolbar while this document is
                    // open — the welcome screen's own notice isn't visible then.
                    // A child view owns the store lookup so integrations churn
                    // (sync/download ticks) re-renders only the overlay, not
                    // this pane's whole body.
                    .overlay(alignment: .bottomTrailing) {
                        if app.document != nil {
                            PaneIntegrationNotice(path: app.document?.pdfPath)
                                .padding(18)
                        }
                    }
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
        .onReceive(NotificationCenter.default.publisher(for: .vellumDocumentSidecarImported)) { note in
            // A `.vellum` import merged notes/chat into documents/<key>/ on disk.
            // If THIS pane shows that document, its live scratchpad/AiStore hold
            // pre-import state whose next flush would overwrite the merge — drop
            // the AI memory cache (authoritative) and reload both stores WITHOUT
            // flushing first. A plain `loadForDocument` flushes the stale note
            // over the just-imported scratchpad.md before reading it back (the
            // mirror of the delete path below), so use discard-then-reload.
            guard let key = note.userInfo?["key"] as? String,
                  let document = app.document,
                  DocumentIdentity.storageKey(for: document) == key else { return }
            AiPersistence.invalidateCachedConversation(forKey: key)
            pane.ai.loadConversationForDocument(document)
            pane.scratchpad.discardAndReload(for: document)
        }
        .onReceive(NotificationCenter.default.publisher(for: .vellumDocumentDataDeleted)) { note in
            // The Storage pane deleted this document's notes/chat on disk. If THIS
            // pane shows it, drop the matching in-memory state WITHOUT saving so a
            // live writer's next flush can't resurrect the just-deleted file.
            guard let keys = note.userInfo?["keys"] as? [String],
                  let document = app.document else { return }
            let key = DocumentIdentity.storageKey(for: document)
            guard keys.contains(key) else { return }
            if note.userInfo?["chat"] as? Bool == true {
                // Cache already invalidated by the poster; reload re-reads the now
                // empty disk without writing.
                pane.ai.loadConversationForDocument(document)
            }
            if note.userInfo?["notes"] as? Bool == true {
                pane.scratchpad.discardNotesForExternalDelete(matchingKey: key)
            }
        }
    }

    @ViewBuilder
    private var content: some View {
        if app.tabs.isEmpty {
            // No tab at all: closing the last tab in a lone pane leaves the pane
            // open on the home screen (`AppStore.closeTab` → `paneDidEmpty`).
            // The `ForEach` below would render an empty ZStack here, so this
            // case has to be spelled out — there is no tab to host it.
            WelcomeScreen(isPaneFocused: isFocused)
        } else {
            ZStack {
                ForEach(app.tabs) { tab in
                    LiveTabHost(
                        tabId: tab.id,
                        document: tab.document,
                        isActive: tab.id == app.activeTabId,
                        isPaneFocused: isFocused,
                        runtime: workspace.liveTabRuntime(for: tab.id)
                    )
                    .opacity(tab.id == app.activeTabId ? 1 : 0)
                    .allowsHitTesting(tab.id == app.activeTabId)
                    .accessibilityHidden(tab.id != app.activeTabId)
                    .zIndex(tab.id == app.activeTabId ? 1 : 0)
                }
            }
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
        if let tabId = app.activeTabId,
           let runtime = workspace.existingLiveTabRuntime(for: tabId) {
            pane.ai.restorePageTexts(runtime.pageTexts)
        }
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

/// Stable identity for one tab's expensive native viewer. Inactive hosts stay
/// mounted (and therefore keep PDFKit/WKWebView/Home transient state) while
/// becoming visually and interactively inert. The document value may change
/// in-place when a start tab adopts an opened file; keying by tab id preserves
/// the tab identity across that transition.
private struct LiveTabHost: View {
    let tabId: String
    let document: DocumentInfo?
    let isActive: Bool
    /// Whether the *pane* is the focused one. Only ever passed on to the home
    /// screen, ANDed with `isActive` — see the start-tab branch in `body`.
    let isPaneFocused: Bool
    let runtime: LiveTabRuntime
    @Environment(WorkspaceStore.self) private var workspace

    /// The active tab always renders, whatever the policy currently thinks —
    /// `body` runs before the `.task` below has had a chance to promote it, and
    /// the tab the user just clicked must never be the one we decline to draw.
    private var shouldRender: Bool { isActive || runtime.isRendered }

    var body: some View {
        Group {
            // `document != nil` matters: a start tab's runtime can be evicted
            // like any other, but it has nothing to restore, and flashing
            // "Restoring tab…" over the home screen for the frame before the
            // `.task` below reactivates it would read as a bug.
            if runtime.isEvicted, document != nil {
                if isActive {
                    VStack(spacing: 8) {
                        ProgressView()
                        Text("Restoring tab…")
                            .foregroundStyle(.secondary)
                    }
                } else {
                    Color.clear
                }
            } else if !shouldRender {
                // WARM. The tab's `PDFView`/`WKWebView` are alive on its runtime,
                // but nothing here holds them, so they leave the window's layout
                // and display cycle entirely — no draw, no tile work, no
                // relayout on a window resize. Coming back re-parents the same
                // native view (`PdfKitView.makeNSView` returns the retained
                // `PDFView`; `WebViewerController.attach` takes its
                // already-attached branch and never reloads), so the restore is
                // a re-parent rather than a parse or a network fetch.
                //
                // This host itself stays mounted so the `.task` below still runs
                // and can promote the tab back to hot the moment it is selected.
                Color.clear
            } else if let document {
                if document.kind == .web {
                    WebViewerView(
                        tabId: tabId, document: document, isActive: isActive,
                        runtime: runtime)
                } else {
                    PdfViewerView(
                        tabId: tabId, documentInfo: document, isActive: isActive,
                        runtime: runtime)
                }
            } else {
                // A start tab. `isPaneFocused` is what stops an *invisible* home
                // screen from taking the keyboard: hosts stay mounted here, so a
                // pane can have several start tabs alive at once, and the home
                // screen both grabs first responder on appear and registers ⌘F.
                // Opacity and hit-testing do not suppress either of those, so the
                // claim has to be gated on being the selected tab as well as
                // being in the focused pane — one claimant per window, exactly as
                // the two-pane case already required.
                WelcomeScreen(isPaneFocused: isPaneFocused && isActive)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task(id: isActive) {
            guard isActive else { return }
            // Hand the runtime to the residency policy. Reclaiming it later is
            // entirely that policy's job (Services/TabResidency.swift): a single
            // shared sweeper applies the hot/warm/cold windows and the ceilings,
            // and a memory-pressure source can pull the trigger early.
            //
            // Deliberately NOT a per-tab `Task.sleep` here. A view-owned timer is
            // one wakeup per inactive tab, it dies silently whenever the host
            // unmounts (a tab dragged to another pane would never be reclaimed at
            // all), it has no ceiling and no pressure valve, and there is no way
            // to test a 30-minute boundary without waiting 30 minutes.
            workspace.activateLiveTabRuntime(runtime)
        }
    }
}

private struct PaneDocumentIdentity: Hashable {
    var tabId: String?
    var path: String?
}

/// Floating notice for the read-later item behind the open document (move
/// confirmations/errors, download progress). Owns the integrations-store
/// lookup so only this small view re-renders on store churn.
private struct PaneIntegrationNotice: View {
    let path: String?

    @Environment(IntegrationsStore.self) private var integrations

    var body: some View {
        if let item = integrations.readLaterItem(forOpenDocumentPath: path),
           let notice = integrations.notice(forItem: item.id) {
            FloatingNotice(
                message: notice.state.message, progress: notice.state.progress,
                isActive: notice.state.isActive, isSuccess: notice.state.isSuccess,
                accessibilityID: notice.isMove ? "integrations.notice" : "integrations.downloadNotice"
            ) {
                if notice.isMove { integrations.dismissMoveNotice(item.id) } else { integrations.dismissDownloadNotice(item.id) }
            }
        }
    }
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
#endif  // os(macOS) — iPad pane view: Platform/iOS/PaneView_iOS.swift
