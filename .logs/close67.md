Closing in favour of #74, which now contains the consolidated implementation. Both PRs implemented issue #52 independently and touched the same six files, so only one could land.

**Why #74 survived.** The two PRs solved different halves of the issue. This PR kept the tab's *resources* alive (`TabResidencyManager` parking the parsed `PDFDocument` and the `WKWebView`) but left `PaneView` keying its viewer on `.id(app.activeTabId)`, so the SwiftUI/AppKit subtree was still destroyed and rebuilt on every switch and PDFKit still paid a full relayout on the way back. That matches the report on this PR that "there is still a big loading delay when switching tabs": the parse was cached, the view was not. #74 keeps the whole `LiveTabHost` mounted per tab in a `ZStack` and only toggles visibility, so a switch costs an opacity change. It also dissolves a class of bug rather than defending against it — the mount-token protocol, the `mountedDocument` indirection and the warm/cold `loadedUrl` handshake in this PR all exist solely to survive a view teardown that #74 does not perform.

**Carried over from here, essentially whole:**

- `Vellum/Services/TabResidency.swift` — the entire policy engine. `ResidencyClock` + `ContinuousResidencyClock` with the wall-clock and `SuspendingClock` reasoning intact; the 2-hour `retentionWindow`; per-pane pinning via `markActive` / `forgetOwner`; `residentTabLimit` (8) and `residentByteBudget` (768 MB); `.warning` → 2 tabs / 128 MB vs `.critical` → everything off screen; the one shared sweeper with lazy start, self-cancellation and 30s tolerance; `enforceCeilings()` deferred one main-actor turn from `store` so a burst is bounded long before the sweeper's first tick; `deinit` cancelling both handles.
- The `TabResidencyTests` suite — 23 Swift Testing cases on a hand-driven clock with `automaticMaintenance: false`.
- `closePane` / `mergeAll` dropping a discarded pane's pin.
- `WebViewerController` hard teardown holding the controller alive until a pending auto-archive lands (this PR's fix for `detach()` silently dropping the offline snapshot), and nil'ing the WebKit delegates first so a late `webViewWebContentProcessDidTerminate` cannot reload an evicted tab over the network.
- `removeFromSuperview()` in the representable's `makeNSView`, extended to `PdfKitView` as well, since `mergeAll` can transiently mount two hosts for one tab.

**Dropped, with reasons:**

- **The `.id(activeTabId)` viewer keying and everything built to survive it** — the mount token/`mountGeneration` protocol, the `attach`/`detach(token:)` split, the `loadedUrl` warm-vs-cold handshake, the `skipEmptyAnnotationPush` workaround, and the background-`init` `loadedUrl` invalidation. All correct fixes for a problem #74 does not have: the web view is never re-parented mid-session because the host never unmounts.
- **The `Slot` enum.** It existed because this PR tracked the PDF and the web side of a tab as separate residency entries. `LiveTabRuntime` already owns both, so a tab is one resident resource and the two-slot bookkeeping (including the double-report bug fixed in 823c802) has nothing left to do.
- **`PreparedPdfResidency` and the `AppStore` prepared-PDF path.** Subsumed by `LiveTabRuntime`. In fact #74's own inherited three-entry LRU was *removed* for the same reason this PR removed it — with both in play, evicting a runtime freed the viewer but left the `PDFDocument` alive in the LRU, so for the three most recent tabs the memory the eviction existed to reclaim never came back.
- **The process-wide `TabResidencyManager.shared`.** The manager is owned by `WorkspaceStore` instead, so a discarded workspace takes its sweeper and pressure source with it — which also removes the "one live `DispatchSource` per unit test" leak.
- **The `about:blank` blank-out on eviction.** Correctly identified in this PR's own review as being cancelled by `decidePolicyFor`; the delegate-nil'ing that was added alongside it is what actually matters, and dropping the last reference to the controller is what releases the view.
- **`residencyCostBytes` on `WebViewerController` as an unconditional constant** — kept, but now gated on the web view having actually been created, so a tab the user never opened does not consume budget.

**On the data-loss question**, I reached the same conclusion this PR's review did, independently: no persisted state is lost by eviction. The pending-auto-archive cancellation was the one genuine gap, and this PR's fix for it is in #74.

No commits are lost — `keep-tabs-active` stays on the remote for reference.
