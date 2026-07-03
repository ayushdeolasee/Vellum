import { create } from "zustand";
import * as commands from "@/lib/tauri-commands";
import { recordRecentPdf } from "@/lib/recent-pdfs";
import type { DocumentInfo, PdfTab } from "@/types";

export type InteractionMode = "view" | "note";

interface PdfState {
  // Tab state
  tabs: PdfTab[];
  activeTabId: string | null;

  // Active document state
  document: DocumentInfo | null;
  isLoading: boolean;
  error: string | null;

  // Active viewport state
  currentPage: number;
  numPages: number;
  zoom: number;
  visiblePages: number[];
  /** Raw text-offset span currently on screen (web documents only). */
  webVisibleRange: { start: number; end: number } | null;

  // Active interaction mode
  mode: InteractionMode;

  // Actions
  openFile: (path: string) => Promise<void>;
  openFiles: (paths: string[]) => Promise<void>;
  openUrl: (url: string) => Promise<void>;
  /** Rebind a webpage tab to a new URL (in-tab link navigation). */
  webNavigated: (tabId: string, url: string) => Promise<DocumentInfo | null>;
  /** Update a tab's document title (reported by the webpage content script). */
  updateDocumentTitle: (tabId: string, title: string) => void;
  closeFile: () => Promise<void>;
  closeTab: (tabId: string) => Promise<void>;
  activateTab: (tabId: string) => void;
  setCurrentPage: (page: number) => void;
  setNumPages: (num: number) => void;
  setZoom: (zoom: number) => void;
  zoomIn: () => void;
  zoomOut: () => void;
  setVisiblePages: (pages: number[]) => void;
  setWebVisibleRange: (range: { start: number; end: number } | null) => void;
  goToPage: (page: number) => void;
  setMode: (mode: InteractionMode) => void;
}

const MIN_ZOOM = 0.25;
const MAX_ZOOM = 4.0;
const ZOOM_STEP = 0.1;

const EMPTY_ACTIVE_STATE = {
  activeTabId: null,
  document: null,
  currentPage: 1,
  numPages: 0,
  zoom: 1.0,
  visiblePages: [] as number[],
  webVisibleRange: null as { start: number; end: number } | null,
  mode: "view" as InteractionMode,
};

function activeStateFromTab(tab: PdfTab) {
  return {
    activeTabId: tab.id,
    document: tab.document,
    currentPage: tab.currentPage,
    numPages: tab.numPages,
    zoom: tab.zoom,
    visiblePages: tab.visiblePages,
    webVisibleRange: tab.webVisibleRange,
    mode: tab.mode,
  };
}

export const usePdfStore = create<PdfState>((set, get) => {
  const updateActiveTab = (updates: Partial<PdfTab>) => {
    const activeTabId = get().activeTabId;
    if (!activeTabId) return;
    set((state) => ({
      tabs: state.tabs.map((tab) =>
        tab.id === activeTabId ? { ...tab, ...updates } : tab,
      ),
    }));
  };

  const adoptOpenedDocument = async (doc: DocumentInfo, sessionId: string) => {
    recordRecentPdf(doc);
    const existing = get().tabs.find(
      (tab) => tab.document.pdf_path === doc.pdf_path,
    );

    if (existing) {
      await commands.closeFile(sessionId).catch(() => {});
      get().activateTab(existing.id);
      return;
    }

    const tab: PdfTab = {
      id: sessionId,
      document: doc,
      currentPage: doc.last_page ?? 1,
      numPages: doc.page_count ?? 0,
      zoom: 1.0,
      visiblePages: [],
      webVisibleRange: null,
      mode: "view",
    };

    set((state) => ({
      tabs: [...state.tabs, tab],
      ...activeStateFromTab(tab),
    }));
  };

  const openOneFile = async (path: string) => {
    const sessionId = crypto.randomUUID();
    // .vellumweb archives import as web documents; everything else is a PDF.
    const isArchive = path.toLowerCase().endsWith(".vellumweb");
    const doc = isArchive
      ? await commands.openVellumwebFile(path, sessionId)
      : await commands.openFile(path, sessionId);
    await adoptOpenedDocument(doc, sessionId);
    if (isArchive) {
      // The import may have merged annotations into a tab that is already
      // open and active, in which case no document change fires — nudge the
      // annotation store to reload.
      window.dispatchEvent(new CustomEvent("vellum:annotations-updated"));
    }
  };

  const openOneUrl = async (url: string) => {
    const sessionId = crypto.randomUUID();
    const doc = await commands.openWebDocument(url, sessionId);
    await adoptOpenedDocument(doc, sessionId);
  };

  return {
    tabs: [],
    ...EMPTY_ACTIVE_STATE,
    isLoading: false,
    error: null,

    openFile: async (path: string) => {
      set({ isLoading: true, error: null });
      try {
        await openOneFile(path);
        set({ isLoading: false });
      } catch (e) {
        set({ isLoading: false, error: String(e) });
      }
    },

    openFiles: async (paths: string[]) => {
      if (paths.length === 0) return;
      set({ isLoading: true, error: null });
      const errors: string[] = [];

      for (const path of paths) {
        try {
          await openOneFile(path);
        } catch (e) {
          errors.push(`${path}: ${String(e)}`);
        }
      }

      set({
        isLoading: false,
        error: errors.length > 0 ? errors.join("\n") : null,
      });
    },

    openUrl: async (url: string) => {
      set({ isLoading: true, error: null });
      try {
        await openOneUrl(url);
        set({ isLoading: false });
      } catch (e) {
        set({ isLoading: false, error: String(e) });
      }
    },

    webNavigated: async (tabId: string, url: string) => {
      const tab = get().tabs.find((candidate) => candidate.id === tabId);
      if (!tab || tab.document.kind !== "web") return null;
      try {
        // Reuse the session id: the Rust side rebinds the session to the new
        // URL, so annotation commands keep working against the same tab.
        const doc = await commands.openWebDocument(url, tabId);
        recordRecentPdf(doc);
        set((state) => ({
          tabs: state.tabs.map((candidate) =>
            candidate.id === tabId
              ? {
                  ...candidate,
                  document: doc,
                  currentPage: doc.last_page ?? 1,
                  numPages: doc.page_count ?? 0,
                  visiblePages: [],
                  webVisibleRange: null,
                }
              : candidate,
          ),
          ...(state.activeTabId === tabId
            ? {
                document: doc,
                currentPage: doc.last_page ?? 1,
                numPages: doc.page_count ?? 0,
                visiblePages: [] as number[],
                webVisibleRange: null,
              }
            : {}),
        }));
        return doc;
      } catch (e) {
        set({ error: String(e) });
        return null;
      }
    },

    updateDocumentTitle: (tabId: string, title: string) => {
      const trimmed = title.trim();
      if (!trimmed) return;
      set((state) => {
        const tab = state.tabs.find((candidate) => candidate.id === tabId);
        if (!tab || tab.document.title === trimmed) return state;
        const document = { ...tab.document, title: trimmed };
        return {
          tabs: state.tabs.map((candidate) =>
            candidate.id === tabId ? { ...candidate, document } : candidate,
          ),
          ...(state.activeTabId === tabId ? { document } : {}),
        };
      });
    },

    closeFile: async () => {
      const activeTabId = get().activeTabId;
      if (activeTabId) {
        await get().closeTab(activeTabId);
      }
    },

    closeTab: async (tabId: string) => {
      const state = get();
      const closingIndex = state.tabs.findIndex((tab) => tab.id === tabId);
      if (closingIndex < 0) return;

      const closingTab = state.tabs[closingIndex];
      await commands
        .setDocumentMetadata(
          closingTab.id,
          "last_page",
          String(closingTab.currentPage),
        )
        .catch(() => {});
      await commands.closeFile(closingTab.id).catch(() => {});

      set((current) => {
        const tabs = current.tabs.filter((tab) => tab.id !== tabId);
        if (current.activeTabId !== tabId) {
          return { tabs };
        }

        const nextTab =
          tabs[Math.min(closingIndex, tabs.length - 1)] ?? null;
        return nextTab
          ? { tabs, ...activeStateFromTab(nextTab) }
          : { tabs, ...EMPTY_ACTIVE_STATE };
      });
    },

    activateTab: (tabId: string) => {
      const state = get();
      if (state.activeTabId === tabId) return;
      const tab = state.tabs.find((candidate) => candidate.id === tabId);
      if (!tab) return;

      const currentTab = state.tabs.find(
        (candidate) => candidate.id === state.activeTabId,
      );
      if (currentTab) {
        commands
          .setDocumentMetadata(
            currentTab.id,
            "last_page",
            String(currentTab.currentPage),
          )
          .catch(() => {});
      }

      set(activeStateFromTab(tab));
    },

    setCurrentPage: (page: number) => {
      if (get().currentPage === page) return;
      set({ currentPage: page });
      updateActiveTab({ currentPage: page });
    },

    setNumPages: (num: number) => {
      set({ numPages: num });
      updateActiveTab({ numPages: num });
      const activeTabId = get().activeTabId;
      if (activeTabId) {
        commands
          .setDocumentMetadata(activeTabId, "page_count", String(num))
          .catch(() => {});
      }
    },

    setZoom: (zoom: number) => {
      const nextZoom = Math.min(MAX_ZOOM, Math.max(MIN_ZOOM, zoom));
      set({ zoom: nextZoom });
      updateActiveTab({ zoom: nextZoom });
    },

    zoomIn: () => {
      const nextZoom = get().zoom + ZOOM_STEP;
      const zoomTo = (window as unknown as Record<string, unknown>)
        .__zoomPdfTo as ((targetZoom: number) => void) | undefined;
      if (zoomTo) {
        zoomTo(nextZoom);
      } else {
        get().setZoom(nextZoom);
      }
    },

    zoomOut: () => {
      const nextZoom = get().zoom - ZOOM_STEP;
      const zoomTo = (window as unknown as Record<string, unknown>)
        .__zoomPdfTo as ((targetZoom: number) => void) | undefined;
      if (zoomTo) {
        zoomTo(nextZoom);
      } else {
        get().setZoom(nextZoom);
      }
    },

    setVisiblePages: (pages: number[]) => {
      const prev = get().visiblePages;
      if (
        pages.length === prev.length &&
        pages.every((page, index) => page === prev[index])
      ) {
        return;
      }
      set({ visiblePages: pages });
      updateActiveTab({ visiblePages: pages });
    },

    setWebVisibleRange: (range) => {
      const prev = get().webVisibleRange;
      if (
        prev === range ||
        (prev && range && prev.start === range.start && prev.end === range.end)
      ) {
        return;
      }
      set({ webVisibleRange: range });
      updateActiveTab({ webVisibleRange: range });
    },

    goToPage: (page: number) => {
      const { numPages } = get();
      // Before the document reports its page count, clamping would produce
      // page 0 — ignore navigation until pages exist.
      if (numPages < 1) return;
      const clamped = Math.min(numPages, Math.max(1, page));
      get().setCurrentPage(clamped);
      const scrollToPage = (window as unknown as Record<string, unknown>)
        .__scrollToPage as ((targetPage: number) => void) | undefined;
      scrollToPage?.(clamped);
    },

    setMode: (mode: InteractionMode) => {
      set({ mode });
      updateActiveTab({ mode });
    },
  };
});
