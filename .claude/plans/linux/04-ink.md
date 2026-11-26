# Layer 5 — Ink on Linux, step by step

Decides: how handwriting made on iPad shows up on Linux, and when Linux can draw,
without ever losing or resurrecting anyone's ink.

Depends on: D7 (ink shows up eventually, not in the first build), layer 2 (format contract,
especially "never drop unknown fields"), layer 3 (PDF engine and ink-page rules).
Reviewed by Gemini 4 Neon and GPT 6.2 Astra (round 2).

## Question

Ink exists in two places with different portability, and only iPad writes it. In what order
do we make it visible, then editable, on Linux, with every Apple version still safe?

## What exists today

| | Stored as | Who writes | Portable? |
|---|---|---|---|
| Ink on **PDFs** | Standard `/Ink` annotations: `/InkList`, `/C`, `/BS`, **no `/CA`**, **no `/AP`**. The whole page's `PKDrawing` sits in `/VellumInk` on the **first** ink annotation; the others carry `"1"` markers (`Platform/iOS/PdfInk.swift`) | **iPad only** (`#if os(iOS)`) | Geometry yes; the brush look, pressure and erasures live only in `/VellumInk` |
| Ink on **web pages** | `<key>.ink.json`: JSON wrapper (version, url, layout, clusters with bounds and text anchors); each cluster's required `drawing` field is a base64 **`PKDrawing`** (`WebInkStore.swift:92-118`) | **iPad only**; the Mac shows saved ink read-only (`WebSavedInk_macOS.swift`) | No |

Merge rules today (must be preserved by any new format):
- Live saves merge against a **baseline**, so an erasure stays erased (`WebInkStore` live merge).
- Archive import merges additively by stable **stroke identity** using the **record** timestamp
  (`additivelyMerged`). Stroke identity = creation date + points + time offsets.
- Strokes have **masked ranges** (`maskedPathRanges`): partially erased strokes keep their points
  but hide parts of them.

`ScratchOutRecognizer` is not PencilKit-bound (CoreGraphics + Foundation on point arrays);
only its iOS adapter touches `PKStroke`.

## Steps

### Step 1: v1, view PDF ink on Linux (no ink-format change)
PDFium draws `/Ink` from `/InkList` at render time (layer 3). Read-only.
- Uniform-width strokes: `/InkList` has no pressure. Marker strokes have no `/CA`, so they may
  render opaque. The layer-3 spike checks how they look.
- Never save a PDFium document after rendering. All saves go through the Swift writer on the
  original bytes.
- Web-page ink is **not** shown in v1. Linux shows a quiet "has handwriting (view on iPad/Mac)" badge.

### Step 2: Apple apps learn to *read* portable strokes (iPad + Mac, no writes yet)
Before any device writes the new format, every Apple app must tolerate it:
- **Unknown-field preservation** on `WebInkRecord` and the PDF ink path (layer 2, contract rule 1).
- A cluster may carry `strokes`, and `drawing` becomes **optional**. When `drawing` is absent,
  build a `PKDrawing` from `strokes`.
- Without this, a strokes-only file makes `loadRecord` return nil. iPad's next save then treats
  the page as empty and **overwrites it, deleting the other device's ink**.

### Step 3: iPad dual-writes portable strokes
iPad keeps writing `drawing` (Apple source of truth) and **also** writes `strokes`:

```json
"strokes": [{
  "id": "<stable stroke identity>",
  "ink": "pen",                          // PKInk.InkType raw value
  "color": [r, g, b, a],                 // sRGB
  "transform": [a, b, c, d, tx, ty],
  "created_at": "RFC3339",
  "visible_ranges": [[0.0, 12.5]],       // maskedPathRanges: keeps erasures erased
  "points": [{"x":0,"y":0,"t":0.0,"size":[w,h],"opacity":1,"force":1,"azimuth":0,"altitude":1.57}]
}]
```

- PDFs: a portable sibling of `/VellumInk` on the same first-annotation rule, plus iPad starts
  writing `/CA` on marker strokes (so any engine draws them translucent).
- **Backfill** is an explicit operation, not "open once". The Mac never writes ink, so backfill runs
  on iPad when a page is saved, or as a one-off migration command. Pages never re-saved stay
  non-portable and show the badge.
- File size roughly doubles for heavily inked pages. Measure before shipping.

### Step 4: Linux shows web ink (read-only)
Linux reads `strokes`, honours `visible_ranges`, and draws them with Cairo/GSK over the
WebKitGTK page in the same zoom-1 CSS-pixel space, reusing the existing anchors for reflow.

### Step 5: Linux draws
Gate: steps 2–3 shipped on every Apple device you use, and a **mixed-version round trip** passes.
iPad + Mac + Linux edit the same page (including an erasure), and nothing is lost or resurrected.
- Input: GTK4 `GtkGestureStylus` (pressure, tilt) on Wayland.
- Web pages: Linux writes `strokes` only. Merge by stable stroke id, with deletions expressed as
  tombstones or baseline diffs (the rule must be written down before this step starts).
- PDFs: new `/Ink` annotations through the Swift writer (layer 3). Linux must not move, delete or
  reorder the annotation holding `/VellumInk`. Apple apps must reconcile Linux-added `/Ink`
  annotations with the page's `PKDrawing`, and leave unrelated third-party ink alone.
- Eraser and scratch-out on Linux: decided at this step (`ScratchOutRecognizer` is reusable).

## Risks

- **Two sources of truth** (`drawing` vs `strokes`) once Linux writes. Hence the strict gate on step 5.
- **Fidelity**: Linux strokes won't match PencilKit's brush rendering. Fine for viewing.
- **Old Apple builds** still installed somewhere can drop `strokes`. Contract rule 1 must ship
  everywhere before step 3.

## Open questions

- **N10**: Start steps 2–3 soon (iPad work, independent of Linux) so less non-portable ink piles up?
  Recommendation: step 2 soon, step 3 right after.
- Is drawing on Linux a real use case (do you have a pen tablet there), or is view-only the
  long-term goal? If view-only, step 5 moves out of scope.

## Work items

Sizes: **S** < half a day, **M** about 1 day, **L** 2–3 days (one agent session each).
Cross-layer IDs: `S*` shared library (layer 2), `P*` PDF (layer 3), `C*` core + shell (layer 4).
Written in round 3; reviewed by Gemini 4 Neon and GPT 6.2 Astra.

### Round 4 corrections (authoritative: where an item below disagrees, this wins)

Both agents cross-reviewed these items against `PdfInk.swift`, `WebInkStore.swift` and the Mac views.

- **I0/I1: what PDF ink actually contains.** `PdfInk.apply` skips fully erased strokes, but writes a partially
  erased stroke's **whole** path into `/InkList`. So Linux (and any non-Apple reader) shows erased segments of
  partially erased strokes. That's a documented v1 limitation, not a test failure. The `/VellumInk` blob sits on the
  **first emitted Vellum** ink annotation, which may come after third-party ink, not necessarily the page's first
  `/Ink`. I0's PDFs live in P7's single fixture corpus.
- **I3: a reconstructible stroke.** Add `secondaryScale` to `PortablePoint` (the Apple stroke signature compares it).
  `visible_ranges` is for **display only**: PencilKit derives `maskedPathRanges` from a geometric mask that ranges
  can't reproduce, so Apple never rebuilds a mask from them. The stroke `id` is computed **on Apple** from the raw,
  untransformed `PKStrokePath` points (as `WebInkStore.strokeIdentity` does), with canonical encoding: creation date
  as RFC 3339 UTC with microseconds, numbers as IEEE-754 bit patterns in hex. It is **stored verbatim and opaque**
  everywhere else. Portable points are in cluster-local coordinates, translated by the cluster's stored bounds.
- **I4: every reader path, version stays 3.** `drawing` becomes optional and `strokes` is added, without bumping
  `WebInkRecord.currentVersion` (older builds check `1...currentVersion`). Update all six places that assume a
  `PKDrawing`: `validatedMergedDrawing`, `loadRecordForExport`, `additivelyMerged`, `WebArchive.mergeInk`,
  `WebSavedInkRenderer.load` (`WebSavedInk_macOS.swift`) and `SavedHandwritingReader.webClusters`
  (`MacHandwritingNavigator.swift`). Each must build the drawing from `strokes` when `drawing` is missing.
- **I6: prove PDFKit keeps the new keys.** Verify on iPadOS 26 that `dataRepresentation()` preserves
  `/VellumInkStrokes` and a real `/CA` on `/Ink`. If not, add `/Ink` to `PdfSessionBackend.rehydrateAnnotationMetadata`
  (it only handles Highlight/Text/FreeText today). Marker translucency needs a rendered fixture: the marker tool is
  built from a palette colour with no explicit alpha (`InkToolState.swift`).
- **I8 uses a dual-written fixture** (from I5 or I7). The original I0 sidecar has only `drawing`.
- **I9: tombstones ship before Linux writes.** Both Apple merge paths (the live baseline merge and `additivelyMerged`)
  rebuild fresh clusters, so preserving unknown JSON keys alone won't preserve tombstones. I9 implements and **ships**
  tombstone-aware save and import on iPad and Mac. That makes it a real code change, sized M, not just a spec.
- **I9b: capability gate (new).** An iPad running only I4 has no tombstone rules and could resurrect a stroke Linux
  deleted. So each device writes `.vellum/capabilities/<device>.json` (supported features + app build), and Linux
  enables ink writing only when every known device lists `ink-tombstones`.
- **I10: Linux edits only its own PDF strokes.** Linux can't express deleting an iPad stroke that lives inside the
  `/VellumInk` drawing, so in v1 Linux adds, edits and deletes only `/VellumInkOrigin (linux)` strokes. I10 also owns
  adding `/Ink` emission (`/InkList`, `/BS`, `/C`, `/CA`, `/Rect`, `/F`, `/VellumInkOrigin`, `/VellumInkStrokes`) to
  the P5 writer. Linux ink carries no `/VellumInk` key, so older iPad builds' `removeVellumInk` leaves it alone.
- **I11** updates `PdfInk.isVellumInk` and the iPad viewer so promoted Linux strokes count as handwriting, and is
  idempotent when run repeatedly.
- **I12 tests web and PDF separately**, including deleting the last stroke on a page, a save by an I4-only build
  (blocked by I9b), and running the I11 import twice.

### A rule found while detailing: iPad rewrites Vellum ink on save
`PdfInk.apply` (iPad) first calls `removeVellumInk(from: page)`, which deletes **every**
annotation carrying a `/VellumInk` key, then re-creates them from its own `PKDrawing`. So:
- Any ink Linux adds **with** a `/VellumInk` key is deleted the next time iPad saves that page.
- Ink **without** the key is treated as foreign and left alone, but iPad can't edit it.

Linux-written PDF ink is therefore written as tagged foreign ink (I10) until iPad learns to
import it (I11).

### Fixtures first

**I0 Ink fixture set** · S · depends on: nothing
- Goal: real iPad-made data every later item tests against. Tests today build PDFs in code
  (`Tests/InkPersistenceTests.swift`), so these are the first committed ink fixtures.
- New: `Tests/Ink/Fixtures/`
  - `pdf-ink-basic.pdf`: one page, pen strokes, colours
  - `pdf-ink-marker.pdf`: marker (highlighter) strokes, so `/CA` behaviour is visible
  - `pdf-ink-erased.pdf`: one fully erased and one partially erased stroke
  - `pdf-ink-rotated.pdf`: rotated page (rotated pages are a documented limitation)
  - `web-ink-v3.ink.json` + `web-ink-v3.page.json`: a real web page's ink sidecar and record
  - `README.md`: how each was made (device, app version, steps)
- Made on iPad with a Debug build, exported, checked in. Small files only.
- Acceptance: existing `InkPersistenceTests` and `WebInkPersistenceTests` load every fixture.

### Step 1: view PDF ink on Linux (v1)

**I1 PDF ink display on Linux** · S · depends on: P1, C5b, I0
- Goal: iPad ink appears on Linux, read-only.
- Rendering uses PDFium's `FPDF_ANNOT` render flag (draws annotations, synthesising an appearance
  from `/InkList`). Colour is read from `/C` **before** rendering, because `FPDFAnnot_GetColor`
  fails once an appearance exists.
- Acceptance: for each `pdf-ink-*.pdf`, a Linux screenshot (Weston) matches a Mac PDFKit
  render within a pixel-difference tolerance, ignoring stroke width (`/InkList` carries no
  pressure). Erased strokes do not appear. The library checksum is unchanged (C5b gate).
- Known gap recorded, not fixed: marker strokes may render opaque until I6 adds `/CA`.

**I2 Web-ink badge on Linux** · S · depends on: C5c
- Goal: a page with `<key>.ink.json` shows "has handwriting: view on iPad/Mac" until I8.

### Step 2: Apple apps learn to read portable strokes (no new writes)

**I3 Portable stroke model in VellumCore** · M · depends on: C1 (package exists)
- Goal: a PencilKit-free stroke type both platforms share.
- New: `Packages/VellumCore/Sources/VellumCore/Ink/PortableStroke.swift`

```swift
public struct PortableStroke: Codable, Equatable, Sendable {
    public var id: String              // stable identity, see below
    public var ink: String             // PKInk.InkType raw value: "pen", "marker", "pencil", …
    public var color: [Double]         // sRGB r, g, b, a
    public var transform: [Double]     // a, b, c, d, tx, ty
    public var createdAt: String       // RFC 3339
    public var visibleRanges: [[Double]]  // maskedPathRanges as [lower, upper] parametric pairs
    public var points: [PortablePoint]
    // + unknown-field bag (S-item pattern)
}
public struct PortablePoint: Codable, Equatable, Sendable {
    public var x, y, t: Double         // location, timeOffset
    public var w, h: Double            // size
    public var opacity, force, azimuth, altitude: Double
}
public enum PortableStrokeID {
    /// sha256 of creation date + (x, y, t) of every point: the same inputs as
    /// WebInkStore.strokeIdentity today, so ids line up with the existing merge.
    public static func make(createdAt: String, points: [PortablePoint]) -> String
}
```
- Apple adapter (app target, `Vellum/Services/Ink/PortableStroke+PencilKit.swift`):
  `PortableStroke(_ stroke: PKStroke)` and `PKStroke(_ portable: PortableStroke)`.
- Tests (`Tests/Ink/PortableStrokeTests.swift`): PKStroke → portable → PKStroke keeps the same
  `strokeSignature` (float tolerance 1e-6); masked ranges survive; ids are stable across encode/decode;
  JSON field names are snake_case and pinned by a golden file.

**I4 Readers accept `strokes` and optional `drawing`** · M · depends on: I3, S3
- Files: `Vellum/Services/Web/WebInkStore.swift`.
  - `WebInkRecord.Cluster.drawing: Data` becomes `Data?`, and `strokes: [PortableStroke]?` is added.
  - Decode: either may be missing, not both.
  - `mergedDrawing()` / `validatedMergedDrawing()`: when `drawing` is nil, build the `PKDrawing` from
    `strokes`. Never return an empty drawing for a cluster that has strokes.
  - `loadRecord` must not return nil for a strokes-only file.
  - Encode: re-emit both fields exactly as loaded (no silent drop), plus unknown keys.
- PDF side (`Vellum/Platform/iOS/PdfInk.swift`, `MacHandwritingNavigator.swift`): read a new
  `/VellumInkStrokes` key when present (format in I6). Absent → today's behaviour.
- Tests (extend `WebInkPersistenceTests`):
  - `testStrokesOnlyClusterLoads`
  - `testStrokesOnlyClusterSurvivesIPadSave`: load a strokes-only file, add a stroke, save; the
    original strokes are still present.
  - `testUnknownClusterKeysRoundTrip`
- Acceptance: ships in an iPad **and** Mac build before I5/I6 ship anywhere.

### Step 3: iPad dual-writes portable strokes

**I5 iPad dual-writes web ink** · S · depends on: I4 shipped
- `WebInkRecord.snapshot(...)` also fills `strokes` from the live `PKDrawing`. `currentVersion`
  stays 3, because the change is additive.
- Erasure: fully erased strokes are dropped (matching `PdfInk.apply`); partially erased ones carry
  `visible_ranges`.
- Test: `testSnapshotWritesMatchingStrokes`: every stroke in `drawing` has a portable twin with
  the same id.

**I6 iPad dual-writes PDF ink + `/CA` on marker strokes** · M · depends on: I4 shipped, P4 (= C6)
- On the first Vellum ink annotation of the page (the same one that holds `/VellumInk`), add
  `/VellumInkStrokes`: base64 of zlib-compressed JSON `[PortableStroke]`. The others keep `"1"`.
- Marker strokes get `/CA` from the ink colour's alpha, so other engines draw them translucent.
- Tests (extend `InkPersistenceTests`): `testApplyWritesPortableStrokes`,
  `testMarkerStrokeWritesCA`, and the existing erase tests unchanged.

**I7 Backfill** · M · depends on: I5, I6
- Goal: make existing ink portable without waiting for a re-save.
- iPad-only command (Settings → Storage → "Make handwriting portable"): walks web ink sidecars and
  PDFs with `/VellumInk`, decodes the `PKDrawing`, writes `strokes` / `/VellumInkStrokes`. It
  never changes `drawing`. Runs through the same atomic writers and the document drain rules.
- Reports counts (pages updated, skipped, failed). Resumable.
- Test: backfill on fixtures, then byte-compare `drawing` unchanged and the strokes present.

### Step 4: Linux shows web ink

**I8 Web ink display on Linux** · M · depends on: I5 (data exists), C5c
- Draw strokes **inside the page** as an injected SVG layer positioned in zoom-1 CSS pixels (the
  same space the sidecar uses), so it scrolls and zooms with the content and reuses the existing
  anchor/reflow logic.
- Honour `visible_ranges`. Approximate pressure by varying stroke width from `force`.
- Acceptance: screenshots of `web-ink-v3` on Linux and Mac line up within tolerance; layout-width
  mismatch shows the existing "best-effort" behaviour.

### Step 5: Linux draws (only if you want pen input on Linux, see open questions)

**I9 Merge rule for three writers (spec only)** · S · depends on: nothing; must finish before I10
- Write down, then test: identity = `PortableStroke.id`; deletions are **tombstones**
  (`deleted_ids` with timestamps) so a stale device can't resurrect an erased stroke; partial
  erasure = the newest `visible_ranges` wins.
- Update `additivelyMerged` and the live baseline merge to the same rule on Apple first.

**I10 Linux web + PDF ink writing** · L · depends on: I9, P5 (= C7b), C5b
- Input: GTK4 `GtkGestureStylus` (pressure, tilt) on Wayland.
- Web: write `strokes` only, plus tombstones.
- PDF: new `/Ink` annotations through the Swift writer, tagged `/VellumInkOrigin (linux)` and
  **without** `/VellumInk`, so iPad's `removeVellumInk` doesn't delete them. Each carries its own
  portable stroke in `/VellumInkStrokes`.

**I11 iPad imports Linux PDF ink** · M · depends on: I10
- On page load, iPad folds `/VellumInkOrigin (linux)` annotations into its `PKDrawing`. On the next
  save, `apply` writes them back as normal Vellum ink and removes the Linux-tagged copies, in one
  atomic save.

**I12 Mixed-version round trip** · M · depends on: I4–I11
- Scripted scenario on fixtures: iPad draws → Linux adds and erases one stroke → iPad (old build
  with only I4) saves → iPad (new build) saves → Linux reloads. No stroke lost, none resurrected.
- This is the gate for calling Linux ink writing done.

| ID | Item | Size | Depends on |
|---|---|---|---|
| I0 | Ink fixtures: iPad PDFs (in P7's shared corpus) + web sidecar; full vs partial erasure recorded separately | S | P7 |
| I1 | View PDF ink on Linux | S | P1, C5b, I0 |
| I2 | "Has handwriting" badge for web ink | S | C5c |
| I3 | `PortableStroke` in VellumCore + PencilKit adapter | M | C1 |
| I4 | Apple readers accept `strokes` and optional `drawing` (all 6 code paths, version stays 3) | M–L | I3, S3 |
| I5 | iPad dual-writes web ink | S | I4 shipped |
| I6 | iPad dual-writes PDF ink + `/CA` on marker strokes | M | I4 shipped, P4 |
| I7 | Backfill command on iPad | M | I5, I6 |
| I8 | Linux shows web ink | M | I5, C5c |
| I9 | Tombstone merge rule, **shipped** in both Apple merge paths | M | I4 |
| I9b | Capability gate: Linux writes ink only when every device reports I9 support | S | I9 |
| I10 | Linux draws (web + PDF), incl. `/Ink` emission in the P5 writer | L | I9 shipped, I9b, P5 (= C7b), S9 |
| I11 | iPad imports Linux PDF ink | M | I10 |
| I12 | Mixed-version round trip | M | I4–I11 |

### Dependency order

```
I0 → I1          C5c → I2
C1 → I3 → I4 ──(ship on iPad + Mac)──→ I5 ─┐
                       P4 (= C6) ──→ I6 ────┼→ I7
                                            └→ I8
I4 → I9 (shipped) → I9b → I10 → I11 → I12   (I10 also needs P5 = C7b and S9)
```

Minimum for "ink shows up on Linux": I0, I1, I2 (PDF ink in v1), then I3–I5 + I8 (web ink).
