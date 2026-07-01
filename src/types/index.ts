// Core annotation types — mirrors the Rust models

export type AnnotationType = "highlight" | "note" | "bookmark";

export interface Rect {
  x: number;
  y: number;
  width: number;
  height: number;
}

export interface PositionData {
  rects: Rect[];
  page_width: number;
  page_height: number;
  selected_text: string | null;
  start_offset: number | null;
  end_offset: number | null;
}

export interface Annotation {
  id: string;
  type: AnnotationType;
  page_number: number;
  color: string | null;
  content: string | null;
  position_data: PositionData | null;
  created_at: string;
  updated_at: string;
}

export interface CreateAnnotationInput {
  type: AnnotationType;
  page_number: number;
  color?: string;
  content?: string;
  position_data?: PositionData;
}

export interface UpdateAnnotationInput {
  id: string;
  color?: string;
  content?: string;
  position_data?: PositionData;
}

export interface DocumentInfo {
  pdf_path: string;
  title: string | null;
  page_count: number | null;
  last_page: number | null;
}

export interface PdfTab {
  id: string;
  document: DocumentInfo;
  currentPage: number;
  numPages: number;
  zoom: number;
  visiblePages: number[];
  mode: "view" | "note";
}

export const HIGHLIGHT_COLORS = [
  { name: "Yellow", value: "#fef08a", dark: "#854d0e80" },
  { name: "Green", value: "#bbf7d0", dark: "#16653480" },
  { name: "Blue", value: "#bfdbfe", dark: "#1e40af80" },
  { name: "Pink", value: "#fbcfe8", dark: "#9d174d80" },
  { name: "Purple", value: "#ddd6fe", dark: "#5b21b680" },
] as const;
