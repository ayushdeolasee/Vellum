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

## Work items (P1–P7)

Round 3: drafted by Gemini 4 Neon; GPT 6.2 Astra drafted the overlapping core-extraction items. Where they
overlap, **one item, two IDs**: P3 = C7a, P4 = C6, P5 = C7b. The P section below holds the design; layer 4
holds the extraction constraints (module access, typealiases, which Apple tests must keep passing).

| ID | Item | Size | Depends on |
|---|---|---|---|
| P7 | One shared fixture corpus (7 PDFs incl. iPad ink + `PdfFixtureBuilder`), wired into SwiftPM and Apple test bundles | M | C1 |
| P1 | Read-only PDFium spike: module map, serial `PdfiumActor`, render to bitmap, text with char boxes | M | C1, P7 |
| P2 | Reading-order sorting to match `PdfTextLocator` + PDFKit goldens generated on Mac | M | P1, P4 (= C6), P7 |
| P4 (= C6) | Split byte primitives, `/Info` + outline increments **and numeric `PageGeometry`** from CGPDF/Darwin/`SessionServiceError` | L | C2, after C5b |
| P3 (= C7a) | `PdfWriteEligibility`: decide from original bytes whether Linux may edit | S–M | P4, P7 |
| P5 (= C7b) | Pure-Swift annotation writer (create/update/delete highlight + note) | L (+M qualification) | P3, P4, P7 |
| P6 | Xref-stream + object-stream reading, and xref-stream increments | L | P5, after P2 |

### Round 4: one authoritative design per item

Both reviewers found that the paired items still described two different designs. The rule from now on: **the
design named here is the one to build.** Where a sketch further down disagrees, this section wins.

- **P1 (PDFium read-only).** The input is **validated bytes** from the read-only store (C5b's `RootDirectory`), not
  a path. Each operation (page info, render, text) is **one serial C job** that loads, works and closes, and returns
  owned results. There is no persistent `FPDF_DOCUMENT`, no `@unchecked Sendable` document class and no deferred
  cleanup. Page info is a Linux-local `PdfiumPageInfo { widthPt, heightPt, rotation }`; P4's `PageGeometry` is not
  needed yet. `PdfiumActor` is just the serial, prioritised queue that runs those jobs.
- **P2 (text order).** PDFKit golden JSON is generated **on the Mac** and checked in; Linux consumes it. Needs P4's
  numeric geometry.
- **P3 = C7a (eligibility).** Build **C7a's API**: `PdfEditEligibility { editable | readOnly(PdfReadOnlyReason) }`
  in `Core/Pdf/PdfEditEligibility.swift`, with reasons `unsupportedXref, encrypted, signed, nonzeroGeneration,
  malformed, ambiguousAnnotation, unsupportedGeometry`. The decision is **structural** (every revision, hybrid
  `/XRefStm`, inherited `/Encrypt`, signature fields and `/Perms`). A raw `/ByteRange` scan may only add
  `readOnly(.signed)`, never grant editing. Use P3's test list.
- **P4 = C6 (primitives).** Build **C6's file split**: `PdfBytes.swift`, `PdfAtomicFile.swift`,
  `PdfInfoIncrement.swift`, `PdfOutlineIncrement.swift`, **plus P4's numeric `PageGeometry`** (moved here from C7b,
  because P2 needs it). `PdfCoreError` is `invalidDocument | io` only, with no dependency on eligibility reasons.
  Stamping (`stampDocumentId`) stays an Apple entry point. Language mode is Swift 5 (`.swiftLanguageMode(.v5)`), per C0.
- **P5 = C7b (annotation writer).** The API is **C7b's**: `PdfAnnotationIncrement.applying(_ edit: PdfAnnotationEdit,
  to original: Data, now: String)`. The dictionary contract, the three `/Annots` cases and the ink invariants come
  from P5's design below. Two corrections from Astra:
  - `/QuadPoints`: map each **UI** corner TL, TR, BL, BR independently through `uiToPdf`, giving absolute PDF
    coordinates. Subtracting the bounds origin is specific to PDFKit's setter; don't copy it.
  - Foreign annotations: derive `pdf-direct-{page}-{index}` from the raw slot index (counting nulls and direct
    dictionaries), stamp `/NM` on first update, and before rewriting an indirect `/Annots` array or annotation in
    place, check that no other page references it.
  - `/Ink` emission belongs to I10, not P5.
- **P7 (fixtures).** There is **one corpus**, in `Packages/VellumCore/Tests/VellumCoreTests/Fixtures/Pdf/`, declared
  as a `.copy("Fixtures")` resource. The Apple test bundles reference the same directory through `project.yml`;
  the Linux tests stage a copy. The iPad ink PDFs from layer 5's I0 live here too, with full and partial erasure
  recorded separately. Sized M (seven fixtures, a builder, and wiring into three test hosts).

### How the two agents' designs were reconciled

- **Package layout:** Astra's. Portable PDF code goes in `Packages/VellumCore/Sources/VellumCore/Pdf/`;
  PDFium code lives only in the Linux package (`Linux/Sources/CPdfium`, `Linux/Sources/LinuxReader/Pdf/`).
  `VellumCore` never links PDFium.
- **PDFium serialisation:** Neon's `PdfiumActor` (priority: on-demand beats background, mirroring
  `PageTextExtractionGate`) is the Swift API. Astra's rule applies inside it: each job loads, renders or
  extracts, and closes **within one C call**, and the input bytes stay borrowed for the whole job.
- **Signed-PDF detection:** the structural check decides (`/AcroForm /SigFlags`, `/Perms`, signature field
  dictionaries). Neon's byte scan for `/ByteRange` may only **add** a read-only verdict, never grant writing
  (Astra: an authorisation decision can't rest on a text search).
- **Text comparison harness (P2):** golden JSON is generated on the Mac with PDFKit and checked in; Linux
  tests consume it. PDFium is never built for the Mac.
- **PDFium pin:** `chromium/8179` arm64, SHA-256 `18bb6d568257b28d14f6c3b8bfb48caf73d4615b319ca4d43b424c2a03431d9f`
  (Astra downloaded it and verified the checksum, headers and `.so`; see layer 4's Dockerfile).

### P1 — Read-only PDFium spike (C module map, Swift wrapper, `PdfiumActor`)

* **Goal**: Prove linking and calling PDFium from Swift 6 on Linux (and optionally macOS for cross-checking in `P2`), wrapping document loading, RGBA page rendering, page geometry, and text-with-char-boxes extraction behind a single serial executor actor (`PdfiumActor`).
* **Files changed**:
  * **New**: `Linux/Sources/CPdfium/module.modulemap` + `Linux/Sources/CPdfium/shim.h` (imports `fpdfview.h`, `fpdf_text.h`, `fpdf_doc.h`, `fpdf_annot.h`, `fpdf_edit.h`)
  * **New**: `Linux/Sources/LinuxReader/Pdf/PdfiumActor.swift` (global serial actor owning `FPDF_InitLibrary` & all `FPDF_*` calls + priority scheduling)
  * **New**: `Linux/Sources/LinuxReader/Pdf/PdfiumDocument.swift` (`PdfiumDocument`, `PdfiumPage`, `PdfiumRgbaBitmap`, `PdfiumCharBox`, `PdfiumPageText`)
  * **New**: `Linux/Sources/LinuxReader/Pdf/PdfTextExtractionScheduler.swift` (cross-platform abstraction bridging `PageTextExtractionGate` on Apple vs `PdfiumActor` priority queue on Linux)
  * `Linux/Package.swift` (the `CPdfium` system-library target; PDFium code lives only in the Linux package, never in `VellumCore`)
* **Code sketch**:
```c
// Linux/Sources/CPdfium/module.modulemap
module CPdfium [system] {
    header "shim.h"
    link "pdfium"
    export *
}
```
```swift
// Linux/Sources/LinuxReader/Pdf/PdfiumActor.swift
/// PDFium is NOT thread-safe across concurrent `FPDF_*` calls (even across distinct
/// `FPDF_DOCUMENT` handles). Every `FPDF_*` call in the process runs on this single
/// serial actor — off the main thread.
///
/// Relation to `PageTextExtractionGate` (Vellum/Services/Ai/PageTextExtractionGate.swift):
/// - On macOS/iOS, `PageTextExtractionGate` is `@MainActor` solely to throttle PDFKit's
///   CoreML/ANE Live Text compilation bursts (16ms cooldown after empty/slow reads).
/// - On Linux, PDFium has no Live Text/ANE and never needs the main thread. Instead,
///   `PdfiumActor` provides priority-ordered scheduling (`.onDemand` preempts `.background`
///   AI page walks, FIFO within each tier) with ZERO artificial cooldown, reusing the same
///   `Priority` semantics as `PageTextExtractionGate.Priority`.
@globalActor
public actor PdfiumActor {
    public static let shared = PdfiumActor()

    public enum Priority: Sendable { case onDemand, background }

    private var initialized = false
    private var busy = false
    private var onDemandQueue: [CheckedContinuation<Void, Never>] = []
    private var backgroundQueue: [CheckedContinuation<Void, Never>] = []

    private func ensureInitialized() {
        guard !initialized else { return }
        var config = FPDF_LIBRARY_CONFIG(
            version: 2, m_pUserFontPaths: nil, m_pIsolate: nil, m_v8EmbedderSlot: 0
        )
        FPDF_InitLibraryWithConfig(&config)
        initialized = true
    }

    /// Runs a PDFium operation with priority preemption between steps (e.g. per page).
    public func run<T: Sendable>(
        priority: Priority = .onDemand,
        _ body: @PdfiumActor () throws -> T
    ) async throws -> T {
        await acquire(priority: priority)
        defer { release() }
        ensureInitialized()
        return try body()
    }

    private func acquire(priority: Priority) async {
        if !busy { busy = true; return }
        await withCheckedContinuation { cont in
            switch priority {
            case .onDemand: onDemandQueue.append(cont)
            case .background: backgroundQueue.append(cont)
            }
        }
    }

    private func release() {
        if !onDemandQueue.isEmpty { onDemandQueue.removeFirst().resume(); return }
        if !backgroundQueue.isEmpty { backgroundQueue.removeFirst().resume(); return }
        busy = false
    }
}
```
```swift
// Linux/Sources/LinuxReader/Pdf/PdfiumDocument.swift
public struct PdfiumRgbaBitmap: Sendable {
    public let width: Int
    public let height: Int
    public let bytesPerRow: Int
    public let pixels: Data          // BGRA or RGBA premultiplied, explicitly documented
}

public struct PdfiumCharBox: Sendable, Equatable {
    public let utf16Index: Int       // index into FPDFText_GetText UTF-16 buffer
    public let scalar: UInt16        // UTF-16 code unit
    public let pdfRect: PdfRect      // (left, bottom, right, top) in PDF user space
    public let isGenerated: Bool     // FPDFText_IsGenerated (synthetic spaces/linebreaks)
}

public struct PdfiumPageText: Sendable, Equatable {
    public let text: String
    public let chars: [PdfiumCharBox]
}

public final class PdfiumDocument: @unchecked Sendable {
    // Only ever dereferenced on @PdfiumActor!
    private var handle: FPDF_DOCUMENT?
    public let pageCount: Int

    @PdfiumActor
    public init(path: String, password: String? = nil) throws { ... }

    @PdfiumActor
    public func close() {
        if let h = handle { FPDF_CloseDocument(h); handle = nil }
    }

    @PdfiumActor
    public func pageGeometry(at index: Int) throws -> PageGeometry { ... }

    @PdfiumActor
    public func renderPage(
        at index: Int,
        scale: Double,
        backgroundRGBA: UInt32 = 0xFFFFFFFF
    ) throws -> PdfiumRgbaBitmap {
        // FPDF_LoadPage -> FPDFBitmap_CreateEx(w, h, FPDFBitmap_BGRA, ...) ->
        // FPDFBitmap_FillRect -> FPDF_RenderPageBitmap(flags: FPDF_ANNOT | FPDF_LCD_TEXT) ->
        // swizzle/copy into Data -> FPDFBitmap_Destroy -> FPDF_ClosePage
    }

    @PdfiumActor
    public func extractText(at index: Int) throws -> PdfiumPageText {
        // FPDF_LoadPage -> FPDFText_LoadPage ->
        // FPDFText_CountChars -> loop FPDFText_GetUnicode + FPDFText_GetCharBox + FPDFText_IsGenerated ->
        // FPDFText_ClosePage -> FPDF_ClosePage
    }
}
```
* **Tests**:
  * Reuse/extend: `Tests/PageTextExtractionGateTests.swift` (`testOnDemandJumpsAheadOfQueuedBackgroundWork` — mirror the exact same priority preemption test on `PdfiumActor`).
  * New tests (`PdfiumSpikeTests.swift`):
    * `testOpenRenderAndExtractTextFromClassicFixture`
    * `testRenderRotatedPageRespectsDisplayDimensions`
    * `testEncryptedPdfOpensWithPasswordAndFailsWithout`
    * `testPdfiumActorPreemptsBackgroundWalkForOnDemandRender`
    * `testConcurrentTasksNeverOverlapInsidePdfium`
* **Acceptance criteria**:
  * Builds and passes `swift test` in Linux container (colima) against prebuilt `pdfium-binaries` (`libpdfium.so`).
  * Renders a page to a non-blank RGBA/BGRA buffer of expected pixel dimensions (`Int(round(displayWidth * scale))` × `Int(round(displayHeight * scale))`).
  * Extracts UTF-16 text + per-character PDF bounding boxes cleanly with zero leaks (`FPDF_ClosePage` / `FPDF_CloseDocument` paired on all paths).
* **Size**: `M`
* **Depends on**: `C1`, `P7` *(minimal classic fixture)*. Not `P4`: the read-only reader (C5b) comes before P4, so P1 takes page size and rotation from PDFium itself (`FPDF_GetPageWidthF`/`HeightF`, `FPDFPage_GetRotation`). The Swift `PageGeometry` port arrives with P4.
* **Risks**:
  * `FPDF_ANNOT` renders embedded `/Highlight`, `/Text`, and `/Ink` annotations automatically — verify how PDFium renders Vellum's `/Ink` annotations without `/AP` appearance streams (if iPad ink lacks `/AP` or uses `/InkList`, verify visual output early in the spike).
  * `deinit` on `PdfiumDocument` cannot be `@PdfiumActor`-isolated; enforce explicit `close()` or dispatch `Task { @PdfiumActor in FPDF_CloseDocument(raw) }` using an unmanaged `UnsafeMutableRawPointer` wrapper so finalization never races with active `FPDF_*` calls.

---

### P2 — Text-order sorting for `PdfTextLocator` + PDFKit comparison harness

* **Goal**: Normalize PDFium's content-stream character order into reading-order lines/spans that match `Vellum/Services/Pdf/PdfTextLocator.swift` (`locate`, `resizedPosition`, `mergeLineRects`), and build a Mac-runnable comparison harness against Apple PDFKit so text/rect drift is measured quantitatively across real PDFs.
* **Files changed**:
  * **New**: `Linux/Sources/LinuxReader/Pdf/PdfTextReadingOrder.swift` (groups `PdfiumCharBox` → words → lines → columns → reading-order `ExtractedPageText` with `utf16Range → [UiRect]`)
  * **New**: `Linux/Sources/LinuxReader/Pdf/PdfTextLocatorPortable.swift` (portable `PdfTextLocator` core using `ExtractedPageText` instead of `PDFPage`, sharing `mergeLineRects` and `resizedPosition` math)
  * **New**: `Tests/PdfTextComparisonHarnessTests.swift` (macOS-only harness comparing `PDFPage.string` + `PDFSelection` rects vs PDFium sorted output against golden fixtures)
  * **New**: `Tests/Fixtures/PdfTextGolden/*.json` (golden fixture schema below)
* **Code sketch**:
```swift
// Linux/Sources/LinuxReader/Pdf/PdfTextReadingOrder.swift
public struct ExtractedTextSpan: Sendable, Equatable {
    public let utf16Range: Range<Int>
    public let uiRect: UiRect          // already mapped via PageGeometry.pdfToUi
}

public struct ExtractedPageText: Sendable, Equatable {
    public let text: String
    public let charUiRects: [UiRect?]  // parallel to text.utf16 (nil for synthetic whitespace)
    public let lines: [Line]

    public struct Line: Sendable, Equatable {
        public let utf16Range: Range<Int>
        public let bounds: UiRect
    }
}

public enum PdfTextReadingOrder {
    /// Converts raw PDFium char boxes into reading-order text matching PdfTextLocator expectations:
    /// 1. Transform each char box from PDF space to UI space via `geometry.pdfToUi`
    ///    (normalizes 0/90/180/270° rotation so reading order is always top-to-bottom, left-to-right).
    /// 2. Drop zero-area control chars; keep explicit/generated spaces.
    /// 3. Cluster glyphs into visual lines: two glyphs share a line when vertical overlap >= 0.5 * min(h1, h2)
    ///    and horizontal gap < 3 * medianCharHeight (prevents merging two columns into one line!).
    /// 4. Detect multi-column bands via vertical gutter projection: if a contiguous vertical band splits
    ///    into disjoint X-intervals with gap >= 1.5 * medianCharHeight, order left column top-to-bottom
    ///    before right column top-to-bottom.
    /// 5. Within each line, sort left-to-right by `uiRect.x`, inserting a single ASCII space when
    ///    horizontal gap > 0.28 * medianCharHeight and no space char is already present.
    /// 6. Join lines with `\n` (de-hyphenating only in search normalization, never mutating char indices).
    public static func sort(
        raw: PdfiumPageText,
        geometry: PageGeometry
    ) -> ExtractedPageText { ... }
}
```
```json
// Golden comparison fixture format: Tests/Fixtures/PdfTextGolden/<fixture-name>.json
{
  "fixture": "two-column-academic.pdf",
  "page": 1,
  "pdfkitTextSha256": "...",
  "normalizedText": "...",
  "probes": [
    {
      "quote": "self-attention mechanism",
      "pdfkitUiRects": [{ "x": 72.1, "y": 310.4, "width": 148.2, "height": 11.5 }],
      "tolerancePt": 3.0
    }
  ]
}
```
* **Tests**:
  * Reuse/extend: `HighlightResizeTests` (`Tests/PdfPersistenceTests.swift`) (`testDragEndExtendsWhileStartStaysPinned`, `testDragStartExtendsWhileEndStaysPinned`, `testResizeOnEmptyPageReturnsNil`), `Tests/PdfSearchTests.swift` (`testPrivateSearchFindsCaseInsensitiveUTF16RangesAndCancels`).
  * New tests:
    * `PdfTextReadingOrderTests.testSingleColumnAndRotatedPagesMatchExpectedOrder`
    * `PdfTextReadingOrderTests.testTwoColumnLayoutReadsLeftColumnBeforeRight`
    * `PdfTextComparisonHarnessTests.testPdfiumMatchesPdfKitWithinToleranceOnGoldenSet` (macOS; asserts normalized Levenshtein similarity ≥ 0.98 and probe rect IoU ≥ 0.85 / edge delta ≤ 3 pt)
* **Acceptance criteria**:
  * On every fixture in `P7` (single-column, two-column, rotated 90°/180°/270°), `PdfTextReadingOrder.sort` produces text that locates every probe quote via `PdfTextLocator` and produces UI rects within `3.0 pt` of PDFKit.
  * Highlight drag-resize (`HighlightResizeTests`) passes identically on the portable `ExtractedPageText` backend.
* **Size**: `M`
* **Depends on**: `P1`, `P4` (`PageGeometry`), `P7`.
* **Risks**:
  * Complex tables / dropped caps / math formulas can differ subtly between PDFKit's proprietary heuristics and a rule-based sorter; keep the golden comparison harness as a regression gate when tuning thresholds.

---

### P3 — Supported-input classifier (`PdfWriteEligibility`) · same item as C7a

* **Goal**: Classify any PDF byte buffer *before* attempting incremental writes (`stampDocumentId`, annotation create/update/delete, bookmarks, metadata) so Linux (and Mac's pure-Swift path) never corrupts encrypted, digitally signed, xref-stream (pre-`P6`), or non-zero-generation PDFs — instead cleanly reporting read-only eligibility with an actionable reason.
* **Files changed**:
  * **New**: `Packages/VellumCore/Sources/VellumCore/Pdf/PdfWriteEligibility.swift` (or `Vellum/Services/Pdf/PdfWriteEligibility.swift`)
  * `Vellum/Services/Pdf/PdfAtomicWriter.swift` (`ClassicPdfFile` exposes trailer/xref metadata needed by classifier)
* **Code sketch**:
```swift
// Packages/VellumCore/Sources/VellumCore/Pdf/PdfWriteEligibility.swift
public enum PdfWriteIneligibilityReason: String, Equatable, Sendable, CaseIterable {
    case emptyOrTruncated
    case missingStartXref
    case xrefStreamUnsupported   // /Type /XRef (cleared once P6 xref-stream reading is enabled)
    case encrypted               // trailer contains /Encrypt
    case digitallySigned         // /AcroForm /SigFlags != 0 OR any /FT /Sig / /Type /Sig / /ByteRange
    case nonZeroGeneration       // target object or /Root or /Pages or /Annots has generation != 0
    case malformedTrailer
}

public enum PdfWriteEligibility: Equatable, Sendable {
    case writable(xrefFormat: XrefFormat)
    case readOnly(reasons: [PdfWriteIneligibilityReason])

    public enum XrefFormat: String, Equatable, Sendable {
        case classicTable
        case xrefStream          // enabled by P6
    }

    public var isWritable: Bool {
        if case .writable = self { return true }
        return false
    }
}

public enum PdfWriteEligibilityClassifier {
    /// Pure-Swift byte-level inspection — zero CGPDF / PDFKit / PDFium dependency.
    /// Checks in deterministic order:
    /// 1. Header `%PDF-` + trailing `startxref` offset in bounds.
    /// 2. Xref header at offset: `xref` keyword (classic) vs indirect obj with `/Type /XRef` (xref stream).
    /// 3. Walk `/Prev` chain (cycle-guarded, max depth 64):
    ///    - Reject if any trailer has `/Encrypt` (unless explicit decrypt/unsupported).
    ///    - Reject if `/Root` catalog has `/Perms` (`/DocMDP` / `/UR3`) or `/AcroForm` with `/SigFlags` bit 1 set
    ///      (or scan object dictionary for `/ByteRange` + `/SubFilter` signature dictionary).
    ///    - Reject if `/Root`, `/Info` (if present), or referenced page/annots objects have generation > 0.
    /// 4. If `allowXrefStreams == false` and any section is an xref stream, report `.xrefStreamUnsupported`.
    public static func classify(
        _ data: Data,
        allowXrefStreams: Bool = false
    ) -> PdfWriteEligibility { ... }

    public static func classify(
        atPath path: String,
        allowXrefStreams: Bool = false
    ) throws -> PdfWriteEligibility {
        try classify(Data(contentsOf: URL(fileURLWithPath: path)), allowXrefStreams: allowXrefStreams)
    }
}
```
* **Tests**:
  * Reuse/extend: `Tests/PdfPersistenceTests.swift` (`testOpenValidation`).
  * New tests (`PdfWriteEligibilityTests.swift`):
    * `testClassicUnencryptedUnsignedPdfIsWritable`
    * `testXrefStreamPdfRejectedWhenXrefStreamsDisabledAndAcceptedWhenEnabled`
    * `testEncryptedPdfClassifiedReadOnlyWithEncryptedReason`
    * `testDigitallySignedPdfClassifiedReadOnlyWithDigitallySignedReason`
    * `testNonZeroGenerationObjectClassifiedReadOnly`
    * `testTruncatedOrCorruptPdfClassifiedReadOnlyWithoutCrashing`
    * `testCyclicPrevXrefChainTerminatesSafely`
* **Acceptance criteria**:
  * Zero crashes on malformed/truncated/cyclic PDFs.
  * Correctly classifies every fixture in `P7` (classic → `.writable(.classicTable)`; xref-stream → `.readOnly([.xrefStreamUnsupported])` pre-`P6` and `.writable(.xrefStream)` post-`P6`; encrypted → `.readOnly([.encrypted])`; signed → `.readOnly([.digitallySigned])`).
  * Pure Swift + Foundation only; compiles and passes on Linux.
* **Size**: `S`
* **Depends on**: `P4` (uses `ClassicPdfFile` primitives), `P7` (test fixtures).
* **Risks**:
  * Signature detection via `/AcroForm /SigFlags` can miss unsigned-flag signatures that still contain `/Type /Sig` + `/ByteRange`; therefore check **both** `/Catalog` (`/Perms`, `/AcroForm /SigFlags`) **and** fast byte-scan for `/ByteRange` inside indirect dicts so signed PDFs are never silently invalidated by an incremental append.

---

### P4 — Split pure-Swift PDF writer & geometry primitives from Darwin / CGPDF / `SessionServiceError` · same item as C6

* **Goal**: Make Vellum's existing battle-tested pure-Swift incremental PDF engine (`PdfAtomicWriter`, `ClassicPdfFile`, `PdfIncrement`, `PdfMetadata` writer, `PdfBookmarks` writer, `PageGeometry` math, `PdfAnnotationDefaults`/`PdfDates`/`PdfColor`) compile cleanly on Linux with zero `CoreGraphics`, `PDFKit`, or Darwin-only imports, while keeping macOS/iOS behavior 100% unchanged.
* **Files changed**:
  * **New**: `Packages/VellumCore/Sources/VellumCore/Pdf/PdfCoreError.swift` (pure-Swift `PdfCoreError` replacing direct `SessionServiceError` throws; Apple layer bridges `PdfCoreError` → `SessionServiceError`)
  * **Split** `Vellum/Services/Pdf/PdfAtomicWriter.swift`:
    * Portable core (`PdfBytes`, `PdfBytePatch`, `PdfAtomicWriter`, `PdfXrefRepair`, `PdfDictSource`, `PdfArraySource`, `ClassicPdfFile`, `PdfIncrement`, `PdfTextString`): `#if canImport(Darwin) import Darwin #elseif canImport(Glibc) import Glibc #endif` for `rename`/`errno`/`strerror`; throw `PdfCoreError`.
  * **Split** `Vellum/Services/Pdf/PdfGeometry.swift`:
    * `Packages/VellumCore/Sources/VellumCore/Pdf/PageGeometry.swift`: pure-Swift `PageGeometry` (`pdfToUi`, `uiToPdf`, `displayWidth`, `displayHeight`, memberwise `init`, + `init(pageNumber:in: ClassicPdfFile)` walking `/Parent` inheritance for `/MediaBox`, `/CropBox`, `/Rotate`, `/UserUnit`).
    * `Vellum/Services/Pdf/CgPdfGeometry.swift` (Apple-only): `CgPdf` helpers + `extension PageGeometry { init(pageDictionary: CGPDFDictionaryRef) throws }`.
  * **Split** `Vellum/Services/Pdf/PdfMetadata.swift`:
    * `Packages/VellumCore/Sources/VellumCore/Pdf/PdfMetadataWriter.swift`: pure-Swift `setMetadataIncrement`, `parseLastPage`, `metadataKeySuffix`, `readInfoString`/`readDocumentId(from: ClassicPdfFile)`, pure-Swift `stampDocumentId(atPath:id:)` (without PDFKit fallback).
    * `Vellum/Services/Pdf/PdfMetadataCgReader.swift` (Apple-only): `CGPDFDocument` readers + PDFKit stamp fallback.
  * **Split** `Vellum/Services/Pdf/PdfBookmarks.swift`:
    * `Packages/VellumCore/Sources/VellumCore/Pdf/PdfBookmarksWriter.swift`: pure-Swift `createBookmarkIncrement`, `updateBookmarkIncrement`, `deleteBookmarkIncrement`, `pageObjectNumber`, `kidReferences`, `readBookmarks(from: ClassicPdfFile)`.
    * `Vellum/Services/Pdf/PdfBookmarksCgReader.swift` (Apple-only): `CGPDFDocument` outline reader.
  * **Split** `Vellum/Services/Pdf/PdfAnnotationCodec.swift`:
    * `Packages/VellumCore/Sources/VellumCore/Pdf/PdfAnnotationContract.swift`: pure-Swift `PdfAnnotationDefaults`, `PdfDates`, `PdfColor` (`parseHex`, `defaultHex`, RGB `[Double]`), `uiBoundingRect`, `PdfAnnotationReader.derivedForeignId`.
    * `Vellum/Services/Pdf/PdfAnnotationCodecApple.swift` (Apple-only): `PDFAnnotation` / `CgPdf` / `PlatformColor` bridges.
* **Code sketch**:
```swift
// Packages/VellumCore/Sources/VellumCore/Pdf/PdfCoreError.swift
public enum PdfCoreError: Error, Equatable, Sendable {
    case invalidDocument(String)
    case io(String)
    case unsupported(PdfWriteIneligibilityReason)
}

// Apple bridge (inside Vellum/Services/Pdf/PdfSessionBackend.swift):
extension SessionServiceError {
    init(_ error: PdfCoreError) {
        switch error {
        case .invalidDocument(let msg): self = .invalidDocument(msg)
        case .io(let msg): self = .io(msg)
        case .unsupported(let reason): self = .invalidDocument("Unsupported PDF for writing: \(reason.rawValue)")
        }
    }
}

// Packages/VellumCore/Sources/VellumCore/Pdf/PdfAtomicWriter.swift — POSIX portability
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

// Replace `String(format: "%010llu 00000 n \n", ...)` if desired with zero-alloc pure Swift pad,
// and replace `FileAttributeKey.posixPermissions` fallback safely on Linux.

// Packages/VellumCore/Sources/VellumCore/Pdf/PageGeometry.swift — pure-Swift page dict geometry
extension PageGeometry {
    /// Resolves `/CropBox` (fallback `/MediaBox`), `/Rotate`, `/UserUnit` by walking
    /// `/Page` -> `/Parent` chain inside `ClassicPdfFile`.
    public init(pageNumber: Int, in file: ClassicPdfFile) throws {
        guard let pageObjNum = PdfBookmarksWriter.pageObjectNumber(in: file, oneBasedPage: pageNumber) else {
            throw PdfCoreError.invalidDocument("Page \(pageNumber) does not exist")
        }
        // Walk pageDict -> /Parent for inheritable /MediaBox, /CropBox, /Rotate
        ...
    }
}
```
* **Tests**:
  * Reuse/extend: **ALL** existing tests in `Tests/PdfPersistenceTests.swift` (`testBookmarkCreateReadDelete`, `testBookmarkTitleCreateUpdateClear`, `testMetadataLastPageTitleAndCustomKeys`, `testRotatedPagesRoundTrip`) must continue passing unchanged on macOS!
  * New tests (run on BOTH macOS and Linux via `VellumPdfCoreTests`):
    * `PdfCoreMetadataTests.testStampAndReadMetadataPureSwift`
    * `PdfCoreBookmarksTests.testCreateUpdateDeleteBookmarkPureSwift`
    * `PdfCoreGeometryTests.testInheritedMediaBoxAndRotationMatchCgPdf`
* **Acceptance criteria**:
  * `VellumPdfCore` compiles cleanly on Linux Swift 6 with ZERO `CoreGraphics`, `PDFKit`, `AppKit`, or `UIKit` imports.
  * Every existing test in `PdfPersistenceTests` and `DocumentIdentityTests` passes on macOS with zero behavioral regression.
  * `PageGeometry(pageNumber:in:)` matches `PageGeometry(pageDictionary:)` on all rotation angles (`0, 90, 180, 270`), `/CropBox != /MediaBox`, and inherited `/Parent` attributes.
* **Size**: `M`
* **Depends on**: `C1` *(core-extraction anchor)*.
* **Risks**:
  * `PdfBookmarks.readBookmarks` currently uses `CGPDFDocument` for reading; adding a pure-Swift `ClassicPdfFile`-based reader in `P4` (or reading bookmarks via PDFium in `P1`) ensures Linux can read Vellum bookmarks without `CGPDF`. Recommend pure-Swift `ClassicPdfFile` reader for `/Outlines` so bookmarks work identically even without PDFium!

---

### P5 — Pure-Swift incremental PDF annotation writer · same item as C7b

* **Goal**: Implement a pure-Swift incremental writer for creating, updating, and deleting Vellum highlight and note annotations directly via `ClassicPdfFile` + `PdfIncrement` + `PdfAtomicWriter` — emitting the exact PDF contract-table keys expected by macOS/iPadOS PDFKit, handling absent/inline/indirect `/Annots` arrays, enforcing incremental compaction policy, and preserving `/VellumInk` ink pages and foreign annotations verbatim.
* **Files changed**:
  * **New**: `Packages/VellumCore/Sources/VellumCore/Pdf/PdfAnnotationIncrementWriter.swift`
  * **New**: `Packages/VellumCore/Sources/VellumCore/Pdf/PdfAnnotationPureReader.swift` (pure-Swift `/Annots` dictionary reader matching `PdfAnnotationReader` + foreign derived IDs)
  * `Vellum/Services/Pdf/PdfSessionBackend.swift` (optional shared opt-in seam so macOS tests can cross-verify Linux-written PDFs with PDFKit!)
* **Code sketch**:
```swift
// Packages/VellumCore/Sources/VellumCore/Pdf/PdfAnnotationIncrementWriter.swift
public enum PdfAnnotationIncrementWriter {

    public struct HighlightSpec: Sendable, Equatable {
        public let id: String                  // /NM (UUID string)
        public let pageNumber: Int             // 1-based
        public let uiRects: [UiRect]           // >= 1 rect in UI coordinates
        public let colorHex: String            // e.g. "#FDE047"
        public let comment: String?            // /Contents (optional)
        public let selectedText: String?       // /VellumSelectedText (optional)
        public let pinned: Bool                // /VellumPinned (1 / omitted or 0)
        public let createdAt: String           // ISO-8601 /VellumCreatedAt
        public let updatedAt: String           // ISO-8601 /VellumUpdatedAt
        public let pdfModDate: String          // D:YYYYMMDDHHMMSSZ /M
    }

    public struct NoteSpec: Sendable, Equatable {
        public let id: String                  // /NM
        public let pageNumber: Int             // 1-based
        public let anchorUiRect: UiRect        // 18x18 UI-unit rect anchored at rects[0]
        public let colorHex: String
        public let content: String             // /Contents
        public let pinned: Bool
        public let createdAt: String
        public let updatedAt: String
        public let pdfModDate: String
    }

    /// Creates a new /Highlight or /Text annotation on `pageNumber`.
    /// Returns the full updated PDF bytes (original + incremental update).
    public static func createHighlight(_ spec: HighlightSpec, in data: Data) throws -> Data
    public static func createNote(_ spec: NoteSpec, in data: Data) throws -> Data

    /// Updates an existing annotation matched by `/NM == id` (or derived foreign ID).
    /// - If annotation is an indirect object `N 0 R`: rewrites ONLY object `N` in the increment
    ///   (preserving `/Annots` order verbatim — NEVER touches sibling annotations!).
    /// - If annotation was an inline dictionary inside `/Annots`: promotes it to a new indirect
    ///   object `N 0 R` at the exact same index in `/Annots`.
    public static func updateAnnotation(
        id: String,
        pageNumber: Int,
        patch: AnnotationPatch,
        in data: Data
    ) throws -> Data

    /// Deletes an annotation matched by `/NM == id` (or derived foreign ID).
    /// Removes ONLY that entry from `/Annots` (inline or indirect array) and preserves every
    /// other `/Annots` entry verbatim (including `/VellumInk` and foreign annotations).
    public static func deleteAnnotation(
        id: String,
        pageNumber: Int,
        in data: Data
    ) throws -> Data
}
```
```swift
// Key algorithm 1: Exact Contract-Table Serialization (verified against PdfAnnotationCodec.swift:260-360)
// Highlight dictionary:
//   <<
//     /Type /Annot
//     /Subtype /Highlight
//     /Rect [minX minY maxX maxY]                    // PDF user space via PageGeometry.uiToPdf
//     /QuadPoints [x1 y1 x2 y2 x3 y3 x4 y4 ...]      // 8 floats per rect: TL, TR, BL, BR in PDF space
//     /C [r g b]                                     // 0.0...1.0 from PdfColor.parseHex
//     /CA 0.4                                        // PdfAnnotationDefaults.highlightOpacity
//     /F 4                                           // Print flag (bit 2)
//     /NM (<id>)
//     /T (Vellum)
//     /M (D:YYYYMMDDHHMMSSZ)
//     /VellumCreatedAt (<iso8601>)
//     /VellumUpdatedAt (<iso8601>)
//     [/Contents (<utf16be-or-pdfdoc>)]              // via PdfTextString.encode
//     [/VellumSelectedText (<utf16be-or-pdfdoc>)]
//     [/VellumPinned 1]                              // emitted when pinned == true (0 or removed when false)
//   >>
// Note dictionary:
//   <<
//     /Type /Annot
//     /Subtype /Text
//     /Name /Note
//     /Rect [x0 y0 x1 y1]                            // 18x18 UI-unit box mapped via uiToPdf
//     /C [r g b]
//     /F 4
//     /NM (<id>)
//     /T (Vellum)
//     /M (D:YYYYMMDDHHMMSSZ)
//     /Contents (<utf16be-or-pdfdoc>)
//     /VellumCreatedAt (<iso8601>)
//     /VellumUpdatedAt (<iso8601>)
//     [/VellumPinned 1]
//   >>

// Key algorithm 2: Handling all 3 `/Annots` representations on `/Page`:
// 1. `/Annots` absent on pageDict:
//      pageDict.setting("Annots", to: "[\(annotObjNum) 0 R]") -> emit updated pageObjNum in increment.
// 2. `/Annots` is an indirect reference `M 0 R`:
//      Read raw array from object `M`, append/splice/remove ONLY the target element,
//      emit updated object `M` in increment (pageDict itself doesn't even need rewriting!).
// 3. `/Annots` is an inline array `[ ... ]`:
//      Use `PdfArraySource` to append/splice/remove ONLY the target element,
//      update `/Annots` on pageDict, emit updated pageObjNum in increment.

// Key algorithm 3: Ink-page invariant (verified in Vellum/Platform/iOS/PdfInk.swift:32-44, 108-115):
// - On an iPad-inked page, the FIRST `/Ink` annotation carries base64 PKDrawing in `/VellumInk`;
//   subsequent `/Ink` annotations carry `/VellumInk (1)`.
// - INVARIANT: `PdfAnnotationIncrementWriter` MUST:
//   (a) Refuse to delete or mutate any annotation whose dictionary contains `/VellumInk`.
//   (b) NEVER reorder existing `/Annots` elements (new highlights/notes always append at the tail;
//       updates rewrite the target object in-place by object number; deletes splice out only the
//       single target index).
//   (c) Preserve raw bytes of all untouched `/Annots` entries (indirect refs & foreign inline dicts).

// Key algorithm 4: Compaction policy (preventing unbounded incremental tail growth):
// - Track incremental revision count via `ClassicPdfFile.prevChainDepth` (number of `/Prev` hops).
// - Default writes ALWAYS append incrementally (fast, O(delta), preserves foreign bytes & `/VellumInk`).
// - Compaction (optional/deferred): do NOT rewrite/compact encrypted, signed, or `/VellumInk` PDFs
//   on Linux. When `prevChainDepth >= 64` (or trailing increments exceed max(2 MB, 50% of base size))
//   on a plain eligible PDF, expose an explicit `PdfCompactor.compact` (deferred/post-MVP; in MVP,
//   incremental updates are ~400 bytes each so 64 edits = ~25 KB, and log a soft telemetry notice).
```
* **Tests**:
  * Reuse/extend: `Tests/PdfPersistenceTests.swift` (`testHighlightRoundTripAndRawFormat`, `testNoteRoundTripAndContentEdit`, `testUpdateHighlightColorAndPosition`, `testPinHighlightPersistsAndSortsFirst`, `testDeleteHighlight`, `testForeignAnnotationDerivedIdAndUpdate`, `testRotatedPagesRoundTrip`, `testRustWrittenFileInteropAndPreservation`), `Tests/InkPersistenceTests.swift`.
  * New tests (`PdfAnnotationIncrementWriterTests.swift`):
    * `testCreateUpdateDeleteHighlightWhenAnnotsAbsent`
    * `testCreateUpdateDeleteHighlightWhenAnnotsInline`
    * `testCreateUpdateDeleteHighlightWhenAnnotsIndirect`
    * `testNoteAnnotationEmitsExact18x18RectAndNameNote`
    * `testQuadPointsOrientationMatchesPdfKitOnAllRotations` (0°, 90°, 180°, 270°)
    * `testForeignAnnotationsPreservedByteForByteOnCreateUpdateDelete`
    * `testVellumInkFirstAnnotationInvariantPreservedAcrossHighlightEdits` (Mac+iOS cross-test: iPad-inked fixture → pure-Swift add/update/delete highlight → reload on PDFKit/PdfInk → `PKDrawing` decodes identically!)
    * `testLinuxWrittenPdfOpensAndRoundTripsCleanlyInMacPdfKit`
* **Acceptance criteria**:
  * Every highlight/note created, updated, pinned, or deleted by `PdfAnnotationIncrementWriter` reads back identically via BOTH `PdfAnnotationPureReader` (Linux) and `PdfAnnotationReader` / PDFKit (macOS/iOS).
  * Foreign annotations and `/VellumInk` annotations remain byte-for-byte untouched and in original `/Annots` order.
  * All three `/Annots` forms (absent, inline, indirect) pass full create → update → pin → delete cycles.
* **Size**: `L`
* **Depends on**: `P3`, `P4`, `P7`.
* **Risks**:
  * **QuadPoints vertex order**: PDF spec (ISO 32000-1 §12.5.6.10) vs PDFKit's `quadPoints` ordering (TL, TR, BL, BR vs BL, BR, TL, TR) is a classic pitfall! Verify exact order against `Vellum/Services/Pdf/PdfAnnotationCodec.swift` and assert visual highlight placement in both PDFium and macOS PDFKit on rotated pages (`0/90/180/270°`).
  * **Hybrid-reference PDFs** (classic xref with `/XRefStm` pointing to an object stream): until `P6` lands, `P3` must classify `/XRefStm` trailers as `.xrefStreamUnsupported` so `P5` never misses objects stored in `/ObjStm`.

---

### P6 — Xref-stream & object-stream reading in `ClassicPdfFile`

* **Goal**: Extend `ClassicPdfFile` (currently classic ASCII `xref` tables only, rejecting `/Type /XRef` at PdfAtomicWriter.swift:738 (`Vellum/Services/Pdf/PdfAtomicWriter.swift`)) to parse PDF 1.5+ cross-reference streams (`/Type /XRef`) and compressed object streams (`/Type /ObjStm`), enabling Linux incremental writes on modern PDFs (arXiv/LaTeX/Preview/Chrome-printed PDFs).
* **Files changed**:
  * `Vellum/Services/Pdf/PdfAtomicWriter.swift` (after `P4`: `Packages/VellumCore/Sources/VellumCore/Pdf/ClassicPdfFile.swift` — rename or keep `ClassicPdfFile` alias)
  * **New**: `Packages/VellumCore/Sources/VellumCore/Pdf/PdfXrefStreamParser.swift` (FlateDecode via zlib/`libz`, PNG predictor Up/Sub/Average/Paeth & TIFF predictor 2, `/W`, `/Index`, `/Prev`, `/XRefStm` hybrid chains, `/ObjStm` unpacking)
  * `Packages/VellumCore/Sources/VellumCore/Pdf/PdfWriteEligibility.swift` (flip `allowXrefStreams: true` once verified; emit xref-stream incremental trailer when base PDF uses xref streams per ISO 32000-1 §7.5.8.4!)
* **Code sketch**:
```swift
// Packages/VellumCore/Sources/VellumCore/Pdf/PdfXrefStreamParser.swift
/// ISO 32000-1 §7.5.8 cross-reference stream + §7.5.7 object stream reader.
public enum PdfXrefEntry: Equatable, Sendable {
    case free(nextFree: Int, generation: Int)               // type 0
    case uncompressed(offset: Int, generation: Int)         // type 1
    case compressed(objectStreamNumber: Int, index: Int)    // type 2 (generation is always 0)
}

public enum PdfXrefStreamParser {
    /// Parses an indirect `/Type /XRef` stream object at `offset`.
    /// Scope:
    /// - Filters: uncompressed or `/FlateDecode` (with `/DecodeParms` `/Predictor` 1, 2, 10–15, `/Columns`, `/Colors`, `/BitsPerComponent`).
    /// - `/W [w0 w1 w2]` big-endian unsigned integer decoding (missing `w0 == 0` defaults type to 1).
    /// - `/Index [first count ...]` (defaults to `[0 Size]`).
    /// - Hybrid-reference tables: classic `xref` trailer carrying `/XRefStm` merges both tables.
    /// - Follows `/Prev` recursively (cycle-guarded, newest entry wins).
    public static func parseXrefStream(
        in data: Data,
        at offset: Int
    ) throws -> (entries: [Int: PdfXrefEntry], trailer: PdfDictSource, prev: Int?) { ... }

    /// Unpacks `/Type /ObjStm` stream (FlateDecode) using `/N` and `/First` header pairs
    /// (`objNum byteOffset ...`) and returns the raw bytes of the object at `index`.
    public static func extractCompressedObject(
        fromStreamData streamData: Data,
        dict: PdfDictSource,
        index: Int
    ) throws -> Data { ... }
}

// IMPORTANT ISO 32000-1 §7.5.8.4 writer rule when base PDF uses xref streams:
// A PDF reader MUST NOT be given a classic `xref` + `trailer` increment whose `/Prev` points to
// an xref stream (strict readers including PDFium/Adobe reject classic-on-top-of-xref-stream!).
// Therefore `PdfIncrement.appended(to:)` checks `file.usesXrefStreams`:
//   - false -> emit classic `xref` + `trailer` (existing code, untouched!)
//   - true  -> emit an uncompressed `/Type /XRef` stream object (object number `nextObjNum`)
//              with `/W [1 8 2]`, `/Index [...]`, `/Size`, `/Root`, `/Info`, `/Prev`, `/ID`,
//              followed by `startxref\n<xrefStreamOffset>\n%%EOF\n`.
// Note: when mutating a compressed object (type 2 in `/ObjStm`), emitting it as a normal
// top-level uncompressed indirect object (type 1) in the new xref stream overrides it cleanly
// without ever needing to rewrite the original `/ObjStm`!
```
* **Tests**:
  * Reuse/extend: `Tests/PdfPersistenceTests.swift` (run the full highlight/note/bookmark/metadata round-trip suite against an xref-stream + `/ObjStm` fixture!).
  * New tests (`PdfXrefStreamTests.swift`):
    * `testParseXrefStreamWithPngUpPredictor`
    * `testParseHybridXrefTableWithXRefStm`
    * `testReadAndOverrideCompressedObjectInsideObjStm`
    * `testAppendXrefStreamIncrementReadableByPdfKitAndPdfium`
    * `testStampDocIdAndCreateHighlightOnChromeAndLatexXrefStreamFixtures`
* **Acceptance criteria**:
  * `ClassicPdfFile` reads `/Root`, `/Info`, `/Pages`, `/Page`, `/Annots`, and `/Outlines` transparently whether stored as top-level objects or compressed inside `/ObjStm`.
  * Appending a `/VellumDocId`, bookmark, or highlight to an xref-stream PDF emits a spec-compliant `/Type /XRef` incremental update readable by **both** PDFium (Linux) and Apple PDFKit (macOS/iOS).
  * `PdfWriteEligibilityClassifier` accepts xref-stream + `/ObjStm` PDFs as `.writable(.xrefStream)` while still rejecting encrypted/signed/non-zero-gen PDFs.
* **Size**: `L`
* **Depends on**: `P3`, `P4`, `P5`, `P7` *(explicitly scheduled after the read-only reader `P1`–`P2` and classic writer `P5` are working end-to-end)*.
* **Risks**:
  * **Spec trap**: Appending a classic `xref` table on top of a `/Type /XRef` stream violates ISO 32000-1 §7.5.8.4 and causes PDFKit / Acrobat / PDFium to fail to locate `/Prev`. Emitting an uncompressed `/Type /XRef` increment (only ~20 lines of code) avoids this cleanly.
  * **zlib dependency on Linux**: `Foundation` on Linux does not expose Apple's `Compression` framework; use system `zlib` (`CZlib` / `libz`, already ubiquitous on Linux and macOS) with a strict decompressed-size cap (e.g. 64 MB) to defend against zip-bomb PDFs.

---

### P7 — PDF fixture set & generators

* **Goal**: Establish a minimal, deterministic, self-contained PDF fixture corpus covering every edge case required by `P1`–`P6` (and `S8`), reusing existing programmatic generators where possible and adding tiny committed binary fixtures only where programmatic synthesis is impractical or platform-locked.
* **Current repo state (verified)**: Zero `.pdf` binary files currently exist in the repository. Existing tests synthesize PDFs programmatically inside `Tests/PdfPersistenceTests.swift` (classic PDF generator) and `Tests/InkPersistenceTests.swift` (`UIGraphicsPDFRenderer` iOS-only).
* **Files changed**:
  * **New**: `Tests/TestSupport/PdfFixtureBuilder.swift` (pure-Swift programmatic builder for classic xref, inline/indirect `/Annots`, rotated pages, non-zero generation, foreign annotations, and minimal synthetic xref-stream + `/ObjStm` PDFs — runs on Linux & macOS!)
  * **New**: `Tests/Fixtures/Pdf/` (tiny committed binary fixtures, <25 KB each, CC0/self-authored):
    1. `classic-two-column.pdf` — classic xref, multi-column English + Unicode text (for `P1`, `P2`, `P5`)
    2. `xref-stream-objstm.pdf` — PDF 1.5+ `/Type /XRef` + FlateDecode PNG-Up predictor + `/ObjStm` (e.g. minimal PDF saved via macOS Quartz/Chrome or qpdf, for `P3`, `P6`)
    3. `encrypted-user-pass.pdf` — RC4/AES encrypted with user password `"vellum"` (for `P1` unlock, `P3` read-only rejection, `S8` byte-hash fallback)
    4. `digitally-signed.pdf` — self-signed dummy PKCS#7 `/Type /Sig` + `/ByteRange` + `/AcroForm /SigFlags 3` (for `P3` read-only rejection)
    5. `rotated-all-angles.pdf` — 4-page PDF with `/Rotate` `0`, `90`, `180`, `270` and non-zero `/CropBox` origin (for `P1`, `P2`, `P4`, `P5`)
    6. `foreign-annotations.pdf` — classic PDF containing Preview/Acrobat `/Highlight`, `/FreeText`, `/Link`, and inline-dict `/Annots` without `/NM` (for `P5` preservation & derived-ID tests)
    7. `ipad-vellum-ink.pdf` — 1-page PDF generated by Vellum on iOS simulator using real `PdfInk.apply` (`PKDrawing` in first `/Ink` annotation's `/VellumInk`, second `/Ink` with `/VellumInk (1)`) so Linux tests can verify `/VellumInk` preservation without UIKit/PencilKit!
  * `Package.swift` (declare `.copy("Fixtures/Pdf")` resource in test target so `Bundle.module` locates them on both Linux and macOS)
* **Code sketch**:
```swift
// Tests/TestSupport/PdfFixtureBuilder.swift
public enum PdfFixtureBuilder {
    public enum AnnotsLayout { case absent, inlineEmpty, indirectEmpty, withForeignInline }

    /// Pure-Swift generator (works identically on Linux and macOS, zero CoreGraphics).
    public static func makeClassicPdf(
        pages: [(width: Double, height: Double, rotation: Int, text: String)],
        annotsLayout: AnnotsLayout = .absent,
        generation: Int = 0
    ) -> Data { ... }

    /// Locates committed binary fixtures under `Tests/Fixtures/Pdf/`.
    public static func fixtureURL(_ name: String) throws -> URL { ... }
}
```
* **Tests**:
  * Reuse/extend: `Tests/PdfPersistenceTests.swift` (deduplicate helper into `PdfFixtureBuilder`), `Tests/InkPersistenceTests.swift` (add a one-time helper/test confirming `ipad-vellum-ink.pdf` decodes a valid non-empty `PKDrawing`).
  * New tests (`PdfFixturesSanityTests.swift`):
    * `testAllSevenFixturesExistAndOpenInReader`
    * `testClassicBuilderProducesValidCrossPlatformPdf`
* **Acceptance criteria**:
  * All 7 fixtures exist under `Tests/Fixtures/Pdf/` (total size < 200 KB), carry clear provenance comment in `Tests/Fixtures/Pdf/README.md`, and load cleanly via `Bundle.module` on both macOS and Linux.
  * `ipad-vellum-ink.pdf` is verified by `InkPersistenceTests` on iOS/macOS to contain a decodable `PKDrawing` with ≥ 2 `/Ink` annotations exercising the first-annotation `/VellumInk` invariant.
* **Size**: `S`
* **Depends on**: `C1` *(core-extraction anchor for `Package.swift` test resources)*.
* **Risks**:
  * Ensure no copyrighted or private PDFs are ever committed — every fixture must be synthetic/self-authored.
