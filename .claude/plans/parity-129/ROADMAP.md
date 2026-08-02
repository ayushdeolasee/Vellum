# Vellum iPad parity — landing roadmap (issue #129)

Derived from `packet-10-coverage.md` §4, with the gap assignments (§1.1), conflict resolutions
(§2), cycle breaks (§3.1) and phantom-packet decisions (§3.2) already folded into packets 1–9.

**Ten stages, A → J.** The order is load-bearing: it exists to break cycles C1/C2/C3 and to put
the test bundle on its feet before anything else needs it. Do not reorder stages A, C, D or F.

---

## How to read a stage

Every stage below lists four things:

* **Contents** — the packets and named sub-scopes that land in it.
* **Sub-issue** — the GitHub phase issue it reports against.
* **Gate** — what must be green before the stage is called done.
* **Commits** — the commit boundaries inside the stage.

**The gate is the same command everywhere:**

```bash
cd /Users/ayushdeolasee/Developer/Vellum/ipad-app
xcodegen generate                       # after ANY new file under Vellum/ or Tests/
xcodebuild test \
  -project Vellum.xcodeproj -scheme Vellum \
  -destination 'platform=iOS Simulator,name=iPad Pro 13-inch (M5)'
```

`xcodegen generate` + **the full suite** on **iPad Pro 13-inch (M5)**. Commit the regenerated
`Vellum.xcodeproj/project.pbxproj`; never hand-edit it. A stage is not done on a subset run — the
test bundle is a single compile unit, so a partial pass means nothing.

## Sub-issue map

| issue | phase | packet |
|---|---|---|
| #130 | storage | packet 1 |
| #131 | bundles | packet 2 |
| #132 | home | packet 3 |
| #133 | tabs | packet 4 |
| #134 | inspector + AI | packet 4 (inspector half) + packet 5 |
| #135 | annotations / scratchpad | packet 6 |
| #136 | toolbar / web | packet 7 |
| #137 | integrations | packet 8 |
| #138 | QA | packet 9 |

**Packet 9 has no stage of its own except A and J.** Its per-suite work trails whichever feature
packet it tests, and reports against that packet's sub-issue — the test file lands in the same PR
as the feature, or immediately after it. Packet 9 is the only packet that *writes* into `Tests/`;
every other packet's test claim is a specification it applies.

---

## Stage A — test & build infrastructure (packet 9, Stage 0)

**Contents.** Packet 9 Stage 0 only:

* `project.yml` test sources (the `VellumTests` sources/excludes + `Tests/Integrations/Fixtures`
  resource wiring). Packet 9 is the **sole editor** of `project.yml` — packets 1 and 8 hand it
  their hunks. One `xcodegen generate` per landing, not five.
* `Vellum/Services/KeychainStore.swift` + `Tests/KeychainStoreTests.swift`.
* `Vellum/Services/TestEnvironment.swift`.
* `.gitignore`.
* `Vellum/Resources/Info-iOS.plist` (packet 9 owns the plist; packet 2's cosmetic copy of main's
  macOS `Info.plist` is dropped).

**Sub-issue.** #138. It lands **first** despite #138 being the QA issue — everything else needs
the test bundle to build, and `WebLibrary.appDataDir` / `PageTextCache` read
`UITestLaunchConfiguration.storageRoot`, so packets 5 and 7 cannot compile their copies without
Stage 0.2. Say so in the issue so nobody reads the ordering as a mistake.

**Gate.** Full suite green. Additionally: verify the **first Swift Testing suite actually runs**
on the iPad Pro 13-inch (M5) destination before anything else depends on it —
`-only-testing:VellumTests/KeychainStoreTests` is the cheap probe. The iPad `Tests/` tree is 100%
XCTest today and ~15 incoming suites use `import Testing`.

**Commits.**
1. `project.yml` + regenerated pbxproj + `.gitignore`.
2. `TestEnvironment.swift`.
3. `KeychainStore.swift` + `KeychainStoreTests.swift` (the vault migration — its own commit, it is
   the one piece of Stage A with real behavioural risk on a device that already holds keys).
4. `Info-iOS.plist`.

**Blocks.** Everything. **Do not start any other stage until A is green.**

---

## Stage B — storage foundations (packet 1) + `Theme.swift`

**Contents.**

* **Packet 1** in full. This is where cycles **C1** (packet 1 ↔ packet 6) and **C2** (packet 1 ↔
  packet 5) break, using packet 1's documented stubs: `legacyScratchpad` stubbed to `[]` behind a
  TODO, and the `AiPersistence` deferral. Both stubs are already written into packet 1 §5 — land
  them, do not try to close them here.
* **`Vellum/Views/Shared/Theme.swift`** — the 3-line `ThemePalette.success` merge (light
  `#2f7d46` / dark `#5bbf77`). Owned by packet 8, pulled forward into this stage: it was the one
  delta file **no packet mentioned at all**, and packet 8's `FloatingNotice.swift` does not compile
  without it. Trivial, additive, no AppKit — no reason to make packet 8 wait on it.

**Sub-issue.** #130 for packet 1; the `Theme.swift` commit reports against **#137** even though it
lands here.

**Gate.** Full suite green, including the packet-1 test specifications packet 9 applies:
`StorageManagementTests` (minus the two Integrations tests), `DocumentIdentityTests` (adapted to
`PdfFileGate` stamping, not `PdfDocumentIO`), `PageTextCacheTests` (docId re-key),
`DocumentDataStoreTests`.

**Commits.** Packet 1's own §2 order (2.1 → 2.23) is the commit sequence; `AppStore.swift` and
`Models.swift` each get their own commit because later stages rebase onto them. Plus one
standalone `Theme.swift` commit.

**File-edit orders opened here** (packet 10 §2.3 — packet 1 always goes first):
`AppStore.swift` **1 → 4 → 2**; `Models.swift` **1 → 4 → 6**; `PdfSessionBackend.swift` /
`WebSessionBackend.swift` **1 → 6 → 7**. The old "these files are dirty in the iPad worktree"
warning is **stale** — that work landed in `783c8835`.

---

## Stage C — the PDF/Web interface contract (packet 4 §2.0)

**Contents.** Packet 4 §2.0 **only** — the cross-packet contract for the PDF/Web viewers, landed
as a **standalone interface-only commit with no-op implementations**:

* the `isActiveMount` flag on the viewer entry points;
* the `makeUIView` retained-view protocol;
* the `documentAttached()` callback;
* plus the `LiveTabRuntime` stubs those imply (`pdfController`, `webController`, `ink`,
  `preparedDocument`, `adoptPreparedPdf(_:byteCount:)`, `documentGeneration`, `pageTexts`).

**Why it is its own stage.** This is the **C3 cycle break**. Packet 4 D1 said "§2.8 cannot land
without the viewer packet"; packet 7 D2/D3 said background-tab restore and `FindBar` are blocked
on packet 4. Two of the three largest packets each declared themselves blocked by the other with
no stub on either side. Shipping the signatures first — and nothing else — unblocks both.

**Sub-issue.** #133.

**Gate.** Full suite green, and a reviewer must be able to confirm there is **no behavioural diff
in the commit**. If they can point at one, the commit is too big.

**Commits.** Exactly one.

**Chain this opens** (do not reorder): **C → packet 7 viewers → packet 4 §2.8 → packet 7 §2.9**.
That chain is Stage F.

---

## Stage D — AI delta (packet 5), including the markdown/selection files

**Contents.** Packet 5 §A–§I. §I is the work packet 10 §3.2 folded in from the
"markdown / math / text-selection packet" that was never cut (~730 delta lines with no owner):

* `Vellum/Views/AI/InlineMarkdown.swift` — **[VERBATIM]**, pure Foundation + `AttributedString`.
* `Vellum/Views/AI/MarkdownMessage.swift` — **[MERGE]**, the list model change
  (`case list([MarkdownListItem])` replacing `unordered`/`ordered`, plus the nested-depth
  `MarkdownListItem` struct).
* `Vellum/Views/AI/SelectableMessageText.swift` — **[REBUILD into the existing UIKit rewrite]**:
  `AttachmentText`, `fittedAttachments(in:width:)`, `measureSize`, `mathMaxWidth` plumbing, the new
  `attributedString(for:)` signature. Do **not** overwrite iPad's UIKit file with main's AppKit one.
* `Vellum/Views/PDF/PdfOverlays.swift` — **[MERGE]**, the 2-line optional-`pageNumber` adaptation
  applied to `Vellum/Platform/iOS/RegionCaptureOverlay_iOS.swift`.

Packet 5 also owns `AiPanel.swift` and the **structure** of `AiPanel_iOS.swift`; packet 6
contributes only the clear/undo/redo slice, afterwards, in Stage E.

**Sub-issue.** #134.

**Gate.** Full suite green. §I unblocks three suites packet 9 was stuck on:
`AiMarkdownRenderingTests` (blocked on §I.1), `SelectableMessageTests` (§I.3) and
`MarkdownParserTests` (§I.2 — it does **not compile** against iPad's current `MarkdownParser`).
`Tests/AiAddAsNoteTests.swift` lands here with **packet 5's content**; packet 7's 14 web-dismissal
cases are a separate new file in Stage F.

**Commits.** §A–§C (self-contained, land immediately) → §D → §E → §F → §G → §H → **§I as its own
commit** (it is a source-breaking signature change and touches every `MarkdownBlock` switch arm in
the tree). Tell packet 9 the moment §I lands.

---

## Stage E — annotations & scratchpad (packet 6)

**Contents.** Packet 6 in full. This **closes C1's stubs** — the `legacyScratchpad` stub packet 1
left behind gets its real `ScratchpadPersistence.listLegacyEntries` here. Revisit every
`// TODO(packet 1)` marker packet 6 shipped.

Packet 6's contribution to `AiPanel_iOS.swift` (the clear-conversation / undo / redo slice) lands
here, **after** packet 5's structure — as a `[MERGE]`, not a rebuild. It must not restructure the
file. On `AiStore.swift`, packet 6 takes **only its six named symbols**; do not diff-and-apply the
whole file.

**Sub-issue.** #135.

**Gate.** Full suite green, including `SafeClearTests` (packet 6's §4.4 adaptation, 2 tests
dropped, receiving the GC-cutoff test relocated out of `DocumentDataStoreTests` — a verbatim copy
would leave that test in both files) and the `is_pinned` case in `WebLibraryStorageTests`.

**Commits.** Packet 6's §2 order. `Models.swift` (pin fields, **1 → 4 → 6**, packet 6 last),
`PdfSessionBackend.swift` / `WebSessionBackend.swift` (**1 → 6 → 7**, packet 6 second) each get
their own commit.

---

## Stage F — viewers, toolbar, residency, find bar (the C3 chain)

**Contents, strictly in this order** — this is the rest of the chain Stage C opened:

1. **Packet 7 viewers + toolbar** — `PdfViewerController_iOS`, `WebViewerView_iOS`,
   `PdfChrome_iOS`, `WebNotePopovers`, `MathRenderer`, `PageTextExtractionGate`, the offline-copy
   semantics, and the Liquid Glass toolbar rebuild. Packet 7 fills in the no-op implementations
   Stage C shipped.
2. **Packet 4 §2.8** — `LiveTabHost_iOS` / tab residency in `PaneView_iOS.swift`. This is the
   section that "cannot land" without the viewers; now it can.
3. **Packet 7 §2.9** — `FindBar.swift`. Last link. It needs `AppStore.findQuery` +
   `PdfTab.findQuery` from step 2. Packet 4 also holds a `[MERGE]` claim on `FindBar.swift`; land
   packet 4's hunk first, then packet 7's on top (**order 4 → 7**).

Also in this stage: the rest of **packet 4** (§2.1–2.7, §2.10–2.13, §2.15) and **packet 4 §2.14**,
the document-actions sub-scope — `TabTeardownRegistry` hunks in `WorkspaceStore` / `AppStore` /
`PaneTree`, the close half of #113, and Save As state. That work had no owner at all until packet
10 §3.2 assigned it; land §2.14 **before** §2.2's `teardowns:` parameter and before §2.12.5's
`Rename…` menu item.

**Sub-issues.** #136 (packet 7), #133 (packet 4 §2.8 + §2.14 + the rest of packet 4).

**Gate.** Full suite green **after each of the three chain steps**, not just at the end — the
whole point of the chain is that each step compiles only after the one before it.
`Tests/DocumentActionsTests.swift` lands after §2.14. Packet 7's 14 web-dismissal cases land as a
**new file, `Tests/WebNoteDraftTests.swift`** (not in `delta-files.txt`, so it needs no claim).
Device check: open a 400-page scanned PDF and confirm the toolbar and scroll stay responsive
through the text walk, and verify ink does not alias across two inked PDFs in live tabs.

**Commits.** One per chain step, minimum. §2.14 splits into two: the registry (items 1–3,
mechanical, three files) and the close path + Save As (behavioural).

**Dropped here by decision** (packet 10 §3.3): `Vellum/App/SheetPresenceMonitor.swift` and
`Tests/SheetPresenceTests.swift`. iOS has no attached sheets and therefore no menu-bar-disabling
contract to preserve. The replacement is packet 4's own `SheetPresence_iOS` gate (consulted by the
iPad shortcut router, with `.dismiss` handled by dismissing `topPresented`) plus a new iOS test,
`Tests/SheetPresenceIOSTests.swift`.

---

## Stage G — home & onboarding (packet 3)

**Contents.** Packet 3 in full: the search core, content data, Home rebuild, walkthrough and help.

**Sub-issue.** #132.

**Gate.** Full suite green, including `HomeSearchStoreTests` (packet 3 drops the `HomeSourceTests`
suite — the read-later seam does not exist on iPad until Stage I), `SettingsNavigationTests`
(packet 3 drops the updateChecker test; no Sparkle on iPad) and `WalkthroughLayoutTests`
(`NSHostingView` → `UIHostingController`).

**Commits.** Packet 3's phases A → B → C → D.

**`SettingsView.swift` opens here.** It is a four-packet file; each hunk is <10 lines in the
`TabView`. **Land 3 → 1 → 5 → 8.** Packet 3 goes **first** — it restructures the `TabView` to
`$workspace.settingsSection`. If Stages B and D have already shipped their tabs, expect a
mechanical conflict and resolve it in packet 3's favour on the structure.

---

## Stage H — `.vellum` bundles (packet 2)

**Contents.** Packet 2 in full. It sits behind packets 1, 5 and 6, which is why it lands this late
despite being phase 2.

`AppStore.swift`: packet 2 is the **last** of the three MERGE owners (**1 → 4 → 2**). The
`nonisolated(unsafe)` removals in `WebArchive.swift` are **not** packet 2's — they moved to packet
9 §3.5. Packet 2 keeps only the two `MiniZip` pre-parse accessors. Packet 2's cosmetic copy of
main's macOS `Info.plist` is **dropped** entirely.

**Sub-issue.** #131.

**Gate.** Full suite green, including `VellumBundleTests` with packet 2's 3 iOS adaptations. Device
check: open a `.vellum` file from Files.app and round-trip an export with notes.

**Commits.** Packet 2's Step 0 → Step 9.

---

## Stage I — read-later integrations (packet 8)

**Contents.** Packet 8 in full, minus `Theme.swift` (already landed in Stage B).

Packet 8's D1 stopgap keychain shim **must not ship** — packet 9's real `KeychainStore` landed in
Stage A and is the fix. Packet 8 hands its `project.yml` hunk to packet 9 rather than editing the
file. `SettingsView.swift`: packet 8 goes **last** (3 → 1 → 5 → **8**).

**Sub-issue.** #137.

**Gate.** Full suite green, including `Tests/Integrations/**` (the only part of `Tests/` packet 9
does not own). Device check: connect and disconnect a Readwise and a Raindrop account and confirm
the credential survives a cold launch.

**Commits.** Packet 8's Stage 0 → Stage 8.

---

## Stage J — trailing test suites + final QA

**Contents.**

* **Packet 9 Stages 1–4** for anything that did not land alongside its feature packet — defaults
  isolation, the keychain vault suite, the nine modified suites, the new feature suites.
* **Packet 9 Stage 5** — the remaining plist and build-settings work.
* A sweep of every `// TODO(packet N)` marker left behind by the stub-based cycle breaks in
  Stages B and E. None should survive Stage J.
* Final QA against #138.

**Sub-issue.** #138.

**Gate.** Full suite green on iPad Pro 13-inch (M5), **plus** a clean-build run from a fresh
derived-data directory, **plus** the on-device passes each stage deferred. Confirm no suite was
silently skipped: compare the test count against the sum of the per-stage gates.

**Commits.** One per suite group. The final commit is the parity sign-off.

**Not in scope for #138 — recorded so it is not re-litigated:**

* **`SWIFT_TREAT_WARNINGS_AS_ERRORS` is not adopted in #129** (packet 9 §3.5). The iPad tree never
  had main's #86 warning-cleanup pass. Packet 9 takes the orphaned `nonisolated(unsafe)` removals
  in `WebPageExtractor.swift` and `WebArchive.swift`; the flag itself is a **separate follow-up
  issue** — file it, reference packet 9 §3.5 from it, and do not open a repo-wide sweep inside #129.
* `SheetPresenceMonitor.swift` and `Tests/SheetPresenceTests.swift` — dropped (Stage F).
* The AppKit drag/drop harness (`SidebarDropCatcher.swift`, `SidebarDropRoutingTests`,
  `ScratchpadDropRegistrationTests`) — the iPad keeps its iOS-native drop rebuild.
* The macOS XCUITest target and `Vellum.xcodeproj/project.pbxproj` — the iPad regenerates its own.

---

## Dependency summary

```
A  packet 9 Stage 0 ─────────────────────────────► everything
│
├─ B  packet 1 (+ Theme.swift)  ── breaks C1, C2
│  │
│  ├─ C  packet 4 §2.0 (interface only) ── breaks C3
│  │  │
│  │  └─ F1 packet 7 viewers ─► F2 packet 4 §2.8 ─► F3 packet 7 §2.9
│  │
│  ├─ D  packet 5 (incl. §I) ──► unblocks H, and packet 9's markdown suites
│  │  │
│  │  └─ E  packet 6 ── closes C1's stubs
│  │
│  ├─ G  packet 3
│  ├─ H  packet 2        (behind 1, 5, 6)
│  └─ I  packet 8        (behind A, B)
│
└─ J  packet 9 Stages 1–5 + QA (#138)
```
