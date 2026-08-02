# Packet 4 — Tabs, panes & inspector (parity phase 4 + part of 5, issues #133 / #134)

Delta range (SOURCE): `a42705d1~1..7742a895` in `/Users/ayushdeolasee/Developer/Vellum/main`.
TARGET: `/Users/ayushdeolasee/Developer/Vellum/ipad-app` (branch `ipad-app`, iOS-only, xcodegen).

Upstream PRs covered here: **#74** (live tabs + residency policy), **#83** (tab overview /
tab management), **#108** (pane merge transfers tab ownership), **#71 + #119** (window-scoped
command routing + sheet-gated command suppression), **#72** (inspector state across Home
transitions), **#73 + #112 + #120** (responsive inspector tab switcher), **#122** (resizable
inspector width envelope).

Read this whole file before touching code. Section 2 is ordered — do not reorder it, several
steps do not compile until the one before them lands.

---

## 1. Delta files claimed

Every path below is relative to the repo root of each worktree.

### Source (`Vellum/`)

| Delta path | Tag | One-line reason |
|---|---|---|
| `Vellum/Models/LiveTabRuntime.swift` | **[REBUILD]** | New file. Same shape, but it owns the **iOS** controller types (`PdfViewerControlleriOS`, `WebViewerController_iOS`) and an `InkController_iOS`, none of which exist on macOS. |
| `Vellum/Services/TabResidency.swift` | **[REBUILD]** | New file, ~90 % adopted verbatim. Rebuilt parts: the `DispatchSource` memory-pressure source → `UIApplication.didReceiveMemoryWarningNotification`, and every ceiling retuned down for iPad jetsam limits. |
| `Vellum/Stores/WorkspaceStore.swift` | **[MERGE]** | Shared, heavily diverged (iPad drag watchdog + `#if os(iOS)` blocks). I own the residency / `allTabs` / inspector / `mergeAll` / `closePane` / `pruneAbandonedEmptyPanes` hunks only — see §2.5 for the exact hunk list and who owns the rest. |
| `Vellum/Stores/AppStore.swift` | **[MERGE]** | Shared. I own the prepared-PDF-LRU removal, per-tab find/note/region state, `closeTab` runtime release, `closeOtherTabs` / `closeTabsToRight` / `duplicateTab`, `restoreTabs` rewrite, `applyActiveState`/`applyEmptyActiveState` pinning, `tab(id:)`/`containsTab(id:)`. **Edit order 1 → 4 → 2** (packet 10 §2.3 — 58 KB diff in main, three MERGE owners); packet 7's single `restorePendingNote` addition is a surgical insert after those. |
| `Vellum/Models/Models.swift` | **[MERGE]** | Shared. I own **only** the top-level `RegionCaptureTarget` enum and the new `PdfTab` fields (`pendingNoteContent`, `regionCaptureTarget`, `findVisible`, `findQuery`, `findMatchCount`, `findCurrentMatch`). `Annotation.isPinned` → packet 6; `DocumentInfo.docId`/`bookmarkData`, `RecentDocument.docId` → packet 1. **Edit order 1 → 4 → 6** (packet 10 §2.3); packet 1 preserves `CreateAnnotationInput.createdAt`. |
| `Vellum/Models/PaneTree.swift` | **[MERGE]** | Small: `PaneModel.init` gains `teardowns:` and wires `scratchpad.app = app`. `teardowns` is now **in scope** — see §2.14, the document-actions sub-scope. **Edit order 4 → 6** (packet 6 adds pin-related hunks). |
| `Vellum/Views/PDF/TabBarView.swift` | **[MERGE]** | On iPad this whole file is inside `#if os(macOS)` (dead reference). Copy main's new body into the gate, **but lift `enum TabPresentation` OUTSIDE the gate** — the iPad tab strip and tab overview consume it. |
| `Vellum/Views/Shared/InspectorTabSwitcher.swift` | **[REBUILD]** | New file. `InspectorLayout` + the `SidebarTab` extension adopt near-verbatim; the view itself is re-derived for iOS (no `.buttonStyle(.plain)` AppKit hit-test quirk, no `.menuStyle(.borderlessButton)`, 44 pt touch targets, iPad width envelope). |
| `Vellum/Views/Shared/Controls.swift` | **[MERGE]** | Only hunk in my scope: the deletion of `GlassSegmentedPicker`. Delete it **last**, after both iPad call sites (`PdfChrome_iOS.SidebarContent_iOS`, the macOS-gated `App/ContentView.swift`) stop using it. |
| `Vellum/Views/Shared/FindBar.swift` | **[MERGE]** | Drops its local `@State query` for `app.findQuery`. iPad's copy differs only by an `#if os(macOS)` around `.onExitCommand`; keep that. **Edit order 4 → 7** (packet 7 §2.9 lands last in the C3 chain — see §2.0). |
| `Vellum/App/SheetPresenceMonitor.swift` | **[SKIP — dropped]** | **Decision (packet 10 §3.3):** the macOS monitor is dropped outright, along with `Tests/SheetPresenceTests.swift`. iOS has no attached sheets and therefore no menu-bar-disabling contract to preserve. **The replacement is packet 4's own iOS-native sheet-presence gate** — `SheetPresence_iOS` (a UIKit `presentedViewController` probe) consulted by the iPad shortcut router, with `.dismiss` handled by dismissing `topPresented` rather than suppressed. Packet 4 owns that gate and its new iOS test. See §2.13. |
| `Vellum/App/ContentView.swift` | **[REBUILD → `Platform/iOS/ContentView_iOS.swift`]** | Normalised per packet 10 §2.2 (packets 2, 4 and 7 gave the same treatment three different tags). macOS-gated dead reference: take main's copy wholesale into the gate; the live iOS work lands in `ContentView_iOS.swift` (§2.11). **Sequence packet 4 → packet 2.** |
| `Vellum/App/VellumCommands.swift` | **[MERGE]** | Same: macOS-gated reference; adopt wholesale. The behaviour (⌥⌘1/2/3 panel reveal, named tab-shortcut modifiers) is rebuilt in the iPad shortcut catalog (§2.13). |
| `Vellum/App/VellumApp.swift` | **[REBUILD → `Platform/iOS/VellumApp_iOS.swift`]** | Normalised per packet 10 §2.2 — packets 1 (SKIP), 2 (REBUILD), 3 (MERGE) and 4 (MERGE) all route hunks into the same iOS counterpart. **Packet 4 is the named sequencer** (it touches the file most): packets 2 and 3 rebase their hunks onto packet 4's. macOS-gated reference; adopt the quit-path hunk wholesale. The iOS analogue lands in `VellumApp_iOS.swift` (§2.9). |
| `Vellum/Views/Panes/PaneView.swift` | **[REBUILD → `Platform/iOS/PaneView_iOS.swift`]** | Normalised per packet 10 §2.2. **Packet 4 owns the file**; packets 1 and 2 each add one observer on top. macOS-gated reference: adopt wholesale (incl. `LiveTabHost`). The live iOS work is `LiveTabHost_iOS` in `PaneView_iOS.swift` (§2.8). |

### Tests (`Tests/`)

| Delta path | Tag | Reason |
|---|---|---|
| `Tests/TabResidencyTests.swift` | **[MERGE]** | Adopt ~verbatim; retune the three literal constants to the iPad numbers and add coverage for `noteMemoryWarning()` escalation. |
| `Tests/PaneTreeTests.swift` | **[MERGE]** | iPad already has a diverged copy (11 tests). Add the 25 new tests from #74/#83/#108. |
| `Tests/InspectorPresentationTests.swift` | **[MERGE]** | New on main. Needs the `.scratchDefaults` trait (packet 1) or a local equivalent. |
| `Tests/InspectorTabSwitcherTests.swift` | **[MERGE]** | New on main. Retune the `maximumWidth` literal; drop the two macOS-only assertions (`headerHeight` drop-routing, `VellumCommands.tabShortcutModifiers`) → replace with the iPad catalog equivalents. |
| `Tests/SheetPresenceTests.swift` | **[SKIP — dropped]** | **Decision (packet 10 §3.3):** dropped along with `SheetPresenceMonitor.swift`; every assertion is about AppKit (`NSWindow.attachedSheet`, `willBeginSheet`/`didEndSheet`) and iOS has no attached-sheet contract. Replaced by a **new iOS test** specified in §4.5, covering `SheetPresence_iOS` and the router's `.dismiss` handling. Packet 4 owns that specification; packet 9 writes the file. |

### Explicit SKIPs inside my subject area

- `Vellum.xcodeproj/project.pbxproj` — **[SKIP: iPad project is generated by xcodegen from `project.yml`.]**
- `project.yml` — **[SKIP: main's diff is UITest target + macOS signing + Integrations fixtures; none of it is mine. See §3 — this packet needs no project.yml change.]**
- `UITests/VellumConsistencyUITests.swift` (inspector-resize UI test), `UITests/VellumUITestCase.swift`, `Vellum.xcodeproj/xcshareddata/xcschemes/VellumUITests.xcscheme` — **[SKIP: macOS XCUITest target; the iPad project has no UITest target.]**
- `Vellum/App/UITestLaunchConfiguration.swift`, `Tests/UITestLaunchConfigurationTests.swift` — **[SKIP: packet 9 owns both.]** No conflict (packet 10 §2.1).
- `Tests/SidebarDropRoutingTests.swift`, `Vellum/Views/Shared/SidebarDropCatcher.swift` — **[SKIP: AppKit drop catcher; iPad keeps its iOS-native drop rebuild (standing decision). But see §5 risk R7 — the switcher's `headerHeight` constant exists for that catcher and is dead weight on iPad.]**
- `Vellum/Views/PDF/PdfViewerView.swift`, `PdfKitView.swift`, `PdfSelectionBridge.swift`, `Vellum/Views/Web/WebViewerView.swift` — **[SKIP: owned by packet 7.]** #74 changes them heavily; §2.8/§5-D1 spell out the exact contract packet 7 must satisfy for my `LiveTabRuntime` to work.

---

## 2. Port order & instructions

### 2.0 Interface-only contract commit — **do this FIRST, before packet 7 starts** (breaks cycle C3)

**Why this exists.** Packet 10 §3.1 found a hard deadlock between this packet and packet 7,
unmitigated on both sides: this packet's D1 says `LiveTabRuntime` holds
`PdfViewerControlleriOS` / the retained `PDFView` and that "**§2.8 cannot**" land without the
viewer packet; packet 7's D2/D3 say background-tab restore needs tab residency and that
`FindBar` is "**fully blocked** on packet 4". Two of the three largest packets each declare
themselves blocked by the other, with no stub on either side.

**The fix: cut the contract out first.** Land the "Cross-packet contract for packet 7"
described at the end of §2.8 as a **standalone, interface-only commit owned by packet 4, with
no-op implementations**. It ships types and signatures only — nothing behavioural — so it
compiles green on its own and lets both packets proceed in parallel afterwards.

**What lands in this commit:**

1. **The `isActiveMount` flag.** Add the `isActive` / `isActiveMount` parameter to the viewer
   entry points (`PdfViewerView_iOS`, `WebViewerView_iOS`) with the
   `(tabId:document:isActive:runtime:)` shape. In this commit the flag is accepted and
   ignored — every `onChange`-driven push still runs as it does today.
2. **The `makeUIView` retained-view protocol.** Declare the protocol/signature by which
   `PdfKitView_iOS.makeUIView` returns the runtime's retained `PDFView` and calls
   `view.removeFromSuperview()` before handing it to a new host (`mergeAll` can transiently
   mount two hosts for one tab; a `UIView` has one superview). In this commit the
   implementation still returns a freshly-made `PDFView` — the shape is what matters.
3. **The `documentAttached()` callback.** Declare it on the viewer-controller side and call
   it from nowhere yet; a no-op default implementation.

Plus the no-op stubs the above imply on `LiveTabRuntime`: `runtime.pdfController`,
`runtime.webController`, `runtime.ink`, `runtime.preparedDocument`,
`runtime.adoptPreparedPdf(_:byteCount:)`, `runtime.documentGeneration`, `runtime.pageTexts`.

**Landing order this unlocks** (packet 10 §4, stages C→F):
`§2.0 (this commit)` → **packet 7 fills the viewers** → **packet 4 §2.8** (residency /
`LiveTabHost_iOS`) → **packet 7 §2.9** (`FindBar`). Do not reorder these four; each one
compiles only after the one before it.

**Commit boundary.** One commit, interface-only, no behaviour change, full test suite green
before and after. If a reviewer can point at a behavioural diff in it, it is too big.

Packet 7 carries the mirror of this note in its §5 dependency list.

### 2.1 `Vellum/Models/Models.swift` — [MERGE]

**What main changed (my hunks only):**

1. Added a top-level enum, moved out of `AppStore`:
   ```swift
   /// Which side panel receives a pending drag-to-crop capture. This is kept on
   /// the live tab rather than the pane-wide active state so changing tabs cannot
   /// silently lose, or misroute, an armed capture.
   enum RegionCaptureTarget: Sendable, Equatable {
       case ai
       case scratchpad
   }
   ```
2. `PdfTab` gained six live-only fields after `mode`:
   ```swift
   var pendingNoteContent: String? = nil
   var regionCaptureTarget: RegionCaptureTarget? = nil
   var findVisible: Bool = false
   var findQuery: String = ""
   var findMatchCount: Int = 0
   var findCurrentMatch: Int = 0
   ```

**iPad today:** `Vellum/Models/Models.swift:166` `PdfTab` ends at `var mode: InteractionMode`.
`RegionCaptureTarget` is still nested in `AppStore` (`Vellum/Stores/AppStore.swift:85`:
`enum RegionCaptureTarget { case ai, scratchpad }`).

**Instructions:**
- Add both hunks exactly as above. All six fields have defaults, so every existing
  `PdfTab(...)` call site keeps compiling.
- Delete the nested `enum RegionCaptureTarget` from `AppStore` in the same commit (step 2.6)
  and grep for `AppStore.RegionCaptureTarget` — iPad call sites in
  `Platform/iOS/AiPanel_iOS.swift`, `Platform/iOS/ScratchpadPanel_iOS.swift`,
  `Platform/iOS/RegionCaptureOverlay_iOS.swift` and `Platform/iOS/PdfViewerView_iOS.swift`
  may spell it either way.
- **PERSISTENCE: nothing here is Codable.** `PdfTab` is not persisted; `TabDescriptor` is.
  Do NOT add any of these to `TabDescriptor` — main deliberately keeps them live-only
  ("relaunching restores the note tool, never a stale AI reply").
- Do **not** take the `Annotation.isPinned` / `sortedForDisplay`, `DocumentInfo.docId` /
  `bookmarkData` or `RecentDocument.docId` hunks — other packets own them and they carry
  byte-compat obligations (`is_pinned`, `doc_id`, `bookmark_data` snake_case keys).

### 2.2 `Vellum/Models/PaneTree.swift` — [MERGE]

**What main changed:** `PaneModel.init` gained `teardowns: TabTeardownRegistry = TabTeardownRegistry()`,
passes it to `AppStore(sessions:teardowns:)`, and now wires the scratchpad's back-ref:
```swift
let scratchpad = ScratchpadStore()
scratchpad.app = app
```

**iPad today:** identical file minus both changes (`Vellum/Models/PaneTree.swift:26-47`).

**Instructions:**
- Take the `scratchpad.app = app` hunk now — it is independent and harmless.
- `TabTeardownRegistry` comes from PR #113 (document actions / open-close threading). **This is
  now in scope** — packet 10 §3.2 found the "document-actions packet (#82/#113)" was never cut
  and every owner disclaimed its hunks, so the orchestrator **assigned it to packet 4 as a named
  sub-scope (§2.14)**. Take the `teardowns:` parameter here, and `WorkspaceStore.tabTeardowns`
  in §2.5, per §2.14. Land §2.14 before or with this hunk; do not leave the earlier
  `// TODO(parity #129): teardowns registry` deferral in place.

### 2.3 `Vellum/Services/TabResidency.swift` — [REBUILD] (adopt ~90 % verbatim)

Copy `/Users/ayushdeolasee/Developer/Vellum/main/Vellum/Services/TabResidency.swift` to
`/Users/ayushdeolasee/Developer/Vellum/ipad-app/Vellum/Services/TabResidency.swift`, **keeping
every doc comment** (they are the design record for the tier boundaries), then make exactly
these changes:

**(a) Imports.** `import Dispatch` is no longer needed once the pressure source goes; replace with:
```swift
import Foundation
import UIKit
```

**(b) Retune the ceilings DOWN (the whole point of the iPad variant).** Keep `hotWindow`
(10 min) and `retentionWindow` (30 min) — those are the repo owner's explicit request and are
time, not memory. Change only the counts and budgets, and replace their doc comments so the
next reader knows they were retuned deliberately:

| Constant | macOS | **iPad** | Why |
|---|---|---|---|
| `hotTabLimit` | 5 | **3** | Every hot tab keeps a live `PDFView`/`WKWebView` in the window's layout+display cycle. iPad has one window and (at most) two visible panes; 3 = the two pinned panes plus one recent. |
| `residentTabLimit` | 8 | **4** | iPadOS jetsams on a per-app footprint limit far below what macOS tolerates; 4 covers "a paper plus its references". |
| `residentByteBudget` | 768 MB | **256 MB** | A flat-96 MB web tab plus a large scanned PDF still fits; a shelf of them does not. |
| `pressureTabLimit` | 2 | **1** | Under an iOS memory warning only the tab on screen is worth keeping. |
| `pressureByteBudget` | 128 MB | **48 MB** | ditto. |
| `sweepInterval` / `sweepTolerance` | 60 s / 30 s | **unchanged** | The sweeper only runs while something is resident and is suspended with the app; the battery-drain work in the iPad tree is about per-frame writes, not a 1-minute coalesced timer. |

Add above them:
```swift
// RETUNED FOR iPad (parity #129). The windows below are the repo owner's request
// on PR #67 and are unchanged; the COUNT and BYTE ceilings are not — iPadOS
// enforces a hard per-app footprint and jetsams rather than swapping, so the
// macOS numbers (8 tabs / 768 MB) are a crash, not a guardrail, here.
```

**(c) Replace the memory-pressure source.** Delete `installMemoryPressureSource()`, the
`pressureSource` property, and the `pressureSource?.cancel()` in `deinit`. Replace with:

```swift
    /// A second warning inside this window means the first eviction did not buy
    /// enough headroom, so the next one drops everything off screen.
    static let pressureEscalationWindow: Duration = .seconds(60)

    private var memoryWarningObserver: NSObjectProtocol?
    private var lastMemoryWarning: Duration?

    /// iOS has one memory signal, `UIApplication.didReceiveMemoryWarningNotification`,
    /// and no severity on it — unlike Dispatch's memory-pressure source, which
    /// macOS raises at `.warning` routinely and `.critical` rarely.
    ///
    /// Treating every warning as `.critical` would delete the warm tier on a
    /// device that raises one warning an hour; treating every warning as
    /// `.warning` ignores that on iPadOS the next step after a warning is
    /// jetsam, not swap. So: the first warning applies the tight ceilings, and a
    /// second one inside `pressureEscalationWindow` escalates to `.critical`.
    /// Driven off the injected clock, so a test can prove both branches without
    /// waiting a minute.
    @discardableResult
    func noteMemoryWarning() -> [String] {
        let now = clock.now
        let escalate = lastMemoryWarning.map { now - $0 < Self.pressureEscalationWindow } ?? false
        lastMemoryWarning = now
        return handleMemoryPressure(escalate ? .critical : .warning)
    }

    private func installMemoryWarningObserver() {
        memoryWarningObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.didReceiveMemoryWarningNotification,
            object: nil,
            queue: nil
        ) { [weak self] _ in
            // Deliberately a hop rather than `MainActor.assumeIsolated`: the
            // notification is posted on the main thread today, but nothing in
            // the API contract guarantees the observer's queue, and an eviction
            // mutates `@Observable` state on the resources it releases.
            Task { @MainActor [weak self] in self?.noteMemoryWarning() }
        }
    }
```
- In `init`, `if automaticMaintenance { installMemoryWarningObserver() }`.
- In `deinit`, keep `sweepTask?.cancel()` and add
  `if let memoryWarningObserver { NotificationCenter.default.removeObserver(memoryWarningObserver) }`
  (`removeObserver` is nonisolated-safe, which is why it can live in `deinit`).
- **Keep `PressureLevel`, `handleMemoryPressure(_:)` and its `.warning`/`.critical` branches
  exactly as main has them.** `TabResidencyTests` drives them directly and the two-tier
  semantics are what `noteMemoryWarning()` selects between.

**(d) Everything else is verbatim**: `ResidencyClock` / `ContinuousResidencyClock`,
`TabResidencyTier`, `TabResidentResource`, `Entry`, `store`/`resource`/`isResident`,
`markActive`/`forgetOwner`/`stamp`, `release`/`releaseAll`, `sweep`/`enforceCeilings`/
`scheduleCeilingEnforcement`, `evict`, `hotTabIds`/`refreshTiers`/`residentTabsByIdleDescending`,
the introspection block, `startSweeperIfNeeded`/`stopSweeperIfIdle`.
`ContinuousClock` on iOS is `mach_continuous_time` exactly as on macOS, so the "keeps counting
while asleep" reasoning in the header comment holds unchanged — leave it in.

### 2.4 `Vellum/Models/LiveTabRuntime.swift` — [REBUILD]

Start from main's file and keep **every doc comment**, then swap the controller types and add
the iPad-only ink ownership. Target: `Vellum/Models/LiveTabRuntime.swift` (no `#if` — the
project is iOS-only, but the file references iOS-only types so guard it with `#if os(iOS)` if
you prefer symmetry with the rest of `Platform/iOS`; the rest of `Models/` is ungated, so
**leave it ungated** and let the iOS-only controller types speak for themselves).

**Type substitutions:**

| main | iPad |
|---|---|
| `var pdfController = PdfViewerController()` | `var pdfController = PdfViewerControlleriOS()` (`Platform/iOS/PdfViewerController_iOS.swift:14`) |
| `var webController = WebViewerController()` | `var webController = WebViewerController_iOS()` (`Platform/iOS/WebViewerView_iOS.swift:291`) |
| — | **new:** `var ink = InkController_iOS()` |
| `pdfController.pauseTextExtraction()` | `pdfController.flushPersister()` — iPad's controller has no `pauseTextExtraction`; it exposes `flushPersister() async` (`PdfViewerController_iOS.swift:496`) and `flushAndDropPersister()` (`:505`). Cancel the extraction task first if the iPad controller grows one. |

**iPad-only addition — ink ownership.** This is the single most important divergence in the
whole packet:

```swift
    /// The pane used to own one `InkController_iOS` (registered in
    /// `InkRegistry_iOS` by pane id). That was correct while exactly one tab per
    /// pane was ever mounted. Live tabs break it: several tabs' `PDFView`s are
    /// mounted at once and each installs `ink.inkProvider` as its
    /// `pageOverlayViewProvider`, so one controller would hand tab B's page-3
    /// canvas to tab A's page 3. Ink is per-DOCUMENT state and now lives on the
    /// runtime with everything else the tab owns.
    var ink = InkController_iOS()
```

And `releaseResidency()` must not lose strokes — the iPad coalesces ink writes (PR #78), so an
eviction can land on a debounced, unwritten drawing:

```swift
    func releaseResidency() {
        guard !isEvicted else { return }
        // Debounced ink is a real, unwritten user edit (the write coalescing
        // from PR #78 is exactly what makes it possible for one to be pending
        // here). Hold the controller alive until its flush lands, the same way
        // the web side holds itself open for a pending auto-archive.
        let pendingInk = ink
        Task { @MainActor in
            await pendingInk.flushPendingInkAndWait()
            withExtendedLifetime(pendingInk) {}
        }
        pdfController.flushAndDropPersister()
        pdfController.reset()
        webController.releaseResidency()
        pdfController = PdfViewerControlleriOS()
        webController = WebViewerController_iOS()
        ink = InkController_iOS()
        pdfLoadState = .idle
        preparedDocument = nil
        pdfByteCount = 0
        isRendered = false
        isEvicted = true
    }
```

**Keep verbatim:** `PdfLoadState`, `tabId`, `pdfLoadState`, `pageTexts`, `isEvicted`,
`isRendered` (starts `false` — a never-opened tab must not build a viewer to sit at opacity 0),
`preparedDocument` + the "why not an LRU on AppStore" comment, `pdfByteCount`,
`documentGeneration` + `invalidateLoadedPdf()`, `adoptPreparedPdf(_:byteCount:)`,
`residencyCostBytes`, `applyResidencyTier(_:)` + its measured-Observation comment,
`reactivate()`, `flushPdfText()`, and `extension LiveTabRuntime: TabResidentResource {}`.

**Contract packet 7 must satisfy** (`WebViewerController_iOS` needs, from main's
`WebViewerController`): `var residencyCostBytes: Int { didCreateWebView ? 96 * 1024 * 1024 : 0 }`,
`var isAttached: Bool`, `func deactivate()`, `func releaseResidency()`. If packet 7 has
not landed, stub them in `WebViewerController_iOS` (cost `0`/`96 MB` off a `didCreateWebView`
flag, `releaseResidency()` → existing `detach()`) so this file compiles, and leave a TODO.

### 2.5 `Vellum/Stores/WorkspaceStore.swift` — [MERGE]

**Hunks I own** (take these; leave the rest to their packets):

1. **`SidebarTab` gains `CaseIterable`:**
   `enum SidebarTab: Sendable, CaseIterable { case annotations, ai, scratchpad }`.
2. **Inspector column width** — replace nothing (iPad has no `sidebarWidth` today), add:
   ```swift
   @ObservationIgnored
   private(set) var sidebarWidth: CGFloat = InspectorLayout.idealWidth
   ```
   with main's full doc comment (why it is `@ObservationIgnored`, and why the view must ALSO
   freeze it in `@State`). Do **not** re-add the deleted `minSidebarWidth`/`defaultSidebarWidth`/
   `maxSidebarWidth` statics — `InspectorLayout` (§2.10) is the single owner.
3. **`inspectorPresented` / `setInspectorPresented(_:)` / `revealSidebarTab(_:)` /
   `rememberSidebarWidth(_:)`** — adopt verbatim from main (`WorkspaceStore.swift:60-104` in
   main), doc comments included.
4. **Residency ownership block** — adopt verbatim:
   ```swift
   @ObservationIgnored let residency: TabResidencyManager
   @ObservationIgnored private var liveTabRuntimes: [String: LiveTabRuntime] = [:]
   ```
   plus `liveTabRuntime(for:)`, `activateLiveTabRuntime(_:)`, `existingLiveTabRuntime(for:)`,
   `removeLiveTabRuntime(for:)`, `flushLivePageTextCaches()`, `paneDidActivateTab(_:tabId:)`,
   `forgetPanePin(_:)`.
5. **`init`** — iPad's is `init(sessions: SessionService)`. Main split it into a designated
   `init(sessions:integrations:residency:)` + a convenience. Integrations belong to another
   packet, so on iPad make it:
   ```swift
   init(sessions: SessionService, residency: TabResidencyManager = TabResidencyManager()) {
       self.residency = residency
       ...
   }
   ```
   Every existing call site (`VellumApp_iOS.swift:22`, `Tests/PaneTreeTests.swift:10`) keeps
   compiling. The injectable `residency` is what lets `TabResidencyTests`/`PaneTreeTests` drive
   a manual clock.
6. **`splitFocused`** — delete `sidebarOpen = true` (it now belongs to `adoptOpenedDocument`,
   §2.6).
7. **`closePane(_:)`** — adopt main's version verbatim: bind `closingPane`, `forgetPanePin`,
   and `for tab in closingPane.app.tabs { removeLiveTabRuntime(for: tab.id) }` before the
   existing tree surgery.
8. **`mergeAll()` — PR #108, tab OWNERSHIP TRANSFER.** iPad's current loop is the buggy copy:
   ```swift
   for tab in leaf.app.tabs { keep.app.attachTab(tab) }   // ← copies; donor still claims them
   ```
   Replace with main's detach-then-attach + `forgetPanePin`, comments included:
   ```swift
   for tabId in leaf.app.tabs.map(\.id) {
       guard let tab = leaf.app.detachTab(tabId) else {
           assertionFailure("mergeAll: \(tabId) vanished from its own pane mid-merge")
           continue
       }
       keep.app.attachTab(tab)
   }
   forgetPanePin(leaf.app)
   ```
   The id snapshot matters — `detachTab` mutates the array being walked. On iPad the bug this
   fixes is worse than on macOS: `WebViewerController_iOS`'s mount guard and the ink registry
   both resolve tab→pane, so a copied tab kept pointing at the pane it just left.
9. **`allTabs` / `activateWorkspaceTab(paneId:tabId:)` / `closeWorkspaceTab(paneId:tabId:)`**
   and the `struct WorkspaceTab` at file scope — adopt verbatim. These back the iPad tab
   overview (§2.12).
10. **`dto(from:)`** — adopt main's: filter start tabs out of persistence (`$0.document != nil`),
    map `mode: $0.regionCaptureTarget == nil ? $0.mode : .view`, and index `activeIndex` into
    `liveTabs`, not `tabs`.
    **BYTE-COMPAT:** `TabDescriptor`'s encoded shape is unchanged — this only changes *which*
    tabs get written. Verify `Tests/PaneTreeTests.testWorkspaceStateRoundTrips` still passes
    unmodified.
11. **`restoreFromDisk()` tail + `pruneAbandonedEmptyPanes()` + `pruningEmptyLeaves(_:)`** —
    adopt verbatim.

**`let tabTeardowns`** — **now in scope**, see §2.14 (the document-actions sub-scope assigned to
this packet by packet 10 §3.2). Take it here.

**Hunks I do NOT own** (skip; other packets):
`SettingsSection` enum (packet 3), `let integrations: IntegrationsStore` (packet 8),
`settingsSection` (packet 3), `updateChecker` / `didStartAutomaticUpdateCheck` /
`checkForUpdatesAutomatically()` / `claimAutomaticUpdateCheck()`.
**Preserve unconditionally** (iPad-only, must survive the merge):
`beginTabDrag`'s `#if os(macOS)` NSEvent poll / `#else scheduleDragExpiry()`, the whole
`#if os(iOS) noteDragActivity() / scheduleDragExpiry()` block (`WorkspaceStore.swift:120-137`),
`endTabDrag`.

### 2.6 `Vellum/Stores/AppStore.swift` — [MERGE]

**Hunks I own, in order:**

1. **Delete the prepared-PDF LRU** (`AppStore.swift:17-46` on iPad: `maxPreparedCache`,
   `preparedPdfCache`, `cachedPreparedPdf`, `storePreparedPdf`, `evictPreparedPdf`) and replace
   with main's explanatory comment block ("One owner, one lifetime"). Its two iPad call sites
   are `Platform/iOS/PdfViewerView_iOS.swift:93` and `:117` — they move to
   `runtime.preparedDocument` / `runtime.adoptPreparedPdf(_:byteCount:)` in §2.8.
   Also delete the `evictPreparedPdf(tabId:)` call at the top of `closeTab`.
2. **Delete the nested `enum RegionCaptureTarget`** (`:85`); the top-level one from §2.1 replaces it.
3. **Find state becomes per-tab.** Add `private(set) var findQuery = ""`; mirror into the tab
   in `showFind`, `hideFind`, `performFind`, `setFindResults`; add `findQuery = ""` to
   `resetFindState()`. Verbatim from main's #74 hunk.
4. **`tab(id:)` and `containsTab(id:)`** — adopt verbatim (persistent viewer hosts validate
   their own tab identity instead of consulting the pane-global active projection).
5. **`closeTab(_:)` — runtime release.** iPad's `closeTab` deliberately defers backend teardown
   into a detached `Task` so the close gesture never looks frozen (an iPad divergence — KEEP IT).
   Main awaits inline. Merge like this — ordering matters, `setDocumentMetadata` rewrites the
   PDF and therefore its page-text validation hash, so the flush must come after it and the
   runtime release after that:
   ```swift
   if closingTab.document != nil {
       let sessions = sessions
       let workspace = self.workspace
       Task { @MainActor in
           try? await sessions.setDocumentMetadata(
               sessionId: closingTab.id, key: "last_page", value: String(closingTab.currentPage))
           // Metadata rewrites the PDF and therefore its validation hash. Flush
           // extraction after that rewrite and before dropping the runtime so
           // the cache is keyed to the bytes that will reopen.
           await workspace?.existingLiveTabRuntime(for: tabId)?.flushPdfText()
           try? await sessions.closeFile(sessionId: closingTab.id)
           workspace?.removeLiveTabRuntime(for: tabId)
       }
   } else {
       // A start tab has no session and nothing to flush: hand its (empty)
       // runtime back now rather than leaving it against the ceiling.
       workspace?.removeLiveTabRuntime(for: tabId)
   }
   ```
   ⚠ Race to note in the code: if the user reopens the same document before that Task
   finishes, `openFile` mints a **fresh session id**, so the release targets the old id only —
   safe. It is only unsafe if a future change reuses tab ids. Say so in a comment.
6. **`closeOtherTabs(keeping:)` / `closeTabsToRight(of:)`** — adopt verbatim (PR #83).
7. **`duplicateTab(_:)`** — adopt verbatim, including the `guard sourceDocument.kind == .web`
   (PDF mutations are serialized per *session*, not per path, so two live PDF sessions on one
   file would overwrite each other's annotation writes).
8. **`restoreTabs(_:activeIndex:)`** — adopt main's rewrite wholesale. It stops routing through
   `openUrl`/`openFiles` (which dedupe by location and would collapse two saved tabs on the
   same URL), opens `.vellumweb` via `openVellumwebFile`, preserves the saved title, records
   recents, maps the saved active index through `restoredTabIds`, and skips unavailable
   documents instead of aborting.
   **Check first:** does iPad's `SessionService` expose `openVellumwebFile(path:sessionId:)`?
   If not (it may be arriving in the packet 1), keep the `.vellumweb` branch behind the
   same capability the iPad's `openFiles` uses today, and leave a TODO.
9. **`setMode` / `beginRegionCapture` / `beginNoteWithContent` / `finishNotePlacement(forSessionId:)`
   / `finishRegionCapture()` / `consumePendingNoteContent()`** — adopt main's #83 versions
   wholesale (note/capture state moves onto the tab). `finishNotePlacement(forSessionId:)` is
   the fix for "a delayed save from tab A dismisses the note interaction the user started in
   tab B" — with live tabs that is now reachable on iPad too. Update the iPad viewer call sites
   (`PdfViewerView_iOS`, `RegionCaptureOverlay_iOS`, `WebViewerView_iOS`) to call
   `finishRegionCapture()` / `finishNotePlacement(forSessionId:)` instead of `setMode(.view)`.
10. **`applyActiveState(from:)`** — adopt main's final version:
    ```swift
    pendingNoteContent = tab.pendingNoteContent
    workspace?.paneDidActivateTab(self, tabId: tab.id)   // pin incoming, restart outgoing idle clock
    ...
    regionCaptureTarget = tab.regionCaptureTarget ?? .ai
    mode = tab.regionCaptureTarget == nil ? tab.mode : .snapshotRegion
    findVisible = tab.findVisible
    findQuery = tab.findQuery
    findMatchCount = tab.findMatchCount
    findCurrentMatch = tab.findCurrentMatch
    ```
    and **delete** the leading `resetFindState()` (find now travels with the tab).
11. **`applyEmptyActiveState()`** — add `workspace?.paneDidActivateTab(self, tabId: nil)` and
    `regionCaptureTarget = .ai`.
12. **`adoptOpenedDocument`** — move `workspace?.sidebarOpen = true` from the top of the method
    to *after* the "already-open document → just activate it" early return (PR #72). Reopening
    an already-tabbed document is navigation, not a fresh open, and must not re-reveal an
    inspector the user closed.

### 2.7 `Vellum/Views/Shared/FindBar.swift` — [MERGE]

Take main's diff verbatim: delete `@State private var query`, bind the `TextField` to
`Binding(get: { app.findQuery }, set: { app.performFind($0) })`, and swap the two remaining
`query` reads for `app.findQuery`. **Keep** the iPad's `#if os(macOS)` guard around
`.onExitCommand` (iPad dismisses with the bar's Done button and Escape via the shortcut router).

### 2.8 `Platform/iOS/PaneView_iOS.swift` — REBUILD of main's `LiveTabHost` (PR #74)

**What main did** (`Views/Panes/PaneView.swift`): replaced the single `.id(app.activeTabId)`
viewer with a `ZStack { ForEach(app.tabs) { LiveTabHost(...) } }`, one mounted host per open
tab, inactive ones at `opacity 0` / `allowsHitTesting(false)` / `accessibilityHidden(true)` /
`zIndex 0`; `if app.tabs.isEmpty` renders the welcome screen (there is no tab to host it).
`LiveTabHost` renders: eviction placeholder (only `if document != nil`), else `Color.clear`
when `!(isActive || runtime.isRendered)` (WARM), else the viewer, else the start-tab home
screen; and `.task(id: isActive) { guard isActive else { return }; workspace.activateLiveTabRuntime(runtime) }`.

**iPad today** (`PaneView_iOS.swift:112-146`): `content` switches on `app.document == nil`
→ `WelcomeLibrary_iOS(compact: true)`, else a `VStack { PdfToolbar_iOS; FindBar; documentViewer }`
where `documentViewer` is `WebViewerView_iOS()` or `PdfViewerView_iOS(ink:)`. The pane owns
`@State private var ink = InkController_iOS()` and registers it in `InkRegistry_iOS` by pane id.

**Rebuild instructions:**

1. Keep the pane's chrome (`TabStrip_iOS`, `PdfToolbar_iOS`, `FindBar`) OUTSIDE the per-tab
   ZStack — it is pane-scoped and reads the pane's active projection. Only the *viewer* is
   multiplexed:
   ```swift
   @ViewBuilder
   private var content: some View {
       if app.tabs.isEmpty {
           WelcomeLibrary_iOS(onOpen: requestOpenFile, onAddWebpage: requestAddWebpage, compact: true)
       } else if app.document == nil {
           // Active start tab keeps the full-pane library, as today.
           WelcomeLibrary_iOS(onOpen: requestOpenFile, onAddWebpage: requestAddWebpage, compact: true)
       } else {
           VStack(spacing: 0) {
               PdfToolbar_iOS(ink: activeInk, onOpenFile: requestOpenFile, onAddWebpage: requestAddWebpage)
               if app.findVisible { FindBar() }
               ZStack {
                   ForEach(app.tabs) { tab in
                       LiveTabHost_iOS(
                           tabId: tab.id,
                           document: tab.document,
                           isActive: tab.id == app.activeTabId,
                           runtime: workspace.liveTabRuntime(for: tab.id))
                       .opacity(tab.id == app.activeTabId ? 1 : 0)
                       .allowsHitTesting(tab.id == app.activeTabId)
                       .accessibilityHidden(tab.id != app.activeTabId)
                       .zIndex(tab.id == app.activeTabId ? 1 : 0)
                   }
               }
               .frame(maxWidth: .infinity, maxHeight: .infinity)
               .ignoresSafeArea(edges: .bottom)
           }
       }
   }
   ```
   (A start tab does not need a host on iPad because its "home" surface is the full-pane
   library, which is pane-scoped, not tab-scoped. Note the difference from macOS in a comment —
   macOS hosts `WelcomeScreen` per tab because it grabs first responder.)
2. **`LiveTabHost_iOS`** — mirror main's `LiveTabHost` body exactly, minus the `isPaneFocused`
   parameter (see 1):
   ```swift
   private struct LiveTabHost_iOS: View {
       let tabId: String
       let document: DocumentInfo?
       let isActive: Bool
       let runtime: LiveTabRuntime
       @Environment(WorkspaceStore.self) private var workspace

       private var shouldRender: Bool { isActive || runtime.isRendered }

       var body: some View {
           Group {
               if runtime.isEvicted, document != nil {
                   if isActive {
                       VStack(spacing: 8) { ProgressView(); Text("Restoring tab…").foregroundStyle(.secondary) }
                   } else { Color.clear }
               } else if !shouldRender {
                   Color.clear            // WARM — see main's comment, copy it
               } else if let document {
                   if document.kind == .web {
                       WebViewerView_iOS(tabId: tabId, document: document, isActive: isActive, runtime: runtime)
                   } else {
                       PdfViewerView_iOS(tabId: tabId, documentInfo: document, isActive: isActive, runtime: runtime)
                   }
               } else { Color.clear }
           }
           .frame(maxWidth: .infinity, maxHeight: .infinity)
           .task(id: isActive) {
               guard isActive else { return }
               workspace.activateLiveTabRuntime(runtime)
           }
       }
   }
   ```
3. **Ink ownership moves off the pane.** Delete `@State private var ink = InkController_iOS()`.
   Add:
   ```swift
   private var activeInk: InkController_iOS? {
       app.activeTabId.map { workspace.liveTabRuntime(for: $0).ink }
   }
   ```
   `InkRegistry_iOS` keeps its pane→controller map for the shared inspector, but now registers
   the **active tab's** controller and re-registers on tab change:
   ```swift
   .onChange(of: app.activeTabId, initial: true) { _, _ in
       if let activeInk { inkRegistry.register(activeInk, for: pane.id) }
   }
   .onDisappear {
       activeInk?.flushPendingInk()      // flush BEFORE deregistering — comment already in the file
       inkRegistry.remove(pane.id)
   }
   ```
   ⚠ **Do not skip this.** Without it every mounted tab installs the same `ink.inkProvider` as
   its `PDFView.pageOverlayViewProvider` (`PdfKitView_iOS.swift:73`) and the provider's
   per-page canvas cache aliases across tabs — tab B's page 3 strokes appear on tab A's page 3.
   This is the #1 correctness hazard of live tabs on iPad.
4. Keep everything else on `PaneView_iOS` untouched: the focus ring, `PaneFocusCatcher_iOS`,
   the tab drop catcher gated on `workspace.draggingTab != nil`, `DropZoneOverlay`,
   `.task(id: documentIdentity) { await loadDocumentState() }`, the `.vellumAnnotationsUpdated`
   receiver, the `#if DEBUG` auto-ink hook.
5. In `loadDocumentState()`, add main's page-text restore after `loadConversationForDocument`:
   ```swift
   if let tabId = app.activeTabId, let runtime = workspace.existingLiveTabRuntime(for: tabId) {
       pane.ai.restorePageTexts(runtime.pageTexts)
   }
   ```
   (`AiStore.restorePageTexts` already exists on iPad, `Stores/AiStore.swift:387`.)

**Cross-packet contract for packet 7 (the PDF/Web viewers)** (they own `PdfViewerView_iOS.swift`,
`PdfKitView_iOS.swift`, `PdfViewerController_iOS.swift`, `WebViewerView_iOS.swift`):
- Both viewers must take `(tabId:document:isActive:runtime:)` instead of reading
  `app.document`/`app.activeTabId`, must gate every `onChange`-driven push on `isActive`, and
  must use `runtime.pdfController` / `runtime.webController` / `runtime.ink` rather than
  `@State` controllers.
- `PdfKitView_iOS.makeUIView` must return the runtime's retained `PDFView` and
  `view.removeFromSuperview()` before handing it to a new host (`mergeAll` can transiently
  mount two hosts for one tab; a UIView has one superview).
- The prepared-PDF path becomes `runtime.preparedDocument` / `runtime.adoptPreparedPdf(_:byteCount:)`,
  keyed on `.task(id: runtime.documentGeneration)` as well as `isActive`.
- `PdfViewerControlleriOS` writes extracted text to `runtime.pageTexts[page]` in addition to
  `AiStore.setPageText`.

### 2.9 `Platform/iOS/VellumApp_iOS.swift` — teardown flush (main's `VellumApp.swift` hunk)

**What main changed:** on quit it now writes `last_page` for every tab **first**, then
`await workspace.flushLivePageTextCaches()` (every runtime, not just the focused pane's shared
handler — a rewritten PDF changes its validation hash), then `closeFile` for every tab, then
drains `PageTextPersister.awaitInFlightFlushes()` / `AiPersistence.awaitPendingFlush()`.

**iPad instructions** (`flushOnBackground()`, `VellumApp_iOS.swift:100-134`) — keep the whole
`beginBackgroundTask` envelope and the iPad-only ink/scratchpad drains, and re-order to:
```swift
for pane in workspace.root.allLeaves() {
    pane.scratchpad.flush()
    for tab in pane.app.tabs {
        try? await workspace.sessions.setDocumentMetadata(
            sessionId: tab.id, key: "last_page", value: String(tab.currentPage))
        try? await workspace.sessions.saveFile(sessionId: tab.id)
    }
}
// Every runtime, not just the focused pane's handler: metadata rewrites above
// changed each PDF's validation hash, and with live tabs there is one extractor
// per tab rather than one per pane.
await workspace.flushLivePageTextCaches()
await PageTextPersister.awaitInFlightFlushes()
await ScratchpadPersistence.awaitPendingFlush()
await AiPersistence.awaitPendingFlush()
```
And replace the ink loop `for controller in inkRegistry.controllers.values` with one over the
runtimes (the registry now holds only the focused-pane projection):
```swift
for pane in workspace.root.allLeaves() {
    for tab in pane.app.tabs {
        await workspace.liveTabRuntime(for: tab.id).ink.flushPendingInkAndWait()
    }
}
```
Delete the now-redundant `await pane.app.flushPageTextCacheHandler?()` inside the pane loop.

### 2.10 `Vellum/Views/Shared/InspectorTabSwitcher.swift` — [REBUILD]

Create the file at the same path. Three parts:

**(a) `enum InspectorLayout` — adopt verbatim except one constant.**
```swift
static let minimumWidth: CGFloat = 280
static let idealWidth: CGFloat = 360
static let maximumWidth: CGFloat = 560   // iPad: was 700 on macOS
```
Rationale to write into the comment: 700 pt is over half the width of an 11" iPad in portrait
and nearly all of a Split View pane; 560 preserves the envelope
`ContentView_iOS` already ships (`.inspectorColumnWidth(min: 280, ideal: 360, max: 560)`), so
no user-visible regression.
Keep `fullLabelsMinimumWidth = 320`, `iconsMinimumWidth = 170`, `switcherHorizontalPadding = 12`,
`switcherVerticalPadding = 8`, `narrowestContentWidth`, `Presentation`, `presentation(for:)`.
`switcherHeight`: **30 → 36 on iPad** and say why (a 30 pt segment is under the 44 pt HIG touch
target; 36 pt of control inside 8 pt of vertical padding gives a 52 pt row, and the segment
itself gets its remaining reach from `.contentShape` — see (c)).
`headerHeight` — keep the computed property but drop the drop-routing half of its comment;
on iPad it is layout-only (the AppKit `SidebarDropCatcher` is not ported).

**(b) `extension WorkspaceStore.SidebarTab` — adopt verbatim.**
`Identifiable`, `title`, `systemImage` (`highlighter` / `sparkles` / `note.text`),
`accessibilityIdentifierStem`, `accessibilityIdentifier` (`sidebarTab.annotations` etc.),
`shortcutDigit` ("1"/"2"/"3"), `static let shortcutModifiers: EventModifiers = [.command, .option]`.
**The identifier convention is load-bearing** — the old iPad `GlassSegmentedPicker` interpolated
the *display label* and therefore emitted `sidebarTab.Annotations`; anything automating the
sidebar must move to the lowercase stem.

**(c) `struct InspectorTabSwitcher` — rebuild.**
Keep main's structure exactly: `GeometryReader` → `switch InspectorLayout.presentation(for:)`
→ `.fullLabels` / `.icons` / `.menu`, `.frame(height: InspectorLayout.switcherHeight)`,
`.accessibilityElement(children: .contain)`.

Per-segment button, iOS-adapted:
```swift
Button {
    withAnimation(.snappy) { selection = tab }
} label: {
    Group {
        if showTitles {
            Label(tab.title, systemImage: tab.systemImage)
                .labelStyle(.titleAndIcon).lineLimit(1).minimumScaleFactor(0.85)
        } else {
            Label(tab.title, systemImage: tab.systemImage).labelStyle(.iconOnly)
        }
    }
    // KEEP THIS PLACEMENT. On macOS `.buttonStyle(.plain)` hit-tests against the
    // label's rendered content, so the expanding frame has to be inside the
    // label closure to widen the tap target. UIKit's hit test is frame-based and
    // would forgive the outer placement — but the whole-segment target is a
    // touch requirement here too, and keeping the two platforms structurally
    // identical is what stops the next port from re-introducing #112.
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .contentShape(Rectangle())
}
.buttonStyle(.plain)
.foregroundStyle(SelectionStyle.foreground(palette, selected: isSelected, hovering: false))
.selectionSurface(selected: isSelected, hovering: false, in: Capsule(), palette: palette)
.accessibilityLabel(tab.title)
.accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
.accessibilityIdentifier(tab.accessibilityIdentifier)
```
- `SelectionStyle.foreground` and `.selectionSurface(...)` already exist on iPad
  (`Views/Shared/Theme.swift:139-176`) — no port needed.
- Track background: `.padding(2)` + `.background(palette.muted, in: Capsule())`, verbatim
  (`.quaternary` resolves from the color scheme and disappears on the parchment palette).
- `@State private var hovering` / `.onHover`: **keep but make it pointer-only**. `.onHover`
  fires on iPadOS for a trackpad/Magic Mouse pointer, so keeping it is a genuine iPad feature,
  not dead macOS code. If it causes trouble, dropping it is acceptable — pass `hovering: false`
  everywhere as shown above and delete the state.
- `compactMenu`: `.menuStyle(.borderlessButton)` is **macOS-only** — replace with
  `.menuStyle(.button).buttonStyle(.plain)`. Everything else (the checkmark-vs-icon trick, the
  `sidebarTab.menu` identifier, `accessibilityLabel("Inspector section")` +
  `accessibilityValue(selection.title)`) is verbatim.
- Font: main uses `.font(.callout)`. Keep it.

### 2.11 `Platform/iOS/ContentView_iOS.swift` + `Platform/iOS/PdfChrome_iOS.swift` — inspector presentation, width and switcher (PRs #72, #73, #120, #122)

**(a) `PaneShell_iOS.inspectorPresented`** (`ContentView_iOS.swift:154-159`) — today it reads
`focused.app.document != nil && workspace.sidebarOpen` and writes `workspace.sidebarOpen = $0`.
Replace with the store-owned pair (this IS PR #72):
```swift
private var inspectorPresented: Binding<Bool> {
    Binding(
        get: { workspace.inspectorPresented },
        set: { workspace.setInspectorPresented($0) })
}
```
The behavioural fix: when focus moves to a start tab SwiftUI writes `false` because the
inspector became conditionally unavailable; `setInspectorPresented` ignores that write, so the
user's chosen panel and column width survive a trip through Home.

**(b) Width envelope + remembered width (PR #122).** Replace the hardcoded
`.inspectorColumnWidth(min: 280, ideal: 360, max: 560)` with the frozen-ideal pattern. Give
`PaneShell_iOS` an `@State private var idealColumnWidth: CGFloat` seeded from
`workspace.sidebarWidth` in `init`, and:
```swift
.inspector(isPresented: inspectorPresented) {
    SidebarContent_iOS(ink: inkRegistry.controllers[workspace.focusedPaneId])
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width in
            workspace.rememberSidebarWidth(width)
        }
        // MUST STAY THE OUTERMOST MODIFIER ON THE INSPECTOR CONTENT — the
        // column-width envelope is a view trait read off the ROOT of this
        // closure and does not survive being wrapped. (Measured on macOS in
        // #122: with `.onGeometryChange` applied after it, the host fell back
        // to its built-in width and registered NO min/max, so the divider had
        // nothing to drag between.)
        .inspectorColumnWidth(
            min: InspectorLayout.minimumWidth,
            ideal: idealColumnWidth,
            max: InspectorLayout.maximumWidth)
}
.onChange(of: workspace.inspectorPresented) { _, isPresented in
    if isPresented { idealColumnWidth = workspace.sidebarWidth }
}
```
Copy main's `idealColumnWidth` doc comment verbatim — it explains why a live read of
`workspace.sidebarWidth` reopens a layout feedback loop.

**(c) Switcher swap** (`PdfChrome_iOS.swift:664-678`, inside `SidebarContent_iOS`). Replace
```swift
GlassSegmentedPicker(options: [...], selection: Binding(...), accessibilityIdentifierPrefix: "sidebarTab")
    .padding(.vertical, 10)
```
with
```swift
InspectorTabSwitcher(selection: Binding(
    get: { workspace.sidebarTab }, set: { workspace.sidebarTab = $0 }))
    .padding(.horizontal, InspectorLayout.switcherHorizontalPadding)
    .padding(.vertical, InspectorLayout.switcherVerticalPadding)
```
**Preserve everything else in `SidebarContent_iOS` untouched** — in particular the
`hasShownAi` / `hasShownScratchpad` lazy-mount latches and their long comment (that is a
measured ~56 ms launch win from the iPad tree, not present on macOS), the mounted-panel ZStack,
and `panel(_:content:)`.

**(d) `Controls.swift`** — only after (c) and after the macOS-gated `App/ContentView.swift` is
replaced by main's copy (which no longer uses it), delete `GlassSegmentedPicker`. Grep first:
`grep -rn GlassSegmentedPicker Vellum/` must return zero hits outside `Controls.swift`.

### 2.12 `Platform/iOS/PdfChrome_iOS.swift` — tab strip improvements + tab overview (PR #83)

**What main changed** (`Views/PDF/TabBarView.swift`): a `rectangle.stack` toolbar button opening
a `TabOverview` popover over `workspace.allTabs` with a search field; a per-tab context menu
(Rename… / Duplicate / Move to New Pane / Copy Link | Reveal in Finder / Close Tab / Close
Others / Close Tabs to Right); a pending-action dot (`tab.mode != .view || pendingNoteContent != nil
|| regionCaptureTarget != nil`); close button visible when hovered **or active**; and the
presentation helpers extracted into `enum TabPresentation`.

**iPad today:** `TabStrip_iOS` (`:500`) + `TabChip_iOS` (`:556`) — chips with their own title
derivation (`RecentFilesService.webpageDisplayName` / `.fileName`), a 44 pt close button,
`selectionSurface(in: Capsule())`, `.onDrag` with `TabDragPayload`, and a `+` button.

**Instructions:**

1. **Adopt `TabPresentation`.** Put it in `Vellum/Views/PDF/TabBarView.swift` **outside** the
   `#if os(macOS)` gate (or, cleaner, a new `Vellum/Views/PDF/TabPresentation.swift` — say
   which you did in the commit message). Then make `TabChip_iOS.title` call
   `TabPresentation.title(for: tab)`.
   ⚠ **Behaviour change to check:** `TabPresentation.title` falls back to the filename minus
   `.pdf`, whereas iPad currently calls `RecentFilesService.webpageDisplayName(for:)` for web
   tabs (which prettifies a URL into a host/slug). Keep the iPad behaviour for web tabs by
   overriding inside `TabPresentation` under `#if os(iOS)` **or** by leaving `TabChip_iOS.title`
   as-is and using `TabPresentation` only for the overview. Prefer the latter — smaller blast
   radius, and the overview then shows the same string as the chip only for PDFs. Decide and
   comment it.
2. **Pending-action dot** on `TabChip_iOS`: a 6 pt `Circle().fill(.orange).accessibilityHidden(true)`
   after the title when `tab.mode != .view || tab.pendingNoteContent != nil ||
   tab.regionCaptureTarget != nil`, plus `.accessibilityValue(hasPendingAction ? "Action pending" : "")`
   merged with the existing `isActive ? "Selected" : ""` value (concatenate; do not drop
   the selected state).
3. **Overview button** in `TabStrip_iOS`, pinned to the trailing edge next to `+`:
   ```swift
   Button { showingOverview.toggle() } label: {
       Image(systemName: "rectangle.stack")
           .font(.system(size: 15, weight: .medium))
           .foregroundStyle(palette.mutedForeground)
           .frame(width: 44, height: 44)
           .contentShape(Rectangle())
   }
   .buttonStyle(.plain)
   .accessibilityLabel("Show all tabs")
   .accessibilityIdentifier("tabBar.overview")
   .popover(isPresented: $showingOverview) { TabOverview_iOS(...) }
   ```
   Move both the `+` and this button OUT of the horizontal `ScrollView` (they must stay
   reachable when the strip scrolls) — today `+` is inside it. That is an iPad-only fix worth
   making while you are here.
4. **`TabOverview_iOS`** — port main's `TabOverview` body: `Text("All Tabs").font(.headline)`,
   `TextField("Search tabs", text: $query).textFieldStyle(.roundedBorder)
   .accessibilityIdentifier("tabOverview.search")`, `ContentUnavailableView.search(text:)` when
   empty, a `ScrollView { LazyVStack }` of rows.
   - Filtering is verbatim: `TabPresentation.title` OR `TabPresentation.typeLabel` OR
     `paneLabel`, all via `localizedStandardContains`.
   - Row: icon + title (2 lines) + `"\(tab.paneLabel) · \(TabPresentation.typeLabel(for:))"`
     caption + checkmark when `isFocusedActive` + pending dot; trailing close button.
   - Keep the identifiers exactly: `tabOverview.tab.\(tab.id)`, `tabOverview.close.\(tab.id)`,
     and the composed `accessibilityLabel` (`"<title>, <pane>, <type>[, action pending]"`).
   - iOS adaptations: `.frame(width: 360)` → `.frame(minWidth: 360, idealWidth: 380)` and add
     `.presentationCompactAdaptation(.popover)` so it stays a popover rather than becoming a
     full-screen sheet in a compact Split View pane; row hit targets ≥ 44 pt
     (`.padding(.vertical, 10)`); the close button `.frame(width: 44, height: 44)`.
   - `onActivate` → `workspace.activateWorkspaceTab(paneId:tabId:)` + dismiss;
     `onClose` → `Task { await workspace.closeWorkspaceTab(paneId:tabId:) }`.
5. **Tab context menu** on `TabChip_iOS`. Port main's ONE `.contextMenu` (two `.contextMenu`
   modifiers on one view do not compose — the outer replaces the inner), with these platform
   edits:
   - `Copy Link` → `UIPasteboard.general.string = tab.document?.pdfPath`.
   - **Drop `Reveal in Finder`** — no iPad equivalent. (Do not substitute a Files-app reveal;
     out of scope.)
   - `Rename…` + the `.sheet(item: $renamingTab) { RenameDocumentSheet(...) }` depend on
     `RenameDocumentSheet` and `AppStore.renameDocument(tabId:title:)`. Those come from the
     document-actions sub-scope, **which is now this packet's** (§2.14) — land §2.14 first and
     take these unconditionally rather than gating them out.
   - `Duplicate` keeps `.disabled(tab.document?.kind == .pdf)`; `Move to New Pane` and
     `Close Others` keep `.disabled(appStore.tabs.count < 2)`; `Close Tabs to Right` keeps
     `.disabled(isLastTab)`.
   - ⚠ `.contextMenu` and `.onDrag` both key off long-press in SwiftUI on iOS. They normally
     coexist (drag = press-then-move, menu = press-and-hold) but this is exactly the kind of
     thing that regresses. **Verify tab drag-between-panes still works after adding the menu**
     (device-interaction skill, or codex computer-use). If it breaks, fall back to an ellipsis
     `Menu` button rendered on the active chip only.
   - Skip `MiddleClickView` entirely (AppKit `NSEvent` monitor; no iPad middle button).

### 2.13 Sheet-gated command suppression (PRs #71 + #119) — iOS-native sheet-presence gate + the existing iPad router

> **Decision (packet 10 §3.3).** `Vellum/App/SheetPresenceMonitor.swift` and
> `Tests/SheetPresenceTests.swift` are **dropped entirely [SKIP]** — the macOS monitor exists
> to gate `.focusedSceneValue` so a disabled menu item declines its key equivalent, and iOS has
> no menu validation and no attached sheets, so there is no contract to preserve. **Packet 4
> owns the replacement**: the iOS-native gate below (`SheetPresence_iOS`, consulted by the iPad
> shortcut router, with `.dismiss` handled by dismissing `topPresented` rather than suppressed)
> plus a new iOS test (§4.5). This supersedes the earlier "keep the path so the packet maps 1:1
> to the delta" instruction.

**What main did.** #71 moved the document commands from `.focusedValue` to
`.focusedSceneValue`, which fixed nested-responder blanking but meant a sheet no longer
displaced the value — so ⌘W behind a sheet closed the tab underneath (#98). #119 added
`SheetPresenceMonitor`, fed by `NSWindow.willBeginSheetNotification` / `didEndSheetNotification`
and reading `NSWindow.attachedSheet` (not SwiftUI presentation flags — see the file's long
comment for the two reasons), and `ContentView` publishes
`.focusedSceneValue(\.vellumFocus, sheets.sheetPresented ? nil : VellumFocus(...))`.

**iPad has no `.focusedSceneValue` gate at all** — `VellumCommands_iOS` captures the
`WorkspaceStore` directly and `VellumShortcutRouter.perform` re-checks every precondition at
invocation time (`Platform/iOS/ShortcutRouter_iOS.swift:43`, and the comment at `:27-42`
explains why). **That is the seam to use**: a live query at invocation beats a published flag,
and it needs no notification plumbing.

**Rebuild:**

1. New file **`Vellum/Platform/iOS/SheetPresence_iOS.swift`** (an iPad-only file — do **not**
   recreate `Vellum/App/SheetPresenceMonitor.swift`, which is dropped), body:
   ```swift
   #if os(iOS)
   import UIKit

   /// Whether the app is currently showing a modal on top of the document UI —
   /// asked of UIKit, not inferred from SwiftUI's presentation flags.
   ///
   /// The macOS twin of this file gates `.focusedSceneValue` so a disabled menu
   /// item declines its key equivalent (issue #98: ⌘W pressed to dismiss a sheet
   /// closed the tab underneath). iPadOS has no menu validation to lean on —
   /// `VellumCommands_iOS` is rebuilt only when SwiftUI re-evaluates `Commands`,
   /// which is why `VellumShortcutRouter` re-checks every precondition at
   /// invocation time. So this is a live query, consulted there.
   ///
   /// WHY UIKIT RATHER THAN A SET OF `isPresented` FLAGS — same two reasons as
   /// macOS. A flag records what the app ASKED for, not what is on screen, and
   /// Vellum does not present all of its own modals: `UIDocumentPickerViewController`
   /// (DocumentPickerCoordinator_iOS), the share sheet and `UIPrintInteractionController`
   /// are all presented by frameworks. `presentedViewController` covers every one
   /// of them and cannot describe a modal that is not there.
   @MainActor
   enum SheetPresence_iOS {
       /// True while any view controller is presented modally over the app's
       /// foreground-active scene.
       static var isPresenting: Bool { topPresented != nil }

       /// The frontmost presented controller, or nil. Also the dismissal target
       /// for Escape — see `VellumShortcutRouter.dismiss`.
       static var topPresented: UIViewController? {
           guard let scene = UIApplication.shared.connectedScenes
               .compactMap({ $0 as? UIWindowScene })
               .first(where: { $0.activationState == .foregroundActive }),
                 let root = scene.keyWindow?.rootViewController
           else { return nil }
           var presented = root.presentedViewController
           while let next = presented?.presentedViewController { presented = next }
           return presented
       }
   }
   #endif
   ```
2. **Gate the router.** In `VellumShortcutRouter.perform(_:workspace:)`
   (`ShortcutRouter_iOS.swift:43`), before the `switch`:
   ```swift
   // A modal is up: every document command below acts on something the user
   // cannot see, and on macOS the equivalent items are disabled (and a disabled
   // item does not claim its key equivalent — issue #98). `.dismiss` is the one
   // exception and is handled rather than suppressed, because a `UIKeyCommand`
   // that matches is consumed unconditionally on iOS: if we no-oped Escape here,
   // the sheet the user is trying to close would simply stop responding to it.
   if SheetPresence_iOS.isPresenting {
       if case .dismiss = action { SheetPresence_iOS.topPresented?.dismiss(animated: true) }
       return
   }
   ```
   This suppresses the whole table — File (⌘T/⌘O/⌘L/⌘W/⌘P/⌘S), View (zoom, inspector, splits),
   Navigate (pages, history, ⌘1…⌘9, tab cycling) and Annotations (⌘D, `N`) — which is exactly
   the macOS set, since main publishes a nil focus value and every one of those items is gated
   on `hasFocus`.
3. **Do NOT gate** anything that would be reachable from a Help/Settings scene on macOS (main
   keeps Help ▸ Vellum Walkthrough always enabled). iPad's catalog has no such entry today; if
   the packet 3 adds one, it must bypass this gate — leave a comment saying so.
4. **Inspector panel shortcuts (⌥⌘1/2/3, PR #120).** Add to `VellumShortcutCatalog`
   (`Platform/iOS/KeyboardShortcuts_iOS.swift`):
   - `enum VellumShortcutAction` gains `case showSidebarTab(WorkspaceStore.SidebarTab)` with
     `identifier` `"showSidebarTab.\(tab.accessibilityIdentifierStem)"`.
     (`SidebarTab` must be `Hashable` for this — it is `Sendable, CaseIterable` after §2.5;
     add `Hashable` in the same hunk, it is a payload-free enum so the conformance is free.)
   - Three rows in the `view` group, after `.toggleInspector`:
     ```swift
     ] + WorkspaceStore.SidebarTab.allCases.map { tab in
         VellumShortcut(
             .showSidebarTab(tab), "Show \(tab.title)",
             VellumKeyCombo(tab.shortcutDigit, [.command, .option]), menu: .view)
     }
     ```
   - Router: `case .showSidebarTab(let tab): workspace.revealSidebarTab(tab)`.
   - **The collision rule main encodes**: ⌘1…⌘9 already switch TABS, so panels take ⌥⌘.
     `Tests/KeyboardShortcutsTests.swift` (iPad, already exists) should gain an assertion that
     no two rows share a `VellumKeyCombo` — that is the iPad equivalent of main's
     `InspectorTabSwitcherTests` modifier check. Check whether it already has one before adding.

### 2.14 Document actions (#82 / #113) — named sub-scope assigned to this packet

> **Decision (packet 10 §3.2).** Packets 4, 7 and 9 all cited a "document-actions packet
> (#82/#113)" that was never cut. The *files* were claimed (this packet MERGEs all three) but
> the *hunks* were explicitly disclaimed by every owner, so `TabTeardownRegistry`, the close
> half of #113 and Save As had no owner at all. **The orchestrator assigns them to packet 4 as
> this named sub-scope.** Land it before §2.2's `teardowns:` parameter and before §2.12.5's
> `Rename…` menu item.

**Scope — exactly these four things, nothing else from #82/#113:**

1. **`TabTeardownRegistry` hunks in `Vellum/Stores/WorkspaceStore.swift`.** The
   `let tabTeardowns` property and its registration/deregistration plumbing (main's
   `WorkspaceStore.swift`). This is the store-side half of §2.5.
2. **`TabTeardownRegistry` hunks in `Vellum/Stores/AppStore.swift`.** The
   `AppStore(sessions:teardowns:)` initializer parameter and the teardown invocation on the
   close path, so `closeTab` / `closeOtherTabs` / `closeTabsToRight` run registered teardowns
   instead of relying on deinit ordering. Fold into §2.6 rather than making a second pass over
   the file.
3. **`TabTeardownRegistry` hunks in `Vellum/Models/PaneTree.swift`.** `PaneModel.init` gains
   `teardowns: TabTeardownRegistry = TabTeardownRegistry()` and forwards it to
   `AppStore(sessions:teardowns:)` — this is §2.2's deferred parameter, now taken.
4. **The close half of #113 + Save As state.** The document-close path off the main thread
   (the *close* half only — packet 7 §2.8 owns the *open* half, `PdfSessionBackend`), and the
   `Save As` state that hangs off it (`AppStore.renameDocument(tabId:title:)` +
   `RenameDocumentSheet`, consumed by §2.12.5's tab context menu).

**Not in scope:** anything in #82/#113 touching `PdfSessionBackend`'s open path (packet 7
§2.8), or the annotation-side teardown (packet 6).

**Test.** `Tests/DocumentActionsTests.swift` stays in packet 9's Stage 4, re-tagged
**[MERGE — content per packet 4 §2.14]**, and must land **after** this sub-scope. Packet 4
supplies the adaptation list; packet 9 writes the file.

**Commit boundary.** One commit for items 1–3 (the registry, which is mechanical and touches
three files), a second for item 4 (close path + Save As, which is behavioural).

### 2.15 macOS-gated reference files — [MERGE], mechanical

These four compile to nothing on iOS (`#if os(macOS)` at line 1) but are kept in the tree as the
parity reference. Copy main's post-delta version into the gate, verbatim, changing nothing:

| iPad path | Source |
|---|---|
| `Vellum/App/ContentView.swift` | main `Vellum/App/ContentView.swift` (549 lines) |
| `Vellum/App/VellumCommands.swift` | main `Vellum/App/VellumCommands.swift` (363 lines) |
| `Vellum/App/VellumApp.swift` | main `Vellum/App/VellumApp.swift` (260 lines) |
| `Vellum/Views/Panes/PaneView.swift` | main `Vellum/Views/Panes/PaneView.swift` (372 lines) |
| `Vellum/Views/PDF/TabBarView.swift` | main `Vellum/Views/PDF/TabBarView.swift` (508 lines), **minus `TabPresentation`, which moves outside the gate** (§2.12.1) |

Mechanics: `#if os(macOS)` on line 1, `#endif  // os(macOS) — iPad reference; see Platform/iOS`
on the last line, exactly as the existing files do.
⚠ These files reference symbols from OTHER packets (`SidebarPanelStack`, `SidebarDropCatcher`, `AttachmentDrop`, `RenameDocumentSheet`,
`HelpCenterView`, `UpdateChecker`…). Because they are inside the gate they will not fail the
iOS build even when those symbols are absent — but they will look broken to a reader.
main's `ContentView.swift` also references the AppKit `SheetPresenceMonitor`, which iPad
**never** ships (§2.13's decision). That is fine inside the gate; note it in the commit message
so a later reader does not "fix" it by resurrecting the monitor. **Do this
step LAST in the packet**, after the other packets have landed as much as they are going to, and
note in the commit message that the gated files are reference-only.

---

## 3. `project.yml` / `Info-iOS.plist` / entitlements

**No changes required by this packet.**

- **Packet 9 is the SOLE editor of `project.yml`** (packet 10 §2.2 — three packets had tagged it
  MERGE; xcodegen re-reads it for every target, so it gets one `xcodegen generate` per landing,
  not five). This packet needs no hunk in it, which is why the glob below suffices.
- `project.yml`'s `Vellum` target globs `- path: Vellum` (with three `excludes` for Info.plists
  and the katex folder), and `VellumTests` globs `- path: Tests`. Every new file here
  (`Vellum/Services/TabResidency.swift`, `Vellum/Models/LiveTabRuntime.swift`,
  `Vellum/Views/Shared/InspectorTabSwitcher.swift`, `Vellum/Platform/iOS/SheetPresence_iOS.swift`,
  `Tests/TabResidencyTests.swift`, …) is picked up automatically. Re-run `xcodegen generate`
  after adding files; do not hand-edit the pbxproj.
- No new capability, background mode, URL scheme or usage description. The memory-warning
  notification needs no entitlement.
- Main's `project.yml` delta (UITesting config + `VellumUITests` target + macOS signing +
  `SWIFT_TREAT_WARNINGS_AS_ERRORS` + Integrations fixtures) and its `Info.plist` delta
  (document types / exported UTIs for `.vellum` / `.vellumweb`) are **out of scope** —
  packets 1 and 9 own them.
- Watch item, not an action: the iPad target sets `SWIFT_STRICT_CONCURRENCY: minimal`. Main's
  `TabResidency.swift` is written to be clean under stricter settings anyway; keep it that way
  (that is why §2.3(c) hops to `@MainActor` rather than using `assumeIsolated`).

---

## 4. Tests to port

> **Ownership rule (packet 10 §2.1).** **Packet 9 is the only packet that writes into `Tests/`;
> every other packet's test claim is a specification, not an edit.** Everything in this section
> is the adaptation list packet 9 applies — do not create or modify these files yourself.
> Packet 9's `[VERBATIM]` tags on `TabResidencyTests`, `PaneTreeTests` and
> `InspectorPresentationTests` are downgraded to `[MERGE — content per packet 4 §4.N]`.

Target dir: `/Users/ayushdeolasee/Developer/Vellum/ipad-app/Tests/`.

### 4.1 `Tests/TabResidencyTests.swift` — [MERGE] (35 Swift Testing cases)

Copy main's file. Adaptations:

- The private harness (`ManualResidencyClock`, `FakeResident`, `makeManager`, `PaneIdentity`)
  ports unchanged — it never touches PDFKit/WebKit/AppKit, which is the whole point of
  `TabResidentResource` being a protocol.
- Retune the module-level literals to match §2.3(b):
  `private let hotTabLimit = 3` and `makeManager(tabLimit: 4)` defaults. `hotWindow` /
  `retentionWindow` stay at 10 / 30 minutes.
- `theMostRecentlyUsedTabsUpToTheHotLimitAreRendered`, `aSixthTabDemotesTheLeastRecentlyUsed…`,
  `aPinnedTabSpendsOneOfTheHotSlots`, `tabCeilingEvictsLeastRecentlyActiveFirst` all count tabs
  against the limits — rewrite the counts in terms of `TabResidencyManager.hotTabLimit` /
  `.residentTabLimit` rather than hardcoding 5/6/8, so the retune cannot silently break them.
  (Rename `aSixthTabDemotes…` → `oneTabPastTheHotLimitDemotesTheLeastRecentlyUsed…`.)
- `memoryPressureWarningShrinksToTheTightCeiling`,
  `memoryPressureWarningKeepsAWarmSetRatherThanDroppingEverything` and
  `criticalMemoryPressureEvictsEverythingButTheTabOnScreen` keep calling
  `handleMemoryPressure(_:)` directly — that API is unchanged.
- **New tests for the iOS pressure seam** (the piece main has no analogue for):
  ```
  @Test func aSingleMemoryWarningAppliesTheTightCeilingsRatherThanDroppingEverything()
  @Test func aSecondMemoryWarningInsideTheEscalationWindowDropsEverythingOffScreen()
  @Test func aSecondMemoryWarningAfterTheEscalationWindowIsTreatedAsTheFirstAgain()
  ```
  All three drive `noteMemoryWarning()` with the manual clock and assert on the returned
  evicted-id array + `residentTabIds`.
- `sweeperRunsOnlyWhileSomethingIsResident`, `sweeperStopsWhenTheLastResidentIsEvictedByTheWindow`,
  `noSweeperWhenAutomaticMaintenanceIsOff` — port as-is; they opt back into
  `automaticMaintenance: true` and assert `isSweeping`. On iOS a live manager with
  `automaticMaintenance: true` also registers the notification observer; that is inert in a test
  process, but assert nothing about it.
- No `@Suite(.serialized)` needed — every case builds its own manager.

### 4.2 `Tests/PaneTreeTests.swift` — [MERGE]

iPad's copy has 11 XCTest cases and `makeWorkspace() { WorkspaceStore(sessions: DocumentSessionManager()) }`,
same as main's. Add these, verbatim where possible:

From **#74**: `testFindStateFollowsItsDocumentTab`, `testLiveRuntimeTextIsIsolatedPerTab`,
`testLiveRuntimeLimitEvictsLeastRecentlyUsedInactiveTab` (async; spins on `Task.yield()` until
`residentTabCount <= residentTabLimit` — it is asserting the *deferred* ceiling enforcement from
`scheduleCeilingEnforcement`), `testMemoryPressureEvictsInactiveButKeepsActiveRuntime`,
`testClosingATabReleasesItsRuntimeImmediately`, `testEachPanePinsItsOwnTabAgainstCriticalPressure`,
`testSixthTabStopsRenderingButKeepsItsResources`,
`testReactivatingAWarmRuntimeRendersItWithoutReloading`,
`testRuntimeCostsNothingBeforeLoadAndNothingAfterEviction`, `testReleasingARuntimeTwiceIsANoOp`,
`testPdfControllerActiveGateFollowsReboundPane`.

From **#83**: `testPruneAbandonedEmptyPanesCollapsesSplit`,
`testAllTabsIncludesEveryPaneAndActivationFocusesOwningPane`,
`testWorkspaceCloseRoutesToTheOwningPane`, `testSerializeDropsTransientNewTabsAndReindexesSelection`,
`testSerializeDoesNotRestoreAbandonedActiveNewTab`,
`testSerializePreservesDuplicateWebTabsAndTheirSelection`,
`testPendingNoteAndRegionCaptureBelongToTheirTabAcrossSwitches`,
`testInteractionCompletionKeepsTheTargetThatWasArmedBeforeReset`,
`testDelayedNoteCompletionNeverClearsAnotherTabMode`,
`testNotePlacementConsumesItsQueuedContentBeforeModeReset`,
`testCloseOthersAndCloseRightPreserveExpectedTabs`, `testTabPresentationUsesFullTitleAndType`,
`testTabSwitchRestoresFindAndNoteStateAndPinsTheIncomingTab`, and the `makeTab(id:document:)` helper.

From **#108**: `testMergeAllTransfersTabOwnershipInsteadOfCopying`,
`testMergeAllMigratesEveryTabAcrossNestedSplits`, and the `pdfDocument(path:)` helper.
(`testMergeAllTransfersTabOwnershipInsteadOfCopying` is the regression test for the exact bug
iPad ships today — port it first and watch it fail before §2.5.8.)

iOS adaptations: rename any `sixthTab` wording to match the retuned `hotTabLimit`;
`testMemoryPressureEvictsInactiveButKeepsActiveRuntime` asserts `inactive.webController !== inactiveWebController`
— that works once `WebViewerController_iOS` is what the runtime holds. Add an iPad-only case:
`testEvictionDoesNotDropDebouncedInk` (arrange a runtime whose `ink` has pending strokes,
evict it, await, assert the ink write landed) — this covers §2.4's `withExtendedLifetime` and is
the only guard against silently losing Pencil strokes to a memory warning.

### 4.3 `Tests/InspectorPresentationTests.swift` — [MERGE] (Swift Testing, 5-ish cases)

Main's file uses `@Suite(.serialized, .scratchDefaults)` and a local `InspectorSessionService`
stub. `.scratchDefaults` is `Tests/ScratchDefaultsTrait.swift`, introduced by the `AppDefaults`
work in **packet 1** — see §5-D2. If it has not landed, either port `ScratchDefaultsTrait.swift`
with it or drop to `@Suite(.serialized)` and accept the recents write going to the real defaults
domain (note it in a TODO; do not ship that permanently).
The assertions themselves are pure store logic (`inspectorPresented`, `setInspectorPresented`,
`sidebarTab`, `sidebarWidth`, `rememberSidebarWidth`) and port unchanged. Also port the two cases
#120 added (they assert `revealSidebarTab` opens a closed inspector and never closes an open one).

### 4.4 `Tests/InspectorTabSwitcherTests.swift` — [MERGE] (XCTest)

Port all cases with these edits:
- `testEnvelopeIsTheWidenedOne`: `maximumWidth` literal `700` → **`560`**, and update the
  comment to say the iPad envelope was deliberately kept narrower.
- `testHeaderHeightIsTheStripTheCatcherMustCover`: `switcherHeight` literal `30` → **`36`**,
  `headerHeight` `46` → **`52`**; rewrite the doc comment (on iPad this is a touch-target fact,
  not a drop-routing one) and rename to `testHeaderHeightMatchesTheSwitcherPlusItsInset`.
- The case asserting `WorkspaceStore.SidebarTab.shortcutModifiers != VellumCommands.tabShortcutModifiers`
  cannot compile (`VellumCommands` is macOS-gated). Replace with the iPad equivalent: assert that
  no two rows of `VellumShortcutCatalog.all` share a `VellumKeyCombo`, and specifically that
  `⌥⌘1/2/3` (the panel reveals) are distinct from `⌘1/2/3` (tab switching).
- `testAccessibilityIdentifiersMatchTheAutomationConvention` and
  `testNarrowestRealInspectorStillShowsEveryDestinationInline` port verbatim (with 280-24=256 →
  `.icons`, unchanged).

### 4.5 `Tests/SheetPresenceTests.swift` — **[SKIP — dropped]**; replaced by a NEW iOS test

> **Decision (packet 10 §3.3).** Packet 4 had tagged this [REBUILD] while packet 9 tagged it
> [SKIP] ("macOS-only: asserts `NSWindow.willBeginSheetNotification` / `attachedSheet`"), and
> packet 9's Appendix A suggested dropping `SheetPresenceMonitor.swift` outright. **Resolved by
> dropping BOTH the macOS monitor and `Tests/SheetPresenceTests.swift` entirely.** iOS has no
> attached sheets and therefore no menu-bar-disabling contract to preserve.
>
> **Packet 4 owns the replacement**: the iOS-native sheet-presence gate in §2.13
> (`SheetPresence_iOS`, consulted by the iPad shortcut router, with `.dismiss` handled by
> dismissing `topPresented`) **and a new iOS test for it**. Name it
> `Tests/SheetPresenceIOSTests.swift` so nobody mistakes it for a port of main's file. Packet 4
> supplies the specification below; **packet 9 writes the file** (§2.1 ownership rule).

Main's file drives real `NSWindow`s offscreen and a real hosted SwiftUI `.sheet` because every
claim is about AppKit. None of that carries. The new iOS test asserts:
- Build a `UIWindow` (offscreen frame), give it a `rootViewController`, make it key & visible.
- `testNoPresentationMeansNoGate`: `SheetPresence_iOS.isPresenting == false`.
- `testPresentedControllerIsSeen`: `present(UIViewController(), animated: false)`; pump the
  runloop; expect `isPresenting == true` and `topPresented === presented`.
- `testNestedPresentationReportsTheFrontmost`: present A, then present B from A; expect
  `topPresented === B`.
- `testDismissalClosesTheGate`: dismiss, pump, expect false.
- `testGateIgnoresNonForegroundScenes` — **skip**; an XCTest host has one scene and faking
  `activationState` is not worth it. Say so in a comment (main documents its own "what is NOT
  covered" section; keep that habit).
- Add `testDismissActionClosesTheTopmostPresentationInsteadOfNoOping` driving
  `VellumShortcutRouter.perform(.dismiss, workspace:)` with a presented controller up, asserting
  the controller is dismissed — that is the behaviour §2.13.2 exists for.
- **Note in the file header** what is NOT covered on iPad: that SwiftUI `Commands` key
  equivalents still *fire* behind a modal (they are not validated the way an AppKit menu is), so
  the gate is a router-level suppression rather than a "the chord never reaches us" guarantee.

---

## 5. Risks & cross-packet dependencies

### Dependencies (blockers, in order)

- **D1 — packet 7 (PDF & Web viewers). Mitigated by §2.0** — cycle C3 (packet 10 §3.1) is broken
  by landing the cross-packet contract as a standalone interface-only commit with no-op
  implementations *before* packet 7 starts. Chain: **§2.0 → packet 7 viewers → packet 4 §2.8 →
  packet 7 §2.9 (`FindBar`)**. The rest of this bullet describes what packet 7 must fill in.
  `LiveTabRuntime` holds `PdfViewerControlleriOS`,
  `WebViewerController_iOS` and needs `WebViewerController_iOS.{residencyCostBytes, isAttached,
  deactivate(), releaseResidency()}` plus `(tabId:document:isActive:runtime:)` initializers on
  both viewers, plus `PdfKitView_iOS.makeUIView` returning the retained `PDFView` after
  `removeFromSuperview()`. Coordinate: **§2.1–2.7 can land first** (models/services/stores
  compile without the viewers), **§2.8 cannot**. If you must unblock, land §2.8 with the viewers
  still self-owning their controllers and `LiveTabHost_iOS` merely multiplexing — the residency
  policy then evicts objects nothing points at, which is worse than not shipping it. Don't.
- **D2 — packet 1 (`AppDefaults` / `ScratchDefaultsTrait`).** Needed only by
  `InspectorPresentationTests`' `.scratchDefaults` trait. Everything else is independent.
- **D3 — ~~document-actions packet (#82/#113)~~ — no longer a dependency: it is now §2.14 of
  this packet.** Packet 10 §3.2 found the packet was never cut and every owner disclaimed its
  hunks, leaving `TabTeardownRegistry`, the close half of #113 and Save As unowned; the
  orchestrator assigned them to packet 4 as a named sub-scope. Land §2.14, then take
  `TabTeardownRegistry` in §2.2/§2.5 and `RenameDocumentSheet` + `AppStore.renameDocument` in
  §2.12.5 unconditionally. Packet 9's `Tests/DocumentActionsTests.swift` stays in its Stage 4,
  re-tagged **[MERGE — content per packet 4 §2.14]**, landing after this sub-scope.
- **D4 — packet 1.** `AppStore.restoreTabs` (§2.6.8) calls
  `sessions.openVellumwebFile(path:sessionId:)`. Verify it exists on iPad before porting that
  branch.
- **D5 — the packet 6** also edits `Models.swift` and the **packet 5** also edits
  `AppStore.swift` / `WorkspaceStore.swift`. Land whole hunks, never whole files, and rebase
  rather than overwrite.

### Risks

- **R1 (highest) — ink aliasing across live tabs.** `PdfKitView_iOS` installs
  `ink.inkProvider` as `pageOverlayViewProvider` and a `UIPencilInteraction` delegate on the
  `PDFView`. With N mounted tabs sharing one pane-owned `InkController_iOS`, the per-page canvas
  cache aliases by page number across documents. §2.4 + §2.8.3 move ink onto the runtime; if you
  skip that, live tabs will corrupt handwriting. Verify on device with two inked PDFs open.
- **R2 — losing debounced ink or an in-flight web archive to an eviction.** The iPad's ink write
  coalescing (PR #78) is exactly what makes an unwritten drawing possible at eviction time.
  §2.4's `withExtendedLifetime` flush is mandatory; test 4.2's `testEvictionDoesNotDropDebouncedInk`
  is its only guard.
- **R3 — memory ceilings still too generous.** 4 tabs / 256 MB is a guess informed by macOS's
  numbers, not a measurement. After landing, profile on the oldest supported iPad with 3 large
  scanned PDFs + 2 web tabs; if the app is jetsammed before the ceilings bite, lower
  `residentByteBudget` first (it is the one that tracks real footprint) and re-run
  `TabResidencyTests`.
- **R4 — battery.** Live tabs mean N mounted `WKWebView`s per pane. Warm tabs are `Color.clear`
  (unmounted representable) so they cost nothing to draw, but a *hot* inactive web tab keeps
  running timers/observers. The iPad tree's web-observer throttling (PR #78) must apply to
  inactive-but-hot tabs too — check that `WebViewerController_iOS.deactivate()` (D1) throttles
  rather than merely clearing selection, and that `hotTabLimit = 3` is respected.
- **R5 — `.inspectorColumnWidth` may not be user-draggable on iPadOS.** If the iPad inspector
  column has no drag handle, `.onGeometryChange` never reports a user-chosen width and
  `rememberSidebarWidth` simply never fires — harmless, and `sidebarOpen`/`sidebarTab`
  preservation (the actual PR #72 win) is unaffected. Verify before writing a UI test that
  assumes dragging. Do **not** hand-roll a drag handle in this packet.
- **R6 — Escape consumption behind a modal.** A matched `UIKeyCommand`/SwiftUI key equivalent is
  consumed unconditionally on iOS, so a naive "suppress everything while a sheet is up" gate
  makes Escape stop dismissing sheets. §2.13.2 handles `.dismiss` explicitly instead of
  suppressing it. Verify with a hardware keyboard: ⌘W behind the Add-Webpage sheet must NOT
  close a tab, Escape must close the sheet.
- **R7 — dead constant.** `InspectorLayout.headerHeight` exists on macOS for the AppKit
  `SidebarDropCatcher`, which iPad does not port (standing decision: iOS-native drop rebuild).
  Keep the constant (the switcher's own layout uses it and the test pins it) but do not port the
  drop-routing rationale — an implementer who reads that comment will go looking for a catcher
  that does not exist.
- **R8 — `TabPresentation.title` vs `RecentFilesService.webpageDisplayName`.** iPad chips
  currently show a prettified host/slug for web tabs; main's helper shows the raw path. Decide
  once (§2.12.1) and apply the same choice in the chip and the overview, or the two surfaces
  will disagree about what a tab is called.
- **R9 — `mergeAll` transfer + `paneDidEmpty`.** `detachTab` on the donor's last tab calls
  `applyEmptyActiveState()` → `paneDidActivateTab(self, nil)`, and on iPad `AppStore.closeTab`
  (not `detachTab`) is what calls `workspace?.paneDidEmpty`. Confirm the merge loop does not
  re-enter `closePane` mid-walk on iPad the way it could not on macOS — main's
  `assertionFailure` in the loop is there precisely to catch a tab vanishing mid-merge.
- **R10 — start tabs are no longer persisted** (§2.5.10). iPad's `restoreTabs` currently calls
  `newStartTab()` for a nil-document descriptor; main's rewrite `continue`s instead. Combined
  with the `dto` filter this means a workspace of only start tabs restores to an empty pane →
  `WelcomeLibrary_iOS`. That is the intended behaviour, but it changes what an existing user's
  saved `workspace.json` reopens to. The format is unchanged (no migration needed); just do not
  be surprised.
