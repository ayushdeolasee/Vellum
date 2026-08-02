#if os(iOS)
import SwiftUI

// The multiplexed live-tab viewer stack, shared by every iOS shell. Extracted
// verbatim from `PaneView_iOS` so the phone reader mounts the SAME stack the
// iPad pane does (issue #153, D7) rather than a single viewer keyed on
// `activeTabId` — the eviction/warm/hot states below are what make tab
// switching instant, and a second copy of them would drift.

/// Renders one host per tab, all mounted at once, with only the active one
/// visible and interactive. The caller owns the surrounding frame, safe-area
/// and overlay decisions; this view is only the stack.
struct LiveTabStack_iOS: View {
    let app: AppStore

    @Environment(WorkspaceStore.self) private var workspace

    var body: some View {
        ZStack {
            ForEach(app.tabs) { tab in
                LiveTabHost_iOS(
                    tabId: tab.id,
                    document: tab.document,
                    isActive: tab.id == app.activeTabId,
                    runtime: workspace.liveTabRuntime(for: tab.id))
                    .opacity(tab.id == app.activeTabId ? 1 : 0)
                    .allowsHitTesting(tab.id == app.activeTabId)
                    .accessibilityHidden(tab.id != app.activeTabId)
                    .zIndex(tab.id == app.activeTabId ? 1 : 0)
            }
        }
    }
}

/// Stable identity for one tab's expensive native viewer. Inactive hosts stay
/// mounted (and therefore keep PDFKit / WKWebView state) while becoming
/// visually and interactively inert. The document value may change in place
/// when a start tab adopts an opened file; keying by tab id preserves the tab
/// identity across that transition.
private struct LiveTabHost_iOS: View {
    let tabId: String
    let document: DocumentInfo?
    let isActive: Bool
    let runtime: LiveTabRuntime

    @Environment(WorkspaceStore.self) private var workspace

    /// The active tab always renders, whatever the policy currently thinks —
    /// `body` runs before the `.task` below has had a chance to promote it, and
    /// the tab the user just tapped must never be the one we decline to draw.
    private var shouldRender: Bool { isActive || runtime.isRendered }

    var body: some View {
        Group {
            // `document != nil` matters: a start tab's runtime can be evicted
            // like any other, but it has nothing to restore, and flashing
            // "Restoring tab…" for the frame before the `.task` below
            // reactivates it would read as a bug.
            if runtime.isEvicted, document != nil {
                if isActive {
                    VStack(spacing: 8) {
                        ProgressView()
                        Text("Restoring tab…").foregroundStyle(.secondary)
                    }
                } else {
                    Color.clear
                }
            } else if !shouldRender {
                // WARM. The tab's PDFView/WKWebView are alive on its runtime,
                // but nothing here holds them, so they leave the window's
                // layout and display cycle entirely — no draw, no tile work, no
                // relayout on a rotation. Coming back RE-PARENTS the same
                // native view (`PdfKitView_iOS.makeUIView` adopts the retained
                // PDFView; `WebViewerController_iOS.attach` takes its
                // already-attached branch and never reloads), so the restore is
                // a re-parent rather than a parse or a network fetch.
                //
                // This host itself stays mounted so the `.task` below still runs
                // and can promote the tab back to hot the moment it is selected.
                Color.clear
            } else if let document {
                if document.kind == .web {
                    WebViewerView_iOS(
                        tabId: tabId, document: document, isActive: isActive, runtime: runtime)
                } else {
                    PdfViewerView_iOS(
                        tabId: tabId, documentInfo: document, isActive: isActive, runtime: runtime)
                }
            } else {
                // A start tab. Its home surface is the pane-wide library (see
                // `PaneView_iOS.content`), so there is nothing tab-scoped to
                // draw here.
                Color.clear
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task(id: isActive) {
            guard isActive else { return }
            workspace.activateLiveTabRuntime(runtime)
        }
    }
}

struct PaneDocumentIdentity_iOS: Hashable {
    var tabId: String?
    var path: String?
}
#endif
