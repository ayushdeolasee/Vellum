import type { DocumentInfo, DocumentKind } from "@/types";

export interface RecentPdf {
  /** File path for PDFs, normalized URL for webpages. */
  pdf_path: string;
  kind: DocumentKind;
  title: string | null;
  page_count: number | null;
  opened_at: string;
}

const RECENT_PDFS_STORAGE_KEY = "vellum.recent-pdfs";
const MAX_RECENT_PDFS = 8;

export function getRecentPdfs(): RecentPdf[] {
  try {
    const stored = localStorage.getItem(RECENT_PDFS_STORAGE_KEY);
    if (!stored) return [];

    const parsed: unknown = JSON.parse(stored);
    if (!Array.isArray(parsed)) return [];

    return parsed.filter(isRecentPdf).slice(0, MAX_RECENT_PDFS);
  } catch {
    return [];
  }
}

export function recordRecentPdf(document: DocumentInfo): void {
  const recentPdf: RecentPdf = {
    pdf_path: document.pdf_path,
    kind: document.kind ?? "pdf",
    title: document.title,
    page_count: document.page_count,
    opened_at: new Date().toISOString(),
  };
  const next = [
    recentPdf,
    ...getRecentPdfs().filter((pdf) => pdf.pdf_path !== document.pdf_path),
  ].slice(0, MAX_RECENT_PDFS);

  writeRecentPdfs(next);
}

export function removeRecentPdf(path: string): RecentPdf[] {
  const next = getRecentPdfs().filter((pdf) => pdf.pdf_path !== path);
  writeRecentPdfs(next);
  return next;
}

export function getPdfFileName(path: string): string {
  return path.split(/[\\/]/).filter(Boolean).pop() ?? path;
}

/** Compact display label for a webpage URL, e.g. "example.com/post". */
export function getWebpageDisplayName(url: string): string {
  try {
    const parsed = new URL(url);
    const path = parsed.pathname === "/" ? "" : parsed.pathname.replace(/\/$/, "");
    return `${parsed.hostname}${path}`;
  } catch {
    return url;
  }
}

function isRecentPdf(value: unknown): value is RecentPdf {
  if (typeof value !== "object" || value === null) return false;

  const pdf = value as Partial<RecentPdf> & { kind?: unknown };
  if (
    typeof pdf.pdf_path !== "string" ||
    !(typeof pdf.title === "string" || pdf.title === null) ||
    !(typeof pdf.page_count === "number" || pdf.page_count === null) ||
    typeof pdf.opened_at !== "string"
  ) {
    return false;
  }

  // Entries written before webpage support have no kind; treat them as PDFs.
  if (pdf.kind === undefined) {
    (pdf as RecentPdf).kind = "pdf";
    return true;
  }
  return pdf.kind === "pdf" || pdf.kind === "web";
}

function writeRecentPdfs(recentPdfs: RecentPdf[]): void {
  try {
    localStorage.setItem(RECENT_PDFS_STORAGE_KEY, JSON.stringify(recentPdfs));
  } catch {
    // Recent files are a convenience; opening a PDF should still succeed.
  }
}
