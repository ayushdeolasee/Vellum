import {
  useCallback,
  useEffect,
  useLayoutEffect,
  useMemo,
  useRef,
  useState,
} from "react";
import { Document, Page, pdfjs } from "react-pdf";
import "react-pdf/dist/Page/AnnotationLayer.css";
import "react-pdf/dist/Page/TextLayer.css";
import { usePdfStore } from "@/stores/pdf-store";
import { useAnnotationStore } from "@/stores/annotation-store";
import { useAiStore } from "@/stores/ai-store";
import { HighlightLayer } from "@/components/annotations/HighlightLayer";
import { SelectionPopover } from "@/components/annotations/SelectionPopover";
import { useTextSelection } from "@/hooks/useTextSelection";
import { cn } from "@/lib/utils";
import { ErrorBoundary } from "@/components/ErrorBoundary";
import { StickyNote } from "lucide-react";
import * as commands from "@/lib/tauri-commands";
import type { Annotation } from "@/types";

pdfjs.GlobalWorkerOptions.workerSrc = new URL(
  "pdfjs-dist/build/pdf.worker.min.mjs",
  import.meta.url,
).toString();

/** Number of pages to render above/below the visible range */
const PAGE_BUFFER = 4;
/** Default PDF page dimensions in points (US Letter) */
const DEFAULT_PAGE_WIDTH = 612;
const DEFAULT_PAGE_HEIGHT = 792;
const MIN_ZOOM = 0.25;
const MAX_ZOOM = 4.0;
const WHEEL_ZOOM_SENSITIVITY = 0.035;
const GESTURE_SCALE_DAMPING = 0.55;
const MAX_WHEEL_DELTA = 8;

const clampZoom = (value: number) =>
  Math.min(MAX_ZOOM, Math.max(MIN_ZOOM, value));

const clampScrollPosition = (value: number) =>
  Number.isFinite(value) ? Math.max(0, value) : 0;

type ZoomAnchorSnapshot = {
  anchorX: number;
  anchorY: number;
  contentX: number;
  contentY: number;
  pageNum: number | null;
  relX: number;
  relY: number;
};

export function PdfViewer() {
  const containerRef = useRef<HTMLDivElement>(null);
  const pagesWrapperRef = useRef<HTMLDivElement>(null);
  const pageElementsRef = useRef<Map<number, HTMLDivElement>>(new Map());
  const zoomAnchorRafRef = useRef<number | null>(null);
  const manuallyAnchoredZoomRef = useRef(false);
  const zoomSettlingRef = useRef(false);
  const prevZoomRef = useRef<number | null>(null);
  const pinchRef = useRef({
    active: false,
    baseZoom: 1,
    scale: 1,
    anchorX: 0,
    anchorY: 0,
    contentX: 0,
    contentY: 0,
    focusPage: null as number | null,
    focusRelX: 0.5,
    focusRelY: 0.5,
  });

  // --- Zustand selectors (individual subscriptions) ---
  const doc = usePdfStore((s) => s.document);
  const numPages = usePdfStore((s) => s.numPages);
  const zoom = usePdfStore((s) => s.zoom);
  const renderZoom = zoom;
  const mode = usePdfStore((s) => s.mode);
  const currentPage = usePdfStore((s) => s.currentPage);
  const visiblePages = usePdfStore((s) => s.visiblePages);
  const setMode = usePdfStore((s) => s.setMode);
  const setNumPages = usePdfStore((s) => s.setNumPages);
  const setCurrentPage = usePdfStore((s) => s.setCurrentPage);
  const setVisiblePages = usePdfStore((s) => s.setVisiblePages);
  const setZoom = usePdfStore((s) => s.setZoom);
  const renderDevicePixelRatio = useMemo(
    () => Math.min(window.devicePixelRatio || 1, 1.5),
    [],
  );

  const annotations = useAnnotationStore((s) => s.annotations);
  const addNote = useAnnotationStore((s) => s.addNote);
  const selectAnnotation = useAnnotationStore((s) => s.selectAnnotation);
  const setPageText = useAiStore((s) => s.setPageText);
  const clearDocumentContext = useAiStore((s) => s.clearDocumentContext);
  const textExtractionRunRef = useRef(0);

  // Page dimension tracking for virtualization placeholders.
  const [pageDimensions, setPageDimensions] = useState<
    Record<number, { width: number; height: number }>
  >({});

  const {
    selection,
    popoverPosition,
    popoverRef,
    clearSelection,
    handleMouseUp,
  } = useTextSelection();

  // Read PDF bytes from Rust backend
  const [pdfData, setPdfData] = useState<{ data: Uint8Array } | null>(null);
  const [pdfError, setPdfError] = useState<string | null>(null);

  // Right-click context menu state
  const [contextMenu, setContextMenu] = useState<{
    x: number;
    y: number;
    pageNum: number;
    clickX: number;
    clickY: number;
    pageWidth: number;
    pageHeight: number;
  } | null>(null);

  useEffect(() => {
    if (!doc) {
      queueMicrotask(() => {
        setPdfData(null);
        setPdfError(null);
        setPageDimensions({});
        clearDocumentContext();
      });
      return;
    }
    let cancelled = false;

    queueMicrotask(() => {
      if (cancelled) return;
      setPdfData(null);
      setPdfError(null);
      setPageDimensions({});
    });

    commands
      .readPdfBytes()
      .then((buffer) => {
        if (!cancelled) {
          const arr = new Uint8Array(buffer);
          setPdfData({ data: arr });
        }
      })
      .catch((err) => {
        if (!cancelled) {
          console.error("[PdfViewer] readPdfBytes FAILED:", err);
          setPdfError(String(err));
        }
      });

    return () => {
      cancelled = true;
    };
  }, [clearDocumentContext, doc]);

  const onDocumentLoadSuccess = useCallback(
    (loadedPdf: { numPages: number; getPage: (page: number) => Promise<unknown> }) => {
      const pages = loadedPdf.numPages;
      setNumPages(pages);

      const runId = textExtractionRunRef.current + 1;
      textExtractionRunRef.current = runId;

      void (async () => {
        for (let pageNum = 1; pageNum <= pages; pageNum++) {
          if (textExtractionRunRef.current !== runId) return;
          try {
            const page = (await loadedPdf.getPage(pageNum)) as {
              getTextContent: () => Promise<{
                items: Array<{ str?: string }>;
              }>;
            };
            const textContent = await page.getTextContent();
            const pageText = textContent.items
              .map((item) => item.str ?? "")
              .join(" ")
              .replace(/\s+/g, " ")
              .trim();
            setPageText(pageNum, pageText);
          } catch (err) {
            console.warn(`[PdfViewer] Failed text extraction for page ${pageNum}:`, err);
          }

          // Yield periodically to keep UI responsive.
          if (pageNum % 4 === 0) {
            await new Promise((resolve) => window.setTimeout(resolve, 0));
          }
        }
      })();
    },
    [setNumPages, setPageText],
  );

  useEffect(() => {
    const wrapper = pagesWrapperRef.current;
    return () => {
      if (zoomAnchorRafRef.current !== null) {
        window.cancelAnimationFrame(zoomAnchorRafRef.current);
      }
      if (wrapper) {
        wrapper.style.transform = "";
        wrapper.style.transformOrigin = "";
        wrapper.style.willChange = "";
      }
      pinchRef.current.active = false;
    };
  }, []);

  // Track page dimensions on load.
  // react-pdf reports original PDF dimensions (before scale).
  const handlePageLoad = useCallback(
    (pageNum: number) =>
      ({ width, height }: { width: number; height: number }) => {
        setPageDimensions((prev) => {
          const existing = prev[pageNum];
          if (existing && existing.width === width && existing.height === height) {
            return prev;
          }
          return {
            ...prev,
            [pageNum]: { width, height },
          };
        });
      },
    [],
  );

  // --- Pre-index annotations by page (O(N) once, not O(N*P) per render) ---
  const annotationsByPage = useMemo(() => {
    const map = new Map<number, Annotation[]>();
    for (const a of annotations) {
      const existing = map.get(a.page_number);
      if (existing) {
        existing.push(a);
      } else {
        map.set(a.page_number, [a]);
      }
    }
    return map;
  }, [annotations]);

  // Memoize page number array
  const pageNumbers = useMemo(
    () => Array.from({ length: numPages }, (_, i) => i + 1),
    [numPages],
  );

  // --- Page virtualization: only mount pages near the viewport ---
  const pagesToRender = useMemo(() => {
    // Keep all pages mounted while zoomed in to avoid placeholder blanking.
    if (renderZoom > 1.1) {
      return new Set(pageNumbers);
    }

    const center = visiblePages.length > 0 ? visiblePages : [currentPage];
    const dynamicBuffer =
      renderZoom >= 2
        ? PAGE_BUFFER + 4
        : renderZoom >= 1.25
          ? PAGE_BUFFER + 2
          : PAGE_BUFFER + 1;
    const min = Math.max(1, center[0] - dynamicBuffer);
    const max = Math.min(
      numPages,
      center[center.length - 1] + dynamicBuffer,
    );
    const set = new Set<number>();
    for (let i = min; i <= max; i++) set.add(i);
    return set;
  }, [renderZoom, visiblePages, currentPage, numPages, pageNumbers]);

  const visiblePagesSet = useMemo(() => new Set(visiblePages), [visiblePages]);

  // --- Scroll handler: RAF-throttled visibility tracking ---
  const ticking = useRef(false);
  const scrollEventPendingRef = useRef(false);
  const lastKnownScrollRef = useRef<{ top: number; left: number } | null>(null);
  const handleScroll = useCallback(() => {
    if (ticking.current) return;
    ticking.current = true;
    requestAnimationFrame(() => {
      ticking.current = false;
      if (zoomSettlingRef.current) return;
      const container = containerRef.current;
      if (!container) return;
      const triggeredByScrollEvent = scrollEventPendingRef.current;
      scrollEventPendingRef.current = false;

      const prevScroll = lastKnownScrollRef.current;
      const scrollDeltaY = prevScroll
        ? Math.abs(container.scrollTop - prevScroll.top)
        : 0;
      const scrollDeltaX = prevScroll
        ? Math.abs(container.scrollLeft - prevScroll.left)
        : 0;
      const hasMeaningfulScroll = scrollDeltaY > 1 || scrollDeltaX > 1;

      lastKnownScrollRef.current = {
        top: container.scrollTop,
        left: container.scrollLeft,
      };

      if (selection && triggeredByScrollEvent && hasMeaningfulScroll) {
        clearSelection();
      }

      if (numPages < 1) {
        setVisiblePages([]);
        return;
      }

      const wrapperOffsetTop = pagesWrapperRef.current?.offsetTop ?? 0;
      const viewportTop = container.scrollTop;
      const viewportBottom = viewportTop + container.clientHeight;
      const visible: number[] = [];
      const overlaps: Array<{ pageNum: number; overlap: number }> = [];

      for (const [pageNum, pageElement] of pageElementsRef.current.entries()) {
        const top = wrapperOffsetTop + pageElement.offsetTop;
        const bottom = top + pageElement.offsetHeight;
        if (bottom > viewportTop && top < viewportBottom) {
          visible.push(pageNum);
          const overlap =
            Math.min(bottom, viewportBottom) - Math.max(top, viewportTop);
          overlaps.push({ pageNum, overlap });
        }
      }

      if (visible.length > 0) {
        visible.sort((a, b) => a - b);
        overlaps.sort((a, b) => {
          if (b.overlap !== a.overlap) return b.overlap - a.overlap;
          return a.pageNum - b.pageNum;
        });
        const dominantPage = overlaps[0]?.pageNum ?? visible[0];
        setVisiblePages(visible);
        setCurrentPage(dominantPage);
      }
    });
  }, [
    clearSelection,
    numPages,
    selection,
    setCurrentPage,
    setVisiblePages,
  ]);

  const handleContainerScroll = useCallback(() => {
    scrollEventPendingRef.current = true;
    handleScroll();
  }, [handleScroll]);

  // Scroll to a specific page
  const scrollToPage = useCallback((pageNum: number) => {
    const pageElement = pageElementsRef.current.get(pageNum);
    if (pageElement) {
      pageElement.scrollIntoView({ behavior: "auto", block: "start" });
    }
  }, []);

  // Expose scrollToPage via window for external callers (toolbar, sidebar, shortcuts)
  useEffect(() => {
    (window as unknown as Record<string, unknown>).__scrollToPage =
      scrollToPage;
    return () => {
      delete (window as unknown as Record<string, unknown>).__scrollToPage;
    };
  }, [scrollToPage]);

  useEffect(() => {
    handleScroll();
  }, [handleScroll, numPages, pdfData]);

  useEffect(() => {
    if (!pdfData || numPages < 1) return;
    const raf = window.requestAnimationFrame(() => {
      handleScroll();
    });
    return () => {
      window.cancelAnimationFrame(raf);
    };
  }, [handleScroll, pdfData, numPages, pageDimensions]);

  const captureZoomAnchorSnapshot = useCallback(
    (clientX?: number, clientY?: number): ZoomAnchorSnapshot | null => {
      const container = containerRef.current;
      const wrapper = pagesWrapperRef.current;
      if (!container || !wrapper) return null;

      const containerRect = container.getBoundingClientRect();
      const anchorX =
        clientX !== undefined ? clientX - containerRect.left : containerRect.width / 2;
      const anchorY =
        clientY !== undefined ? clientY - containerRect.top : containerRect.height / 2;
      const wrapperOffsetLeft = wrapper.offsetLeft;
      const wrapperOffsetTop = wrapper.offsetTop;
      const pointerX = container.scrollLeft + anchorX;
      const pointerY = container.scrollTop + anchorY;

      let pageNum: number | null = null;
      let bestDistance = Number.POSITIVE_INFINITY;

      for (const [candidatePage, pageElement] of pageElementsRef.current.entries()) {
        const pageTop = wrapperOffsetTop + pageElement.offsetTop;
        const pageBottom = pageTop + pageElement.offsetHeight;
        const centerY = (pageTop + pageBottom) / 2;
        const distance =
          pointerY >= pageTop && pointerY <= pageBottom
            ? 0
            : Math.abs(pointerY - centerY);

        if (distance < bestDistance) {
          bestDistance = distance;
          pageNum = candidatePage;
        }
      }

      let relX = 0.5;
      let relY = 0.5;

      if (pageNum !== null) {
        const pageElement = pageElementsRef.current.get(pageNum);
        if (pageElement) {
          const pageLeft = wrapperOffsetLeft + pageElement.offsetLeft;
          const pageTop = wrapperOffsetTop + pageElement.offsetTop;
          relX = clampScrollPosition(
            (pointerX - pageLeft) / Math.max(1, pageElement.offsetWidth),
          );
          relY = clampScrollPosition(
            (pointerY - pageTop) / Math.max(1, pageElement.offsetHeight),
          );
          relX = Math.min(1, relX);
          relY = Math.min(1, relY);
        }
      }

      return {
        anchorX,
        anchorY,
        contentX: pointerX - wrapperOffsetLeft,
        contentY: pointerY - wrapperOffsetTop,
        pageNum,
        relX,
        relY,
      };
    },
    [],
  );

  const applyZoomAnchorSnapshot = useCallback(
    (snapshot: ZoomAnchorSnapshot) => {
      const container = containerRef.current;
      const wrapper = pagesWrapperRef.current;
      if (!container || !wrapper) return;

      const wrapperOffsetLeft = wrapper.offsetLeft;
      const wrapperOffsetTop = wrapper.offsetTop;
      let targetScrollLeft: number | null = null;
      let targetScrollTop: number | null = null;

      if (snapshot.pageNum !== null) {
        const pageElement = pageElementsRef.current.get(snapshot.pageNum);
        if (pageElement) {
          const pageLeft = wrapperOffsetLeft + pageElement.offsetLeft;
          const pageTop = wrapperOffsetTop + pageElement.offsetTop;
          targetScrollLeft =
            pageLeft + snapshot.relX * pageElement.offsetWidth - snapshot.anchorX;
          targetScrollTop =
            pageTop + snapshot.relY * pageElement.offsetHeight - snapshot.anchorY;
        }
      }

      if (targetScrollLeft === null || targetScrollTop === null) {
        targetScrollLeft = snapshot.contentX + wrapperOffsetLeft - snapshot.anchorX;
        targetScrollTop = snapshot.contentY + wrapperOffsetTop - snapshot.anchorY;
      }

      container.scrollTop = clampScrollPosition(targetScrollTop);
      container.scrollLeft = clampScrollPosition(targetScrollLeft);
    },
    [],
  );

  const beginPinchPreview = useCallback((clientX?: number, clientY?: number) => {
    const container = containerRef.current;
    const wrapper = pagesWrapperRef.current;
    if (!container || !wrapper) return;

    const snapshot = captureZoomAnchorSnapshot(clientX, clientY);
    if (!snapshot) return;

    const currentZoom = usePdfStore.getState().zoom;

    pinchRef.current = {
      active: true,
      baseZoom: currentZoom,
      scale: 1,
      anchorX: snapshot.anchorX,
      anchorY: snapshot.anchorY,
      contentX: snapshot.contentX,
      contentY: snapshot.contentY,
      focusPage: snapshot.pageNum,
      focusRelX: snapshot.relX,
      focusRelY: snapshot.relY,
    };

    wrapper.style.willChange = "transform";
    wrapper.style.transformOrigin = `${Math.max(0, snapshot.contentX)}px ${Math.max(
      0,
      snapshot.contentY,
    )}px`;
  }, [captureZoomAnchorSnapshot]);

  const updatePinchPreview = useCallback((scale: number) => {
    const wrapper = pagesWrapperRef.current;
    if (!wrapper || !pinchRef.current.active) return;

    pinchRef.current.scale = scale;
    wrapper.style.transform = `scale(${scale})`;
  }, []);

  const commitPinchPreview = useCallback(() => {
    const container = containerRef.current;
    const wrapper = pagesWrapperRef.current;
    if (!container || !wrapper || !pinchRef.current.active) return;

    const pinch = pinchRef.current;
    const targetZoom = clampZoom(pinch.baseZoom * pinch.scale);
    const snapshot: ZoomAnchorSnapshot = {
      anchorX: pinch.anchorX,
      anchorY: pinch.anchorY,
      contentX: pinch.contentX,
      contentY: pinch.contentY,
      pageNum: pinch.focusPage,
      relX: pinch.focusRelX,
      relY: pinch.focusRelY,
    };

    wrapper.style.transform = "";
    wrapper.style.transformOrigin = "";
    wrapper.style.willChange = "";

    pinchRef.current.active = false;
    pinchRef.current.scale = 1;

    zoomSettlingRef.current = true;
    manuallyAnchoredZoomRef.current = true;
    setZoom(targetZoom);

    if (zoomAnchorRafRef.current !== null) {
      window.cancelAnimationFrame(zoomAnchorRafRef.current);
    }
    zoomAnchorRafRef.current = window.requestAnimationFrame(() => {
      zoomAnchorRafRef.current = null;
      applyZoomAnchorSnapshot(snapshot);
      zoomSettlingRef.current = false;
      handleScroll();
    });
  }, [applyZoomAnchorSnapshot, handleScroll, setZoom]);

  const zoomWithAnchorStep = useCallback(
    (targetZoom: number, clientX: number, clientY: number) => {
      const container = containerRef.current;
      if (!container) return;

      const snapshot = captureZoomAnchorSnapshot(clientX, clientY);
      if (!snapshot) return;

      const currentZoom = usePdfStore.getState().zoom;
      const nextZoom = clampZoom(targetZoom);
      if (Math.abs(nextZoom - currentZoom) < 0.0001) return;

      zoomSettlingRef.current = true;
      manuallyAnchoredZoomRef.current = true;
      setZoom(nextZoom);

      if (zoomAnchorRafRef.current !== null) {
        window.cancelAnimationFrame(zoomAnchorRafRef.current);
      }
      zoomAnchorRafRef.current = window.requestAnimationFrame(() => {
        zoomAnchorRafRef.current = null;
        applyZoomAnchorSnapshot(snapshot);
        zoomSettlingRef.current = false;
        handleScroll();
      });
    },
    [applyZoomAnchorSnapshot, captureZoomAnchorSnapshot, handleScroll, setZoom],
  );

  useLayoutEffect(() => {
    const container = containerRef.current;
    const prevZoom = prevZoomRef.current;

    if (prevZoom === null) {
      prevZoomRef.current = zoom;
      return;
    }

    if (!container || Math.abs(zoom - prevZoom) < 0.0001) {
      prevZoomRef.current = zoom;
      return;
    }

    if (manuallyAnchoredZoomRef.current) {
      manuallyAnchoredZoomRef.current = false;
      prevZoomRef.current = zoom;
      return;
    }

    // Keep toolbar/shortcut zoom anchored to viewport center.
    const anchorX = container.clientWidth / 2;
    const anchorY = container.clientHeight / 2;
    const ratio = zoom / prevZoom;
    container.scrollTop = (container.scrollTop + anchorY) * ratio - anchorY;
    container.scrollLeft = (container.scrollLeft + anchorX) * ratio - anchorX;

    prevZoomRef.current = zoom;
  }, [zoom]);

  // Trackpad pinch-to-zoom inside the PDF viewer only.
  // - WKWebView/Safari emits GestureEvents with scale.
  // - Chromium-style environments emit wheel events with ctrlKey=true.
  useEffect(() => {
    const container = containerRef.current;
    if (!container || !pdfData) return;

    let gestureIdleCommitTimer: number | null = null;
    const clearGestureIdleCommit = () => {
      if (gestureIdleCommitTimer !== null) {
        window.clearTimeout(gestureIdleCommitTimer);
        gestureIdleCommitTimer = null;
      }
    };
    const scheduleGestureIdleCommit = () => {
      clearGestureIdleCommit();
      gestureIdleCommitTimer = window.setTimeout(() => {
        gestureIdleCommitTimer = null;
        commitPinchPreview();
      }, 90);
    };

    const onGestureStart = (e: Event) => {
      const ge = e as GestureEvent;
      if (typeof ge.scale !== "number") return;
      e.preventDefault();
      clearGestureIdleCommit();

      const maybeClientX = (ge as unknown as { clientX?: number }).clientX;
      const maybeClientY = (ge as unknown as { clientY?: number }).clientY;
      const clientX = typeof maybeClientX === "number" ? maybeClientX : undefined;
      const clientY = typeof maybeClientY === "number" ? maybeClientY : undefined;

      beginPinchPreview(clientX, clientY);
    };

    const onGestureChange = (e: Event) => {
      const ge = e as GestureEvent;
      if (typeof ge.scale !== "number") return;
      e.preventDefault();
      const dampedScale = 1 + (ge.scale - 1) * GESTURE_SCALE_DAMPING;
      updatePinchPreview(dampedScale);
      scheduleGestureIdleCommit();
    };

    const onGestureEnd = (e: Event) => {
      const ge = e as GestureEvent;
      if (typeof ge.scale !== "number" && !pinchRef.current.active) return;
      e.preventDefault();
      clearGestureIdleCommit();
      commitPinchPreview();
    };

    const onWheel = (e: WheelEvent) => {
      if (pinchRef.current.active && !e.ctrlKey) {
        clearGestureIdleCommit();
        commitPinchPreview();
        return;
      }

      if (!e.ctrlKey) return;
      e.preventDefault();

      // Ignore wheel fallback while native gesture preview is active.
      if (pinchRef.current.active) return;

      const currentZoom = usePdfStore.getState().zoom;
      const clampedDelta = Math.max(
        -MAX_WHEEL_DELTA,
        Math.min(MAX_WHEEL_DELTA, e.deltaY),
      );
      const zoomFactor = Math.exp(-clampedDelta * WHEEL_ZOOM_SENSITIVITY);
      zoomWithAnchorStep(currentZoom * zoomFactor, e.clientX, e.clientY);
    };

    const onScrollDuringPinch = () => {
      if (!pinchRef.current.active) return;
      clearGestureIdleCommit();
      commitPinchPreview();
    };

    container.addEventListener("gesturestart", onGestureStart, {
      passive: false,
    });
    container.addEventListener("gesturechange", onGestureChange, {
      passive: false,
    });
    container.addEventListener("gestureend", onGestureEnd, {
      passive: false,
    });
    container.addEventListener("wheel", onWheel, { passive: false });
    container.addEventListener("scroll", onScrollDuringPinch, { passive: true });

    return () => {
      clearGestureIdleCommit();
      container.removeEventListener("gesturestart", onGestureStart);
      container.removeEventListener("gesturechange", onGestureChange);
      container.removeEventListener("gestureend", onGestureEnd);
      container.removeEventListener("wheel", onWheel);
      container.removeEventListener("scroll", onScrollDuringPinch);
    };
  }, [
    beginPinchPreview,
    commitPinchPreview,
    pdfData,
    updatePinchPreview,
    zoomWithAnchorStep,
  ]);

  // Click-to-place sticky note when in "note" mode, or deselect when in "view" mode
  const handlePageClick = useCallback(
    async (e: React.MouseEvent<HTMLDivElement>) => {
      // In view mode, clicking the page background deselects any selected annotation
      if (mode !== "note") {
        selectAnnotation(null);
        return;
      }

      const pageDiv = e.currentTarget;
      const pageNum = Number(pageDiv.dataset.pageNumber);
      if (!pageNum) return;

      const rect = pageDiv.getBoundingClientRect();
      const clickX = (e.clientX - rect.left) / renderZoom;
      const clickY = (e.clientY - rect.top) / renderZoom;
      const pageWidth = rect.width / renderZoom;
      const pageHeight = rect.height / renderZoom;

      const noteRect = { x: clickX, y: clickY, width: 0, height: 0 };

      try {
        const annotation = await addNote({
          type: "note",
          page_number: pageNum,
          position_data: {
            rects: [noteRect],
            page_width: pageWidth,
            page_height: pageHeight,
            selected_text: null,
            start_offset: null,
            end_offset: null,
          },
        });

        if (annotation) {
          selectAnnotation(annotation.id);
        }
      } catch (err) {
        console.error("[PdfViewer] Failed to add note:", err);
      }

      setMode("view");
    },
    [mode, renderZoom, addNote, selectAnnotation, setMode],
  );

  // Right-click context menu handler
  const handleContextMenu = useCallback(
    (e: React.MouseEvent<HTMLDivElement>) => {
      const pageDiv = e.currentTarget;
      const pageNum = Number(pageDiv.dataset.pageNumber);
      if (!pageNum) return;

      e.preventDefault();

      const rect = pageDiv.getBoundingClientRect();
      const clickX = (e.clientX - rect.left) / renderZoom;
      const clickY = (e.clientY - rect.top) / renderZoom;
      const pageWidth = rect.width / renderZoom;
      const pageHeight = rect.height / renderZoom;

      setContextMenu({
        x: e.clientX,
        y: e.clientY,
        pageNum,
        clickX,
        clickY,
        pageWidth,
        pageHeight,
      });
    },
    [renderZoom],
  );

  // Place note from context menu
  const handleContextMenuAddNote = useCallback(async () => {
    if (!contextMenu) return;

    const noteRect = {
      x: contextMenu.clickX,
      y: contextMenu.clickY,
      width: 0,
      height: 0,
    };

    try {
      const annotation = await addNote({
        type: "note",
        page_number: contextMenu.pageNum,
        position_data: {
          rects: [noteRect],
          page_width: contextMenu.pageWidth,
          page_height: contextMenu.pageHeight,
          selected_text: null,
          start_offset: null,
          end_offset: null,
        },
      });

      if (annotation) {
        selectAnnotation(annotation.id);
      }
    } catch (err) {
      console.error("[PdfViewer] Failed to add note via context menu:", err);
    }

    setContextMenu(null);
  }, [contextMenu, addNote, selectAnnotation]);

  // Deselect annotations when clicking the container background (gray area around pages)
  const handleContainerClick = useCallback(
    (e: React.MouseEvent<HTMLDivElement>) => {
      // Only deselect if the click target is the container itself (not bubbled from pages)
      if (e.target === e.currentTarget) {
        selectAnnotation(null);
      }
    },
    [selectAnnotation],
  );

  // Dismiss context menu on click outside or scroll
  useEffect(() => {
    if (!contextMenu) return;

    const dismiss = () => setContextMenu(null);
    window.addEventListener("click", dismiss);
    window.addEventListener("scroll", dismiss, true);
    return () => {
      window.removeEventListener("click", dismiss);
      window.removeEventListener("scroll", dismiss, true);
    };
  }, [contextMenu]);

  if (!doc) return null;

  if (pdfError) {
    return (
      <div className="flex flex-1 items-center justify-center bg-muted">
        <p className="text-destructive">Failed to read PDF: {pdfError}</p>
      </div>
    );
  }

  if (!pdfData) {
    return (
      <div className="flex flex-1 items-center justify-center bg-muted">
        <p className="text-muted-foreground">Loading PDF...</p>
      </div>
    );
  }

  return (
    <div
      ref={containerRef}
      className={cn(
        "relative min-h-0 min-w-0 flex-1 overflow-auto overscroll-contain bg-muted",
        mode === "note" && "cursor-crosshair",
      )}
      onScroll={handleContainerScroll}
      onMouseUp={handleMouseUp}
      onClick={handleContainerClick}
    >
      <ErrorBoundary>
        <Document
          file={pdfData}
          onLoadSuccess={onDocumentLoadSuccess}
          loading={
            <div className="flex h-full items-center justify-center">
              <p className="text-muted-foreground">Loading PDF...</p>
            </div>
          }
          error={
            <div className="flex h-full items-center justify-center">
              <p className="text-destructive">Failed to load PDF</p>
            </div>
          }
        >
          <div
            ref={pagesWrapperRef}
            className="mx-auto flex w-max min-w-full flex-col items-center gap-3 py-4"
          >
            {pageNumbers.map((pageNum) => {
              const shouldRender = pagesToRender.has(pageNum);
              const dims = pageDimensions[pageNum];
              const pageAnnotations = annotationsByPage.get(pageNum);

              return (
                <div
                  key={pageNum}
                  ref={(el) => {
                    if (el) {
                      pageElementsRef.current.set(pageNum, el);
                    } else {
                      pageElementsRef.current.delete(pageNum);
                    }
                  }}
                  className="relative w-fit shadow-md"
                  data-page-number={pageNum}
                  onClick={shouldRender ? handlePageClick : undefined}
                  onContextMenu={shouldRender ? handleContextMenu : undefined}
                >
                  {shouldRender ? (
                    <>
                      <Page
                        pageNumber={pageNum}
                        scale={renderZoom}
                        devicePixelRatio={renderDevicePixelRatio}
                        onLoadSuccess={handlePageLoad(pageNum)}
                        renderTextLayer={
                          visiblePagesSet.has(pageNum) || pageNum === currentPage
                        }
                        renderAnnotationLayer={false}
                      />
                      {pageAnnotations && pageAnnotations.length > 0 && (
                        <HighlightLayer
                          zoom={renderZoom}
                          annotations={pageAnnotations}
                        />
                      )}
                    </>
                  ) : (
                    /* Placeholder — preserves scroll height for off-screen pages */
                    <div
                      className="bg-white"
                        style={{
                          width:
                            (dims?.width ?? DEFAULT_PAGE_WIDTH) * renderZoom,
                          height:
                            (dims?.height ?? DEFAULT_PAGE_HEIGHT) * renderZoom,
                        }}
                      />
                  )}
                </div>
              );
            })}
          </div>
        </Document>
      </ErrorBoundary>

      {selection && popoverPosition && (
        <SelectionPopover
          ref={popoverRef}
          position={popoverPosition}
          selection={selection}
          currentPage={selection.pageNumber}
          onClose={clearSelection}
        />
      )}

      {/* Right-click context menu */}
      {contextMenu && (
        <div
          className="fixed z-50 min-w-[160px] rounded-lg border bg-background py-1 shadow-lg"
          style={{ left: contextMenu.x, top: contextMenu.y }}
          onClick={(e) => e.stopPropagation()}
        >
          <button
            className="flex w-full items-center gap-2 px-3 py-1.5 text-left text-sm hover:bg-accent"
            onClick={handleContextMenuAddNote}
          >
            <StickyNote size={14} className="text-amber-500" />
            Add note here
          </button>
        </div>
      )}
    </div>
  );
}
