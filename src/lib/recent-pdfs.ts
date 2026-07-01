import type { DocumentInfo } from "@/types";

export interface RecentPdf {
  pdf_path: string;
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

function isRecentPdf(value: unknown): value is RecentPdf {
  if (typeof value !== "object" || value === null) return false;

  const pdf = value as Partial<RecentPdf>;
  return (
    typeof pdf.pdf_path === "string" &&
    (typeof pdf.title === "string" || pdf.title === null) &&
    (typeof pdf.page_count === "number" || pdf.page_count === null) &&
    typeof pdf.opened_at === "string"
  );
}

function writeRecentPdfs(recentPdfs: RecentPdf[]): void {
  try {
    localStorage.setItem(RECENT_PDFS_STORAGE_KEY, JSON.stringify(recentPdfs));
  } catch {
    // Recent files are a convenience; opening a PDF should still succeed.
  }
}
