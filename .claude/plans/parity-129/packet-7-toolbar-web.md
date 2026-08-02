# Packet 7 — Reader chrome & web viewer (issue #136, parity phase 7)

Source of the delta: `/Users/ayushdeolasee/Developer/Vellum/main`, range `a42705d1~1..7742a895`.
Target: `/Users/ayushdeolasee/Developer/Vellum/ipad-app`, branch `ipad-app`.

**Read this first — the single most important structural fact about this packet.**
Four of the six files main changed in this scope are **`#if os(macOS)`-gated dead
code inside the iPad worktree**. They compile to nothing on iOS. The live iPad
counterparts live in `Vellum/Platform/iOS/`:

| main file (delta) | compiles on iPad? | live iPad counterpart |
|---|---|---|
| `Vellum/Views/PDF/ToolbarView.swift` | no (`#if os(macOS)`) | `Vellum/Platform/iOS/PdfChrome_iOS.swift` |
| `Vellum/Views/PDF/PdfSelectionBridge.swift` | no (`#if os(macOS)`) | `Vellum/Platform/iOS/PdfViewerController_iOS.swift` |
| `Vellum/Views/Web/WebViewerView.swift` | no (`#if os(macOS)`) | `Vellum/Platform/iOS/WebViewerView_iOS.swift` |
| `Vellum/App/ContentView.swift` | no (`#if os(macOS)`) | `Vellum/Platform/iOS/ContentView_iOS.swift` |
| `Vellum/Views/Web/WebNotePopovers.swift` | **yes** (cross-platform) | itself |
| `Vellum/Views/AI/MathRenderer.swift` | **yes** (cross-platform) | itself |
| `Vellum/Services/**` | **yes** | itself |

So "port ToolbarView.swift" never means editing `ToolbarView.swift`. Edit the
iOS file. Do not delete or un-gate the macOS files — they are kept in the tree
deliberately so future `git`-level comparisons against main stay legible.

---

## 1. Delta files claimed

### Implementation

```
Vellum/Services/Ai/PageTextExtractionGate.swift          [VERBATIM]  (+ one additive iPad-only overload, §2.1)
Vellum/Views/PDF/PdfSelectionBridge.swift                [REBUILD]   → Vellum/Platform/iOS/PdfViewerController_iOS.swift (+ PdfTextLocator.swift)
Vellum/Views/PDF/ToolbarView.swift                       [REBUILD]   → Vellum/Platform/iOS/PdfChrome_iOS.swift  (design language only; PR #115 is NOT ported as code)
Vellum/Views/Web/WebViewerView.swift                     [REBUILD]   → Vellum/Platform/iOS/WebViewerView_iOS.swift (#125 draft preservation)
Vellum/Views/Web/WebNotePopovers.swift                   [MERGE]
Vellum/Views/AI/MathRenderer.swift                       [MERGE]
Vellum/Services/Web/WebSessionBackend.swift              [MERGE]     (offline-copy semantics hunk only; off-main hunks already done on iPad) — EDIT ORDER 1 -> 6 -> 7, packet 7 LAST
Vellum/Services/Pdf/PdfSessionBackend.swift              [MERGE]     (reconcile with the iPad's own off-main open, already landed) — EDIT ORDER 1 -> 6 -> 7, packet 7 LAST
Vellum/Views/Shared/FindBar.swift                        [MERGE]     (blocked on packet 4 — see §5 D3; it is the LAST link of the C3 chain, after packet 4 §2.0, packet 7 viewers and packet 4 §2.8)
Vellum/App/ContentView.swift                             [SKIP: macOS-gated. #116's sheet/environment reorder and #115's inspector ToolbarSpacer are both NSToolbar/AppKit-shaped and structurally impossible on iPad. Verification + a11y-id follow-up recorded in §2.7 against ContentView_iOS.swift.]
```

### Tests

```
Tests/PageTextExtractionGateTests.swift                  [VERBATIM]  (+ 2 iPad-only cases, §4.1)
Tests/MarkdownParserTests.swift                          [MERGE]     (the 11 code-span/math tests from #127)
Tests/WebLibraryStorageTests.swift                       [MERGE]     (testKeepOfflineStatusRequiresAnActualSnapshot ONLY)
Tests/WebProxyUrlTests.swift                             [MERGE]     (one-line `@MainActor`)
Tests/AiAddAsNoteTests.swift                             [SKIP as a file — RESOLVED, packet 10 §2.1: packet 9 creates Tests/AiAddAsNoteTests.swift from packet 5's content. My 14 web-dismissal cases go to a NEW Tests/WebNoteDraftTests.swift instead (not in delta-files.txt, so it needs no claim). Nobody ports it twice. Content spec: §4.3.]
Tests/AiMarkdownRenderingTests.swift                     [SKIP: packet 9 writes it, content per packet 5 §I.1 — and it is BLOCKED until packet 5 lands InlineMarkdown.swift (packet 10 §2.1). Its 4 #127 cases are redundant with the MarkdownParserTests cases I do port.]
Tests/PageTextCacheTests.swift                           [SKIP: the whole 120-line delta is the docId re-key (PageTextCache.lookup(key:…)) — packet 1.]
```

### Everything else in `delta-files.txt`

Out of scope for this packet. Named here only where a reader might reasonably
expect me to have taken them, with the reason:

```
Vellum/Services/Ai/PageTextCache.swift                   [SKIP: docId re-key — packet 1]
Vellum/Services/Ai/PageTextPersister.swift               [SKIP: `key:` init param for the docId re-key — packet 1. My gate work does not touch it.]
Vellum/Services/Web/WebLibrary.swift                     [SKIP: setTitle/totalRecordBytes/UITestLaunchConfiguration + `nonisolated(unsafe)` removals — packets 1 and 9. iPad already has hasLocalSnapshot/removeLocalSnapshots.]
Vellum/Services/Web/WebStorage.swift                     [SKIP: documentsDir layout + migrator — packet 1]
Vellum/Services/Web/WebArchive.swift                     [SKIP: MiniZip entryCount/totalDeclaredUncompressedSize + `nonisolated(unsafe)` removals — packets 2, 1 and 9]
Vellum/Services/Web/WebPageExtractor.swift               [SKIP: `nonisolated(unsafe)` removals only — packet 9 owns them, MERGE. Packet 10 §1.1 assigned this: the "warnings packet" this used to cite was never cut, so the flag decision and the removals go to the single owner of project.yml. Packet 9 states the decision once.]
Vellum/Views/PDF/PdfViewerView.swift                     [SKIP: tab-residency/LiveTabRuntime — packet 4]
Vellum/Views/PDF/PdfKitView.swift                        [SKIP: packet 4]
Vellum/Views/PDF/PdfOverlays.swift                       [SKIP: region-capture/AI-references — packet 5]
Vellum/Views/PDF/TabBarView.swift                        [SKIP: tab overview & management (#83) — packet 4]
Vellum/Models/Models.swift                               [SKIP: PdfTab gains pendingNoteContent/regionCaptureTarget/find* — packet 4. §5 records my dependency on it.]
Vellum/Stores/AppStore.swift                             [SKIP as a file: packets 4 and 1 own it. My one addition (`restorePendingNote`) is specified in §2.4 as a surgical insert.]
plans/*, UITests/*, .github/*, CHANGELOG/AGENTS/CLAUDE.md [SKIP: docs/CI/macOS-only UI test target]
```

---

## 2. Port order & instructions

Order matters. **Do them in this sequence** — 2.1 → 2.2 are independent of every
other packet and should land first; 2.4 depends on 2.3.

---

### 2.1 `PageTextExtractionGate.swift` — [VERBATIM] + one additive overload

**Source → dest**

```
main:  Vellum/Services/Ai/PageTextExtractionGate.swift
iPad:  Vellum/Services/Ai/PageTextExtractionGate.swift   (new file, copy byte-for-byte)
```

Pure Foundation. No `import AppKit`, no availability shims, no `#if` needed.
xcodegen picks it up automatically (`sources: - path: Vellum` in project.yml) —
**no project.yml change.**

Copy it exactly. Do not reword the doc comments: they are the only record of why
`page.string` is dangerous and why pacing keys off an *empty* result instead of a
clock.

**What it is.** A `@MainActor final class` with a process-wide `.shared`
instance. `extractText(priority:_:)` runs one `page.string`-shaped read at a
time; a body that returns an empty string (or takes ≥25 ms) makes the *next*
caller wait out a 16 ms cooldown; `.onDemand` waiters jump ahead of queued
`.background` waiters; FIFO within a band; a waiter cancelled while queued
leaves the queue via `withTaskCancellationHandler` without ever taking the slot.

**The one iPad-only addition (required — read carefully).**

macOS runs its 1→N page walk *on the main actor* over the live view-bound
`PDFDocument`. The iPad deliberately does not: `PdfViewerController_iOS
.startTextExtraction(data:)` runs `Task.detached(priority: .utility)` over a
**private `PDFDocument(data:)` copy**, because walking the live document on the
main actor "starved the run loop for minutes on textbook PDFs, freezing every
interaction after open/tab-switch" (its own doc comment). That is an iPad-only
fix that MUST survive.

Main's `extractText(priority:_:)` takes a **synchronous** body and is
`@MainActor`-isolated, so calling it from the detached walk would drag
`page.string` back onto the main actor and undo that fix.

Fix: append this overload **at the bottom of the same file** (same file, not a
separate one — `acquire`, `release` and `ocrDurationThreshold` are `private`,
which in Swift is file-scoped, so a same-file extension reaches them and a
separate file would not):

```swift
// MARK: - iPad addition: bodies that run off the main actor
//
// The iPad's 1→N walk parses a PRIVATE `PDFDocument` copy on a detached utility
// task (see `PdfViewerController_iOS.startTextExtraction(data:)`) because
// walking the live, view-bound document on the main actor starved the run loop
// for minutes on textbook PDFs. The synchronous `extractText` above runs its
// body on the main actor, which would undo that. This overload holds the exact
// same single slot and applies the exact same pacing — only the queue
// bookkeeping stays main-actor isolated; the body runs wherever the caller is.
//
// The pacing contract is unchanged and load-bearing: return the extracted text
// (empty string included) to have the next caller paced, return nil when no
// read happened so nothing is paced.
extension PageTextExtractionGate {
    func extractText(
        priority: Priority,
        offMain body: @Sendable () async -> String?
    ) async -> String? {
        guard await acquire(priority: priority) else { return nil }
        var suspectedLiveText = false
        defer { release(pacingNeeded: suspectedLiveText) }
        guard !Task.isCancelled else { return nil }
        let started = ContinuousClock.now
        let text = await body()
        if let text {
            suspectedLiveText = text.isEmpty
                || ContinuousClock.now - started >= Self.ocrDurationThreshold
        }
        return text
    }
}
```

Notes for whoever writes it:
- The argument label `offMain:` is what distinguishes it from the verbatim
  overload; do not drop it or the two become ambiguous at trailing-closure call
  sites.
- A `nonisolated` `async` closure invoked from a `@MainActor` function runs on
  the cooperative pool, not the caller's actor — that is what buys the off-main
  execution. The project builds at `SWIFT_STRICT_CONCURRENCY: minimal`
  (project.yml), so the non-`Sendable` `PDFDocument` captured by the walk's
  closure will not error; if strictness is ever raised, this closure and the
  walk's `copy` capture are the first two things that will complain.

---

### 2.2 Extraction-gate routing — [REBUILD] `PdfSelectionBridge.swift` → `PdfViewerController_iOS.swift` + `PdfTextLocator.swift`

**What main changed (commit `cbd09a7d`, PR #121)**

Only one file besides the gate: `Vellum/Views/PDF/PdfSelectionBridge.swift`.
Three changes:

1. **New private helper `extractPage(_:from:tabId:priority:) async -> PageExtractionOutcome`**
   with `enum PageExtractionOutcome { case extracted, alreadyCached, stale }`.
   It is the single choke point for `page.string` on the controller. The body
   passed to the gate does the document-identity check, the active-tab check,
   the **cache re-check (now INSIDE the gate)**, the `page.string` read, the
   `ai.setPageText` publish, the `runtime.pageTexts` write and the
   `persister.noteExtracted`. `outcome` starts at `.stale` so a caller cancelled
   while queued (body never runs) stops the walk.
2. **`startTextExtraction()`** — the per-page inline read became
   `if self.ai?.pageTexts[pageNumber] != nil { continue }` (skip without even
   queueing) followed by `await self.extractPage(…, priority: .background)`, and
   `if case .stale = outcome { return }`.
3. **`ensureExtracted(pages:)`** — the on-demand loop routes each page through
   `extractPage(…, priority: .onDemand)`; `.stale → return extracted`,
   `.alreadyCached → continue`, `.extracted → extracted += 1`. The `sinceYield >= 8`
   `Task.yield()` cadence stays (it is now only load-bearing when the gate is
   uncontended and never suspends).
4. **`locateText`** (the AI highlight locator) — was reading `page.string`
   ungated. Now:
   ```swift
   let extractedPage = await PageTextExtractionGate.shared.extractText(priority: .onDemand) {
       page.string ?? ""
   }
   guard let pageString = extractedPage, !pageString.isEmpty else { return nil }
   ```

Explicitly **not** gated by main, and do not gate it on iPad either:
`PDFDocument.findString` (⌘F) — one synchronous whole-document main-thread call,
user-initiated, never concurrent with itself; gating it would force the find
handler async all the way up through `AppStore`.

**What the iPad looks like today**

`Vellum/Views/PDF/PdfSelectionBridge.swift` is entirely `#if os(macOS)` — dead.
The live producers of `page.string` on iPad are exactly two (verified by
`grep -rn "page.string" Vellum --include="*.swift"`, discounting the gated file):

| # | producer | file:line | actor |
|---|---|---|---|
| 1 | background 1→N walk | `Vellum/Platform/iOS/PdfViewerController_iOS.swift:546` | **detached / off-main**, private `PDFDocument(data:)` copy |
| 2 | AI highlight locator | `Vellum/Services/Pdf/PdfTextLocator.swift:87` (via `PdfViewerController_iOS.locateText`, line 566) | main actor |

There is **no third producer**: `AiStore.ensureExtractedHandler` is declared
(`Vellum/Stores/AiStore.swift:222`) but **never installed on iPad** — nothing in
`Vellum/Platform/iOS/` assigns it, so `AiStore.ensureExtracted` returns 0 and
`AiToolEngine.getPageText`/`searchDocument` and the per-turn context fill read
whatever the walk has already produced. That is a pre-existing iPad gap versus
macOS, **not** something this packet closes (see §5, risk R3).

**Concrete instructions**

**(a) `Vellum/Services/Pdf/PdfTextLocator.swift`** — split the `page.string`
read out of the pure algorithm so the caller can gate it.

Change the signature at line 82:

```swift
    static func locate(pageNumber: Int, query: String, in document: PDFDocument) -> LocatedText? {
```

to a pair — keep the algorithm identical, only move where the text comes from:

```swift
    /// Whitespace-stripped, lowercased first-match locator returning line-merged
    /// rects at zoom 1 in top-left-origin page points.
    ///
    /// `pageString` is passed in rather than read here: on a page with no text
    /// layer `PDFPage.string` falls back to Live Text, and every such read in
    /// the app has to go through `PageTextExtractionGate` (see that file for the
    /// ANE crash it prevents). Keeping the read at the call site is what lets
    /// the caller hold the gate for it.
    static func locate(
        pageNumber: Int, query: String, in document: PDFDocument, pageString: String
    ) -> LocatedText? {
        guard pageNumber >= 1, pageNumber <= document.pageCount,
              let page = document.page(at: pageNumber - 1) else { return nil }
        let needle = query
            .replacingOccurrences(of: "\\s+", with: "", options: .regularExpression)
            .lowercased()
        guard !needle.isEmpty, !pageString.isEmpty else { return nil }
        // …rest of the existing body verbatim, unchanged…
    }
```

i.e. delete the old line 87 `guard !needle.isEmpty, let pageString = page.string else { return nil }`
and replace with the `!pageString.isEmpty` guard shown. Everything below it is
untouched. **Do not** leave a convenience overload that reads `page.string`
itself — an ungated door is exactly what #121 exists to close, and the compiler
finding the (single) call site is the point.

**(b) `Vellum/Platform/iOS/PdfViewerController_iOS.swift:566` — `locateText`**

```swift
    func locateText(pageNumber: Int, query: String) async -> LocatedText? {
        guard let document, pageNumber >= 1, pageNumber <= document.pageCount,
              let page = document.page(at: pageNumber - 1) else { return nil }
        // Same Live Text hazard as the extraction walk: on a scanned page this
        // `page.string` runs OCR, so it takes the gate rather than racing a walk
        // that is mid-compile (see PageTextExtractionGate). Main-actor caller,
        // main-actor body — the synchronous overload.
        let extracted = await PageTextExtractionGate.shared.extractText(priority: .onDemand) {
            page.string ?? ""
        }
        guard let pageString = extracted, !pageString.isEmpty else { return nil }
        return PdfTextLocator.locate(
            pageNumber: pageNumber, query: query, in: document, pageString: pageString)
    }
```

**(c) `Vellum/Platform/iOS/PdfViewerController_iOS.swift:525` — `startTextExtraction(data:)`**

Preserve **all** of these iPad-only properties; they are the reason this method
diverges from main and none of them may be lost:
- the `Task.detached(priority: .utility)` + private `PDFDocument(data:)` copy;
- the `missingPages` pre-filter computed on the main actor before the hop (a
  fully cached document never even pays the copy parse);
- the `docIdentity` / `tabId` generation guards checked on the main actor;
- the 16 ms inter-page sleep;
- the final `persister.flush()` with `complete = true`.

Replace only the inner per-page block. Current (lines ~538-559):

```swift
            for pageNumber in missingPages {
                try? await Task.sleep(for: .milliseconds(16))
                if Task.isCancelled { return }
                guard pageNumber <= copy.pageCount,
                      let page = copy.page(at: pageNumber - 1) else { continue }
                let text = page.string ?? ""
                let stillCurrent = await MainActor.run { [weak self] () -> Bool in
                    guard let self, let ai = self.ai,
                          self.document.map(ObjectIdentifier.init) == docIdentity,
                          self.app?.activeTabId == tabId else { return false }
                    if ai.pageTexts[pageNumber] == nil,
                       let normalized = ai.setPageText(page: pageNumber, text: text) {
                        self.persister?.noteExtracted(page: pageNumber, text: normalized)
                    }
                    return true
                }
                if !stillCurrent { return }
            }
```

New:

```swift
            for pageNumber in missingPages {
                // Idle pacing, kept from the original walk so a background core
                // isn't pinned for the whole document. The gate's own cooldown
                // is measured from the END of the previous page, so this sleep
                // normally absorbs it rather than adding to it.
                try? await Task.sleep(for: .milliseconds(16))
                if Task.isCancelled { return }

                // One page at a time, process-wide (PR #121): `PDFPage.string`
                // on a page with no text layer sends PDFKit to Live Text, and
                // overlapping first-time ANE model compiles crash the process.
                // `offMain:` keeps the read on this detached task — the whole
                // point of walking a private document copy — while the gate's
                // queue bookkeeping stays main-actor isolated.
                let text = await PageTextExtractionGate.shared.extractText(
                    priority: .background
                ) { () async -> String? in
                    // Cache re-check INSIDE the gate: a page the locator (or a
                    // second pane's walk) filled while this request sat in the
                    // queue is skipped, not re-extracted. Returning nil also
                    // tells the gate no read happened, so nothing is paced.
                    let stillNeeded = await MainActor.run { [weak self] () -> Bool in
                        guard let self, let ai = self.ai else { return false }
                        return ai.pageTexts[pageNumber] == nil
                    }
                    guard stillNeeded,
                          pageNumber <= copy.pageCount,
                          let page = copy.page(at: pageNumber - 1) else { return nil }
                    return page.string ?? ""
                }
                guard let text else { continue }

                let stillCurrent = await MainActor.run { [weak self] () -> Bool in
                    guard let self, let ai = self.ai,
                          self.document.map(ObjectIdentifier.init) == docIdentity,
                          self.app?.activeTabId == tabId else { return false }
                    if ai.pageTexts[pageNumber] == nil,
                       let normalized = ai.setPageText(page: pageNumber, text: text) {
                        self.persister?.noteExtracted(page: pageNumber, text: normalized)
                    }
                    return true
                }
                if !stillCurrent { return }
            }
```

Behavioural notes to preserve:
- `guard let text else { continue }` and not `return`: nil means "cached
  already, or cancelled-while-queued". The `Task.isCancelled` check at the top of
  the next iteration handles real cancellation; the document/tab generation
  guard handles staleness. This is the iPad equivalent of main's `.alreadyCached`
  vs `.stale` split — the iPad walk has no `runtime.pageTexts` and no
  `PageExtractionOutcome` enum, so do **not** introduce one just for symmetry.
- Two panes in a split each run their own walk. That is exactly the case #121
  cites ("one per activated tab — so two in a split view"), and the shared
  `PageTextExtractionGate.shared` is what now serializes them.

**(d) Nothing else.** Do not gate `capturePageImage` (renders, does not extract
text) or `findString`.

---

### 2.3 `WebNotePopovers.swift` — [MERGE] (draft mirror on the composer)

Cross-platform file, compiles on iOS, used by `WebViewerView_iOS`. The diff is
small and applies cleanly — the iPad file is at main's pre-#69 baseline for this
struct, so you are applying **two** things at once.

**What main has at HEAD** (`WebNoteComposerView`, main line ~185):

```swift
struct WebNoteComposerView: View {
    var initialContent: String = ""
    var onSubmit: (String) -> Void
    var onClose: () -> Void
    /// Reports edits upward so an unasked-for dismissal (stray click, scroll)
    /// can hand the draft back to the note queue instead of dropping it — see
    /// `WebViewerController.returnNoteComposerDraft` and issue #92.
    var onDraftChange: (String) -> Void = { _ in }

    @State private var text: String
    @Environment(\.palette) private var palette

    init(
        initialContent: String = "",
        onSubmit: @escaping (String) -> Void,
        onClose: @escaping () -> Void,
        onDraftChange: @escaping (String) -> Void = { _ in }
    ) {
        self.initialContent = initialContent
        self.onSubmit = onSubmit
        self.onClose = onClose
        self.onDraftChange = onDraftChange
        _text = State(initialValue: initialContent)
    }
```

and in the body, `NoteTextEditor(text: $text, …)` became:

```swift
                // Written through on set rather than observed with
                // `.onChange`: that fires during a later update pass, so a
                // dismissal landing in the same pass could hand back a mirror
                // one keystroke stale. The write costs nothing — it lands on an
                // observation-ignored field and invalidates no view.
                NoteTextEditor(
                    text: Binding(get: { text }, set: { text = $0; onDraftChange($0) }),
                    onSubmit: submit,
                    onClose: onClose)
```

**What the iPad has today** (`Vellum/Views/Web/WebNotePopovers.swift:185-196`):

```swift
struct WebNoteComposerView: View {
    var onSubmit: (String) -> Void
    var onClose: () -> Void

    @State private var text = ""
    @Environment(\.palette) private var palette
```

— no `initialContent`, no memberwise-replacing `init`, no `onDraftChange`, and
`NoteTextEditor(text: $text, onSubmit: submit, onClose: onClose)` at line 203.

**Merge instructions.** Replace the property block + add the explicit `init`
exactly as main has it, and swap line 203 for main's write-through `Binding`
form. Everything else in the struct (`PopoverCard`, the amber header, the
`SmallGhostButton`/`SmallPrimaryButton` row, `.padding(8)`, `.frame(width: 288)`,
`submit()`) is byte-identical between the two and must stay untouched.

`NoteTextEditor` itself (iPad line 86) is a separate, already-diverged
cross-platform struct — **do not** touch it. `WebNoteViewerPopover`'s second
`NoteTextEditor` call site (iPad line 307) is not part of this change.

---

### 2.4 Web note composer draft preservation — [REBUILD] `WebViewerView.swift` → `WebViewerView_iOS.swift` + one `AppStore` method

Main commit `8785f5a8` (PR #125, closes #92).

**The bug.** On the web path the placement click only *opens* a composer — the
note is not written until submit. Between those two steps the composer holds the
**only** copy of a queued AI reply, because `consumePendingNoteContent()` has
already emptied the store. A stray page tap, a scroll, another popover, a
context menu, an annotation tap, a soft-navigation or a tab switch unmounted the
composer and the reply went with it. (The PDF path has no such window:
`PdfSelectionBridge` writes the note on the placement click itself.)

**Prerequisite the iPad is missing.** Main got `initialContent` on
`WebNoteComposerState` + `consumePendingNoteContent()` in the `"note-placed"`
branch back in PR #69; the iPad never received it. Verified:
`Vellum/Views/Web/WebViewerTypes.swift:31` has only `point/anchor/openedAt`, and
`WebViewerView_iOS.swift:982` is `noteComposer = WebNoteComposerState(point:
point, anchor: anchor, openedAt: Date())` with no reply hand-off. **Land the
prerequisite first**, in this same change, unless the packet 5 already did it.

#### (a) `Vellum/Views/Web/WebViewerTypes.swift` — add the field

```swift
struct WebNoteComposerState {
    var point: CGPoint
    var anchor: WebNoteAnchor
    var openedAt: Date
    /// Text the composer opens pre-filled with — an AI reply routed here by the
    /// panel's "Add as note". Empty for a plain note-tool placement.
    var initialContent: String = ""
}
```

Defaulted, so every existing construction site still compiles.

#### (b) `Vellum/Stores/AppStore.swift` — add `restorePendingNote`

Insert directly after `consumePendingNoteContent()` (currently iPad line 528-533).
Main's version writes `pendingNoteContent` and `regionCaptureTarget` into a
**tab record** for the inactive-tab case. **`PdfTab` on iPad has neither field**
(`Vellum/Models/Models.swift:166-182` — no `pendingNoteContent`, no
`regionCaptureTarget`, no `find*`; those all arrive with the panes/tab-residency
packet). So port the active-tab branch now and leave a marked seam:

```swift
    /// Put an unplaced note draft back on the queue and re-arm placement, so
    /// the next tap on the page offers the same text again.
    ///
    /// Issue #92: the web viewer's placement tap only opens a composer — the
    /// note is not written until the user submits — so between those two steps
    /// the composer holds the *only* copy of a queued AI reply
    /// (`consumePendingNoteContent` already cleared the store). A stray tap, a
    /// page scroll, a misdirected link, or a tab switch all unmount that
    /// composer, and the reply used to go with it. The PDF viewer has no such
    /// window: it writes the note on the placement tap itself. Handing the
    /// draft back here closes the gap — a mis-tap now costs one more tap
    /// instead of the whole reply.
    ///
    /// Empty (or whitespace-only) drafts are dropped — a plain note-tool
    /// placement the user tapped away from has nothing worth preserving, and
    /// re-arming note mode for it would be friction with no payoff.
    ///
    /// PARITY GAP (deliberate): macOS also restores onto a *background* tab, by
    /// writing `pendingNoteContent`/`regionCaptureTarget` into that tab's
    /// record. `PdfTab` here carries neither field yet — they arrive with the
    /// tab-residency port. Until then a restore aimed at a tab that is no
    /// longer on screen is dropped rather than mis-filed onto the tab that is.
    /// When `PdfTab.pendingNoteContent` lands, replace the `return` below with
    /// main's `updateTab(sessionId) { $0.mode = .note; $0.pendingNoteContent =
    /// content; $0.regionCaptureTarget = nil }`.
    func restorePendingNote(_ content: String, forSessionId sessionId: String) {
        guard !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        // While the tab is the one on screen this is exactly "arm placement
        // again", so it goes through the same door rather than restating it —
        // anything `setMode(.note)` grows later applies to restores too.
        guard activeTabId == sessionId else { return }
        beginNoteWithContent(content)
    }
```

Do **not** add `finishNotePlacement(forSessionId:)` — that is main's #83
tab-management API and the iPad's equivalent is the plain `app.setMode(.view)`
already in the `"note-placed"` branch, under `handleMessage`'s existing
`guard app.activeTabId == mountTabId` (iOS line 937).

#### (c) `Vellum/Platform/iOS/WebViewerView_iOS.swift` — the controller

The iOS controller is `final class WebViewerController` inside this file (the
`@Observable` one starting ~line 300; `noteComposer` at line 306, `mountTabId`
at line 319). Apply:

**c1. Mirror property + reseeding `didSet`** — replace line 306:

```swift
    private(set) var noteComposer: WebNoteComposerState? {
        didSet {
            // Every placement reseeds the mirror below from its own initial
            // content, so a composer can never inherit the previous one's text.
            noteComposerDraft = noteComposer?.initialContent ?? ""
        }
    }
    /// The composer's live text, mirrored out of the popover so a dismissal
    /// that isn't an explicit cancel can hand the draft back to the note queue
    /// (issue #92). Observation-ignored: nothing renders from it, and it
    /// changes on every keystroke.
    @ObservationIgnored private var noteComposerDraft = ""
```

**c2. Three new methods**, placed next to `closeNoteComposer()` (line 668):

```swift
    /// Record the composer's edits as they happen. Only the mirror moves, so a
    /// keystroke costs no view invalidation. A write arriving after the
    /// composer is gone needs no guard: nothing reads the mirror without a
    /// composer, and the next one reseeds it in `didSet`.
    func updateNoteComposerDraft(_ text: String) {
        noteComposerDraft = text
    }

    /// Swap in a new composer, rescuing whatever the outgoing one held.
    ///
    /// A second "Add as note" can be pressed while a composer is still open —
    /// the panel's button is not gated on one — and the placement tap that
    /// follows would otherwise overwrite the first reply with the second. This
    /// is the one dismissal path that cannot simply call
    /// `returnNoteComposerDraft` first: the incoming reply has already been
    /// consumed off the queue by the caller, so re-queueing the old draft
    /// before that read would hand the caller back the WRONG text.
    ///
    /// So the order here is load-bearing in both directions: read the stranded
    /// draft before the assignment (whose `didSet` blanks the mirror), and
    /// re-queue it after `setMode(.view)`, which would otherwise drop it again.
    private func presentNoteComposer(
        _ state: WebNoteComposerState, app: AppStore, sessionId: String
    ) {
        let stranded = noteComposer != nil ? noteComposerDraft : nil
        noteComposer = state
        app.setMode(.view)
        if let stranded { app.restorePendingNote(stranded, forSessionId: sessionId) }
    }

    /// Dismissal the user did not ask for: a stray tap on the page, a scroll
    /// that invalidates the anchor, or another popover taking over. The draft
    /// goes back on the note queue and placement re-arms, so one more tap
    /// re-offers the same text instead of it being lost (issue #92).
    private func returnNoteComposerDraft() {
        guard noteComposer != nil else { return }
        // Load-bearing order: `noteComposer`'s didSet blanks the mirror, so
        // reading the draft after the nil would hand back an empty string and
        // silently reinstate the bug.
        let draft = noteComposerDraft
        noteComposer = nil
        guard let app, let sessionId = mountTabId else { return }
        app.restorePendingNote(draft, forSessionId: sessionId)
    }
```

`closeNoteComposer()` (line 668) stays `{ noteComposer = nil }` — explicit
Cancel/Escape/submit **must** discard. Add main's doc comment above it.

**c3. Convert every incidental dismissal** — `noteComposer = nil` →
`returnNoteComposerDraft()`, at these exact iOS sites:

| iOS line | branch | why it counts as incidental |
|---|---|---|
| 672-673 | `closeNotePopovers()` | link tap, SPA soft-navigation, rebind (called at lines 1146 and 1191) — "clicking a link on a dense article is at least as likely a mis-tap as tapping whitespace" |
| 972 | `"selection-cleared"` + `clickOutside` | **the literal repro in issue #92's title** — a stray tap on the page |
| 990 | `"context-menu"` | another popover taking over |
| 1006 | `"annotation-click"` → note branch | ditto |
| 1011 | `"annotation-click"` → highlight branch | ditto |
| 1075 | `viewport-scrolled` + 0.4 s grace | a scroll that invalidates the anchor |

Leave line 493 (`clearTransientStateForRebind()`) as a bare `noteComposer = nil`:
it runs when the whole viewer is being re-pointed at a different document, and
there is no session left to restore onto.

**c4. `"note-placed"` branch** (iOS lines 976-984). Replace:

```swift
        case "note-placed":
            guard let anchor = parseNoteAnchor(data) else { break }
            let point = frameToParent(
                x: doubleValue(data["x"]) ?? 0, y: doubleValue(data["y"]) ?? 0,
                visualScale: payloadVisualScale(data))
            hideContextMenu()
            noteViewer = nil
            noteComposer = WebNoteComposerState(point: point, anchor: anchor, openedAt: Date())
            // Mirror the PDF viewer: placing a note returns to view mode.
            app.setMode(.view)
```

with:

```swift
        case "note-placed":
            guard let anchor = parseNoteAnchor(data) else { break }
            guard let sessionId = mountTabId else { break }
            let point = frameToParent(
                x: doubleValue(data["x"]) ?? 0, y: doubleValue(data["y"]) ?? 0,
                visualScale: payloadVisualScale(data))
            hideContextMenu()
            noteViewer = nil
            // Hand the queued AI reply to the composer (PR #69 parity) instead
            // of silently throwing it away. `presentNoteComposer` also rescues
            // whatever an already-open composer was holding, and mirrors the
            // PDF viewer by returning to view mode.
            let pendingContent = app.consumePendingNoteContent()
            presentNoteComposer(
                WebNoteComposerState(
                    point: point, anchor: anchor, openedAt: Date(),
                    initialContent: pendingContent ?? ""),
                app: app,
                sessionId: sessionId)
```

`handleMessage` already guards `app.activeTabId == mountTabId` at line 937, so
`consumePendingNoteContent()` cannot steal another tab's reply here.

**c5. `contextMenuAddNote()`** (iOS lines 659-666). Replace wholesale:

```swift
    func contextMenuAddNote() {
        guard let menu = contextMenu else { return }
        // Unconditionally, and before the anchor check: the menu is going away
        // either way, and leaving an anchorless one on screen strands it.
        hideContextMenu()
        guard let anchor = menu.anchor else { return }
        // Same payload hand-off as the note-mode placement tap: a queued AI
        // reply pre-fills this composer rather than being left stranded.
        //
        // Gated on the active tab for the same reason the `"note-placed"`
        // branch is: `consumePendingNoteContent` reads the *active* tab's
        // queue, so a menu still mounted on a tab the user has left would
        // otherwise steal the reply armed for the tab now on screen. This is a
        // button action rather than a bridge message, so it does not inherit
        // `handleMessage`'s identical guard.
        //
        // No composer at all on the failing branch, rather than an empty one:
        // `annotationStore` is pane-scoped, so a mount left on a background tab
        // now points at whatever document the pane moved on to, and submitting
        // there would file the note against the wrong document.
        guard let app, let sessionId = mountTabId, app.activeTabId == sessionId else { return }
        let pendingContent = app.consumePendingNoteContent()
        presentNoteComposer(
            WebNoteComposerState(
                point: menu.point, anchor: anchor, openedAt: Date(),
                initialContent: pendingContent ?? ""),
            app: app,
            sessionId: sessionId)
    }
```

**c6. `#if DEBUG` test seams.** Port main's four seams onto the iOS controller
verbatim in shape (`bindForTesting(app:tabId:annotationStore:)`,
`openNoteComposerForTesting(content:openedAt:)`,
`openContextMenuForTesting(anchored:)`,
`handleBridgeMessageForTesting(_:_:)`, plus the `private static let testAnchor`).
Two iPad adaptations:
- `openContextMenuForTesting` — main's comment says it skips "the event monitor
  `showContextMenu` installs"; the iOS controller assigns `contextMenu` directly
  with no monitor, so just say so.
- Keep main's warning verbatim: `post` is not gated on the content script having
  reported in, so it materialises the lazy `WKWebView`; the dismissal branches
  reach it only via `clearSelection()`, which they call only when a selection
  exists, and these seams never create one.

#### (d) `Vellum/Platform/iOS/WebViewerView_iOS.swift` — the view (line 98)

```swift
                            WebNoteComposerView(
                                initialContent: composer.initialContent,
                                onSubmit: { content in
                                    controller.createAnchoredNote(anchor: composer.anchor, content: content)
                                    controller.closeNoteComposer()
                                },
                                onClose: { controller.closeNoteComposer() },
                                onDraftChange: { controller.updateNoteComposerDraft($0) })
                        }
                        // The composer seeds its editable text from
                        // `initialContent` once, at init. Keying on the
                        // placement timestamp gives each placement a fresh
                        // identity, so placing a second note without closing the
                        // first can't reuse the previous text.
                        .id(composer.openedAt)
                        .zIndex(50)
```

The `.id(composer.openedAt)` goes on the `AnchoredPopover`, not on
`WebNoteComposerView` — same position as main's.

---

### 2.5 Math splitter: inline-code immunity — [MERGE] `MathRenderer.swift`

Main commit `157cb5eb` (PR #127, closes #99).

**Divergence check (done):** the iPad's `MathRenderer.swift` is cross-platform
(`PlatformImage`/`PlatformColor`, UIKit rendering branch, `resolvedColor`/
`colorKey` helpers) — but `inlineMathRegex` (line 145), `backslashRun` (line
150) and `segments(in:)` (line 162) are **character-for-character identical** to
main's pre-#127 versions. The change therefore applies as a clean textual merge.

Three callers exist on iPad, all of which the fix covers at once, which is
exactly why main fixed it here rather than in `InlineMarkdown.pieces`:
`SelectableMessageText.swift:317`, `MarkdownMessage.swift:122`, and
`MarkdownParser.plainPreview` (`MarkdownMessage.swift:184`).

**Edit 1 — insert `codeSpanRanges(in:)`** immediately after `backslashRun`
(i.e. between iPad lines 156 and 158, before the `segments` doc comment). Copy
main's function and its full doc comment verbatim:

```swift
    /// Ranges of CommonMark inline code spans, backticks included.
    ///
    /// CommonMark's rule: a run of N backticks opens a span that closes on the
    /// next run of *exactly* N. A run with no matching closer is literal text,
    /// so scanning resumes just past it rather than swallowing the rest of the
    /// line — that is what keeps a stray backtick from hiding real math behind
    /// it.
    ///
    /// Reported as ranges rather than extracted substrings because the callers
    /// need the code spans left in place: `InlineMarkdown` hands the whole line
    /// to Foundation afterwards and wants the backticks still there to style,
    /// and `plainPreview` strips them itself. All this has to do is tell the
    /// math scanner which regions to keep its hands off.
    nonisolated static func codeSpanRanges(in source: String) -> [NSRange] {
        let backtick = UInt16(UnicodeScalar("`").value)
        let ns = source as NSString
        var ranges: [NSRange] = []
        var index = 0
        while index < ns.length {
            guard ns.character(at: index) == backtick else { index += 1; continue }
            var openLength = 0
            while index + openLength < ns.length,
                  ns.character(at: index + openLength) == backtick { openLength += 1 }
            var search = index + openLength
            var closer = -1
            while search < ns.length {
                guard ns.character(at: search) == backtick else { search += 1; continue }
                var closeLength = 0
                while search + closeLength < ns.length,
                      ns.character(at: search + closeLength) == backtick { closeLength += 1 }
                if closeLength == openLength { closer = search; break }
                search += closeLength
            }
            guard closer >= 0 else { index += openLength; continue }
            ranges.append(NSRange(location: index, length: closer + openLength - index))
            index = closer + openLength
        }
        return ranges
    }
```

Note it is `nonisolated static` (not `private`): the tests call it directly.
`MathRenderer` is `@MainActor`, so dropping `nonisolated` would break both
`segments` and the tests.

**Edit 2 — `segments(in:)`.** Replace the doc comment with main's (it explains
the two repros and why the fix lives here), then:

- after `let ns = source as NSString`, add:
  ```swift
        // Only pay for the code-span scan when a backtick is actually present.
        let codeSpans = source.contains("`") ? codeSpanRanges(in: source) : []
  ```
- as the **first statement inside the `for match in …` loop**, add:
  ```swift
            // A match that touches a code span at either end is not math: it
            // either lives inside one or straddles two, which is how the `$1`/
            // `$2` backref case swallowed the text between them.
            if codeSpans.contains(where: { NSIntersectionRange($0, match.range).length > 0 }) {
                continue
            }
  ```
- give the `\(…\)` alternative the backslash-parity check it never had — add
  an `else` to the existing `if isDollar { … }`:
  ```swift
            } else {
                // The `\(…\)` branch had no escape handling at all, so a literal
                // backslash before the delimiter ("\\(not math\\)") opened a
                // span. Both delimiters are two characters, so the backslash to
                // test is the first of the pair and the second-to-last overall.
                let opener = match.range.location
                let closer = match.range.location + match.range.length - 2
                if backslashRun(before: opener, in: ns) % 2 == 1
                    || backslashRun(before: closer, in: ns) % 2 == 1 {
                    continue
                }
            }
  ```
  and move the "Skip when the opening or closing delimiter is escaped…" comment
  up above the `if isDollar` so it covers both branches, exactly as main did.

Nothing else in the file changes. The UIKit rendering branch, `PlatformColor`
helpers and cache-key code are untouched.

**Known residual, copied from main deliberately:** `MarkdownParser.plainPreview`
unwraps `$$…$$` with its own regex *before* `segments` runs, so a `$$` inside a
code span still loses its delimiters in the one-line sidebar preview. Out of
scope; no text is eaten and nothing is reordered.

---

### 2.6 "Save for Offline Use" / "Remove Offline Copy" semantics — [MERGE] `WebSessionBackend.swift`

**Edit order (packet 10 §2.3): 1 → 6 → 7.** Packets 1, 6 and 7 all MERGE this file; packet 7
goes last. (Packet 10 §2.3 also flags this file as "already dirty in the iPad worktree" — that
caveat is **stale**; the in-flight work landed in commit `783c8835`. Nothing to stash.)

**Already correct on iPad, do not re-port:**
- `WebDocumentIO.setSaved(_:)` (iPad line 458) already does
  `record.saved = saved; record.savedAt = …` and, on `false`,
  `WebLibrary.removeLocalSnapshots(forKey: key)`. That is the "Remove deletes
  **only artifacts**" contract: the sidecar record — highlights, notes, reading
  position — always survives.
- `WebLibrary.hasLocalSnapshot(forKey:)` exists (iPad `WebLibrary.swift:366`).
- `PdfChrome_iOS.toggleSavedPage()` already re-archives on Save (covering a copy
  the user deleted from Settings ▸ Storage), serializes Save/Remove through
  `saveToggleTask` and guards with `saveToggleGeneration`. Leave it alone.

**The one missing hunk.** `WebDocumentSession.isSaved()` — iPad line 210 is
`await io.isSaved()`; main HEAD is:

```swift
    func isSaved() async throws -> Bool {
        // The toolbar's promise is "Keep Offline", not merely that the page
        // has a Saved-library record. Settings can remove snapshots while
        // retaining that record, so expose offline availability only when a
        // real local/managed snapshot remains.
        let saved = await io.isSaved()
        return saved && WebLibrary.hasLocalSnapshot(forKey: key)
    }
```

Apply exactly that. Effect on iPad: after a Settings ▸ Storage snapshot sweep,
the More menu flips back to "Save for Offline Use" instead of lying with
"Remove Offline Copy", and re-tapping Save re-archives.

**Do NOT take**, from the same file's delta (other packets own them):
`docId: key` in the `DocumentInfo` init, `ensureDocumentId()`,
`Annotation.sortedForDisplay` in `annotations(pageNumber:)`, and
`if let isPinned = input.isPinned { … }` in `updateAnnotation`.

**Must survive untouched** (iPad-only, verified present):
- `createAnnotation`'s `let createdAt = input.createdAt ?? now` and
  `createdAt: createdAt, updatedAt: createdAt` — the optimistic-create echo.
- `updateAnnotation`'s `if let pageNumber = input.pageNumber { … }` — a web
  highlight resized across a virtual-page boundary keeps its new page. (main
  regressed this; the iPad comment says so.)
- Both `Task.detached` preludes in `openWebDocument` / `openVellumwebFile`,
  including the `normalize`/`pageKey`/`recordPath` computation living *inside*
  the task — see 2.8.

---

### 2.7 Add-webpage crash fix (#116) — [SKIP as code] + one iPad follow-up

**What main fixed.** `AddWebpageSheet` reads `@Environment(AppStore.self)`. In
`ContentView.body` the `.sheet` was chained **after** `.environment(focused.app)`.
SwiftUI composes modifiers outside-in, so the presentation node sat *above* the
environment writes, resolved no `AppStore`, and SwiftUI trapped the instant the
sheet appeared. Fix: move `.sheet` so it is applied to `WindowChrome` **before**
the `.environment` writes. Plus an `addWebpage.urlField` accessibility
identifier and an XCUITest.

**Why the iPad is already immune — verified, not assumed.**
`Vellum/Platform/iOS/ContentView_iOS.swift`'s sheet presents
`AddWebpageSheet_iOS` (line 164), which takes `var onSubmit: (String) -> Void`
and reads only `@Environment(\.dismiss)` and `@Environment(\.palette)`. It never
looks up `AppStore`; the parent closure captures
`workspace.focusedPane.app` at submit time (line 58). `WorkspaceStore` and
`ThemeStore` are injected at the scene root, above `ContentView_iOS`, so they
resolve regardless of modifier order. The crash class does not exist here.

**Do this anyway** (cheap, and it is what makes the sheet a durable automation
target for the `device-interaction` skill):

In `ContentView_iOS.swift`, on the `TextField("https://example.com", text: $url)`
inside `AddWebpageSheet_iOS`, add:

```swift
                    .accessibilityIdentifier("addWebpage.urlField")
```

And add a short comment above the `.sheet(isPresented: $addWebpagePresented)`
recording the invariant so nobody reintroduces the hazard:

```swift
        // `AddWebpageSheet_iOS` takes its destination as a closure and reads no
        // store from the environment — deliberately. macOS's equivalent read
        // `@Environment(AppStore.self)` and trapped when this `.sheet` was
        // chained after the `.environment` writes (modifiers compose
        // outside-in, so the presentation sat above them — main PR #116). Keep
        // the closure form, or move this `.sheet` above the `.environment`
        // block before adding any store lookup inside the sheet.
```

Main's `#115` companion hunk in `ContentView.swift` — `.toolbar { ToolbarSpacer(.flexible) }`
on the inspector, to force macOS 26 to draw a tracking separator — has **no iPad
analogue**: the iPad toolbar is a plain SwiftUI `HStack` inside
`PaneView_iOS.content`, not `ToolbarContent` in an `NSToolbar`. Nothing to do.

---

### 2.8 Document open/close off the main thread (#113) — [MERGE] `PdfSessionBackend.swift`

**Edit order (packet 10 §2.3): 1 → 6 → 7.** Packets 1, 6 and 7 all MERGE this file; packet 7
goes last. The **close** half of #113 is not here — it is packet 4 §2.14 (see §5 D4).

**Read the iPad's current version before touching it.** Commit `783c8835`
("Commit in-flight launch-latency fixes…", already on the branch) did this work
independently, **more thoroughly than main did**, and its result must not be
reverted by a naive port.

| | main HEAD (#113) | iPad `783c8835` |
|---|---|---|
| what moves off `@MainActor` | `canonicalize` + `fileExists` only, via `Task.detached(priority: .userInitiated)` | `canonicalize` + `fileExists` + `PdfDocumentLoader.loadRaw` + `PdfMetadata.documentInfo`, via `offMainRead` |
| the parse | already off-main inside `PdfDocumentIO.open()` (an actor main introduced) | inside the same `offMainRead` closure |
| `PdfDocumentIO` | main swapped `PdfSessionBackend` onto a new `PdfDocumentIO` actor | **iPad keeps `PdfFileGate`** — standing decision |

**Verdict: take nothing from main's `PdfSessionBackend` hunk.** The iPad's
version is a strict superset of the behaviour, expressed through the seam the
project has decided to keep. Concretely:

1. Do **not** introduce `PdfDocumentIO` / the actor swap. Standing decision:
   `PdfFileGate` stays; port `PdfDocumentIO`'s *new behaviours* into it (that is
   the packet 1's job, not this one).
2. Do **not** replace `offMainRead` with `Task.detached` to "match main".
   `offMainRead` is the helper `annotations()` / `readPdfBytes()` already use.
3. Do **not** hoist `PdfDocumentLoader.loadRaw` / `PdfMetadata.documentInfo`
   back onto the main actor. The iPad doc comment on `open` spells out why
   (`async` alone moves nothing off the main actor on a `@MainActor` type) and
   spells out the Sendable analysis (`path` in, `(String, DocumentInfo)` out; the
   non-Sendable `CGPDFDocument` never escapes the closure). Keep that comment.
4. Same for `WebSessionBackend`: the iPad's `Task.detached` blocks in
   `openWebDocument` and `openVellumwebFile` already contain the
   `normalize`/`pageKey`/`recordPath` prelude, which main still runs on the main
   actor. `WebLibrary.recordPath` walks `activeLayout → effectiveMode →
   customRoot → resolveBookmark`, which hits UserDefaults, `FileManager` probes
   and `startAccessingSecurityScopedResource`. Moving it back to the caller (to
   "have `normalized` in scope for the return") would put disk work back in the
   launch critical path. The tuple-return shape is there for exactly that
   reason.

**Action required:** verify the four points above are still true after every
other packet lands, and add a one-line pointer in `PdfSessionBackend.open`'s doc
comment naming main PR #113 so a future reader sees the two histories converge:

```swift
    /// (Main's PR #113 made the same move on macOS but stopped at
    /// canonicalize+stat, leaving the parse to its `PdfDocumentIO` actor. This
    /// branch keeps `PdfFileGate` and hops the whole read, so there is nothing
    /// left to take from that PR here.)
```

The **close** half of #113 (`closeTab` removing the tab before awaiting the
last-page write, `TabTeardownRegistry` on `WorkspaceStore`,
`awaitTeardowns(ofDocumentAt:)`, the 20 s `isLoading` watchdog) lives entirely
in `AppStore`/`WorkspaceStore`/`VellumApp` and belongs to the panes/lifecycle
packet — see §5, dependency D4.

---

### 2.9 `FindBar.swift` — [MERGE], gated on packet 4 — **the last link of the C3 chain**

**Edit order (packet 10 §3.1).** `packet 4 §2.0 (interface-only contract) → packet 7 viewers →
packet 4 §2.8 (residency) → THIS SECTION`. Packet 4 also holds the `[MERGE]` claim on
`FindBar.swift`; land packet 4's hunk first, then this one on top.

Main's change moves the query out of the view's `@State` and onto the store, so
switching tabs no longer silently dismisses the query and its highlights:

```swift
-    @State private var query = ""
…
-            TextField("Find", text: $query)
+            TextField("Find", text: Binding(
+                get: { app.findQuery },
+                set: { app.performFind($0) }
+            ))
…
-                .onChange(of: query) { _, value in app.performFind(value) }
…
-            if !query.isEmpty { app.performFind(query) }
+            if !app.findQuery.isEmpty { app.performFind(app.findQuery) }
…
-        if query.isEmpty { return "" }
+        if app.findQuery.isEmpty { return "" }
```

`FindBar.swift` is cross-platform on iPad and live (`PaneView_iOS.swift:129`).
The change is mechanical **but** requires `AppStore.findQuery` — a
`private(set) var` backed by `PdfTab.findQuery`, both introduced by main's
tab-residency PR #74. The iPad `AppStore` has only `findQueryHandler` (line 104)
and no `findQuery` (line 449 calls the handler without storing).

**Instruction:** apply the FindBar edit **only after** the panes/tab-residency
packet has added `AppStore.findQuery` + `PdfTab.findQuery` + the
`applyActiveState` restore. If that packet has not landed when you reach this
one, leave `FindBar.swift` untouched and record it as deferred — a partial port
(adding `findQuery` to `AppStore` without the per-tab persistence) buys nothing
and creates a merge conflict for that packet.

---

### 2.10 Liquid Glass document toolbar (#115) — [REBUILD], **do not port the code**

Main commit `7742a895` rewrote `Vellum/Views/PDF/ToolbarView.swift` (+502/-95)
around AppKit/NSToolbar realities that do not exist on iOS: `NSViewRepresentable`
page fields, `NSEvent` hover tracking, `ToolbarItem
.sharedBackgroundVisibility(.hidden)`, `ToolbarSpacer` placement quirks. **None
of it is ported.** What transfers is the *design language*, into the toolbar the
iPad already has: `PdfToolbar_iOS` + `GlassToolPod` + `GlassToolButton` in
`Vellum/Platform/iOS/PdfChrome_iOS.swift`.

#### What main's design language actually is (from the diff + its five commit messages)

1. **One glass capsule per semantic cluster, never per button.** Leading
   `[< >] [page / N] [− 100% +]`; trailing `[bookmark note] [sidebar more]`. The
   whole "pill soup" of individual glass circles is the thing being killed.
2. **The system's shared toolbar background is switched off** —
   `.sharedBackgroundVisibility(.hidden)` on the containing `ToolbarItem` —
   "without this the system wraps the whole HStack in one more capsule and the
   three custom pods read as one blob again."
3. **Monochrome glyphs via `.tint(.primary)`.** Borderless buttons otherwise
   tint their labels with the accent colour, "which made the zoom cluster read
   as selected/links next to the monochrome system pods."
4. **Hit area = the whole slot, not the glyph.** `frame` + `contentShape`
   applied **inside the label closure** — borderless buttons hit-test only the
   glyph otherwise (measured: 6.5 pt-wide chevron targets).
5. **One shared interaction backdrop for all nine buttons:** a `Capsule`, fixed
   32×26 for icon buttons and label-width for text buttons, filled with
   **concrete `Color.primary`** at 0.12 (hover) / 0.22 (active note tool).
   Concrete, *not* the hierarchical `.primary` shape style — the hierarchical one
   resolves against the label's `foregroundStyle` and rendered the bookmark's
   pill at ~40 % strength through its gold tint.
6. **The active state is a Button with a stronger persistent fill, not a
   `Toggle`** — "the toggle's system chrome brings back the squished hover/press
   shape this pass removes, and its selected state cannot be drawn through the
   shared backdrop."
7. **Accessibility container per capsule**, applied **outside** `.glassEffect()`:
   `.accessibilityElement(children: .contain)` + `.accessibilityLabel(…)`.
   Applied inside the glass the labels never surface and the group silently
   inherits its first child's description ("Previous page" announced for every
   control). Labels used: `"Page navigation"`, `"Zoom controls"`,
   `"Annotation tools"`, `"Panel and document actions"`.
8. **Redundant AX elements are hidden.** The `/ N` `Text` is
   `.accessibilityHidden(true)`; the page field owns
   `"Page number, of \(totalPages) pages"`.
9. **Geometry rhythm:** 35 pt capsule height, 2 pt inter-button spacing, 6 pt
   horizontal capsule padding, 8 pt inter-capsule spacing (renders as the ~10.5 pt
   gap the system leaves between its own pods).
10. **The overflow Menu is drawn manually** because a menu control paints its own
    system hover *beneath* any attached background: glyph + pill are `ZStack`
    siblings and the `Menu` itself sits at `.opacity(0.02)` as a transparent hit
    target (not 0 — fully transparent views stop hit-testing).

#### What the iPad toolbar already has (verified in `PdfChrome_iOS.swift`)

- `GlassToolPod` (line 454): `HStack(spacing: 2)`, `.padding(.horizontal, 4)`,
  `.frame(height: 48)`, `.glassEffect(.regular, in: .capsule)` — **item 1 already
  satisfied**, and with the right per-cluster granularity.
- `GlassToolButton` (line 465): 44×44 frame, `.contentShape(Circle())`,
  `.buttonStyle(.plain)`, `.accessibilityLabel`, `.accessibilityAddTraits(active
  ? [.isButton, .isSelected] : .isButton)`, active fill
  `Circle().fill(palette.primary.opacity(0.16))` — **items 4 and 6 already
  satisfied**; item 3 satisfied differently (explicit `foregroundStyle`, no
  `.tint` needed under `.buttonStyle(.plain)`).
- The host `HStack` in `PdfToolbar_iOS.body` carries **no** background or glass
  of its own (verified: `PaneView_iOS.content` wraps it in a bare
  `VStack(spacing: 0)`) — **item 2's invariant already holds**, expressed
  natively.
- Progressive disclosure the macOS toolbar has no equivalent for and which
  **must survive**: `showZoomPod` (≥740 pt), `showPageChevrons` (≥590 pt),
  `showActionsPod` (≥500 pt), with the hidden controls reappearing inside
  `moreMenu`.
- iPad-only controls that **must survive**: Find, the Apple Pencil ink toggle,
  Split Right / Split Down / Merge Panes / Close Pane, Settings…, Export a
  Copy… (Files export picker), the leading "Close tab" pod.

#### The five concrete gaps to close

**G1 — pressed state (replaces main's hover).** iPadOS has no hover; the touch
equivalent of item 5 is a *pressed* backdrop. `GlassToolButton` currently gives
no touch feedback at all beyond `.buttonStyle(.plain)`'s default.

Add a backdrop view and a button style next to the existing primitives:

```swift
/// The shared interaction backdrop for every toolbar button — the touch
/// analogue of the macOS toolbar's hover pill (main PR #115). One shape
/// everywhere: a Capsule inset inside the 44pt slot so it reads as sitting
/// *within* the pod's glass capsule rather than filling it edge to edge.
///
/// `Color.primary` is deliberate and concrete, NOT the hierarchical `.primary`
/// shape style: the hierarchical one resolves against the button label's
/// `foregroundStyle`, which on macOS rendered the bookmark's pill at ~40%
/// strength through its gold tint. The bookmark button here has the same gold
/// `tint`, so the same trap applies.
private struct ToolbarPressBackdrop: View {
    let visible: Bool
    var strength: Double = 0.10
    var body: some View {
        Capsule()
            .fill(Color.primary.opacity(visible ? strength : 0))
            .frame(width: 40, height: 36)
    }
}

/// Reports `isPressed` so the shared backdrop can render it. `.plain` alone
/// gives no touch feedback, and `.borderless`/`.bordered` bring back system
/// chrome that fights the pod's glass.
private struct ToolbarPressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background { ToolbarPressBackdrop(visible: configuration.isPressed) }
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}
```

Then in `GlassToolButton`: keep the active fill as-is but change its shape from
`Circle` to `Capsule` for consistency with the pressed pill, and swap the style:

```swift
                .background {
                    if active {
                        // Active keeps `palette.primary` (the app accent): this
                        // one is the iPad's selected-state convention and is
                        // NOT resolved through the label's foregroundStyle, so
                        // the gold-bookmark dilution that forced macOS onto
                        // Color.primary does not apply here.
                        Capsule().fill(palette.primary.opacity(0.16))
                            .frame(width: 40, height: 36)
                    }
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(ToolbarPressStyle())
```

Note the `contentShape` change from `Circle()` to `Rectangle()` — a circular hit
shape inside a 44×44 slot loses the corners, i.e. ~21 % of the nominal target.
Item 4's rule is "the whole slot".

Apply `ToolbarPressStyle()` to the two bare `Button`s in `PdfToolbar_iOS` too:
the zoom-reset `100%` button (line ~101) and `pageField` (line ~200). For those,
main's rule is label-width, so give `ToolbarPressBackdrop` a `width: CGFloat? = 40`
and pass `nil` there so the pill tracks the label (three-digit zoom, four-digit
page counts).

**G2 — accessibility containers per pod (item 7).** `GlassToolPod` currently
exposes no container label, so VoiceOver reads the pod's first child's label as
the group description — the exact failure main measured. Add a label parameter
and apply the container **outside** `.glassEffect()`:

```swift
struct GlassToolPod<Content: View>: View {
    /// VoiceOver name for the whole capsule. Applied OUTSIDE `.glassEffect()`:
    /// the glass wraps its content in one more accessibility group, and labels
    /// applied inside it never surface — the group then inherits its first
    /// child's description ("Previous page" on every cluster, as measured on
    /// macOS in PR #115).
    var label: String
    @ViewBuilder var content: () -> Content
    var body: some View {
        HStack(spacing: 2) { content() }
            .padding(.horizontal, 4)
            .frame(height: 48)
            .glassEffect(.regular, in: .capsule)
            .accessibilityElement(children: .contain)
            .accessibilityLabel(label)
    }
}
```

Then label every call site in `PdfToolbar_iOS.body`, using main's vocabulary
where a cluster corresponds:

| pod | label |
|---|---|
| close-tab (leading, iPad-only) | `"Tab"` |
| web back/forward | `"Page history"` |
| page steppers + field | `"Page navigation"` |
| zoom | `"Zoom controls"` |
| find / note / ink / bookmark | `"Annotation tools"` |
| sidebar toggle + more | `"Panel and document actions"` |

`GlassToolPod` is also used outside this file — grep before changing the
signature and either give `label` a default or fix every call site.

**G3 — the `/ N` sub-label (item 8).** `pageField`'s label already reads
`"Page \(currentPage) of \(numPages). Tap to jump."`, and because the two `Text`s
sit inside a single `Button` label they merge into one element — so no
`.accessibilityHidden` is needed. **Verify with the `device-interaction` skill's
UI-hierarchy dump** that the digits are not announced twice, and add a comment
recording why the macOS `.accessibilityHidden(true)` has no counterpart here.

**G4 — the overflow Menu (item 10).** UIKit menus do **not** paint a system
hover under an attached background, so main's `Color.clear` + `.opacity(0.02)`
`ZStack` trick is unnecessary and would only make the glyph 2 % opaque if copied
blindly. **Do not copy it.** Leave `moreMenu`'s `Menu { … } label: { Image… }`
as it is, and add a comment saying so, otherwise the next reader comparing
against main will "fix" it. If touch feedback on the menu is wanted, wrap the
`Image` in `.contentShape(Rectangle())` (already there) and accept the system's
own menu-open highlight.

**G5 — deliberate deviations to document in code.** Two places where the iPad
must *not* follow main, each needing a comment so the divergence reads as a
decision:

- **Touch-target sizes.** Main uses 32×35 hit frames, a 32×26 pill and 35 pt
  capsules. The iPad keeps 44×44 buttons, a 40×36 pill and 48 pt pods. 44 pt is
  the HIG minimum and this packet's hard requirement; do not shrink anything to
  match main's pixel measurements.
- **Page-stepper / page-counter pod split.** Main's #115 review explicitly broke
  `[< >]` and `[1 / N]` into two capsules. The iPad keeps them in **one** pod
  (`[< 1/N >]`). Reason: at 44 pt targets a second capsule costs ~16 pt of
  padding + gap in a toolbar that already sheds the zoom pod at 740 pt and the
  chevrons at 590 pt; and the iPad's page indicator is a *tap target that opens a
  jump alert*, not an inline editable field, so it belongs with the steppers it
  duplicates. Record this next to `showPageChevrons`.

**Explicitly not ported:** `PageNumberField` (`NSViewRepresentable` +
`SelectAllTextField` + `NSTextFieldDelegate` — the iPad uses an
`.alert` with a `.numberPad` `TextField`), `CapsuleIconButton`,
`ToolbarHoverBackdrop`, `PdfLeadingControls`, `PageStepButtons`,
`PageIndicator`, `WebHistoryButtons`, `.sharedBackgroundVisibility`,
`ToolbarSpacer`, every `.help(…)` tooltip (no tooltips on iPadOS), and every
`.onHover`.

**Verification.** Per `CLAUDE.md`, drive this with the `device-interaction`
skill (or `codex-computer-use`), not by eye: screenshot the toolbar in light and
dark, at full width and with the inspector open in a split pane (to exercise all
three disclosure tiers), and dump the accessibility hierarchy to confirm six
labelled containers with correctly-named leaves and no "Previous page"
inheritance.

---

## 3. project.yml / Info-iOS.plist / entitlements

**No changes required by this packet.**

- `Vellum/Services/Ai/PageTextExtractionGate.swift` and
  `Tests/PageTextExtractionGateTests.swift` are picked up automatically —
  `project.yml` declares `sources: - path: Vellum` (with only
  `Resources/Info*.plist` and `Resources/katex` excluded) for the app target and
  `sources: - path: Tests` for `VellumTests`. Adding files under those trees
  needs no manifest edit; just re-run `xcodegen generate`.
- New test file `Tests/WebNoteDraftTests.swift` (§4.3): same, no manifest edit.
- Nothing here adds a capability, URL scheme, document type, background mode or
  usage description, so **`Vellum/Resources/Info-iOS.plist` is untouched** and
  `Vellum/Vellum-iOS.entitlements` stays unwired (project.yml's comment: the
  free/Personal team can't provision iCloud; re-add `CODE_SIGN_ENTITLEMENTS`
  only on a paid account).
- For completeness, main's `project.yml`/`Info.plist` delta in this range is
  entirely out of scope: the `VellumUITests` macOS XCUITest target + `UITesting`
  build config (macOS-only test target; the iPad has none), the `Apple Development`
  signing switch (the iPad target already sets `CODE_SIGN_STYLE: Automatic` +
  `DEVELOPMENT_TEAM: 9DCG97VASG`), `SWIFT_TREAT_WARNINGS_AS_ERRORS` (warnings
  packet), `Tests/Integrations/Fixtures` as a resource folder (integrations
  packet), and the `CFBundleDocumentTypes`/`UTExportedTypeDeclarations` entries
  for `.vellum`/`.vellumweb` (packet 2 — and those belong in
  `Info-iOS.plist`, not `Info.plist`).

**One flag for whoever owns the packet 9:** if
`SWIFT_TREAT_WARNINGS_AS_ERRORS: "YES"` is ever adopted for the iPad target, the
`offMain:` overload in §2.1 and the walk's `copy` capture in §2.2(c) are the
first two sites that will need `sending`/`@Sendable` attention, because
`PDFDocument` is not `Sendable`.

---

## 4. Tests to port

> **Ownership rule (packet 10 §2.1).** **Packet 9 is the only packet that writes into `Tests/`;
> every other packet's test claim is a specification, not an edit.** Everything in this section
> is the adaptation list packet 9 applies — do not create or modify these files yourself.
> Packet 9's `[VERBATIM]` on `WebProxyUrlTests`, `WebLibraryStorageTests` and
> `MarkdownParserTests` is downgraded to `[MERGE — content per packet 7 §4.N]`.

The iPad `Tests/` target is **XCTest** (`import XCTest` / `@testable import Vellum`),
same as main. No Swift Testing migration.

### 4.1 `Tests/PageTextExtractionGateTests.swift` — [VERBATIM] + 2 additions

Copy main's file byte-for-byte. It is `@MainActor final class …: XCTestCase`,
uses only Foundation + the gate, builds its own `PageTextExtractionGate()` per
test (never `.shared`), and needs no iOS adaptation. The eight cases:

1. `testOnDemandJumpsAheadOfQueuedBackgroundWork`
2. `testBackgroundWaitersStayInQueueOrder`
3. `testCancelledWaiterReleasesTheQueue`
4. `testAlreadyCancelledCallerSkipsExtraction`
5. `testEmptyPageResultPacesTheNextExtraction`
6. `testSlowExtractionAlsoPacesTheNextOne`
7. `testTextLayerPagesAreNotPaced`
8. `testSkippedReadDoesNotPaceTheNextExtraction`

Keep the `Recorder` helper class and the `spin(for:)` busy-wait — the comment
explains it must busy-wait, because case 6's signal is how long the
*synchronous* body took and `Task.sleep` would not reproduce it.

**Timing sensitivity on device/simulator:** cases 5-7 assert wall-clock
thresholds (`≥ 10 ms`, `< 200 ms` for 40 pages). They pass on macOS; on a cold
simulator the 200 ms budget in case 7 is the one most likely to flake. If it
does, raise **only** that bound and leave a comment saying why — do not weaken
the `≥ 10 ms` pacing assertions, which are the actual contract.

**Add two iPad-only cases** covering the `offMain:` overload from §2.1, since
nothing in main's suite exercises it:

```swift
    // (9) iPad: the off-main-body overload holds the same single slot, so a
    // detached walk and a main-actor locator can never both be reading.
    func testOffMainBodiesShareTheSameSlotAsSynchronousOnes() async {
        let gate = PageTextExtractionGate()
        await primeCooldown(on: gate)
        let recorder = Recorder()

        let holder = Task {
            await gate.extractText(priority: .background, offMain: {
                await MainActor.run { recorder.log("holder") }
            })
        }
        await Task.yield()
        let queued = Task { await gate.extractText(priority: .onDemand) { recorder.log("onDemand") } }

        _ = await holder.value
        _ = await queued.value
        XCTAssertEqual(recorder.entries, ["holder", "onDemand"])
        XCTAssertEqual(gate.queueDepth, 0)
    }

    // (10) …and the pacing contract is identical across the two overloads: an
    // empty result from an off-main body still paces the next caller.
    func testOffMainEmptyResultPacesTheNextExtraction() async {
        let gate = PageTextExtractionGate()
        _ = await gate.extractText(priority: .background, offMain: { "" })
        let started = ContinuousClock.now
        _ = await gate.extractText(priority: .onDemand) { "page text" }
        XCTAssertGreaterThanOrEqual(ContinuousClock.now - started, .milliseconds(10))
    }
```

### 4.2 `Tests/MarkdownParserTests.swift` — [MERGE], 11 cases

⚠ **Ordering.** Packet 9's `[VERBATIM]` on this file is downgraded to
`[MERGE — content per packet 5 §I.2 + packet 7 §4.2]` (packet 10 §2.1). The file **cannot
compile** until packet 5 §I.2 lands `MarkdownMessage.swift`'s new list model
(`case list([MarkdownListItem])` replacing `unordered`/`ordered`) — main's `testLists`
constructs `MarkdownListItem(depth:marker:text:)`. The 11 cases below are additive on top of
that; hand them to packet 9, do not write the file yourself.

Append main's `// MARK: - Segments: code spans vs the math splitter (#99)`
section immediately before the existing `// MARK: - Segments: MathRenderer.segments(in:)`
mark. All eleven are pure-string assertions against `MathRenderer.segments` /
`MathRenderer.codeSpanRanges`, with **no platform dependency** — copy verbatim:

```
testSegmentsCodeSpanWithBackrefsIsNotMath
testSegmentsCodeSpanWithPosixGroupIsNotMath
testSegmentsLoneCodeSpanWithDollarStaysText
testSegmentsCodeSpanWithDisplayMathDelimitersStaysText
testSegmentsMathOutsideACodeSpanStillTypesets
testSegmentsUnmatchedBacktickDoesNotSwallowLaterMath
testSegmentsDoubleBacktickSpanIsProtected
testSegmentsEscapedParenOpenerIsLiteral
testSegmentsEscapedParenCloserIsLiteral
testSegmentsCodeSpanOffsetsSurviveAstralCharacters
testSegmentsMismatchedBacktickRunsDoNotHideMath
```

One thing to check when copying: the iPad's `MarkdownParserTests` class must be
`@MainActor` (or the tests must not be) for `MathRenderer.codeSpanRanges` /
`.segments` — both are `nonisolated static`, so either works; match whatever the
existing file already does.

### 4.3 `Tests/AiAddAsNoteTests.swift` → NEW `Tests/WebNoteDraftTests.swift`

> **Three-way conflict, resolved (packet 10 §2.1).** Packet 5 tagged this file MERGE, packet 7
> REBUILD, packet 9 VERBATIM. **Resolution: packet 9 creates `Tests/AiAddAsNoteTests.swift`
> with packet 5's content; packet 7's 14 web-dismissal cases go to their own new file,
> `Tests/WebNoteDraftTests.swift`** — which is not in `delta-files.txt`, so it needs no claim.
> Nobody ports the file twice. Packet 7 supplies the spec below; packet 9 writes the file.

Main's file is 473 lines and mostly the AI panel's "Add as note" path (packet 5's). The
**web-dismissal half** is mine, and it lands in the new file:

Store-level (5), against the `restorePendingNote` from §2.4(b):
```
testStrayDismissalReturnsTheReplyAndTheNextPlacementUsesIt
testEmptyDraftDoesNotReArmNoteMode
testRestoringForAnUnknownTabIsIgnored
```
- **Drop** `testDraftIsRestoredOntoItsOwnTabNotTheOneOnScreen` and
  `testRestoringClearsAnyArmedRegionCapture`: both assert the background-tab
  branch, which the iPad's `restorePendingNote` deliberately does not have yet
  (`PdfTab` has no `pendingNoteContent`/`regionCaptureTarget`). Add an
  `XCTExpectFailure`-free `// TODO(#129 packet 4)` comment naming them so
  they come back with the tab-residency port.

Controller-level (8), against the `#if DEBUG` seams from §2.4(c6):
```
testIncidentalTeardownHandsTheReplyBack
testExplicitCloseDiscardsTheDraft
testEditsMadeInTheComposerAreWhatComesBack
testDismissingAnEmptyComposerArmsNothing
testTheDraftMirrorDoesNotLeakBetweenPlacements
testContextMenuAddNoteCarriesTheQueuedReply
testContextMenuAddNoteOnABackgroundTabCannotStealTheForegroundReply
testTeardownOnABackgroundTabDoesNotArmTheForegroundOne
```

Bridge-message-level (7), driven through `handleBridgeMessageForTesting`:
```
testAStrayClickOnThePageHandsTheReplyBack            ← the literal repro in #92's title
testThePlacementClicksOwnEventDoesNotDismissTheComposer   ← the 0.4 s grace period
testScrollingThePageHandsTheReplyBack
testAFreshComposerSurvivesTheScrollThePlacementClickCauses
testRightClickingThePageHandsTheReplyBack            ← rename to …LongPressingThePage… (iPad gesture)
testClickingAnExistingNoteHandsTheReplyBack
testClickingAnExistingHighlightHandsTheReplyBack
testASecondPlacementRescuesTheComposerItReplaces
```

iOS adaptations required:
- The controller under test is `WebViewerController` **from
  `Vellum/Platform/iOS/WebViewerView_iOS.swift`**, not the macOS one. Both are
  named `WebViewerController`; only one compiles per platform, so
  `@testable import Vellum` resolves correctly — but say so in the file header,
  because a reader diffing against main will assume otherwise.
- The `"note-placed"`/`"selection-cleared"`/`"viewport-scrolled"` payloads on iOS
  carry an extra `visualScale` (`payloadVisualScale(data)`); omit it and the
  helpers default sanely, but check `frameToParent`'s behaviour with it missing
  before asserting on `composer.point`.
- Rename `click`→`tap` in test *names and comments* where the gesture is a touch
  one; keep the bridge message **type strings** (`"selection-cleared"`,
  `"context-menu"`, …) byte-identical — they are the content script's wire
  protocol.

**Mutation-check the port.** Main's commit message is explicit that its first
two cuts were green with the entire viewer-side fix reverted. After writing
these, revert each of the six `returnNoteComposerDraft()` call sites from §2.4(c3)
one at a time back to `noteComposer = nil` and confirm exactly one test fails
each time. A port that does not do this reproduces main's original mistake.

### 4.4 `Tests/WebLibraryStorageTests.swift` — [MERGE], one case

Append **only** `testKeepOfflineStatusRequiresAnActualSnapshot` (main lines
113-130). The iPad file already has the `makeRecord(url:saved:openedMonthsAgo:)`
(line 38) and `makeArtifacts(forKey:fill:)` (line 58) helpers it needs, is
already `@MainActor`, and already points `WebLibrary.storeDirOverride` at a
scratch dir in `setUp`. Copy verbatim:

```swift
    func testKeepOfflineStatusRequiresAnActualSnapshot() async throws {
        let url = "https://example.com/offline-status"
        let key = try makeRecord(url: url, saved: true, openedMonthsAgo: 1)
        let session = WebDocumentSession(
            url: url,
            record: try XCTUnwrap(WebLibrary.loadRecord(at: WebLibrary.recordPath(forKey: key))))

        let initiallyOffline = try await session.isSaved()
        XCTAssertFalse(initiallyOffline, "a Saved record without bytes is not offline")

        try makeArtifacts(forKey: key)
        let archivedOffline = try await session.isSaved()
        XCTAssertTrue(archivedOffline, "a Saved record with snapshot bytes is offline")

        try await session.setSaved(false)
        let removedOffline = try await session.isSaved()
        XCTAssertFalse(removedOffline, "removing the copy clears both membership and artifacts")
    }
```

**Do not** take `testPinAnnotationPersistsAndSortsFirst` from the same hunk — it
needs `Annotation.sortedForDisplay` + `UpdateAnnotationInput.isPinned`, both the
packet 6's, and it constructs `UpdateAnnotationInput` with a member
list the iPad does not have.

### 4.5 `Tests/WebProxyUrlTests.swift` — [MERGE], one line

Add `@MainActor` above `final class WebProxyUrlTests: XCTestCase`. Trivially
safe; it came from main's warnings-free pass (`62b7f33c`) and is included here
only so the file is not left orphaned.

---

## 5. Risks & cross-packet dependencies

### Dependencies (things that must land first, or the port degrades)

**D1 — §2.4 needs the packet 5's web "Add as note" prerequisite, or ships it itself.**
`WebNoteComposerState.initialContent` and `consumePendingNoteContent()` in the
`"note-placed"` branch come from main PR #69, which the iPad never received.
§2.3 and §2.4(a)(c4) include them. **Coordinate with the packet 5** — if it also
ports #69, one of the two must yield or `WebViewerTypes.swift` will conflict.
Cheap check before starting: `grep -n initialContent Vellum/Views/Web/WebViewerTypes.swift`.

**D2 — §2.4's background-tab restore needs packet 4. Mitigated by packet 4 §2.0.**
Cycle C3 (packet 10 §3.1) — this packet and packet 4 each declared themselves blocked by the
other with no stub on either side. **Broken by packet 4 landing its interface-only contract
commit (§2.0) first**: the `isActiveMount` flag, the `makeUIView` retained-view protocol and
the `documentAttached()` callback ship as signatures with no-op implementations before this
packet starts. Chain: **packet 4 §2.0 → packet 7 viewers → packet 4 §2.8 (residency) →
packet 7 §2.9 (`FindBar`)**. Do not reorder.

`PdfTab` (`Vellum/Models/Models.swift:166`) has no `pendingNoteContent` or
`regionCaptureTarget`. Until main's #74 lands, `restorePendingNote` handles only
the active tab and two of main's five store-level tests are deferred (§4.3).
This is a *degradation*, not a break: on iPad a background-tab restore currently
drops the draft rather than mis-filing it.

**D3 — §2.9 (`FindBar`) is the LAST link of the C3 chain.** Needs `AppStore.findQuery` +
`PdfTab.findQuery`, so it lands after packet 4 §2.8 (residency), which lands after this
packet's viewers, which land after packet 4 §2.0. Do not partially port.

**D4 — the close half of #113 is not in this packet; it is packet 4 §2.14.** `closeTab`'s
remove-then-teardown reordering, `TabTeardownRegistry` on `WorkspaceStore`,
`awaitTeardowns(ofDocumentAt:)` and the 20 s `isLoading` watchdog live in
`AppStore`/`WorkspaceStore`/`VellumApp`. Packet 10 §3.2 found nobody owned these hunks (every
packet claimed the *files* and disclaimed the *hunks*); the orchestrator **assigned them to
packet 4 as a named sub-scope, §2.14**.
**Tell that packet's owner** that §2.8 has already decided the *open* half: the
iPad's `offMainRead` version stays, `PdfDocumentIO` is not adopted, `PdfFileGate`
stays.

**D5 — the packet 1 owns `PdfFileGate`.** §2.8's "don't adopt
`PdfDocumentIO`" decision is that packet's premise; if it ever reverses, §2.8's
comment must be revisited.

### Risks

**R1 (highest) — the gate can undo the iPad's off-main walk.** The single most
likely way to break this packet is to route
`PdfViewerController_iOS.startTextExtraction(data:)` through main's *synchronous*
`extractText(priority:_:)`. That compiles, passes the unit tests, and silently
drags `page.string` back onto the main actor — reintroducing the multi-minute
run-loop starvation on textbook PDFs that the iPad fixed with the private
`PDFDocument(data:)` copy. **Mitigation:** the `offMain:` label is mandatory at
that call site; after implementing, open a 400-page scanned PDF on device and
confirm the toolbar and scroll stay responsive throughout the walk (Instruments
App Launch / Time Profiler, or just scroll while it indexes).

**R2 — the gate serializes two panes' walks.** With a split view, both panes'
walks now queue on one slot instead of running truly concurrently. That is the
intended fix (it is precisely the crash scenario #121 names), but it roughly
doubles wall-clock time to index two documents side by side. Acceptable; note it
if anyone reports "indexing got slower in split view."

**R3 — `ensureExtracted` is a no-op on iPad, so one of main's four producers has
no iPad counterpart.** `AiStore.ensureExtractedHandler` is never installed
(`grep -rn ensureExtractedHandler Vellum/Platform` → nothing). The AI tool paths
(`getPageText`, `searchDocument`) and the per-turn context fill therefore read
only what the background walk has already produced. Closing that gap is the AI
packet's call; **if it does, the handler it installs MUST go through
`PageTextExtractionGate.shared` at `.onDemand`**, or the whole packet is
defeated. Leave a comment at `AiStore.swift:222` saying so.

**R4 — the `#127` regex change silently affects the sidebar preview and quoting.**
`MarkdownParser.plainPreview` (`MarkdownMessage.swift:184`) calls `segments`
directly, so the fix reaches annotation pills, quoted text and accessibility
strings — not just chat bubbles. That is the intended blast radius (it is why
main fixed it in `MathRenderer`), but it means a regression here shows up in
three surfaces. The 11 ported tests cover the splitter; spot-check one annotation
pill containing a backtick-wrapped `$` on device.

**R5 — `.id(composer.openedAt)` and the 0.4 s grace period interact.** §2.4(d)
gives each placement a fresh view identity keyed on `openedAt`, while
§2.4(c3)'s `clickOutside` / `viewport-scrolled` branches compare against the same
`openedAt`. If anyone "tidies" `openedAt` to a monotonic counter or reuses a
composer state, both the seeding and the self-dismissal guard break at once.

**R6 — the toolbar rebuild is a visual change with no automated coverage.** The
iPad has no XCUITest target, so §2.10 is verifiable only by driving the running
app. Do not merge it on code review alone; per `CLAUDE.md`, use the
`device-interaction` skill or `codex-computer-use` (never a Fable model for
computer-use) and capture before/after screenshots in all three width tiers,
light and dark, plus an accessibility-hierarchy dump.

**R7 — iPad-only features that this packet's files touch and must not regress.**
Re-verify after implementing: Apple Pencil ink toggle + palette + zoom-crisp
strokes and scribble-to-erase (the ink button lives in the same pod §2.10
restyles); Pencil double-tap; the iPad keyboard-shortcut router
(`ShortcutRouter_iOS`, which drives Find/note/zoom through the same `AppStore`
methods the toolbar calls); Safari-style zoom; touch selection reporting; the
ink-write coalescing and web-observer throttling battery fixes (§2.4 touches the
same `handleMessage` switch as the throttled observers); the drag watchdog; and
`CreateAnnotationInput.createdAt` (§2.6 explicitly preserves its use in
`WebDocumentIO.createAnnotation`).

**R8 — persistence byte-compatibility.** Nothing in this packet changes a
persisted format, and it must stay that way: no new keys in the web sidecar JSON
(snake_case), no change to `/Vellum*` PDF metadata keys, no change to the
`.vellum`/`.vellumweb` zip layouts, no new `UserDefaults` keys.
`restorePendingNote` writes only live, in-memory state — main's `PdfTab
.pendingNoteContent` comment is explicit that it "deliberately remains live
only: relaunching restores the note tool, never a stale AI reply." Keep that
property when D2 lands.
