Closes #52. Supersedes and consolidates #67, which is closed in favour of this.

## Why this branch and not #67

Both PRs attacked issue #52 and could not both land. They solved *different halves* of it, and only one half is the half the issue is about.

#67 kept the tab's **resources** alive (a `TabResidencyManager` parking the parsed `PDFDocument` and the `WKWebView`) but left `PaneView` keying its viewer on `.id(app.activeTabId)`. The SwiftUI/AppKit subtree was still destroyed and rebuilt on every switch, so PDFKit still paid a full relayout of the document on the way back. That is why the report on #67 was *"there is still a big loading delay when switching tabs"* — the parse was cached, the view was not.

This branch keeps the **view** alive: `PaneView` renders a `LiveTabHost` per open tab in a `ZStack` and merely hides the inactive ones (`opacity` / `allowsHitTesting` / `accessibilityHidden`). Nothing is torn down on a switch, so a switch costs an opacity change. It also removes a whole class of bug by construction — #67 needed a mount-token protocol, a `mountedDocument` indirection and a warm/cold `loadedUrl` handshake purely to survive its own view teardown; none of that machinery is needed when the view never unmounts.

What #67 had that this branch did not was a **policy**. That has now been grafted in.

## The retention policy (grafted from #67)

Residency was a per-tab `Task.sleep(for: .seconds(2 * 60 * 60))` inside `LiveTabHost`. That is one wakeup per inactive tab; it dies silently whenever the host unmounts, so a tab dragged to another pane was never reclaimed at all; it has no byte budget; it treated a routine `.warning` memory-pressure event as `.critical` and dropped every background tab; and there is no way to test the two-hour boundary without waiting two hours.

Replaced with `Vellum/Services/TabResidency.swift` — `TabResidencyManager`, a main-actor policy engine behind an injectable `ResidencyClock`. Three layers, in priority order:

1. **Pinned tabs are never evicted.** Pinning is per pane (keyed on the pane's `AppStore` identity), so a split window keeps **both** visible documents resident — that is the split-screen half of the issue. The pin is set from `AppStore.applyActiveState` and dropped by `closePane` / `mergeAll`.
2. **The retention window.** A tab idle past `retentionWindow` — one named constant, 2 hours per the issue — is evicted on the next sweep. The idle clock starts when you switch *away*, not when you activated.
3. **Ceilings.** `residentTabLimit` (8) and `residentByteBudget` (768 MB) evict the least-recently-active *inactive* tabs early. Enforced on the next main-actor turn after a `store`, not just on the next sweep — otherwise anything a user can open inside the sweeper's first 60-second tick stays resident regardless.

Closing a tab still releases immediately: retention is about tabs that are still open.

### Memory-pressure escape hatch

`DispatchSource.makeMemoryPressureSource(eventMask: [.warning, .critical], queue: .main)` feeds the same eviction routine:

- `.warning` → tighten to `pressureTabLimit` (2) / `pressureByteBudget` (128 MB). macOS raises `.warning` routinely; dropping everything on it would delete the feature on a busy machine, so a small warm set survives.
- `.critical` → every off-screen tab goes, now.

Pinned tabs survive both. The handler reads its level off `self.pressureSource` rather than capturing `source`, so there is no retain cycle needing `cancel()` to break it.

### The sweeper and the clock

**One shared sweeper**, not one timer per tab: a single `Task` ticking every 60s with a 30s `tolerance` so the kernel can coalesce the wakeup. It starts lazily on the first resident tab and cancels itself when the last one goes, so an idle Vellum schedules no timer at all.

Deliberately **not `Date`**: an NTP correction can move wall-clock time backwards, making a tab look permanently fresh or instantly stale. `ContinuousClock` (not `SuspendingClock`) is also deliberate — on Darwin it is `mach_continuous_time` and keeps counting while the Mac is asleep. A laptop shut overnight genuinely has left those tabs untouched all night, so reclaiming on wake is right, and it is what stops a machine that sleeps constantly from accumulating unbounded resident documents.

## One owner for expensive state

`AppStore`'s three-entry prepared-PDF LRU is **gone**. Keeping it alongside runtime residency was actively harmful: evicting a runtime under memory pressure freed the viewer but left the `PDFDocument` alive in the LRU, so for the three most recent tabs the memory the eviction existed to reclaim never came back. The parsed document now lives on `LiveTabRuntime.preparedDocument`, which eviction clears — and it still survives a load cancelled by a rapid switch, which is the one case the LRU was genuinely earning its keep.

`LiveTabRuntime` conforms to `TabResidentResource`. PDFs are costed at their file size; a live `WKWebView` at a flat 96 MB, and zero until the view is actually created. Read the byte budget as a rough guardrail, not accounting: PDFKit's live footprint is some multiple of the file size and there is no cheap way to do better — the pressure hook is the real backstop.

The `Slot` enum from #67 was dropped. It existed only because #67 tracked the PDF and the web side of a tab separately; `LiveTabRuntime` already owns both, so a tab is one resident resource.

## Lifetime fixes carried over from #67's review

- **`WebViewerController.releaseResidency()` holds the controller alive until a pending auto-archive lands.** `detach()` used to cancel it, silently losing the offline `.vellumweb` snapshot whenever a tab was closed or evicted within 1.5s of a page finishing loading.
- **It nils the WebKit delegates before teardown.** Eviction targets tabs that are still *open*, so a late `webViewWebContentProcessDidTerminate` would reload the tab's real URL over the network into a view nobody can see — and jetsamming background web content processes is exactly what the system does under the pressure that triggered the eviction. (#67 also navigated to `about:blank` "so WebKit retires the process"; that is a no-op here — `decidePolicyFor` cancels it — so it is not carried over. Dropping the last reference to the controller is what actually releases the view.)
- **`WebViewRepresentable.makeNSView` / `PdfKitView.makeNSView` detach the retained native view from its superview** before handing it to a new host. An NSView may only have one superview, and `mergeAll` copies tabs into the surviving pane before the donor's subtree is torn down — a window in which two hosts can briefly claim one tab.
- **The workspace owns the manager**, rather than #67's process-wide singleton, so a discarded `WorkspaceStore` (one per unit test) takes its sweeper and its memory-pressure source down with it in `deinit`.

## Does eviction lose unsaved work?

I diffed the timed/pressure eviction teardown against the close-tab teardown rather than inheriting either PR's claim. **No, with two inherent caveats.**

- **Extracted page text** — eviction calls `flushAndDropPersister()`, which hands the persister's own authoritative dict to `flushDetached()`; that write is registered in `PageTextPersister.inFlightFlushes` and awaited by the quit path. Ordering differs from the close path (which cancels extraction and then awaits the flush), but `releaseResidency()` is synchronous main-actor code, so the extraction task cannot interleave between the flush and the `reset()` that cancels it. `runtime.pageTexts` is deliberately *kept* across eviction — cheap, and it keeps the AI context truthful while the viewer restores.
- **Annotations** — round-trip through the session backend on every edit. `AnnotationStore` is per-pane and only ever holds the *active* tab's set; eviction only ever targets non-pinned (non-active) tabs, so an evicted tab's annotations are not in memory at all.
- **Reading position** — mirrored into `PdfTab.currentPage` while the tab is on screen and serialized by `WorkspaceStore`. Eviction does not touch it, and the restore reads it back. Precision drops from scroll-offset to page granularity, identical to a fresh open.
- **Scratchpad drafts** — 400 ms debounce, per pane, active document only. Not reachable by eviction.
- **The one real gap, now fixed:** the pending auto-archive, above.
- **Genuinely lost, inherently:** unsubmitted form input in a background web tab. Any eviction loses it, and before either PR it was lost on *every* tab switch.

## Testing

`xcodegen generate` → clean build, no new warnings (the three that land in touched files are present unchanged on `main`).

- **`Tests/TabResidencyTests.swift`** — 23 Swift Testing cases, all driven through an injectable `ResidencyClock` so the 2-hour window is exercised without waiting, and with `automaticMaintenance: false` so no background sweeper races the assertions. Covers survival at 2h−1s and eviction at 2h; the pinned tab never expiring; the idle clock starting at the switch-away; both panes pinning in a split; LRU order under the tab ceiling and the byte budget; immediate release on close; `.warning` keeping a warm set vs `.critical` clearing everything off screen; and the sweeper existing only while something is resident.
- **`Tests/PaneTreeTests.swift`** — +9 XCTest cases wiring the policy to the real stores: per-pane pinning under `.critical`, the tab ceiling trimming on the next turn, immediate release on close, per-tab find state, the PDF controller's active-mount gate following a rebound pane, and a runtime costing nothing before load and nothing after eviction.

```
274 XCTest + 23 Swift Testing = 297, 0 failures, no host crashes or restarts
```

Mutation-checked (each mutation reverted after): widening the retention window ×100 → 5 cases fail; removing the pin exemption → 5 Swift Testing + 2 XCTest cases fail; making eviction keep its controllers → memory-pressure case fails; making eviction keep the parsed document → cost case fails; disabling `stopSweeperIfIdle` and the deferred ceiling pass → 3 Swift Testing + 1 XCTest case fail; zeroing the per-tab find carry and pinning `isActiveMount` to `true` → 5 XCTest cases fail.

**Not verified** (headless unit tests only, no computer-use): that a real switch is visually instant; that the WebKit content process is actually reclaimed on eviction; the pending-auto-archive preservation, which needs a live `WKWebView` and session; and real memory-pressure behaviour under a real `.warning`/`.critical` event.

🤖 Generated with [Claude Code](https://claude.com/claude-code)
