import { pdfjs } from "react-pdf";
import type { PositionData, Rect } from "@/types";

// Minimal structural types for the pdf.js proxies we rely on. We only declare
// the members this module touches so we don't depend on pdfjs-dist's exported
// types (which react-pdf does not re-export cleanly).
interface PdfTextItem {
  str?: string;
  // [a, b, c, d, e, f] mapping text space -> PDF user space.
  transform?: number[];
  width?: number;
  height?: number;
}

interface PdfViewport {
  width: number;
  height: number;
  transform: number[];
}

interface PdfPageProxy {
  getViewport: (options: { scale: number }) => PdfViewport;
  getTextContent: () => Promise<{ items: PdfTextItem[] }>;
}

interface PdfDocumentProxy {
  getPage: (pageNumber: number) => Promise<PdfPageProxy>;
}

// The viewer registers the currently-loaded pdf.js document here so the AI
// store can resolve text -> geometry without the target page being mounted in
// the DOM (pages are virtualized). Cleared when the document unloads.
let currentDocument: PdfDocumentProxy | null = null;

export function registerPdfDocument(doc: PdfDocumentProxy): void {
  currentDocument = doc;
}

export function unregisterPdfDocument(doc: PdfDocumentProxy): void {
  if (currentDocument === doc) {
    currentDocument = null;
  }
}

// Strip every whitespace character so matching is robust to the way pdf.js
// splits a line across text items (often without spaces between runs).
function stripWhitespace(value: string): string {
  return value.replace(/\s+/g, "");
}

// Project a text item to a rect in the page's zoom=1 coordinate space: origin
// top-left, y increasing downward, units = PDF points. This is the exact space
// HighlightLayer renders from (it multiplies each rect by the live zoom).
function itemToRect(item: PdfTextItem, viewport: PdfViewport): Rect | null {
  if (!item.transform || item.transform.length < 6) return null;
  // Compose the page viewport transform with the item's text matrix. At
  // scale=1 the viewport transform only flips Y and offsets by page height,
  // so tx[4]/tx[5] land in top-left-origin viewport pixels.
  const tx = pdfjs.Util.transform(viewport.transform, item.transform);
  const fontHeight = Math.hypot(tx[2], tx[3]);
  const width = Math.max(0, item.width ?? 0);
  const height = fontHeight > 0 ? fontHeight : Math.max(0, item.height ?? 0);
  if (width <= 0 || height <= 0) return null;

  return {
    x: tx[4],
    // tx[5] is the text baseline (bottom); shift up by the glyph height.
    y: tx[5] - fontHeight,
    width,
    height,
  };
}

// Merge per-item rects that sit on the same visual line into a single spanning
// rect, so a multi-item phrase renders as one highlight band per line.
function mergeLineRects(rects: Rect[]): Rect[] {
  if (rects.length === 0) return [];
  const sorted = [...rects].sort((a, b) => a.y - b.y || a.x - b.x);
  const lines: Rect[] = [];

  for (const rect of sorted) {
    const last = lines[lines.length - 1];
    const tolerance = Math.min(rect.height, last?.height ?? rect.height) * 0.6;

    if (last && Math.abs(rect.y - last.y) <= tolerance) {
      const left = Math.min(last.x, rect.x);
      const right = Math.max(last.x + last.width, rect.x + rect.width);
      const top = Math.min(last.y, rect.y);
      const bottom = Math.max(last.y + last.height, rect.y + rect.height);
      last.x = left;
      last.y = top;
      last.width = right - left;
      last.height = bottom - top;
    } else {
      lines.push({ ...rect });
    }
  }

  return lines;
}

/**
 * Resolve the on-page geometry of `query` on `pageNumber` by reading the page's
 * text content directly from pdf.js — no DOM mounting required. Returns
 * `PositionData` ready to store as a highlight, or `null` when the document is
 * unavailable or the text cannot be found.
 *
 * Limitation: a matched run is highlighted at whole-text-item granularity, so a
 * phrase that begins or ends mid-item may extend slightly past the exact words.
 * This always lands on the correct line(s) rather than guessing coordinates.
 */
export async function locateTextOnPage(
  pageNumber: number,
  query: string,
): Promise<PositionData | null> {
  const doc = currentDocument;
  if (!doc) return null;

  const needle = stripWhitespace(query).toLowerCase();
  if (!needle) return null;

  let page: PdfPageProxy;
  try {
    page = await doc.getPage(pageNumber);
  } catch {
    return null;
  }

  const viewport = page.getViewport({ scale: 1 });
  const textContent = await page.getTextContent();
  const items = textContent.items;

  // Build a whitespace-free haystack, remembering which item produced each
  // character so we can recover the items a match spans.
  let haystack = "";
  const owners: number[] = [];
  for (let itemIndex = 0; itemIndex < items.length; itemIndex++) {
    const str = items[itemIndex].str ?? "";
    for (const ch of str) {
      if (/\s/.test(ch)) continue;
      haystack += ch.toLowerCase();
      owners.push(itemIndex);
    }
  }

  const matchStart = haystack.indexOf(needle);
  if (matchStart === -1) return null;
  const matchEnd = matchStart + needle.length;

  const matchedItemIndices = new Set<number>();
  for (let i = matchStart; i < matchEnd; i++) {
    matchedItemIndices.add(owners[i]);
  }

  const rects: Rect[] = [];
  for (const itemIndex of matchedItemIndices) {
    const rect = itemToRect(items[itemIndex], viewport);
    if (rect) rects.push(rect);
  }
  if (rects.length === 0) return null;

  return {
    rects: mergeLineRects(rects),
    page_width: viewport.width,
    page_height: viewport.height,
    selected_text: query,
    start_offset: null,
    end_offset: null,
  };
}
