import { create } from "zustand";
import type { DocumentInfo } from "@/types";
import * as commands from "@/lib/tauri-commands";

export type InteractionMode = "view" | "note";

interface PdfState {
  // Document state
  document: DocumentInfo | null;
  isLoading: boolean;
  error: string | null;

  // Viewport state
  currentPage: number;
  numPages: number;
  zoom: number;
  visiblePages: number[];

  // Interaction mode
  mode: InteractionMode;

  // Actions
  openFile: (path: string) => Promise<void>;
  closeFile: () => Promise<void>;
  setCurrentPage: (page: number) => void;
  setNumPages: (num: number) => void;
  setZoom: (zoom: number) => void;
  zoomIn: () => void;
  zoomOut: () => void;
  setVisiblePages: (pages: number[]) => void;
  goToPage: (page: number) => void;
  setMode: (mode: InteractionMode) => void;
}

const MIN_ZOOM = 0.25;
const MAX_ZOOM = 4.0;
const ZOOM_STEP = 0.1;

export const usePdfStore = create<PdfState>((set, get) => ({
  document: null,
  isLoading: false,
  error: null,
  currentPage: 1,
  numPages: 0,
  zoom: 1.0,
  visiblePages: [],
  mode: "view",

  openFile: async (path: string) => {
    set({ isLoading: true, error: null });
    try {
      const doc = await commands.openFile(path);
      set({
        document: doc,
        isLoading: false,
        currentPage: doc.last_page ?? 1,
        numPages: doc.page_count ?? 0,
      });
    } catch (e) {
      set({ isLoading: false, error: String(e) });
    }
  },

  closeFile: async () => {
    try {
      const { currentPage } = get();
      await commands.setDocumentMetadata("last_page", String(currentPage));
      await commands.closeFile();
    } catch {
      // Ignore close errors
    }
    set({
      document: null,
      currentPage: 1,
      numPages: 0,
      zoom: 1.0,
      visiblePages: [],
      mode: "view",
    });
  },

  setCurrentPage: (page: number) => {
    if (get().currentPage === page) return;
    set({ currentPage: page });
  },
  setNumPages: (num: number) => {
    set({ numPages: num });
    // Page count is derived from the PDF; the backend skips redundant writes.
    commands.setDocumentMetadata("page_count", String(num)).catch(() => {});
  },
  setZoom: (zoom: number) =>
    set({ zoom: Math.min(MAX_ZOOM, Math.max(MIN_ZOOM, zoom)) }),
  zoomIn: () => {
    const { zoom } = get();
    set({ zoom: Math.min(MAX_ZOOM, zoom + ZOOM_STEP) });
  },
  zoomOut: () => {
    const { zoom } = get();
    set({ zoom: Math.max(MIN_ZOOM, zoom - ZOOM_STEP) });
  },
  setVisiblePages: (pages: number[]) => {
    const prev = get().visiblePages;
    if (
      pages.length === prev.length &&
      pages.every((p, i) => p === prev[i])
    )
      return;
    set({ visiblePages: pages });
  },
  goToPage: (page: number) => {
    const { numPages } = get();
    const clamped = Math.min(numPages, Math.max(1, page));
    set({ currentPage: clamped });
    // Trigger scroll to the target page
    const scrollToPage = (window as unknown as Record<string, unknown>)
      .__scrollToPage as ((page: number) => void) | undefined;
    scrollToPage?.(clamped);
  },
  setMode: (mode: InteractionMode) => set({ mode }),
}));
