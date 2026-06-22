import { create } from "zustand";
import type {
  Annotation,
  CreateAnnotationInput,
  UpdateAnnotationInput,
} from "@/types";
import * as commands from "@/lib/tauri-commands";

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
    set({ isLoading: true });
    try {
      const annotations = await commands.getAnnotations();
      set({ annotations, isLoading: false });
    } catch (err) {
      console.error("[annotation-store] Failed to load annotations:", err);
      set({ isLoading: false });
    }
  },

  addHighlight: async (input: CreateAnnotationInput) => {
    try {
      const annotation = await commands.createAnnotation({
        ...input,
        type: "highlight",
      });
      set((state) => ({
        annotations: [...state.annotations, annotation],
      }));
      return annotation;
    } catch (err) {
      console.error("[annotation-store] Failed to create highlight:", err);
      return null;
    }
  },

  addNote: async (input: CreateAnnotationInput) => {
    try {
      const annotation = await commands.createAnnotation({
        ...input,
        type: "note",
      });
      set((state) => ({
        annotations: [...state.annotations, annotation],
      }));
      return annotation;
    } catch (err) {
      console.error("[annotation-store] Failed to create note:", err);
      return null;
    }
  },

  addBookmark: async (pageNumber: number) => {
    try {
      const annotation = await commands.createAnnotation({
        type: "bookmark",
        page_number: pageNumber,
      });
      set((state) => ({
        annotations: [...state.annotations, annotation],
      }));
      return annotation;
    } catch (err) {
      console.error("[annotation-store] Failed to create bookmark:", err);
      return null;
    }
  },

  updateAnnotation: async (input: UpdateAnnotationInput) => {
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
      const updated = await commands.updateAnnotation(input);
      if (!updated) {
        throw new Error(`Annotation ${input.id} was not found`);
      }
    } catch (err) {
      console.error("[annotation-store] Failed to update annotation:", err);
      // Reload on failure to revert optimistic update
      get().loadAnnotations();
    }
  },

  deleteAnnotation: async (id: string) => {
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
      const deleted = await commands.deleteAnnotation(id);
      if (!deleted) {
        throw new Error(`Annotation ${id} was not found`);
      }
    } catch (err) {
      console.error("[annotation-store] Failed to delete annotation:", err);
      // Revert on failure
      set({ annotations: prev });
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
