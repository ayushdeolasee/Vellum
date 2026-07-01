import { create } from "zustand";
import type {
  Annotation,
  CreateAnnotationInput,
  UpdateAnnotationInput,
} from "@/types";
import * as commands from "@/lib/tauri-commands";
import { usePdfStore } from "@/stores/pdf-store";

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
  addBookmark: (pageNumber: number) => Promise<Annotation | null>;
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

  addBookmark: async (pageNumber: number) => {
    const sessionId = usePdfStore.getState().activeTabId;
    if (!sessionId) return null;
    try {
      const annotation = await commands.createAnnotation(sessionId, {
        type: "bookmark",
        page_number: pageNumber,
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
