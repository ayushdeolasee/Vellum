import { useCallback, useEffect, useRef, useState } from "react";
import { usePdfStore } from "@/stores/pdf-store";
import { useAnnotationStore } from "@/stores/annotation-store";
import { useAiStore } from "@/stores/ai-store";
import { SelectionPopover } from "@/components/annotations/SelectionPopover";
import {
  WebContextMenu,
  WebNoteComposer,
  WebNoteViewer,
} from "@/components/web/WebNotePopovers";
import * as commands from "@/lib/tauri-commands";
import type { PositionData } from "@/types";
import { WifiOff } from "lucide-react";

// Tauri custom protocols are exposed as `<scheme>://localhost/` on
// macOS/Linux and `http://<scheme>.localhost/` on Windows.
const IS_WINDOWS = navigator.userAgent.includes("Windows");

function webProxyUrl(target: string): string {
  const query = `?url=${encodeURIComponent(target)}`;
  // Test hook: lets browser-based integration tests substitute an HTTP proxy
  // for the vellum-web custom protocol (which only exists inside Tauri).
  const devProxy = (window as unknown as Record<string, unknown>).__VELLUM_DEV_PROXY__;
  if (typeof devProxy === "string") return `${devProxy}${query}`;
  return IS_WINDOWS
    ? `http://vellum-web.localhost/${query}`
    : `vellum-web://localhost/${query}`;
}

interface FrameRect {
  x: number;
  y: number;
  width: number;
  height: number;
}

interface WebSelection {
  text: string;
  pageNumber: number;
  positionData: PositionData;
}

interface LocatedWebText {
  positionData: PositionData;
  pageNumber: number;
}

interface PendingLocate {
  resolve: (value: LocatedWebText | null) => void;
  timer: number;
}

interface CapturedWebPosition {
  pageNumber: number;
  positionData: PositionData;
}

/** Text-quote anchor for a note placed at a point in the page. */
interface WebNoteAnchor {
  start: number;
  end: number;
  text: string;
  prefix: string | null;
  suffix: string | null;
  pageNumber: number;
}

interface NoteComposerState {
  x: number;
  y: number;
  anchor: WebNoteAnchor;
  openedAt: number;
}

interface WebContextMenuState {
  x: number;
  y: number;
  anchor: WebNoteAnchor | null;
  openedAt: number;
}

interface NoteViewerState {
  id: string;
  x: number;
  y: number;
  openedAt: number;
}

function parseNoteAnchor(data: Record<string, unknown>): WebNoteAnchor | null {
  if (
    typeof data.start !== "number" ||
    typeof data.end !== "number" ||
    typeof data.text !== "string" ||
    !data.text
  ) {
    return null;
  }
  return {
    start: data.start,
    end: data.end,
    text: data.text,
    prefix: typeof data.prefix === "string" ? data.prefix : null,
    suffix: typeof data.suffix === "string" ? data.suffix : null,
    pageNumber:
      typeof data.pageNumber === "number" && data.pageNumber >= 1
        ? data.pageNumber
        : 1,
  };
}

interface PendingCapture {
  resolve: (value: CapturedWebPosition | null) => void;
  timer: number;
}

export function WebViewer() {
  const iframeRef = useRef<HTMLIFrameElement>(null);
  const pendingLocatesRef = useRef<Map<string, PendingLocate>>(new Map());
  const pendingCapturesRef = useRef<Map<string, PendingCapture>>(new Map());
  // Whether the injected content script supports point anchors (declared in
  // its init handshake). False for older embedded scripts.
  const supportsPositionsRef = useRef(false);
  // Auto-archive bookkeeping: the URL already archived this mount, and a
  // debounce timer so the fullest text extraction wins.
  const archivedUrlRef = useRef<string | null>(null);
  const archiveTimerRef = useRef<number | null>(null);
  // The tab this viewer instance was mounted for. Messages processed after a
  // tab switch (queued before React unmounts the old viewer) must not act on
  // the new active tab's state.
  const mountTabIdRef = useRef<string | null>(usePdfStore.getState().activeTabId);
  // Target of an in-flight link navigation: late messages from the outgoing
  // document (e.g. its delayed re-extraction init) are ignored until the new
  // document reports in, so they can't rebind the tab backwards.
  const pendingNavUrlRef = useRef<string | null>(null);
  // URL whose reading position has already been restored this mount; the
  // content script re-sends init after late re-extraction and that must not
  // yank the reader back.
  const restoredUrlRef = useRef<string | null>(null);

  const doc = usePdfStore((s) => s.document);
  const activeTabId = usePdfStore((s) => s.activeTabId);
  const zoom = usePdfStore((s) => s.zoom);
  const mode = usePdfStore((s) => s.mode);
  const annotations = useAnnotationStore((s) => s.annotations);
  const selectedAnnotationId = useAnnotationStore((s) => s.selectedAnnotationId);

  // Counts inits from the document currently bound to this tab; 0 = nothing
  // loaded yet. A counter (not a boolean) so highlight application re-fires
  // after in-tab navigation replaces the document.
  const [initCount, setInitCount] = useState(0);
  const [isOffline, setIsOffline] = useState(false);
  const [selection, setSelection] = useState<WebSelection | null>(null);
  const [popoverPosition, setPopoverPosition] = useState<{ x: number; y: number } | null>(null);
  const popoverRef = useRef<HTMLDivElement | null>(null);

  // Note UI popovers (rendered in the app shell, anchored over the iframe):
  // composer for new notes, context menu for right-clicks, viewer for
  // clicking an existing marker.
  const [noteComposer, setNoteComposer] = useState<NoteComposerState | null>(null);
  const [webContextMenu, setWebContextMenu] = useState<WebContextMenuState | null>(null);
  const [noteViewer, setNoteViewer] = useState<NoteViewerState | null>(null);

  // The iframe src is set once per mount; link navigation swaps it explicitly.
  const [frameSrc, setFrameSrc] = useState(() =>
    doc ? webProxyUrl(doc.pdf_path) : "about:blank",
  );

  const postToFrame = useCallback((vellumCmd: string, payload?: Record<string, unknown>) => {
    iframeRef.current?.contentWindow?.postMessage({ vellumCmd, ...payload }, "*");
  }, []);

  const clearSelection = useCallback(() => {
    setSelection(null);
    setPopoverPosition(null);
    postToFrame("clear-selection");
  }, [postToFrame]);

  const cancelPendingArchive = useCallback(() => {
    if (archiveTimerRef.current !== null) {
      window.clearTimeout(archiveTimerRef.current);
      archiveTimerRef.current = null;
    }
  }, []);

  // Map iframe-viewport coordinates to app-shell coordinates (the iframe is
  // scaled by the zoom transform).
  const frameToParent = useCallback((x: number, y: number) => {
    const rect = iframeRef.current?.getBoundingClientRect();
    const scale = usePdfStore.getState().zoom;
    return {
      x: (rect?.left ?? 0) + x * scale,
      y: (rect?.top ?? 0) + y * scale,
    };
  }, []);

  const closeNotePopovers = useCallback(() => {
    setNoteComposer(null);
    setWebContextMenu(null);
    setNoteViewer(null);
  }, []);

  const createAnchoredNote = useCallback((anchor: WebNoteAnchor, content: string) => {
    void useAnnotationStore
      .getState()
      .addNote({
        type: "note",
        page_number: anchor.pageNumber,
        content,
        position_data: {
          rects: [],
          page_width: 1,
          page_height: 1,
          selected_text: anchor.text,
          start_offset: anchor.start,
          end_offset: anchor.end,
          prefix: anchor.prefix,
          suffix: anchor.suffix,
        },
      })
      .then((annotation) => {
        if (annotation) {
          useAnnotationStore.getState().selectAnnotation(annotation.id);
        }
      });
  }, []);

  // --- Inbound messages from the content script ---
  useEffect(() => {
    const onMessage = (event: MessageEvent) => {
      const frame = iframeRef.current;
      if (!frame || event.source !== frame.contentWindow) return;
      const data = event.data as Record<string, unknown> | null;
      if (!data || data.vellum !== true || typeof data.type !== "string") return;

      const store = usePdfStore.getState();
      // Drop messages queued from before a tab switch: this viewer belongs to
      // one tab, and acting on another tab's state would corrupt it.
      if (store.activeTabId !== mountTabIdRef.current) return;

      switch (data.type) {
        case "init": {
          const tabId = store.activeTabId;
          const currentDoc = store.document;
          if (!tabId || !currentDoc) break;

          const reportedUrl = typeof data.url === "string" ? data.url : null;

          // Mid-navigation: ignore late reports from the outgoing document
          // (its delayed re-extraction) so they can't rebind us backwards.
          if (pendingNavUrlRef.current !== null) {
            if (reportedUrl !== pendingNavUrlRef.current) break;
            pendingNavUrlRef.current = null;
          }

          setIsOffline(Boolean(data.offline));
          supportsPositionsRef.current = Boolean(data.positionAnchors);

          if (reportedUrl && reportedUrl !== currentDoc.pdf_path) {
            // The frame navigated (back/forward or a redirect changed the
            // effective URL): rebind the session, then ask the page to
            // report again so the fresh context lands after the App-level
            // document reset. Any open note popovers belong to the outgoing
            // document — submitting them against the new one would save
            // wrong-page anchors.
            cancelPendingArchive();
            closeNotePopovers();
            void store.webNavigated(tabId, reportedUrl).then((rebound) => {
              if (rebound) postToFrame("request-init");
            });
            break;
          }

          setInitCount((count) => count + 1);

          const pageCount = typeof data.pageCount === "number" ? data.pageCount : 0;
          if (pageCount > 0) store.setNumPages(pageCount);

          const pages = Array.isArray(data.pages)
            ? (data.pages as Array<{ number: number; text: string }>)
            : [];
          const setPageText = useAiStore.getState().setPageText;
          for (const page of pages) {
            if (typeof page?.number === "number" && typeof page?.text === "string") {
              setPageText(page.number, page.text);
            }
          }

          if (typeof data.title === "string" && data.title) {
            store.updateDocumentTitle(tabId, data.title);
            commands.setDocumentMetadata(tabId, "title", data.title).catch(() => {});
          }

          // Default behaviour: archive every opened page as a .vellumweb in
          // the managed library. Skip when we're already showing a snapshot
          // (offline) — re-archiving from a fallback would only degrade it.
          // Debounced so a late re-extraction with fuller text wins, and run
          // once per URL per mount. The Rust side re-checks the URL, so a
          // navigation that slips between the timer and the command can't
          // archive mismatched content.
          if (!data.offline && archivedUrlRef.current !== currentDoc.pdf_path) {
            const archiveTabId = tabId;
            const archiveUrl = currentDoc.pdf_path;
            const pagesForArchive = pages.filter(
              (p) => typeof p?.number === "number" && typeof p?.text === "string",
            );
            cancelPendingArchive();
            archiveTimerRef.current = window.setTimeout(() => {
              archiveTimerRef.current = null;
              archivedUrlRef.current = archiveUrl;
              commands
                .archiveWebpageDefault(archiveTabId, pagesForArchive, archiveUrl)
                .catch(() => {
                  // Non-fatal: reading works without the archive. Allow a
                  // retry on the next init for this URL.
                  if (archivedUrlRef.current === archiveUrl) {
                    archivedUrlRef.current = null;
                  }
                });
            }, 1500);
          }

          // Restore the reading position once per document; later inits from
          // re-extraction must not yank the reader away from where they are.
          if (restoredUrlRef.current !== currentDoc.pdf_path) {
            restoredUrlRef.current = currentDoc.pdf_path;
            const target = store.currentPage;
            if (target > 1) postToFrame("scroll-to-page", { page: target });
          }
          break;
        }

        case "scroll": {
          if (typeof data.currentPage === "number") {
            store.setCurrentPage(data.currentPage);
          }
          if (Array.isArray(data.visiblePages)) {
            store.setVisiblePages(data.visiblePages as number[]);
          }
          if (
            typeof data.visibleStart === "number" &&
            typeof data.visibleEnd === "number"
          ) {
            store.setWebVisibleRange({
              start: data.visibleStart,
              end: data.visibleEnd,
            });
          }
          break;
        }

        case "selection": {
          const rects = Array.isArray(data.rects) ? (data.rects as FrameRect[]) : [];
          const text = typeof data.text === "string" ? data.text : "";
          if (!text || rects.length === 0) break;

          const frameRect = frame.getBoundingClientRect();
          const scale = usePdfStore.getState().zoom;
          const last = rects[rects.length - 1];

          setPopoverPosition({
            x: frameRect.left + (last.x + last.width / 2) * scale,
            y: frameRect.top + last.y * scale - 10,
          });
          setSelection({
            text,
            pageNumber: typeof data.pageNumber === "number" ? data.pageNumber : 1,
            positionData: {
              rects: [],
              page_width: 1,
              page_height: 1,
              selected_text: text,
              start_offset: typeof data.start === "number" ? data.start : null,
              end_offset: typeof data.end === "number" ? data.end : null,
              prefix: typeof data.prefix === "string" ? data.prefix : null,
              suffix: typeof data.suffix === "string" ? data.suffix : null,
            },
          });
          break;
        }

        case "selection-cleared": {
          setSelection(null);
          setPopoverPosition(null);
          // A plain click inside the page doubles as "click outside" for the
          // note popovers (parent-window clicks can't reach the iframe). The
          // grace period keeps the event fired by the opening click itself
          // from instantly dismissing them.
          const clickOutside = (openedAt: number) => Date.now() - openedAt > 400;
          setWebContextMenu((cur) => (cur && clickOutside(cur.openedAt) ? null : cur));
          setNoteViewer((cur) => (cur && clickOutside(cur.openedAt) ? null : cur));
          setNoteComposer((cur) => (cur && clickOutside(cur.openedAt) ? null : cur));
          break;
        }

        case "note-placed": {
          const anchor = parseNoteAnchor(data);
          if (!anchor) break;
          const point = frameToParent(
            typeof data.x === "number" ? data.x : 0,
            typeof data.y === "number" ? data.y : 0,
          );
          setWebContextMenu(null);
          setNoteViewer(null);
          setNoteComposer({
            x: point.x,
            y: point.y,
            anchor,
            openedAt: Date.now(),
          });
          // Mirror the PDF viewer: placing a note returns to view mode.
          store.setMode("view");
          break;
        }

        case "context-menu": {
          const point = frameToParent(
            typeof data.x === "number" ? data.x : 0,
            typeof data.y === "number" ? data.y : 0,
          );
          setNoteComposer(null);
          setNoteViewer(null);
          setWebContextMenu({
            x: point.x,
            y: point.y,
            anchor: data.found ? parseNoteAnchor(data) : null,
            openedAt: Date.now(),
          });
          break;
        }

        case "annotation-click": {
          const id = typeof data.id === "string" ? data.id : null;
          if (!id) break;
          useAnnotationStore.getState().selectAnnotation(id);
          const annotation = useAnnotationStore
            .getState()
            .annotations.find((a) => a.id === id);
          if (annotation?.type === "note") {
            const point = frameToParent(
              typeof data.x === "number" ? data.x : 0,
              typeof data.y === "number" ? data.y : 0,
            );
            setNoteComposer(null);
            setWebContextMenu(null);
            setNoteViewer({ id, x: point.x, y: point.y, openedAt: Date.now() });
          }
          break;
        }

        case "navigate": {
          const url = typeof data.url === "string" ? data.url : null;
          const tabId = store.activeTabId;
          if (!url || !tabId) break;
          // A pending auto-archive for the outgoing page must not fire
          // against the rebound session.
          cancelPendingArchive();
          clearSelection();
          closeNotePopovers();
          void store.webNavigated(tabId, url).then((rebound) => {
            if (rebound) {
              pendingNavUrlRef.current = rebound.pdf_path;
              setInitCount(0);
              setFrameSrc(webProxyUrl(rebound.pdf_path));
            }
          });
          break;
        }

        case "viewport-scrolled": {
          // Popovers are positioned in app-shell coordinates from event-time
          // rects; scrolling the page underneath invalidates them (mirrors
          // the PDF viewer's scroll behaviour).
          setSelection((current) => {
            if (current) {
              setPopoverPosition(null);
              postToFrame("clear-selection");
              return null;
            }
            return current;
          });
          setWebContextMenu(null);
          setNoteViewer(null);
          // Keep the composer only if it just opened (the placement click
          // can nudge scroll on some pages); otherwise typing continues.
          setNoteComposer((current) =>
            current && Date.now() - current.openedAt < 400 ? current : null,
          );
          break;
        }

        case "locate-result": {
          const requestId = typeof data.requestId === "string" ? data.requestId : null;
          if (!requestId) break;
          const pending = pendingLocatesRef.current.get(requestId);
          if (!pending) break;
          pendingLocatesRef.current.delete(requestId);
          window.clearTimeout(pending.timer);
          if (data.found && typeof data.start === "number" && typeof data.end === "number") {
            pending.resolve({
              pageNumber: typeof data.pageNumber === "number" ? data.pageNumber : 0,
              positionData: {
                rects: [],
                page_width: 1,
                page_height: 1,
                selected_text: null,
                start_offset: data.start,
                end_offset: data.end,
                prefix: typeof data.prefix === "string" ? data.prefix : null,
                suffix: typeof data.suffix === "string" ? data.suffix : null,
              },
            });
          } else {
            pending.resolve(null);
          }
          break;
        }

        case "position-result": {
          const requestId = typeof data.requestId === "string" ? data.requestId : null;
          if (!requestId) break;
          const pending = pendingCapturesRef.current.get(requestId);
          if (!pending) break;
          pendingCapturesRef.current.delete(requestId);
          window.clearTimeout(pending.timer);
          if (
            data.found &&
            typeof data.start === "number" &&
            typeof data.end === "number" &&
            typeof data.text === "string"
          ) {
            pending.resolve({
              pageNumber: typeof data.pageNumber === "number" ? data.pageNumber : 1,
              positionData: {
                rects: [],
                page_width: 1,
                page_height: 1,
                selected_text: data.text,
                start_offset: data.start,
                end_offset: data.end,
                prefix: typeof data.prefix === "string" ? data.prefix : null,
                suffix: typeof data.suffix === "string" ? data.suffix : null,
                viewport_offset: typeof data.offset === "number" ? data.offset : null,
              },
            });
          } else {
            pending.resolve(null);
          }
          break;
        }
      }
    };

    window.addEventListener("message", onMessage);
    return () => window.removeEventListener("message", onMessage);
  }, [postToFrame, cancelPendingArchive, clearSelection, closeNotePopovers, frameToParent]);

  // --- Push highlight + note annotations into the frame ---
  useEffect(() => {
    if (initCount === 0) return;
    const anchor = (a: (typeof annotations)[number]) => ({
      id: a.id,
      color: a.color ?? "#fef08a",
      start: a.position_data?.start_offset ?? null,
      end: a.position_data?.end_offset ?? null,
      text: a.position_data?.selected_text ?? "",
      prefix: a.position_data?.prefix ?? null,
      suffix: a.position_data?.suffix ?? null,
    });
    const highlights = annotations
      .filter((a) => a.type === "highlight" && a.position_data?.selected_text)
      .map(anchor);
    const notes = annotations
      .filter(
        (a) =>
          a.type === "note" &&
          a.position_data?.selected_text &&
          a.position_data?.start_offset != null,
      )
      .map((a) => ({ ...anchor(a), content: a.content ?? "" }));
    postToFrame("apply-annotations", { highlights, notes });
  }, [annotations, initCount, postToFrame]);

  // --- Keep the frame's interaction mode in sync (note placement) ---
  useEffect(() => {
    if (initCount === 0) return;
    postToFrame("set-mode", { mode });
  }, [mode, initCount, postToFrame]);

  // --- Scroll to an annotation when it is selected in the sidebar ---
  useEffect(() => {
    if (initCount === 0 || !selectedAnnotationId) return;
    const annotation = annotations.find((a) => a.id === selectedAnnotationId);
    if (
      (annotation?.type === "highlight" || annotation?.type === "note") &&
      annotation.position_data?.selected_text
    ) {
      postToFrame("scroll-to-annotation", { id: selectedAnnotationId });
    } else if (
      annotation?.type === "bookmark" &&
      annotation.position_data?.start_offset != null
    ) {
      const pd = annotation.position_data;
      postToFrame("scroll-to-position", {
        start: pd.start_offset,
        end: pd.end_offset,
        text: pd.selected_text,
        prefix: pd.prefix ?? null,
        suffix: pd.suffix ?? null,
        offset: pd.viewport_offset ?? null,
        page: annotation.page_number,
      });
    }
    // Scrolling should re-run only when the selection changes, not when the
    // annotation list is refreshed.
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [selectedAnnotationId, initCount, postToFrame]);

  // --- Global hooks used by the toolbar, sidebar, and AI tool execution ---
  useEffect(() => {
    const globals = window as unknown as Record<string, unknown>;

    globals.__scrollToPage = (page: number) => {
      postToFrame("scroll-to-page", { page });
    };

    globals.__webHistory = (delta: number) => {
      postToFrame("history", { delta });
    };

    globals.__locateWebText = (page: number, text: string) =>
      new Promise<LocatedWebText | null>((resolve) => {
        const requestId = crypto.randomUUID();
        const timer = window.setTimeout(() => {
          pendingLocatesRef.current.delete(requestId);
          resolve(null);
        }, 4000);
        pendingLocatesRef.current.set(requestId, { resolve, timer });
        postToFrame("locate-text", { requestId, page, text });
      });

    globals.__captureWebPosition = () =>
      new Promise<CapturedWebPosition | null>((resolve) => {
        if (!supportsPositionsRef.current) {
          resolve(null);
          return;
        }
        const requestId = crypto.randomUUID();
        const timer = window.setTimeout(() => {
          pendingCapturesRef.current.delete(requestId);
          resolve(null);
        }, 1500);
        pendingCapturesRef.current.set(requestId, { resolve, timer });
        postToFrame("capture-position", { requestId });
      });

    globals.__scrollToWebPosition = (pd: PositionData, page?: number) => {
      if (!supportsPositionsRef.current) return false;
      postToFrame("scroll-to-position", {
        start: pd.start_offset,
        end: pd.end_offset,
        text: pd.selected_text,
        prefix: pd.prefix ?? null,
        suffix: pd.suffix ?? null,
        offset: pd.viewport_offset ?? null,
        page,
      });
      return true;
    };

    return () => {
      delete globals.__scrollToPage;
      delete globals.__webHistory;
      delete globals.__locateWebText;
      delete globals.__captureWebPosition;
      delete globals.__scrollToWebPosition;
    };
  }, [postToFrame]);

  // Reject in-flight locates and cancel a pending archive when the viewer
  // unmounts.
  useEffect(() => {
    const pendingLocates = pendingLocatesRef.current;
    const pendingCaptures = pendingCapturesRef.current;
    return () => {
      for (const pending of pendingLocates.values()) {
        window.clearTimeout(pending.timer);
        pending.resolve(null);
      }
      pendingLocates.clear();
      for (const pending of pendingCaptures.values()) {
        window.clearTimeout(pending.timer);
        pending.resolve(null);
      }
      pendingCaptures.clear();
      if (archiveTimerRef.current !== null) {
        window.clearTimeout(archiveTimerRef.current);
        archiveTimerRef.current = null;
      }
    };
  }, []);

  if (!doc || !activeTabId) return null;

  // Zoom is applied by scaling the iframe itself: the page reflows to a
  // narrower layout width, like a browser text zoom. The content script
  // stays zoom-agnostic; selection rects are scaled back here.
  const inverse = 100 / zoom;

  return (
    <div className="relative min-h-0 min-w-0 flex-1 overflow-hidden bg-well">
      <iframe
        ref={iframeRef}
        src={frameSrc}
        // aria-label rather than title: a title attribute makes the browser
        // show a hover tooltip over the entire reading surface.
        aria-label={doc.title ?? doc.pdf_path}
        className="border-0 bg-white"
        style={{
          width: `${inverse}%`,
          height: `${inverse}%`,
          transform: `scale(${zoom})`,
          transformOrigin: "0 0",
        }}
        sandbox="allow-scripts allow-same-origin allow-forms"
      />

      {isOffline && (
        <div className="absolute right-3 top-3 z-40 flex items-center gap-1.5 rounded-full border border-border bg-background/95 px-2.5 py-1 text-xs text-muted-foreground shadow-soft">
          <WifiOff size={12} />
          Offline snapshot
        </div>
      )}

      {selection && popoverPosition && (
        <SelectionPopover
          ref={popoverRef}
          position={popoverPosition}
          selection={selection}
          currentPage={selection.pageNumber}
          onClose={clearSelection}
        />
      )}

      {webContextMenu && (
        <WebContextMenu
          x={webContextMenu.x}
          y={webContextMenu.y}
          canAddNote={webContextMenu.anchor !== null}
          onAddNote={() => {
            const menu = webContextMenu;
            setWebContextMenu(null);
            if (menu.anchor) {
              setNoteComposer({
                x: menu.x,
                y: menu.y,
                anchor: menu.anchor,
                openedAt: Date.now(),
              });
            }
          }}
          onClose={() => setWebContextMenu(null)}
        />
      )}

      {noteComposer && (
        <WebNoteComposer
          x={noteComposer.x}
          y={noteComposer.y}
          onSubmit={(content) => {
            createAnchoredNote(noteComposer.anchor, content);
            setNoteComposer(null);
          }}
          onClose={() => setNoteComposer(null)}
        />
      )}

      {noteViewer && (
        <WebNoteViewer
          // Keyed by annotation so switching markers never carries one
          // note's edit draft into another.
          key={noteViewer.id}
          annotationId={noteViewer.id}
          x={noteViewer.x}
          y={noteViewer.y}
          onClose={() => setNoteViewer(null)}
        />
      )}
    </div>
  );
}
