# Layer 3 — PDF engine on Linux

Decides: what replaces PDFKit on Linux for drawing pages and extracting text, and how
Linux writes annotations so a PDF edited on either machine reads identically on the other.

Depends on: D2 (native, no pdf.js), D3 (same files). N1 (licence) only blocks the final
engine choice, not the read-only spike.
Research: Gemini 4 Neon (round 1). Reviewed by Neon and GPT 6.2 Astra (round 2).
Items marked **unverified** are not yet proven on a real file.

## Question

Which engine renders and extracts text on Linux under a licence that leaves the public
release open, and what has to be built so Linux can write Vellum's exact PDF contract?

## Vellum's PDF contract

| Where | Keys | Written on the Mac by |
|---|---|---|
| Trailer `/Info` | `/VellumDocId`, `/VellumLastPage` (int), `/Title`, other `/Vellum*` strings | **Pure Swift**: `PdfMetadata.setMetadataIncrement` → `PdfIncrement` |
| `/Outlines` (bookmarks) | Standard outline tree + `/VellumType /Bookmark`, `/VellumNM`, `/VellumContent`, `/VellumCreatedAt`, `/VellumUpdatedAt`, `/VellumPinned` | **Pure Swift**: `PdfBookmarks` → `PdfIncrement` |
| Highlights / notes (`/Highlight`, `/Text`, `/FreeText`) | `/NM`, `/M`, `/F 4`, `/T (Vellum)`, `/Contents`, `/C`, `/Rect`, `/QuadPoints`, `/CA 0.4` (real), `/Name /Note` (name). Custom: `/VellumCreatedAt`, `/VellumUpdatedAt`, `/VellumSelectedText`, `/VellumPinned` (int), `/VellumType` (name) | **PDFKit**: `PDFAnnotation` + `page.addAnnotation` + `PDFDocument` serialisation; Swift then byte-patches `/CA` and `/Name` and re-adds custom keys PDFKit drops (`PdfSessionBackend`, `PdfBytePatch`, `rehydrateAnnotationMetadata`) |
| Ink (`/Ink`), iPad only | `/InkList`, `/C`, `/BS`, **no `/CA`**, **no `/AP`**. The whole page's `PKDrawing` sits in `/VellumInk` on the **first** ink annotation of the page; the others carry `"1"` markers (`Platform/iOS/PdfInk.swift`) | PDFKit on iPad |

## What this means

Vellum's pure-Swift PDF code (`ClassicPdfFile`, `PdfDictSource`, `PdfIncrement`, `PdfBytePatch`,
`PdfXrefRepair` in `PdfAtomicWriter.swift`) **already writes `/Info` and bookmarks** without
PDFKit. **Page annotations are not written by it.** Linux therefore needs a **new pure-Swift
annotation writer** (create, update, delete in `/Annots`). It's real work, not an extraction.

Limits of the existing Swift code, which the new writer inherits:
- Reads only **classic xref tables**, not PDF 1.5+ cross-reference streams.
- Discards object **generation numbers** and emits generation-0 references.
- `PdfMetadata.swift` and `PdfBookmarks.swift` also import CoreGraphics/PDFKit for their
  *reading* halves (CGPDF), and `PdfAtomicWriter.save` throws `SessionServiceError` and uses
  Darwin `rename`/`errno`. These need splitting before they can move into `VellumCore` (layer 4).

## The options

| | **PDFium** | **MuPDF** | **Poppler** (`poppler-glib`) |
|---|---|---|---|
| Licence | **BSD-3 / Apache-2.0**: any Vellum licence | **AGPL-3.0** or paid Artifex licence | **GPL-2/3** |
| Render pages | Excellent (Chrome's engine) | Excellent, fastest | Good, draws to Cairo |
| Text + character boxes | `FPDFText_GetCharBox`; content-stream order (needs line/column sorting like `PdfTextLocator`) | `fz_stext_page`; content-stream order | Heuristic visual order: closest to PDFKit |
| Write custom keys | `/Info` and outlines read-only; annotation strings yes, no ints or name objects | Full, exact types | No |
| Draw `/Ink` without `/AP` | Synthesises at render time. After that, `FPDFAnnot_GetColor` fails because an `/AP` now exists. Whether it also removes `/C` from memory is **disputed: unverified**. Rule either way: never save a PDFium document after rendering | Synthesises reliably | Synthesises; ink write APIs only in Poppler ≥ 25.06 |
| Incremental save | Yes; use a build **after 10 Sep 2025** (earlier ones drop objects); final-flush write errors are swallowed | Yes, mature | Can't write Vellum's keys |
| Threads | **Not thread-safe**: all calls go through one serial executor | `fz_context` per thread; `setjmp`/`longjmp` needs a C shim | GObject, single-threaded use |
| Linux arm64 + Swift | Prebuilt `.so` (bblanchon/pdfium-binaries), plain C | Static-only on Ubuntu 24.04; SONAME churn elsewhere | Distro packages |

## Recommendation

**PDFium for rendering and text. PDFium is never used to save.** Every write goes through
Vellum's Swift PDF code working on the original bytes.

- PDFium renders pages, extracts text (filtered to the CropBox, sorted like `PdfTextLocator`),
  reads annotations and geometry, and draws ink for display.
- **Serialise all PDFium calls** on one executor, including handle destruction. Interactive
  rendering gets priority, mirroring `PageTextExtractionGate` (CLAUDE.md: all page-text extraction
  goes through the gate).
- Pin a post-September-2025 PDFium build by SHA-256 in the container image.
- **MuPDF** is the technically cleanest single engine. It's an option only if N1 picks AGPL
  (or you pay). **Poppler is ruled out**: GPL, and it can't write Vellum's keys.

## What Linux may edit (supported-input policy)

Linux opens **every** PDF read-only. It writes only when all of these hold; otherwise it shows
"read-only on Linux" and the Mac keeps editing that file:
- classic xref table (until xref-stream reading exists),
- not encrypted, not signed,
- no non-zero generation numbers on the objects being touched.

Closing the xref-stream gap: preferred option is **teaching `ClassicPdfFile` to read xref streams**
(pure Swift, benefits the Mac too). Alternatives are a PDFium full rewrite (`FPDF_NO_INCREMENTAL`),
which makes sync conflicts likelier, or qpdf (Apache-2.0). Decide this after the read-only reader ships.

## The new Linux annotation writer (design to settle before building)

- Create, update and delete highlights and notes by appending a `PdfIncrement`: new annotation
  objects, plus a rewritten `/Annots` array (inline or indirect), plus updated custom keys.
- **Compaction**: increments grow the file. On the Mac, PDFKit's round trip compacts them. Linux
  needs a policy (for example, rewrite only when the user saves on a supported file, or never).
- **Gate**: semantic round trip. A Linux-written annotation must read back identically on the Mac,
  and must pass the existing persistence fixtures (rotated pages, foreign annotations), including
  the iOS-targeted persistence tests.
- **Ink pages**: Linux must never move, delete or reorder the first `/Ink` annotation that holds
  `/VellumInk`, and must preserve the `"1"` markers. Otherwise the page's whole `PKDrawing` is lost.

## Spike (half a day, in the container, read-only)

1. Take 3 Mac/iPad-annotated PDFs: classic xref, xref stream, and one with iPad ink.
2. PDFium: render every page to PNG; extract text with character boxes; compare text and highlight
   positions with what the Mac stored.
3. Check ink: colour, placement, and how marker strokes look without `/CA`.
4. Report which files the supported-input policy would make read-only.

The write side is a later, separate spike once the read-only Linux reader exists (layer 4).

## Open questions

- **N1**: Licence for the public release. Doesn't block the read-only spike.
- Should iPad start writing `/CA` on marker strokes so other engines draw them translucent? This is a
  small iPad change; it belongs with the ink plan (layer 5).
- Compaction policy for Linux increments.
