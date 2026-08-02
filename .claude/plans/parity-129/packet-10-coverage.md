# Packet 10 — Coverage audit of packets 1–9 (issue #129)

Inputs: `delta-files.txt` (214 paths, range `a42705d1~1..7742a895`) and the `§1 Delta files claimed`
sections of `packet-1`…`packet-9`. Delta inspected in `/Users/ayushdeolasee/Developer/Vellum/main`;
current-state checks against `/Users/ayushdeolasee/Developer/Vellum/ipad-app`.

## 0. Headline numbers

| metric | count |
|---|---|
| delta paths | 214 |
| paths named by at least one packet | 213 |
| paths named by **no** packet | **1** (`Vellum/Views/Shared/Theme.swift`) |
| paths where **every** claim is `[SKIP]` (i.e. no packet owns the work) | **34** |
| **effective orphans** (1 + 34) | **35** |
| of those, legitimate skips (docs / plans / CI / macOS-only tooling / already-done) | 29 |
| of those, **real gaps** needing an owner | **6** |
| paths claimed by ≥2 packets with *different* tags | 85 |
| paths claimed by ≥2 packets with the *same* tag (sequencing only) | 41 |

The literal "unclaimed" number (1) is misleading. The number that matters is **35 orphans**, of which
**6 are real work nobody owns** — and 3 of those 6 will hard-break a build that a packet has already
committed to.

---

## 1. Orphans and recommendations

### 1.1 Real gaps — assign an owner (6)

| file | Δ | recommended owner + tag | why |
|---|---|---|---|
| `Vellum/Views/Shared/Theme.swift` | +3 | **packet 8, [MERGE]** | The only delta file **no packet mentions at all**. The diff adds `ThemePalette.success` (light `#2f7d46` / dark `#5bbf77`). Its sole consumer in main is `Vellum/Views/Shared/FloatingNotice.swift:49` (`isSuccess ? palette.success : palette.destructive`) — which **packet 8 claims [VERBATIM]**. Packet 8's own §5 D3 names it (`palette.success` … "theme packet") and packet 9's Appendix A files it under a "shared-UI packet". **Neither exists.** Packet 8 cannot compile without this 3-line merge. Trivial, additive, no AppKit. |
| `Vellum/Views/AI/InlineMarkdown.swift` | +104 (A) | **packet 5, [VERBATIM]** | Pure Foundation + `AttributedString`; zero AppKit. Packet 5 defers it to a "markdown/math/text-selection packet" that was never cut. Packet 9 ports `Tests/AiMarkdownRenderingTests.swift` [REBUILD] and packet 7 explicitly records that those cases "need `InlineMarkdown` (a NEW file from the AI packet)". Nobody adds the file. |
| `Vellum/Views/AI/MarkdownMessage.swift` | +211/−56 | **packet 5, [MERGE]** | Live (not `#if os(macOS)`) on iPad and it is where `MarkdownParser` / `MarkdownBlock` live. The delta replaces `case unordered([String])` / `case ordered([String])` with `case list([MarkdownListItem])` + a nested-depth `MarkdownListItem` struct. **This is a compile-breaking dependency for packet 9**, which tags `Tests/MarkdownParserTests.swift` [VERBATIM] on the grounds that iPad's copy is byte-identical to base — but main's new `testLists` asserts `.list([MarkdownListItem(depth:marker:text:)])` and will not compile against iPad's `MarkdownParser`. Packet 7 also merges 11 `#127` cases into the same test file. Body is SwiftUI-only; safe to merge. |
| `Vellum/Views/AI/SelectableMessageText.swift` | +417/−58 | **packet 5, [REBUILD]** | main's file is AppKit (`NSTextView`, `NSDraggingInfo`, `NSTextAttachment`); iPad already ships a UIKit rewrite (`import SwiftUI / import UIKit`). The delta's substance — `AttachmentText`, `fittedAttachments(in:width:)`, `measureSize`, `mathMaxWidth` plumbing, the new `attributedString(for:…)` signature — is layout logic that the iPad renderer needs too. Packet 9 tags `Tests/SelectableMessageTests.swift` [REBUILD] with no production owner. |
| `Vellum/Views/PDF/PdfOverlays.swift` | +5/−3 | **packet 5, [MERGE]** (apply to `Platform/iOS/RegionCaptureOverlay_iOS.swift`) | The macOS file is `#if os(macOS)` on iPad, so the file itself is dead — but the change is a call-site adaptation to packet 5's own model change: `PdfPageSnapshot.pageNumber` became optional, so `AiReference(kind: .region(image:page:))` needs `let page = snapshot.pageNumber`. Packet 7 SKIPs it as "region-capture/AI-references — AI packet"; packet 5 never picks it up. Two lines in the iOS overlay. |
| `Vellum/Services/Web/WebPageExtractor.swift` | +5/−5 | **packet 9, [MERGE]** (or explicit repo-wide SKIP) | The whole diff is `nonisolated(unsafe)` removals on `WebFetch.session` and four `WebHtml` regexes. Packet 7 SKIPs it to "the warnings packet"; packet 2 defers the identical removals in `WebArchive.swift` to "the warnings-free packet". **No warnings packet exists.** iPad still carries ≥20 `nonisolated(unsafe)` declarations across `WebLibrary`, `WebStorage`, `WebArchive`, `RecentFilesService`. Packet 9 owns `project.yml` and its own R4 already flags `SWIFT_TREAT_WARNINGS_AS_ERRORS` as a trap — the flag decision and these removals must be made by the same owner. If packet 9 declines the flag, downgrade this to SKIP and say so once, in one place. |

### 1.2 Legitimate skips (29) — no owner needed, reasons verified

* **Docs / CI (4):** `.github/workflows/claude.yml`, `AGENTS.md`, `CHANGELOG.md`, `CLAUDE.md`.
* **Plans (11):** `plans/001-…` … `plans/008-…` (8 deleted), `plans/README.md` (D), `plans/storage-design.html` (D), `plans/read-later-integrations.html` (A).
* **macOS XCUITest target (5):** `UITests/README-setup.md` (D), `UITests/README.md`, `UITests/ScratchpadSnapshotUITests.swift`, `UITests/VellumConsistencyUITests.swift`, `UITests/VellumUITestCase.swift`. iPad has no UI-test target.
* **macOS Xcode project (2):** `Vellum.xcodeproj/project.pbxproj`, `Vellum.xcodeproj/xcshareddata/xcschemes/VellumUITests.xcscheme`. iPad regenerates its pbxproj with xcodegen.
* **AppKit drag/drop harness (3):** `Vellum/Views/Shared/SidebarDropCatcher.swift` (A), `Tests/SidebarDropRoutingTests.swift`, `Tests/ScratchpadDropRegistrationTests.swift`. Standing decision: the iPad keeps its iOS-native drop rebuild. Packets 4, 5 and 9 all agree.
* **Already satisfied on iPad (2):** `Vellum/Services/Ai/SpeechService.swift` (D — iPad deleted it in `3ec11e25`), `Vellum/Services/Ai/AiImageAttachment.swift` (A — verified present in the iPad tree with the same `aiImageSnapshot(from:maxSide:)` contract, UIKit/ImageIO instead of AppKit).
* **macOS-gated PDF hosts, work routed to iOS counterparts (2):** `Vellum/Views/PDF/PdfViewerView.swift` (packets 1/4/7 each route their hunks into `Platform/iOS/PdfViewerView_iOS.swift`) and `Vellum/Views/PDF/PdfKitView.swift` (the `isActive` / `isActiveMount` / retained-`PDFView` work is covered by packet 4 §2.x "Cross-packet contract for the PDF/Web packets", which names `PdfKitView_iOS.makeUIView` explicitly). Skips are sound **only because** those contracts exist — do not delete them.

**Recommended tag totals for the 35 orphans: VERBATIM 1, MERGE 4, REBUILD 1, SKIP 29.**

---

## 2. Conflicts

### 2.1 Systemic — the `Tests/` double-ownership (≈30 files)

Packet 9 §0 declares it owns "**the entire `Tests/` tree except `Tests/Integrations/**`**", one owner
because "the test bundle is a single compile unit". Packets 1, 3, 4, 5, 6 and 7 also claim individual
test files, usually with a *different* tag. Packet 9 almost always says `[VERBATIM]`; the feature
packet says `[MERGE]` **and specifies deletions that packet 9's verbatim copy would undo**:

| test file | packet 9 | feature packet | why verbatim is wrong |
|---|---|---|---|
| `Tests/StorageManagementTests.swift` | VERBATIM | 1: MERGE — "drop the two Integrations tests" | verbatim references `Tests/Integrations` types that do not exist until packet 8 |
| `Tests/HomeSearchStoreTests.swift` | VERBATIM | 3: MERGE — "drop `HomeSourceTests` suite" | read-later seam is deleted on iPad until packet 8 |
| `Tests/DocumentDataStoreTests.swift` | VERBATIM | 1: MERGE (needs ScratchpadPersistence v2); 6: SKIP with one test relocated to `SafeClearTests` | verbatim + relocation = duplicate test |
| `Tests/DocumentIdentityTests.swift` | VERBATIM | 1: MERGE — "adapts to `PdfFileGate` stamping" | iPad keeps `PdfFileGate`, main uses `PdfDocumentIO` |
| `Tests/MarkdownParserTests.swift` | VERBATIM | 7: MERGE (11 `#127` cases) | see §1.1 — verbatim does not compile at all |
| `Tests/PageTextCacheTests.swift` | VERBATIM | 1: MERGE (docId re-key) | |
| `Tests/SettingsNavigationTests.swift` | VERBATIM | 3: MERGE — "drop the updateChecker test" | no Sparkle/updater on iPad |
| `Tests/SafeClearTests.swift` | VERBATIM | 6: MERGE (§4.4 adaptation, 2 tests dropped) | |
| `Tests/VellumBundleTests.swift` | VERBATIM | 2: MERGE (3 iOS adaptations) | |
| `Tests/WebLibraryStorageTests.swift` | VERBATIM | 6: MERGE (+1 `is_pinned` test); 7: MERGE (+1 offline test) | |
| `Tests/TabResidencyTests.swift`, `PaneTreeTests.swift`, `InspectorPresentationTests.swift` | VERBATIM | 4: MERGE | |
| `Tests/AiConversationStoreTests.swift`, `AiReferencePersistenceTests.swift`, `AiTranscriptFollowTests.swift` | VERBATIM | 5: MERGE | |
| `Tests/WebProxyUrlTests.swift` | VERBATIM | 7: MERGE (one-line `@MainActor`) | |
| `Tests/WalkthroughLayoutTests.swift` | REBUILD | 3: MERGE (`NSHostingView`→`UIHostingController`) | same intent, different word |

**Resolution.** Keep packet 9 as the *file owner* (it creates, adapts and sequences the file, and owns
`project.yml`'s test sources), but **downgrade every packet-9 `[VERBATIM]` above to `[MERGE — content
per <feature packet> §N]`**. The feature packet supplies the adaptation list; packet 9 applies it. The
literal rule: *packet 9 is the only packet that writes into `Tests/`; every other packet's test claim
is a specification, not an edit.* Add that sentence to packet 9 §0 and to each feature packet's §4.

Three-way test conflicts needing an explicit call:

* `Tests/AiAddAsNoteTests.swift` — 5: MERGE, 7: REBUILD *(→ a new `Tests/WebNoteDraftTests.swift`, "the 14 web-dismissal cases only")*, 9: VERBATIM. **Resolve:** packet 9 creates the file with packet 5's content; packet 7's 14 cases go to its own new file (which is not in `delta-files.txt`, so it needs no claim). Nobody ports it twice.
* `Tests/AiMarkdownRenderingTests.swift` — 5: SKIP, 7: SKIP, 9: REBUILD. Single owner (9), but **blocked on gap §1.1 `InlineMarkdown.swift`**. Do not start it before packet 5 lands the file.
* `Tests/SheetPresenceTests.swift` — 4: REBUILD, 9: SKIP ("macOS-only: asserts `NSWindow.willBeginSheetNotification` / `attachedSheet`"). Packet 9's Appendix A also suggests dropping `SheetPresenceMonitor.swift` outright. **Resolve in favour of packet 9 (SKIP)** unless packet 4 can show a UIKit equivalent of the attached-sheet contract; if packet 4 keeps `SheetPresenceMonitor` [REBUILD], it must also own the test.
* `Tests/UITestLaunchConfigurationTests.swift` / `Vellum/App/UITestLaunchConfiguration.swift` — 4: SKIP, 9: REBUILD. No conflict; packet 9 owns.
* `Tests/KeychainStoreTests.swift` + `Vellum/Services/KeychainStore.swift` — 8: SKIP, 9: VERBATIM. No conflict; packet 9 owns. Packet 8's D1 stopgap shim must **not** be shipped on top (packet 9 §5 says the same).

### 2.2 Genuine tag conflicts on production files

| file | claims | resolution |
|---|---|---|
| `Vellum/Views/AI/AiPanel.swift` | 5: **VERBATIM**, 6: **REBUILD** | Not actually contradictory but written as if it were. The iPad file is `#if os(macOS)`-wrapped (lines 1 and 344), so packet 5's "copy main's content, re-apply the wrapper" is right for the dead file; packet 6's REBUILD target is `Platform/iOS/AiPanel_iOS.swift` (clear-conversation slice). **Owner: packet 5** for both `AiPanel.swift` and the structure of `AiPanel_iOS.swift`; packet 6 contributes the clear/undo/redo slice *after* packet 5. Re-tag packet 6's row as `[MERGE into AiPanel_iOS.swift, after packet 5]`. |
| `Vellum/App/VellumApp.swift` | 1: SKIP, 2: **REBUILD**, 3: **MERGE**, 4: **MERGE** | macOS-gated dead file; all four route hunks into `Platform/iOS/VellumApp_iOS.swift`. Three different tags for the same treatment. **Normalise to `[REBUILD → VellumApp_iOS.swift]` in all three**, and name a single sequencer (packet 4, which touches it most). |
| `Vellum/App/ContentView.swift` | 2: **REBUILD**, 4: **MERGE**, 7: SKIP | Same shape. Normalise to `[REBUILD → ContentView_iOS.swift]`; sequence packet 4 → packet 2. |
| `Vellum/Views/Panes/PaneView.swift` | 1: SKIP, 2: **REBUILD**, 4: **MERGE** | Same shape → `[REBUILD → PaneView_iOS.swift]`; packet 4 owns the file, packets 1 and 2 add one observer each. |
| `Vellum/Resources/Info.plist` | 1: SKIP, 2: **VERBATIM**, 9: **MERGE** | Direct conflict. Packet 2 wants to copy main's macOS plist wholesale "to keep the trees comparable"; packet 9 wants to merge the live changes into `Info-iOS.plist`. **Packet 9 owns.** Packet 2's cosmetic copy is a needless write to a file excluded from the iOS target (`project.yml` `excludes: Resources/Info.plist`) — drop it. |
| `.gitignore` | 2: SKIP, 9: **MERGE** | Packet 9 owns. |
| `project.yml` | 1: MERGE, 2: SKIP, 4: SKIP, 6: SKIP, 8: **MERGE**, 9: **MERGE** | Three MERGE owners on a file that xcodegen re-reads for every target. **Packet 9 is sole editor**; packets 1 and 8 hand it their hunks (packet 8's `VellumTests` sources/excludes + `Tests/Integrations/Fixtures` resource wiring — packet 9 §D4 already flags the same fixtures hunk as shared). One `xcodegen generate` per landing, not five. |
| `Vellum/Views/Settings/StorageSettingsTab.swift` | 1: **REBUILD**, 2: SKIP, 5: SKIP | No conflict; packet 1 owns. |
| `Vellum/Views/Settings/IntegrationsSettingsTab.swift`, `Connect/DisconnectServiceSheet.swift`, `ExternalLibraryList.swift`, `LibraryRowContent.swift`, `FloatingNotice.swift`, `ReadLaterSearchProvider.swift` | others SKIP, 8: VERBATIM/REBUILD | No conflict; packet 8 owns. `FloatingNotice.swift` is the one blocked by gap §1.1 (`Theme.swift`). |

### 2.3 Same tag, several owners — sequencing, not conflict (41 files)

The load-bearing ones, in the order they must be edited:

* `Vellum/Stores/AppStore.swift` — 1, 2, 4 all MERGE (58 KB diff in main). Order **1 → 4 → 2**. Packet 7's one addition (`restorePendingNote`) is a surgical insert after those.
* `Vellum/Models/Models.swift` — 1 (`DocumentInfo.docId`), 4 (`PdfTab` find/region fields), 6 (pin fields). Order **1 → 4 → 6**. Packet 1 already flags "preserve `CreateAnnotationInput.createdAt`".
* `Vellum/Services/Pdf/PdfSessionBackend.swift` and `Vellum/Services/Web/WebSessionBackend.swift` — 1, 6, 7 all MERGE. Order **1 → 6 → 7**. Note both files are *already dirty in the iPad worktree* (`git status`: `PdfSessionBackend.swift`, `WebSessionBackend.swift`, `Platform/iOS/PdfChrome_iOS.swift` modified) — commit or stash that work before the first packet starts, or the first merge will silently swallow it.
* `Vellum/Views/Settings/SettingsView.swift` — 1, 3, 5 (and packet 8 adds a tab). Four-packet file; each hunk is <10 lines in the `TabView`. Land **3 → 1 → 5 → 8** or accept a mechanical conflict.
* `Vellum/Stores/ScratchpadStore.swift` (2, 6), `Vellum/Services/Ai/AiPersistence.swift` (5, 6), `Vellum/Stores/AiStore.swift` (5, 6): packet 6 explicitly warns "do **not** diff-and-apply the whole file" for `AiStore` — take only the six named symbols.
* `Vellum/Models/PaneTree.swift` (4, 6), `Vellum/Views/Shared/FindBar.swift` (4, 7), `Vellum/App/VellumCommands.swift` (3, 4), `Vellum/Views/AI/RevealableSecureField.swift` (5, 8).

---

## 3. Cross-dependency check

### 3.1 Cycles

**C1 — packet 1 ↔ packet 6 (storage ↔ scratchpad).** Packet 1 §5 needs
`ScratchpadPersistence.listLegacyEntries` and the `.vellumDocumentDataDeleted` receiver from packet 6;
packet 6 §5.2 needs `DocumentDataStore` / `DocumentIdentity` / `DocumentInfo.docId` from packet 1.
**Mitigated on both sides** (packet 1 stubs `legacyScratchpad` to `[]` behind a TODO; packet 6 ships
"adapted forms" with `// TODO(storage packet)` markers). Break it at packet 1. Acceptable.

**C2 — packet 1 ↔ packet 5 (storage ↔ AI).** Packet 1 needs `AiPersistence`'s per-document
conversation storage; packet 5 §5.1 needs packet 1's `DocumentDataStore` + `AppStore.syncDocumentId`.
**Mitigated** (packet 5 lands §A–§D minus D.16, defers §E). Break at packet 1. Acceptable.

**C3 — packet 4 ↔ packet 7 (tabs/residency ↔ PDF/web viewers). NOT mitigated — fix this.**
Packet 4 D1: `LiveTabRuntime` holds `PdfViewerControlleriOS` / the retained `PDFView`, "**§2.8 cannot**"
land without the viewer packets. Packet 7 D2: background-tab restore "needs the panes/tab-residency
packet"; D3: "`FindBar` is **fully blocked** on the panes packet". Both sides declare themselves
blocked by the other, with no stub on either side. **Recommendation:** cut the contract out first —
land packet 4 §2.x's "Cross-packet contract for the PDF/Web packets" (the `isActiveMount` flag, the
`makeUIView` retained-view protocol, the `documentAttached()` callback) as a **standalone
interface-only commit** owned by packet 4, with no-op implementations. Then packet 7 fills the
viewers, then packet 4 §2.8 and packet 7 §2.9 (`FindBar`) land. Without this, C3 deadlocks two of the
three largest packets.

No other cycles. Packet 2 sits behind {1, 5, 6}; packet 3 behind {1, 4}; packet 8 behind {9, 1, 8-gap
theme}; packet 9 behind {1, 3} for its Stage 1/2 and behind every feature packet for Stage 4.

### 3.2 Missing prerequisites — packets that are depended upon but were never cut

| phantom packet | cited by | what it owns | consequence |
|---|---|---|---|
| **"markdown / math / text-selection packet"** | 5 §5.2 #2, 5 §1, 7 §1 | `InlineMarkdown.swift`, `MarkdownMessage.swift`, `SelectableMessageText.swift`, and by implication `Tests/AiMarkdownRenderingTests.swift`, `SelectableMessageTests.swift`, `MarkdownParserTests.swift` | **Worst gap.** ~730 delta lines unowned. Packet 9 will fail to compile `MarkdownParserTests` verbatim; packet 9's `AiMarkdownRenderingTests` REBUILD has no production type to test. → fold into packet 5 (§1.1). |
| **"theme / shared-UI packet"** | 8 §5 D3, 9 Appendix A | `Vellum/Views/Shared/Theme.swift` | Packet 8's `FloatingNotice.swift` [VERBATIM] does not compile. → fold into packet 8 (§1.1). |
| **"document-actions packet (#82/#113)"** | 4 §5 D3, 4 §2.2, 7 §5 D4, 9 §1.4 | `TabTeardownRegistry` (lives in `WorkspaceStore.swift` / `AppStore.swift` / `PaneTree.swift`), the close half of #113, Save As | Packet 4 defers it ("omit the `teardowns:` parameter entirely… `WorkspaceStore.tabTeardowns` is likewise deferred"), packet 7 defers the close half, packet 9 ports `Tests/DocumentActionsTests.swift` **[VERBATIM]** with the production dependency listed only as "document actions / Save As". The *files* are claimed (packet 4 MERGEs all three), but the *hunks* are explicitly disclaimed by every owner. → either assign #113 to packet 4 as a named sub-scope, or drop `DocumentActionsTests` from packet 9's Stage 4 and record the deferral. |
| **"warnings-free / warnings packet"** | 2 §1 (`WebArchive`), 7 §1 (`WebPageExtractor`, `WebLibrary`, `WebArchive`) | the `nonisolated(unsafe)` removals + `SWIFT_TREAT_WARNINGS_AS_ERRORS` | See §1.1 `WebPageExtractor.swift`. Packet 9 R4 already calls the flag "a trap". → give the flag *and* the removals to packet 9, or write one explicit "iPad does not adopt warnings-as-errors in #129" decision and stop citing a packet that doesn't exist. |

### 3.3 Naming drift to fix before handing packets to implementers

* Packet 5 §5.1 calls the storage packet "**Packet 2**" — it means **packet 1**. An implementer reading
  packet 5 in isolation will block on the bundles packet.
* Packets refer to owners by role ("foundation packet", "keychain packet", "AppDefaults packet",
  "recents/home packet", "panes packet", "PDF-persistence packet", "shared-chrome packet") rather than
  by number. Several of those roles map to a packet (foundation/AppDefaults/keychain → 1 or 9;
  panes → 4; shared-chrome → 4) and four map to nothing (§3.2). Do one pass replacing every role name
  with `packet N`, and the phantom-packet problem becomes self-evident at read time.
* `Vellum/App/SheetPresenceMonitor.swift` is claimed [REBUILD] by packet 4 while packet 9's Appendix A
  says "if no packet claims it, drop it". Packet 4 does claim it — packet 9's note is stale; either
  delete the note or drop both the monitor and its test (recommended: drop both, iOS has no attached
  sheets and therefore no menu-bar-disabling contract to preserve).

---

## 4. Suggested landing order (accounting for C1–C3 and the gaps)

1. **packet 9 Stage 0** (`project.yml` test sources, `KeychainStore`, `TestEnvironment`, `.gitignore`, `Info-iOS.plist`) — everything else needs the test bundle to build.
2. **packet 1** (storage foundations; break C1/C2 with its documented stubs) — **plus `Theme.swift`** if packet 8 is going to run early.
3. **packet 4 interface-only commit** (the PDF/Web cross-packet contract) — breaks C3.
4. **packet 5** (AI) — **plus the 4 markdown files from §1.1**; unblocks packet 2 and packet 9 Stage 4.
5. **packet 6** (annotations/scratchpad) — closes C1's stubs.
6. **packet 7** (viewers/toolbar) → **packet 4 §2.8** (residency) → packet 7 §2.9 (`FindBar`).
7. **packet 3** (home/onboarding), **packet 2** (bundles), **packet 8** (integrations).
8. **packet 9 Stages 1–4** trailing each feature packet, revisiting every `// TODO(storage packet)` /
   `// TODO(markdown packet)` marker left behind.
