# Layer 3 — PDF engine on Linux

Decides: what replaces PDFKit on Linux for drawing pages, extracting text, and writing
annotations, so a PDF edited on either machine reads identically on the other.

Depends on: D2 (native, no pdf.js), D3 (same files), N1 (licence).
Research: Gemini 4 Neon, round 1. Items marked **unverified** are not yet proven on a real file.

## Question

Which engine (or combination) can render, extract text, and write Vellum's exact PDF
dictionary contract on Linux, under a licence that leaves the public release open?

## Vellum's PDF contract (what Linux must read and write identically)

| Where | Keys |
|---|---|
| Trailer `/Info` | `/VellumDocId` (identity), `/VellumLastPage` (int), `/Title`, other `/Vellum*` strings (`PdfMetadata`) |
| Highlights / notes (`/Highlight`, `/Text`, `/FreeText`) | Standard: `/NM`, `/M`, `/F 4`, `/T (Vellum)`, `/Contents`, `/C`, `/Rect`, `/QuadPoints`, `/CA 0.4` (real), `/Name /Note` (name object). Custom: `/VellumCreatedAt`, `/VellumUpdatedAt`, `/VellumSelectedText`, `/VellumPinned` (int), `/VellumType` (name) (`PdfAnnotationCodec`) |
| Ink (`/Ink`) | `/InkList`, `/C`, `/CA`, `/BS`, **no `/AP` appearance stream**, plus a base64 `PKDrawing` in `/VellumInk` (`Platform/iOS/PdfInk.swift`) |
| Bookmarks (`/Outlines`) | Standard outline tree + `/VellumType /Bookmark`, `/VellumNM`, `/VellumContent`, `/VellumCreatedAt`, `/VellumUpdatedAt`, `/VellumPinned` (`PdfBookmarks`) |

## Key finding: Vellum already writes PDFs itself

PDFKit can't write custom `/Info` keys, outline keys, `/CA` reals or `/Name` objects, so
Vellum already has a **pure-Swift, Foundation-only PDF object writer**: `ClassicPdfFile`,
`PdfDictSource`, `PdfIncrement`, `PdfBytePatch`, `PdfXrefRepair` in
`Services/Pdf/PdfAtomicWriter.swift` (imports only Foundation). The Linux engine therefore
does **not** need to write Vellum's custom keys; the shared Swift writer does that on both
platforms.

Limit: `ClassicPdfFile` reads only **classic xref tables**, not the cross-reference streams
used by many PDF 1.5+ files. It relies on the file being normalised first (today, PDFKit's
rewrite does this on the Mac).

## The options

| | **PDFium** | **MuPDF** | **Poppler** (`poppler-glib`) |
|---|---|---|---|
| Licence | **BSD-3 / Apache-2.0**: any Vellum licence | **AGPL-3.0** or paid Artifex licence: Vellum must be AGPL or pay | **GPL-2/3**: Vellum Linux must be GPL |
| Render pages | Excellent (Chrome's engine) | Excellent, fastest | Good, draws to Cairo |
| Text + character boxes | `FPDFText_GetCharBox`; content-stream order (needs line/column sorting like `PdfTextLocator`) | `fz_stext_page`; also content-stream order | Heuristic visual order: closest to PDFKit out of the box |
| Write `/Info` custom keys | Read only (no public write API) | Full | No |
| Write custom annotation keys | Strings yes (`FPDFAnnot_SetStringValue`); no ints, no name objects; `SetColor` fails if `/AP` exists | Full, exact types | No |
| Write outlines | Read only | Full | Read only |
| Draw `/Ink` without `/AP` | Synthesises on render, **but strips `/C`/`/IC` from the in-memory dictionary**: never save after rendering ink | Synthesises reliably, keeps attributes | Synthesises; ink write APIs only in Poppler ≥ 25.06 (not in Ubuntu 24.04) |
| Incremental save | Yes, but **must use a build after 10 Sep 2025** (earlier builds silently drop objects); write errors in the final flush are swallowed | Yes, mature | Exists, but can't write Vellum's keys |
| Linux arm64/x86_64 + Swift | Prebuilt `.so` (bblanchon/pdfium-binaries), plain C, easy | Ubuntu 24.04 ships static-only; SONAME churn elsewhere; needs a C shim (`fz_try` uses `setjmp`/`longjmp`, which is unsafe across Swift frames; `fz_context` not thread-safe) | Distro packages, GObject C API |

## Recommendation

**PDFium for rendering and text, plus Vellum's existing Swift writer for every mutation.**
This is the same architecture the Mac already uses around PDFKit.

- PDFium: render pages, extract text (filtered to the CropBox, sorted like `PdfTextLocator`),
  read annotation strings and geometry, synthesise ink appearance for display.
- Shared Swift writer (`PdfAtomicWriter` family, moved into `VellumCore`): every write of
  annotations, `/Info`, outlines, `/CA`, `/Name`, `/VellumPinned`.
- Never save a PDFium document after rendering ink (the `/C` stripping above). Saving always
  goes through the Swift writer working on the original bytes.
- Pin a post-September-2025 PDFium build and pin its SHA-256 in the container image.

**MuPDF** is the technically cleanest single engine. It only becomes an option if you choose
AGPL (or pay) in N1. **Poppler is ruled out:** GPL, and it can't write Vellum's keys.

## The one gap to close: cross-reference streams

Before Linux can write to a PDF whose xref is a stream, pick one:
1. **Teach `ClassicPdfFile` to read xref streams** (pure Swift, benefits the Mac too). Preferred.
2. Normalise with PDFium `FPDF_SaveAsCopy(…, FPDF_NO_INCREMENTAL)` first (emits a classic
   table), then append the Swift increment. A full rewrite, so it makes sync conflicts likelier.
3. Pair with **qpdf** (Apache-2.0) for normalisation.

## Spike (half a day, in the container)

1. Take 3 Mac-annotated PDFs: one classic-xref, one xref-stream, one with iPad ink.
2. PDFium: render every page to PNG; extract text with character boxes; compare the
   extracted text and highlight positions with what the Mac stored.
3. Swift writer on Linux: add a highlight, a note, a bookmark, change `/VellumLastPage`.
4. Open the results on the Mac: everything identical, nothing lost (including `/VellumInk`).
5. Report: which files needed normalisation, and whether ink rendered with the right colour.

## Open questions

- **N1**: Licence for the public release. With PDFium it can be anything; MuPDF forces AGPL.
- Which of the three gap-closing options (recommend 1)?
- Is PDFium text-order sorting close enough to PDFKit that saved highlights and AI citations
  land on the same text? The spike answers it.
