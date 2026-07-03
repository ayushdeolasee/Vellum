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
  /** Text-quote anchor context for webpage annotations (normalized text,
   *  ~32 chars each side). Absent for PDF annotations. */
  prefix?: string | null;
  suffix?: string | null;
  /** How far below the viewport top (CSS px) the anchor text sat when a
   *  webpage point bookmark was captured. Absent for PDFs and selections. */
  viewport_offset?: number | null;
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

export type DocumentKind = "pdf" | "web";

export interface DocumentInfo {
  /** "pdf" for files on disk, "web" for proxied webpages. */
  kind: DocumentKind;
  /** Generic document URI: a filesystem path for PDFs, a normalized URL for
   *  webpages. The name is kept for compatibility with stored data keyed on it. */
  pdf_path: string;
  title: string | null;
  page_count: number | null;
  last_page: number | null;
}

export interface VellumwebExportSummary {
  path: string;
  bytes: number;
  asset_count: number;
  assets_skipped: number;
}

export interface WebLibraryEntry {
  url: string;
  title: string | null;
  page_count: number | null;
  saved_at: string | null;
  has_snapshot: boolean;
}

export interface PdfTab {
  id: string;
  document: DocumentInfo;
  currentPage: number;
  numPages: number;
  zoom: number;
  visiblePages: number[];
  /** Raw text-offset span currently on screen (web documents only). */
  webVisibleRange: { start: number; end: number } | null;
  mode: "view" | "note";
}

export const HIGHLIGHT_COLORS = [
  { name: "Yellow", value: "#fef08a", dark: "#854d0e80" },
  { name: "Green", value: "#bbf7d0", dark: "#16653480" },
  { name: "Blue", value: "#bfdbfe", dark: "#1e40af80" },
  { name: "Pink", value: "#fbcfe8", dark: "#9d174d80" },
  { name: "Purple", value: "#ddd6fe", dark: "#5b21b680" },
] as const;
