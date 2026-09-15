#if os(iOS)
import Observation
import PencilKit
import SwiftUI
import UIKit
import WebKit
import os

// Web-ink counterpart of `InkController_iOS`: owns the overlay canvas and the
// activation lifecycle for Pencil ink on web pages, sharing the palette state
// (`InkToolState`) and the palette surface (`InkPaletteHost`) with the PDF
// controller so `InkToolPalette_iOS` renders either untouched. Durable
// persistence is `WebInkPersister` below (debounce, on the main actor) backed
// by the `WebInkIO` actor in `WebInkStore.swift` (all file I/O off-main).

/// Persistence seam for web ink. The interactive core hands every edit here as
/// a full drawing in layout-CSS-pixel document space (decision 3's stored
/// space — the canvas draws in it directly under viewScale)
/// plus the layout fingerprint it was drawn against; debounce, atomic writes,
/// and path resolution are the implementation's concern
/// (`WebInkPersister`/`WebInkIO`).
@MainActor
protocol WebInkPersisting: AnyObject {
    /// Load the current sidecar off-main. Test doubles may return nil when they
    /// only capture controller output.
    func loadRecord() async -> WebInkRecord?
    /// Record the full snapshot that was actually seeded into this runtime.
    /// Future full-canvas writes are diffed against it so another runtime's
    /// concurrent changes are preserved.
    func seedBaseline(_ record: WebInkRecord)
    /// The latest complete drawing, zoom-1 CSS-px document space. `anchorFor`
    /// supplies each derived cluster's text anchor from its document bounds
    /// (Phase 3) — called synchronously while the record is built.
    func drawingChanged(
        _ drawing: PKDrawing,
        layout: WebInkRecord.Layout,
        anchorFor: (CGRect) -> WebInkRecord.Anchor?)
    /// Write any pending debounced state now and wait until it is durable —
    /// called when ink mode turns off, on tab close, and from the
    /// scene-background flush (mirrors the PDF `flushPendingInkAndWait`).
    @discardableResult
    func flushPendingInkAndWait() async -> Bool
}

extension WebInkPersisting {
    func loadRecord() async -> WebInkRecord? { nil }
    func seedBaseline(_ record: WebInkRecord) {}

    /// Anchorless convenience (tests, clear paths).
    func drawingChanged(_ drawing: PKDrawing, layout: WebInkRecord.Layout) {
        drawingChanged(drawing, layout: layout, anchorFor: { _ in nil })
    }
}

/// One outgoing document's joinable flush. A successful attempt lets the
/// controller discard the persister; a failed attempt leaves this entry intact
/// for the next background/teardown barrier.
@MainActor
private final class WebInkFlushEntry {
    let persistence: any WebInkPersisting
    private var task: Task<Bool, Never>?
    private var completedResult: Bool?

    init(_ persistence: any WebInkPersisting) {
        self.persistence = persistence
    }

    func start() {
        guard task == nil else { return }
        completedResult = nil
        let persistence = persistence
        task = Task {
            let succeeded = await persistence.flushPendingInkAndWait()
            self.completedResult = succeeded
            self.task = nil
            return succeeded
        }
    }

    func joinOrRetry() async -> Bool {
        if completedResult == true { return true }
        if let task { return await task.value }
        start()
        guard let task else { return true }
        return await task.value
    }
}

/// Owns Pencil ink state for a web document: the viewport-mounted overlay
/// canvas (`WebInkOverlay_iOS`), the modal activation lifecycle, and the
/// persistence hand-off. One instance per live tab, retained beside that tab's
/// WKWebView so remounting the tab does not reset its drawing or anchor state.
@MainActor
@Observable
final class WebInkController_iOS: InkPaletteHost {
    /// Anchor capture / re-anchor diagnostics — `log stream --predicate
    /// 'category == "web-ink"'` (or the simulator console) shows what each
    /// zoom reflow resolved and applied.
    static let log = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "Vellum", category: "web-ink")

    /// Shared palette state (tool/color/width/eraser/finger-toggle/double-tap);
    /// width settings persist through the same UserDefaults blob the PDF
    /// controller uses, so the palettes stay in sync across document kinds.
    @ObservationIgnored let toolState = InkToolState()

    var isActive = false {
        didSet {
            guard oldValue != isActive else { return }
            if isActive {
                // Ink mode is modal (decision 10): entering it dismisses the
                // selection/note popovers — they anchor to page rects the
                // canvas is about to sit over — and auto-collapses the
                // inspector sidebar for a full-width palette, exactly like the
                // PDF controller (same user preference).
                webController?.clearSelection()
                webController?.closeNotePopovers()
                if InkController_iOS.autoHideSidebarWhileInking {
                    sidebarWasOpen = app?.workspace?.sidebarOpen ?? false
                    app?.workspace?.sidebarOpen = false
                }
            } else {
                // Turning ink off can't lose the last stroke: hand any pending
                // debounced ink to the writer right now.
                flushPendingInk()
                if sidebarWasOpen {
                    sidebarWasOpen = false
                    app?.workspace?.sidebarOpen = true
                }
            }
            overlay?.refreshPolicy()
        }
    }
    /// Whether the inspector sidebar was open when inking began, so Done can
    /// restore it.
    @ObservationIgnored private var sidebarWasOpen = false

    @ObservationIgnored weak var app: AppStore?
    /// The mounted web viewer — ink activation dismisses its popovers.
    @ObservationIgnored weak var webController: WebViewerController_iOS?
    /// Durable-write seam for the current document (swapped by
    /// `documentOpened`; a test can inject a capture double).
    @ObservationIgnored var persistence: (any WebInkPersisting)?
    /// Production creates `WebInkPersister`; tests inject controlled async
    /// loaders to exercise navigation ordering without timing sleeps.
    @ObservationIgnored var persistenceFactory: (String) -> any WebInkPersisting = {
        WebInkPersister(url: $0)
    }
    /// The normalized URL whose ink is currently loaded into the canvas — the
    /// once-per-document guard for `documentOpened` (init re-reports on
    /// hydration and soft navigation).
    @ObservationIgnored private var loadedUrl: String?
    /// A sidecar that finished loading before SwiftUI mounted this tab's
    /// PencilKit overlay. Kept until `attachOverlay` can seed the canvas.
    @ObservationIgnored private var pendingLoadedRecord: WebInkRecord?
    /// Changes on every real open/navigation (and detach). URL equality alone
    /// cannot distinguish A(first) → B → A(second), so async load completions
    /// also have to match this generation before touching the canvas.
    @ObservationIgnored private var openGeneration = 0
    /// Outgoing-document persisters remain joinable after `persistence` is
    /// swapped to the new URL. Successful entries are removed; failures stay
    /// here for a later background/teardown barrier retry.
    @ObservationIgnored private var supersededFlushes: [WebInkFlushEntry] = []

    /// A captured cluster anchor plus the cluster bounds it was captured (or
    /// last re-anchored) against. Clusters are re-derived on every snapshot,
    /// so cache matching is spatial — a cluster inherits the entry whose
    /// bounds it overlaps most.
    private struct AnchorEntry {
        var bounds: CGRect
        var anchor: WebInkRecord.Anchor
    }

    /// Known anchors for the current document's clusters (zoom-1 CSS px).
    /// Seeded from the sidecar on load, extended by async captures on stroke
    /// commit, and kept fresh (rects + bounds) by each re-anchor pass.
    @ObservationIgnored private var anchorCache: [AnchorEntry] = []
    /// One anchor capture currently crossing the native↔JS bridge. Both
    /// generations are part of its identity: a Pencil drawing can change while
    /// capture is suspended, and toolbar zoom can reflow the DOM while the same
    /// request is in flight. Only a result measured for the exact drawing and
    /// layout that requested it may enter `anchorCache`.
    private struct AnchorRequestInFlight {
        var bounds: CGRect
        var drawingGeneration: Int
        var layoutGeneration: Int
    }
    @ObservationIgnored private var anchorRequestsInFlight: [AnchorRequestInFlight] = []
    /// Bumped before every possible DOM-layout shift. This is deliberately
    /// separate from `drawingVersion`: toolbar zoom changes no PKDrawing bytes,
    /// while a live Pencil stroke changes no DOM geometry.
    @ObservationIgnored private var anchorLayoutGeneration = 0
    /// The active re-anchor settle sequence (immediate + 400 ms + 1200 ms
    /// re-checks); superseded wholesale by each new shift signal.
    @ObservationIgnored private var reanchorTask: Task<Void, Never>?

    /// The live overlay for the currently mounted web view (nil between
    /// mounts). Owned strongly here — the hosting view keeps it in its
    /// hierarchy, the controller keeps it alive and drives its state.
    @ObservationIgnored private(set) var overlay: WebInkOverlay_iOS?
    /// The retained WKWebView the overlay observes. Weak because the tab's web
    /// controller is its owner; this only distinguishes a remount from a real
    /// web-view replacement.
    @ObservationIgnored private weak var overlayWebView: WKWebView?

    /// Bumped on every drawing mutation so undo/redo button state re-renders
    /// (UndoManager itself is not observable).
    private(set) var drawingVersion = 0

    init() {
        // Route palette-state side effects into the live canvas.
        toolState.onToolChanged = { [weak self] in self?.overlay?.applyTool() }
        toolState.onPolicyChanged = { [weak self] in self?.overlay?.refreshPolicy() }
    }

    // MARK: - Overlay lifecycle

    /// Return the overlay for this tab's retained web view. A SwiftUI remount
    /// only reparents the existing overlay; a genuine web-view replacement
    /// tears the old observers down and creates a fresh overlay.
    func attachOverlay(to webView: WKWebView) -> WebInkOverlay_iOS {
        if let overlay, overlayWebView === webView {
            overlay.removeFromSuperview()
            overlay.applyTool()
            overlay.refreshPolicy()
            applyPendingLoadedRecordIfPossible()
            return overlay
        }
        detachOverlay()
        let overlay = WebInkOverlay_iOS(webView: webView)
        overlay.ink = self
        self.overlay = overlay
        overlayWebView = webView
        overlay.applyTool()
        overlay.refreshPolicy()
        applyPendingLoadedRecordIfPossible()
        return overlay
    }

    /// Tear down the current overlay (viewer unmounted or replaced — tab close
    /// and tab switch both come through here). Exits ink mode first so the
    /// sidebar restore/flush side effects run while the overlay still exists,
    /// then kicks an explicit flush for the ink-was-already-off case.
    func detachOverlay() {
        guard let overlay else { return }
        isActive = false
        flushPendingInk()
        loadedUrl = nil
        pendingLoadedRecord = nil
        openGeneration &+= 1
        resetAnchorState()
        overlay.teardown()
        self.overlay = nil
        overlayWebView = nil
    }

    // MARK: - Document lifecycle (load + persistence binding)

    /// The web document reported in (`handleInit` bumped `initCount`): bind the
    /// persister for its URL and seed the canvas with any stored ink. Ignores
    /// repeat inits for the same document (hydration re-extraction); an in-tab
    /// navigation flushes the outgoing document's pending ink and resets the
    /// canvas before the incoming document's ink loads.
    @discardableResult
    func documentOpened(url: String?) -> Task<Void, Never>? {
        guard let rawURL = url, !rawURL.isEmpty else { return nil }
        let url = (try? WebUrl.normalize(rawURL)) ?? rawURL
        guard url != loadedUrl else { return nil }
        openGeneration &+= 1
        let generation = openGeneration
        pendingLoadedRecord = nil
        if let previous = persistence {
            let flush = WebInkFlushEntry(previous)
            supersededFlushes.append(flush)
            flush.start()
        }
        if loadedUrl != nil {
            // In-tab navigation reuses the mounted overlay: the outgoing
            // page's strokes must not bleed onto (or get saved under) the
            // incoming document.
            overlay?.setDrawing(PKDrawing())
            drawingVersion &+= 1
        }
        loadedUrl = url
        resetAnchorState()
        let persister = persistenceFactory(url)
        persistence = persister
        return Task { [weak self] in
            guard let record = await persister.loadRecord() else { return }
            guard let self,
                  self.openGeneration == generation,
                  self.loadedUrl == url,
                  self.persistence === persister else { return }
            persister.seedBaseline(record)
            self.pendingLoadedRecord = record
            self.applyPendingLoadedRecordIfPossible()
        }
    }

    /// Apply a completed sidecar load once the retained tab's overlay exists.
    /// SwiftUI may deliver the page-init callback before `makeUIView` mounts
    /// the PencilKit view when several tabs are restored together; consuming
    /// the record only here prevents that ordering from dropping visible ink.
    private func applyPendingLoadedRecordIfPossible() {
        guard let record = pendingLoadedRecord, let overlay else { return }
        pendingLoadedRecord = nil
        let restored = record.mergedDrawing()
        let derivedClusters = WebInkClustering.clusters(of: restored)
        if record.version >= WebInkRecord.currentVersion {
            // Seed only one-to-one stored anchors. A malformed/imported
            // record can still contain one tall cluster spanning several
            // text rows; sharing its anchor across every resulting row
            // would make those rows move rigidly during toolbar reflow.
            anchorCache = record.clusters.compactMap { stored in
                guard let anchor = stored.anchor else { return nil }
                let matches = derivedClusters.filter {
                    $0.bounds.intersects(stored.bounds.rect)
                }
                guard matches.count == 1 else {
                    Self.log.debug(
                        "anchor migration: split stored cluster into \(matches.count) line clusters")
                    return nil
                }
                return AnchorEntry(bounds: matches[0].bounds, anchor: anchor)
            }
        } else {
            // Older records either used broad/point-scored clusters (v1)
            // or allowed an anchor capture to outlive its drawing/layout
            // generation (v2). Recapture every derived row against the
            // stable current DOM.
            anchorCache = []
            Self.log.debug(
                "anchor migration: recapturing version \(record.version) sidecar as version \(WebInkRecord.currentVersion)")
        }
        guard !restored.strokes.isEmpty else { return }
        // Stored ink is CSS px — exactly the canvas's own space; the
        // overlay's zoomScale transform handles any current zoom.
        let current = overlay.canvas.drawing
        if current.strokes.isEmpty {
            overlay.setDrawing(restored)
            drawingVersion &+= 1
        } else {
            // Merge, don't replace: a stroke made before the (async) load
            // finished must survive the seeding — and the merged drawing is
            // re-reported so the pending record includes the restored ink
            // (its stroke-only record would otherwise overwrite the file).
            let merged = current.appending(restored)
            overlay.setDrawing(merged)
            drawingChanged(merged)
        }
        // This also migrates legacy multi-row clusters and fills anchors
        // for old anchorless records. Capture runs against the live layout,
        // then re-snapshots with one independently movable cluster per row.
        captureMissingAnchors(for: overlay.canvas.drawing)
        // The live layout may differ from the one the ink was stored
        // against (hydration since save, different fonts, width change):
        // re-anchor immediately, then re-check as layout settles.
        anchorsShifted()
    }

    // MARK: - Zoom (decision 3)

    /// Toolbar zoom changed (the same `.onChange(of: app.zoom)` hook that
    /// applies viewScale to the web view). Stroke coordinates are layout CSS
    /// px at every zoom — the overlay's `zoomScale` KVO carries the visual
    /// scale — so no geometric rescale happens here. What zoom *does* change
    /// is the layout: the CSS viewport width shrinks/grows and text re-wraps,
    /// so kick the re-anchor settle pass to move clusters with their
    /// paragraphs (the content script's resize relayout reports the same
    /// signal; `anchorsShifted` supersedes/coalesces).
    func zoomChanged(_ newZoom: Double) {
        Self.log.debug("zoomChanged \(newZoom, format: .fixed(precision: 2)) -> reanchor settle")
        anchorsShifted()
    }

    /// The active PencilKit tool. Widths are in CSS px; the overlay's view
    /// transform magnifies them together with the page at any zoom.
    func pkTool() -> PKTool { toolState.pkTool(widthScale: 1) }

    /// Apple Pencil double-tap (delivered via the `UIPencilInteraction` on the
    /// web container): delegated to the shared tool state.
    func pencilDoubleTap(preferredAction: UIPencilPreferredAction) {
        toolState.pencilDoubleTap(preferredAction: preferredAction)
    }

    // MARK: - Reflow anchors (Phase 3, decision 8)

    private func resetAnchorState() {
        anchorCache = []
        anchorRequestsInFlight = []
        anchorLayoutGeneration &+= 1
        reanchorTask?.cancel()
        reanchorTask = nil
    }

    /// The cached anchor for a cluster with these document bounds, if any —
    /// the `anchorFor` hook every record snapshot runs through.
    private func anchorForCluster(_ bounds: CGRect) -> WebInkRecord.Anchor? {
        anchorEntryIndex(for: bounds).map { anchorCache[$0].anchor }
    }

    /// Spatial cache match: the entry whose bounds overlap the cluster's the
    /// most. Erase-splits and grown clusters keep inheriting the original
    /// anchor this way; a genuinely new cluster matches nothing.
    private func anchorEntryIndex(for bounds: CGRect) -> Int? {
        var best: (index: Int, area: CGFloat)?
        for (index, entry) in anchorCache.enumerated() where entry.bounds.intersects(bounds) {
            let overlap = entry.bounds.intersection(bounds)
            let area = overlap.width * overlap.height
            if best == nil || area > best!.area { best = (index, area) }
        }
        return best?.index
    }

    /// Ask the content script for anchors for clusters that don't have one
    /// yet (fresh strokes in a new spot). Results extend the cache and the
    /// record is re-reported so the pending write picks the anchors up —
    /// the 700 ms debounce coalesces this with the stroke that caused it.
    private func captureMissingAnchors(for normalized: PKDrawing) {
        guard let webController, let url = loadedUrl else { return }
        let drawingGeneration = drawingVersion
        let layoutGeneration = anchorLayoutGeneration
        let missing = WebInkClustering.clusters(of: normalized).map(\.bounds).filter { bounds in
            anchorEntryIndex(for: bounds) == nil
                && !anchorRequestsInFlight.contains {
                    $0.drawingGeneration == drawingGeneration
                        && $0.layoutGeneration == layoutGeneration
                        && $0.bounds.intersects(bounds)
                }
        }
        guard !missing.isEmpty else { return }
        anchorRequestsInFlight.append(contentsOf: missing.map {
            AnchorRequestInFlight(
                bounds: $0,
                drawingGeneration: drawingGeneration,
                layoutGeneration: layoutGeneration)
        })
        // Send the cluster's full band: vertical geometry distinguishes an
        // underline from a circle/strike, while horizontal overlap breaks the
        // tie when a boundary-adjacent stroke touches two text rows.
        let points = missing.enumerated().map { index, bounds in
            WebInkAnchorPoint(
                id: "c\(index)",
                x: bounds.midX,
                y: bounds.minY,
                bottom: bounds.maxY,
                left: bounds.minX,
                right: bounds.maxX)
        }
        Task { [weak self] in
            let anchors = await webController.captureInkAnchors(points)
            guard let self else { return }
            self.anchorRequestsInFlight.removeAll {
                $0.drawingGeneration == drawingGeneration
                    && $0.layoutGeneration == layoutGeneration
                    && missing.contains($0.bounds)
            }
            // Actor reentrancy rule: every assumption made before the bridge
            // await must be revalidated. A stale result is worse than no anchor
            // because it becomes durable and moves the stroke toward the wrong
            // text on every later toolbar zoom.
            guard !Task.isCancelled,
                  self.loadedUrl == url,
                  self.drawingVersion == drawingGeneration,
                  self.anchorLayoutGeneration == layoutGeneration else { return }
            var added = false
            for (index, bounds) in missing.enumerated() {
                guard let anchor = anchors["c\(index)"] else {
                    Self.log.debug(
                        "anchor capture: cluster y=\(bounds.minY, format: .fixed(precision: 1))..\(bounds.maxY, format: .fixed(precision: 1)) UNRESOLVED")
                    continue
                }
                Self.log.debug(
                    "anchor capture: cluster y=\(bounds.minY, format: .fixed(precision: 1))..\(bounds.maxY, format: .fixed(precision: 1)) -> text y=\(anchor.rect.y, format: .fixed(precision: 1)) h=\(anchor.rect.h, format: .fixed(precision: 1)) \"\(String((anchor.text ?? "").prefix(40)), privacy: .public)\"")
                self.anchorCache.append(AnchorEntry(bounds: bounds, anchor: anchor))
                added = true
            }
            // New anchors change the sidebar Handwriting jump list — bump the
            // observable version so it recomputes (anchorCache is not observed).
            if added { self.drawingVersion &+= 1 }
            guard added, let overlay = self.overlay else { return }
            self.persistence?.drawingChanged(
                overlay.canvas.drawing, layout: self.zoom1Layout,
                anchorFor: { self.anchorForCluster($0) })
        }
    }

    /// The content script reported a layout shift (relayout hooks, SPA
    /// re-render, hydration settle) — or the document just (re)loaded. Run a
    /// re-anchor pass now and re-check as layout settles, the same 400 ms /
    /// 1200 ms cadence the scroll-restore settle machinery uses.
    func anchorsShifted() {
        anchorLayoutGeneration &+= 1
        reanchorTask?.cancel()
        reanchorTask = Task { [weak self] in
            await self?.reanchorAndCapturePass()
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled else { return }
            await self?.reanchorAndCapturePass()
            try? await Task.sleep(for: .milliseconds(800))
            guard !Task.isCancelled else { return }
            await self?.reanchorAndCapturePass()
        }
    }

    /// Re-anchor known clusters, then capture any clusters whose older request
    /// was invalidated by this layout shift. Keeping the retry in the settle
    /// sequence is what makes "finish a stroke → immediately tap Zoom" safe:
    /// the pre-zoom capture is rejected and the post-reflow layout gets a fresh
    /// request without waiting for another user edit.
    private func reanchorAndCapturePass() async {
        await reanchorPass()
        guard !Task.isCancelled,
              let overlay,
              !overlay.isToolInUse else { return }
        let drawing = overlay.canvas.drawing
        captureMissingAnchors(for: drawing)
    }

    /// Batch-resolve every anchored cluster's anchor against the current DOM
    /// and TRANSLATE each cluster by (new rect − captured rect). Unresolvable
    /// anchors leave their cluster at its stored coordinates (fallback).
    /// Skipped mid-stroke and aborted when the drawing or zoom changed while
    /// the resolve round trip was in flight.
    private func reanchorPass() async {
        guard let overlay, let webController, loadedUrl != nil else { return }
        guard !overlay.isToolInUse, !anchorCache.isEmpty else { return }
        let live = overlay.canvas.drawing
        guard !live.strokes.isEmpty else { return }
        let clusters = WebInkClustering.clusters(of: live)

        // Snapshot the cache match per cluster BEFORE any mutation: split
        // clusters can share one entry, and each must translate against the
        // same captured rect.
        var cacheIndexByCluster: [Int?] = []
        var queries: [WebInkAnchorQuery] = []
        for (index, cluster) in clusters.enumerated() {
            let match = anchorEntryIndex(for: cluster.bounds)
            cacheIndexByCluster.append(match)
            if let match {
                queries.append(WebInkAnchorQuery(id: "r\(index)", anchor: anchorCache[match].anchor))
            }
        }
        guard !queries.isEmpty else { return }

        let versionBefore = drawingVersion
        let layoutBefore = anchorLayoutGeneration
        let resolved = await webController.resolveInkAnchors(queries)
        // `anchorsShifted` cancels an older settle task whenever another zoom
        // step or layout signal supersedes it. The JS continuation itself is
        // not cancellation-aware, so explicitly reject its now-stale result
        // before it can translate strokes using an intermediate zoom layout.
        guard !Task.isCancelled else { return }
        // Same identity check the capture path makes. Cancellation alone would
        // cover today's shift signals (all of them cancel the settle task), but
        // it silently depends on every future one remembering to; the
        // generation is the actual invariant — a rect measured against a
        // superseded layout must never become a translation.
        guard anchorLayoutGeneration == layoutBefore else { return }
        guard !resolved.isEmpty else { return }
        // The user drew/erased while resolving: the clusters no longer
        // describe the canvas — drop this pass, the next shift signal (or
        // settle re-check) reruns it. This is also what makes the wholesale
        // cache replace below safe: the only path that grows `anchorCache`
        // mid-await (a capture landing) bumps `drawingVersion` too, so its
        // entries can never be dropped by a pass that is still running.
        guard let overlay = self.overlay, !overlay.isToolInUse,
              drawingVersion == versionBefore else { return }

        var deltas: [CGVector?] = []
        for (index, _) in clusters.enumerated() {
            guard let cacheIndex = cacheIndexByCluster[index],
                  let newRect = resolved["r\(index)"] else {
                deltas.append(nil)
                continue
            }
            let old = anchorCache[cacheIndex].anchor.rect
            deltas.append(CGVector(dx: newRect.minX - old.x, dy: newRect.minY - old.y))
        }
        let (rebuilt, moved) = WebInkClustering.translated(clusters, by: deltas)

        // REBUILD the cache one entry per live cluster against the resolved
        // layout. Mutating entries in place was wrong whenever two clusters
        // matched the same entry — an erase split, or two rows the proximity
        // pass had merged and this reflow pulled apart: each cluster wrote
        // `entry.bounds` in turn, so only the last one still overlapped its
        // entry and the others silently went unanchored. An unanchored cluster
        // stops translating, so it freezes on the page while its neighbours
        // follow the text — visually, ink "moving" on zoom. Rebuilding also
        // drops entries no live cluster matches, the orphan leak `drawingChanged`
        // only handles for a fully emptied canvas.
        var refreshed: [AnchorEntry] = []
        for (index, cluster) in clusters.enumerated() {
            guard let cacheIndex = cacheIndexByCluster[index] else { continue }
            var entry = anchorCache[cacheIndex]
            if let newRect = resolved["r\(index)"], let delta = deltas[index] {
                // Only consume the delta when the cluster actually moved.
                // `translated` skips sub-half-pixel deltas as measurement noise;
                // overwriting the cached rect anyway would silently absorb that
                // residual every settle pass, accumulating drift the threshold
                // was meant to suppress. Size still refreshes (rect
                // height/width may legitimately change on reflow).
                if WebInkClustering.exceedsTranslationThreshold(delta) {
                    Self.log.debug(
                        "reanchor: cluster \(index) moved dx=\(delta.dx, format: .fixed(precision: 1)) dy=\(delta.dy, format: .fixed(precision: 1)) -> rect y=\(newRect.minY, format: .fixed(precision: 1))")
                    entry.anchor.rect = WebInkRecord.Bounds(newRect)
                    entry.bounds = cluster.bounds.offsetBy(dx: delta.dx, dy: delta.dy)
                } else {
                    entry.anchor.rect.w = Double(newRect.width)
                    entry.anchor.rect.h = Double(newRect.height)
                    entry.bounds = cluster.bounds
                }
            } else {
                // Unresolved this pass: keep the captured rect so a later pass
                // still measures the FULL displacement, but track where the
                // cluster actually sits so the spatial match keeps finding it.
                entry.bounds = cluster.bounds
            }
            refreshed.append(entry)
        }
        anchorCache = refreshed

        guard moved else { return }
        overlay.setDrawing(rebuilt)
        drawingVersion &+= 1
        persistence?.drawingChanged(
            rebuilt, layout: zoom1Layout, anchorFor: { anchorForCluster($0) })
    }

    // MARK: - Sidebar Handwriting jump list (Phase 4)

    /// One inked cluster surfaced in the sidebar's "Handwriting" section: a
    /// virtual page (from its anchor's `start_offset`) and enough anchor context
    /// to scroll back to the cluster's text. Only anchored clusters appear —
    /// the page number comes from the anchor.
    struct InkJump: Identifiable, Equatable {
        var id: String
        var page: Int
        /// Document-space Y (zoom-1 CSS px), for stable ordering.
        var docY: CGFloat
        var anchor: WebInkRecord.Anchor
    }

    /// The current inked clusters mapped to virtual pages, ordered top-to-bottom
    /// down the document. Recomputed on every drawing/anchor change (tied to
    /// `drawingVersion`, which the anchor-capture and re-anchor paths bump).
    var inkJumps: [InkJump] {
        _ = drawingVersion
        guard let overlay else { return [] }
        let drawing = overlay.canvas.drawing
        guard !drawing.strokes.isEmpty else { return [] }
        var jumps: [InkJump] = []
        for (index, cluster) in WebInkClustering.clusters(of: drawing).enumerated() {
            guard let cacheIndex = anchorEntryIndex(for: cluster.bounds) else { continue }
            let anchor = anchorCache[cacheIndex].anchor
            jumps.append(InkJump(
                id: "\(anchor.startOffset)-\(index)",
                page: max(1, anchor.page ?? 1),
                docY: cluster.bounds.minY,
                anchor: anchor))
        }
        return jumps.sorted { $0.docY < $1.docY }
    }

    /// Scroll the reader to an inked cluster's anchored text (tapped in the
    /// sidebar). Uses the same text-quote scroll machinery as bookmarks so it
    /// survives reflow; falls back to a page jump if the position scroll can't
    /// run.
    func scrollTo(_ jump: InkJump) {
        let anchor = jump.anchor
        let position = PositionData(
            rects: [],
            pageWidth: 0,
            pageHeight: 0,
            selectedText: anchor.text,
            startOffset: anchor.startOffset,
            endOffset: anchor.endOffset,
            prefix: anchor.prefix,
            suffix: anchor.suffix,
            viewportOffset: nil)
        if webController?.scrollToWebPosition(position, page: jump.page) != true {
            app?.goToPage(jump.page)
        }
    }

    // MARK: - InkPaletteHost (undo/redo/clear)

    func undo() { overlay?.canvas.undoManager?.undo() }
    func redo() { overlay?.canvas.undoManager?.redo() }
    var canUndo: Bool {
        _ = drawingVersion
        return overlay?.canvas.undoManager?.canUndo ?? false
    }
    var canRedo: Bool {
        _ = drawingVersion
        return overlay?.canvas.undoManager?.canRedo ?? false
    }

    /// Clear the document's ink (undoable). The web document is one continuous
    /// canvas, so "current page" means the whole drawing.
    func clearCurrentPage() {
        guard let canvas = overlay?.canvas else { return }
        canvas.drawing = PKDrawing()
        drawingChanged(PKDrawing())
    }

    // MARK: - Editing lifecycle

    /// Live change on the canvas: bump undo/redo observability and hand the
    /// drawing — already in layout-CSS-pixel document space — to the
    /// persistence seam, along with the layout fingerprint it was drawn
    /// against (decision 8). Clusters pick their anchors out of the cache;
    /// clusters that don't have one yet get an async capture kicked off
    /// (stroke commit is the capture trigger).
    func drawingChanged(_ drawing: PKDrawing) {
        drawingVersion &+= 1
        // An emptied canvas (Clear, or the last stroke undone away) has no
        // clusters, so no anchor should survive: drop the whole anchor cache.
        // Without this the cache accumulates orphaned entries across a long
        // draw/erase session on one page (unbounded growth, decision 5 sidecar
        // never shrinks it), and a later stroke drawn where a cleared cluster
        // sat would spatially inherit that dead cluster's stale anchor.
        if drawing.strokes.isEmpty { resetAnchorState() }
        persistence?.drawingChanged(
            drawing, layout: zoom1Layout, anchorFor: { anchorForCluster($0) })
        // PKCanvasView may report drawing mutations before its tool-end
        // callback. Never capture a partial stroke: its tiny initial bounds can
        // select different nearby text than the completed underline/circle.
        // `toolUseEnded()` captures the stable final drawing.
        if overlay?.isToolInUse != true {
            captureMissingAnchors(for: drawing)
        }
    }

    /// Called after PencilKit commits the current gesture. If the final
    /// `drawingDidChange` arrived while the tool was active, this is the first
    /// point where the cluster bounds are complete and safe to anchor.
    func toolUseEnded() {
        guard let drawing = overlay?.canvas.drawing else { return }
        captureMissingAnchors(for: drawing)
    }

    /// The document's layout fingerprint: the canvas's contentSize is the
    /// full document in layout CSS px (the overlay divides `zoomScale` out of
    /// the web scroll view's contentSize).
    private var zoom1Layout: WebInkRecord.Layout {
        let size = overlay?.canvas.contentSize ?? .zero
        return WebInkRecord.Layout(
            contentWidth: Double(size.width),
            docHeight: Double(size.height))
    }

    /// Kick off an immediate flush without waiting (ink mode turned off).
    func flushPendingInk() {
        Task { [self] in _ = await flushPendingInkAndReportSuccess() }
    }

    /// Wait until every pending write is durable — tab close and the
    /// scene-background hook (`VellumApp_iOS.flushOnBackground`) call this so a
    /// stroke made right before suspension cannot vanish.
    func flushPendingInkAndWait() async {
        _ = await flushPendingInkAndReportSuccess()
    }

    /// Export needs to distinguish a durable flush from a retained-for-retry
    /// failure; the shared palette/background protocol intentionally remains a
    /// fire-and-wait `Void` surface used by both PDF and web controllers.
    @discardableResult
    func flushPendingInkAndReportSuccess() async -> Bool {
        // Navigation can replace `persistence` while a write is suspended. A
        // small ceiling guarantees MainActor progress under pathological churn;
        // anything left remains owned for the next barrier.
        for _ in 0..<3 {
            let generation = openGeneration
            let outgoing = supersededFlushes
            var succeeded = true
            for flush in outgoing {
                if await flush.joinOrRetry() {
                    supersededFlushes.removeAll { $0 === flush }
                } else {
                    succeeded = false
                }
            }
            if let persistence {
                succeeded = await persistence.flushPendingInkAndWait() && succeeded
            }
            guard succeeded else { return false }
            if generation == openGeneration, supersededFlushes.isEmpty {
                return true
            }
        }
        return false
    }
}

// MARK: - Debounced persistence (decision 6)

/// The production `WebInkPersisting`: one instance per open web document.
/// Mirrors the PDF ink write path's hard-won rules — a 700 ms per-document
/// debounce on the main actor, every disk touch on the `WebInkIO` actor
/// (atomic tmp→rename, per-path lock), and a drain-style flush that
/// `flushPendingInkAndWait` can join from ink-mode-off, tab close, and the
/// scene-background hook. Outgoing persisters are retained by the controller,
/// so a write that already passed its debounce remains joinable across in-tab
/// navigation.
@MainActor
final class WebInkPersister: WebInkPersisting {
    typealias Writer = @Sendable (WebInkRecord, WebInkRecord?) async throws -> WebInkRecord

    let io: WebInkIO
    /// Debounce interval — a test seam (`InkPersistenceTests`-style timing
    /// tests would be flaky at the production 700 ms).
    var debounceInterval: Duration = .milliseconds(700)

    /// The newest not-yet-durable record, and the task sleeping out its
    /// debounce. Same invariant as `InkController_iOS`: `pending` is cleared
    /// only once its record is on disk.
    private var pending: WebInkRecord?
    private var debounceTask: Task<Void, Never>?
    /// Monotonic edit counter so a completed write only clears `pending` when
    /// no newer edit replaced it while the write was in flight.
    private var generation = 0
    /// Retains the active immediate flush so a scene-background callback can
    /// join the exact task an ink-mode-off flush already started.
    private var flushTask: Task<Bool, Never>?
    /// This runtime's last loaded or successfully written full snapshot. The
    /// shared path-locked writer applies only baseline → pending changes to the
    /// latest file, which is what makes same-URL runtimes deletion-safe.
    private var baseline: WebInkRecord?
    /// First-stroke promotion (decision 7) is part of the durability barrier.
    /// A failed attempt leaves `needsPromotion` set so the next edit, export,
    /// or background flush retries instead of permanently latching success.
    private var promoteTask: Task<Bool, Never>?
    private var needsPromotion = false
    private var promoted = false
    /// All production writes use `WebInkIO`; injection lets concurrency tests
    /// pause a write at an exact suspension point without timing sleeps.
    private let writer: Writer
    private static let maxDrainPasses = 3

    init(url: String, writer: Writer? = nil) {
        let io = WebInkIO(url: url)
        self.io = io
        self.writer = writer ?? { record, baseline in
            try await io.write(record, replacing: baseline)
        }
    }

    func loadRecord() async -> WebInkRecord? {
        await io.load()
    }

    func seedBaseline(_ record: WebInkRecord) {
        // A user can draw before the async initial load finishes. If that edit
        // already wrote, its newer baseline must not be replaced by the stale
        // load result; the controller will re-report the merged canvas.
        if baseline == nil { baseline = record }
    }

    func drawingChanged(
        _ drawing: PKDrawing,
        layout: WebInkRecord.Layout,
        anchorFor: (CGRect) -> WebInkRecord.Anchor?
    ) {
        let record = WebInkRecord.snapshot(
            of: drawing, url: io.url, layout: layout, anchorFor: anchorFor)
        if !promoted, !record.clusters.isEmpty {
            needsPromotion = true
            _ = ensurePromotionTask()
        }
        pending = record
        generation &+= 1
        let gen = generation
        debounceTask?.cancel()
        let wait = debounceInterval
        debounceTask = Task { [weak self] in
            try? await Task.sleep(for: wait)
            if Task.isCancelled { return }
            guard let self, self.generation == gen else { return }
            self.debounceTask = nil
            guard let task = self.ensureFlushTask() else { return }
            let succeeded = await task.value
            // A newer edit owns its own debounce. If this generation somehow
            // stayed pending after a successful pass, give it one more worker
            // turn; a failed write waits for a later edit/barrier instead.
            guard succeeded, !Task.isCancelled, self.generation == gen,
                  self.pending != nil else { return }
            _ = self.ensureFlushTask()
        }
    }

    /// Cancel the debounce and wait until every pending write (and the
    /// promote-to-saved, if one is in flight) is durable.
    @discardableResult
    func flushPendingInkAndWait() async -> Bool {
        if needsPromotion {
            guard await ensurePromotionTask().value else { return false }
        }
        // An edit can arrive while an earlier flush is suspended in the write.
        // Re-drain a bounded number of times; continuous edits remain pending
        // for the next flush rather than monopolizing the main actor.
        for _ in 0..<Self.maxDrainPasses {
            await cancelDebounceAndWait()
            guard let task = ensureFlushTask() else { return true }
            guard await task.value else { return false }
        }
        return pending == nil && debounceTask == nil && flushTask == nil
    }

    private func ensurePromotionTask() -> Task<Bool, Never> {
        if let promoteTask { return promoteTask }
        let io = io
        let task = Task { [weak self] in
            let succeeded: Bool
            do {
                try await io.promoteToSaved()
                succeeded = true
            } catch {
                WebInkController_iOS.log.error(
                    "web ink page promotion failed; retaining retry: \(error.localizedDescription, privacy: .public)")
                succeeded = false
            }
            guard let self else { return succeeded }
            if succeeded {
                self.needsPromotion = false
                self.promoted = true
            }
            self.promoteTask = nil
            return succeeded
        }
        promoteTask = task
        return task
    }

    private func ensureFlushTask() -> Task<Bool, Never>? {
        if let flushTask { return flushTask }
        guard pending != nil else { return nil }
        let task = Task {
            let succeeded = await self.writePendingRecord()
            self.flushTask = nil
            return succeeded
        }
        flushTask = task
        return task
    }

    private func cancelDebounceAndWait() async {
        let scheduled = debounceTask
        scheduled?.cancel()
        debounceTask = nil
        if let scheduled { await scheduled.value }
    }

    private func writePendingRecord() async -> Bool {
        guard let record = pending else { return true }
        let gen = generation
        return await write(record, generation: gen)
    }

    /// Returns false after a refused/failed disk write. The latest full record
    /// remains in `pending`, so a later foreground edit, explicit export, or
    /// background flush retries it instead of silently declaring it durable.
    private func write(_ record: WebInkRecord, generation gen: Int) async -> Bool {
        let replacing = baseline
        do {
            let committed = try await writer(record, replacing)
            // The coordinated writer may preserve strokes from another runtime
            // or from a load that completed before this write. That exact
            // committed snapshot, not the incoming canvas, is the causal base
            // for the next observed-remove delta.
            baseline = committed
        } catch {
            // A newer edit may have replaced `record` while the I/O actor was
            // suspended. Never overwrite that newest pending snapshot while
            // requeueing the failed one.
            if generation == gen { pending = record }
            Self.logWriteFailure(error)
            return false
        }

        // Even when a newer edit arrived during the write, this snapshot is now
        // part of the shared file and is the correct causal base for the next
        // delta. Only clear pending when it is still this generation.
        if generation == gen { pending = nil }
        return true
    }

    private static func logWriteFailure(_ error: Error) {
        WebInkController_iOS.log.error(
            "web ink write failed; retaining latest snapshot for retry: \(error.localizedDescription, privacy: .public)")
    }
}
#endif
