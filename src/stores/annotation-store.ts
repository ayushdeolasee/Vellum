import { create } from "zustand";
import type {
  Annotation,
  CreateAnnotationInput,
  DocumentKind,
  PositionData,
  UpdateAnnotationInput,
} from "@/types";
import * as commands from "@/lib/tauri-commands";
import { usePdfStore } from "@/stores/pdf-store";

/**
 * The bookmark the toggle button/shortcut acts on. PDF bookmarks are per
 * page; web bookmarks anchor to a text position, so "current" means a
 * bookmark whose anchor is on screen right now. Web bookmarks from before
 * point anchoring existed have no offsets and fall back to page matching.
 */
export function findCurrentBookmark(
  annotations: Annotation[],
  docKind: DocumentKind | undefined,
  currentPage: number,
  webVisibleRange: { start: number; end: number } | null,
): Annotation | undefined {
  return annotations.find((a) => {
    if (a.type !== "bookmark") return false;
    const start = a.position_data?.start_offset;
    if (docKind === "web" && start != null) {
      if (!webVisibleRange) return false;
      return start >= webVisibleRange.start && start < webVisibleRange.end;
    }
    return a.page_number === currentPage;
  });
}

interface AnnotationState {
  // All annotations for the current document
  annotations: Annotation[];
  isLoading: boolean;

  // Selection state
  selectedAnnotationId: string | null;

  // Actions
  loadAnnotations: () => Promise<void>;
  addHighlight: (input: CreateAnnotationInput) => Promise<Annotation | null>;
  addNote: (input: CreateAnnotationInput) => Promise<Annotation | null>;
  addBookmark: (
    pageNumber: number,
    positionData?: PositionData,
  ) => Promise<Annotation | null>;
  /** Add or remove the bookmark at the current reading position. */
  toggleBookmark: () => Promise<void>;
  updateAnnotation: (input: UpdateAnnotationInput) => Promise<void>;
  deleteAnnotation: (id: string) => Promise<void>;
  selectAnnotation: (id: string | null) => void;
  clearAnnotations: () => void;

  // Derived helpers
  getAnnotationsForPage: (pageNumber: number) => Annotation[];
}

export const useAnnotationStore = create<AnnotationState>((set, get) => ({
  annotations: [],
  isLoading: false,
  selectedAnnotationId: null,

  loadAnnotations: async () => {
    const sessionId = usePdfStore.getState().activeTabId;
    if (!sessionId) {
      set({ annotations: [], isLoading: false, selectedAnnotationId: null });
      return;
    }
    set({ isLoading: true });
    try {
      const annotations = await commands.getAnnotations(sessionId);
      if (usePdfStore.getState().activeTabId === sessionId) {
        set({ annotations, isLoading: false, selectedAnnotationId: null });
      }
    } catch (err) {
      console.error("[annotation-store] Failed to load annotations:", err);
      if (usePdfStore.getState().activeTabId === sessionId) {
        set({ isLoading: false });
      }
    }
  },

  addHighlight: async (input: CreateAnnotationInput) => {
    const sessionId = usePdfStore.getState().activeTabId;
    if (!sessionId) return null;
    try {
      const annotation = await commands.createAnnotation(sessionId, {
        ...input,
        type: "highlight",
      });
      if (usePdfStore.getState().activeTabId === sessionId) {
        set((state) => ({
          annotations: [...state.annotations, annotation],
        }));
        return annotation;
      }
      return null;
    } catch (err) {
      console.error("[annotation-store] Failed to create highlight:", err);
      return null;
    }
  },

  addNote: async (input: CreateAnnotationInput) => {
    const sessionId = usePdfStore.getState().activeTabId;
    if (!sessionId) return null;
    try {
      const annotation = await commands.createAnnotation(sessionId, {
        ...input,
        type: "note",
      });
      if (usePdfStore.getState().activeTabId === sessionId) {
        set((state) => ({
          annotations: [...state.annotations, annotation],
        }));
        return annotation;
      }
      return null;
    } catch (err) {
      console.error("[annotation-store] Failed to create note:", err);
      return null;
    }
  },

  addBookmark: async (pageNumber: number, positionData?: PositionData) => {
    const sessionId = usePdfStore.getState().activeTabId;
    if (!sessionId) return null;
    try {
      const annotation = await commands.createAnnotation(sessionId, {
        type: "bookmark",
        page_number: pageNumber,
        ...(positionData && { position_data: positionData }),
      });
      if (usePdfStore.getState().activeTabId === sessionId) {
        set((state) => ({
          annotations: [...state.annotations, annotation],
        }));
        return annotation;
      }
      return null;
    } catch (err) {
      console.error("[annotation-store] Failed to create bookmark:", err);
      return null;
    }
  },

  toggleBookmark: async () => {
    const pdfState = usePdfStore.getState();
    const doc = pdfState.document;
    if (!doc) return;

    const existing = findCurrentBookmark(
      get().annotations,
      doc.kind,
      pdfState.currentPage,
      pdfState.webVisibleRange,
    );
    if (existing) {
      await get().deleteAnnotation(existing.id);
      return;
    }

    if (doc.kind === "web") {
      const capture = (window as unknown as Record<string, unknown>)
        .__captureWebPosition as
        | (() => Promise<{ pageNumber: number; positionData: PositionData } | null>)
        | undefined;
      const captured = capture ? await capture() : null;
      if (captured) {
        await get().addBookmark(captured.pageNumber, captured.positionData);
        return;
      }
    }
    await get().addBookmark(pdfState.currentPage);
  },

  updateAnnotation: async (input: UpdateAnnotationInput) => {
    const sessionId = usePdfStore.getState().activeTabId;
    if (!sessionId) return;
    // Optimistic update
    set((state) => ({
      annotations: state.annotations.map((a) =>
        a.id === input.id
          ? {
              ...a,
              ...(input.color !== undefined && { color: input.color }),
              ...(input.content !== undefined && { content: input.content }),
              ...(input.position_data !== undefined && { position_data: input.position_data }),
              updated_at: new Date().toISOString(),
            }
          : a,
      ),
    }));
    try {
      const updated = await commands.updateAnnotation(sessionId, input);
      if (!updated) {
        throw new Error(`Annotation ${input.id} was not found`);
      }
    } catch (err) {
      console.error("[annotation-store] Failed to update annotation:", err);
      // Reload on failure to revert optimistic update
      if (usePdfStore.getState().activeTabId === sessionId) {
        get().loadAnnotations();
      }
    }
  },

  deleteAnnotation: async (id: string) => {
    const sessionId = usePdfStore.getState().activeTabId;
    if (!sessionId) return;
    // Optimistic delete
    const prev = get().annotations;
    set((state) => ({
      annotations: state.annotations.filter((a) => a.id !== id),
      selectedAnnotationId:
        state.selectedAnnotationId === id
          ? null
          : state.selectedAnnotationId,
    }));
    try {
      const deleted = await commands.deleteAnnotation(sessionId, id);
      if (!deleted) {
        throw new Error(`Annotation ${id} was not found`);
      }
    } catch (err) {
      console.error("[annotation-store] Failed to delete annotation:", err);
      // Revert on failure
      if (usePdfStore.getState().activeTabId === sessionId) {
        set({ annotations: prev });
      }
    }
  },

  selectAnnotation: (id: string | null) =>
    set({ selectedAnnotationId: id }),

  clearAnnotations: () =>
    set({ annotations: [], selectedAnnotationId: null }),

  getAnnotationsForPage: (pageNumber: number) => {
    return get().annotations.filter((a) => a.page_number === pageNumber);
  },
}));
