# Landing packet 2 (Stage H, #131) — integration points

Pre-baked in worktree `/Users/ayushdeolasee/Developer/Vellum/.bare/.claude/worktrees/wf_488625fb-334-2`,
branch `worktree-wf_488625fb-334-2`, commits `6e6be0e6..26ef85f5` (10 commits) on base
`4fbce459` (Stage E complete).

> The worktree was originally cut from `main` (`7742a895`). It was reset to `4fbce459`
> before any work started — same correction the Stage G and Stage I pre-bakes made.

**Landing slot: right after Stage F.** Cherry-pick the 10 commits onto `ipad-app`, then
work through §2 below.

---

## 1. Nothing is held back

Every hunk packet 2 specifies is applied in this worktree. There is no hunk that could
not be written because packet 4's or packet 7's context was missing — packet 2's shared-file
edits all sit in regions those packets do not restructure (checked against
`packet-4-tabs-inspector.md` and `packet-7-toolbar-web.md`, not assumed).

What follows is therefore a **conflict map**, not a to-do list of deferred work.

### Deviations from the packet, and why

| Packet step | What the packet says | What was done | Why |
|---|---|---|---|
| §2 (SessionService) | Append `Notification.Name.vellumDocumentSidecarImported` | **No-op — already present** | Landed with packet 1 in Stage B, byte-identical to main including the comment. No commit. |
| §3 (Info-iOS.plist) | Packet 9 applies it | **Applied here** | Stage A already did the `com.vellum.vellumweb` → `com.vellum.webarchive` rename and the `public.zip-archive` conformance. What remained is `CFBundleTypeRole: Editor` on all three types plus the `Vellum Bundle` type + `com.vellum.bundle` exported UTI. `DocumentImport.openableTypes` uses `UTType(exportedAs:)`, which **traps at runtime** if the identifier is not declared — so the plist edit cannot lag the Swift edit. |
| §4 (tests) | Packet 9 writes `Tests/` | **Applied here** | Same precedent as `b3b5aff1` (packet 1) and `0262788b` (packet 5) and `4fbce459` (packet 6): the suite lands in the same commit range as its feature. |
| §9 (pretty `.vellumweb` names) | Verify only | **Verified, no code change** — see §4 below | |
| Step order | 0→9 | 0, 1, (2 no-op), 3, **§3 plist**, **5**, **4**, 6, 7, 8, tests | Step 5 (`DocumentImport.bundleDestination`) is a compile dependency of Step 4 (`importVellumBundle`), and the plist is a runtime dependency of Step 5. Reordered so **every commit builds** and the range is bisectable. |

---

## 2. Conflict map — expect drift in these five files after Stage F

Ordered by how likely a mechanical conflict is.

### 2.1 `Vellum/Platform/iOS/PdfChrome_iOS.swift` — HIGHEST RISK

Packet 7 rebuilds this file's toolbar (Stage F1, Liquid Glass) and packet 4 §2.11 adds the
inspector switcher; packet 4 §2.14 adds a `Rename…` item to the same More menu. Packet 2
contributes four separate hunks:

1. **State vars**, immediately after `@State private var exporting = false`:
   ```swift
   @State private var exportingBundle = false
   @State private var showExportBundle = false
   ```
   `exportingBundle` is deliberately a *separate* guard from the web-only `exporting`.

2. **The menu item**, in `moreMenu` after the `if isWeb { … Export a Copy… }` block and
   **before** `if !showZoomPod { … }`:
   ```swift
   if appStore.document != nil {
       Button { showExportBundle = true } label: {
           Label("Export with Notes…", systemImage: "arrow.up.doc")
       }
       .disabled(exportingBundle)
       .accessibilityIdentifier("toolbar.exportWithNotes")
   }
   ```
   **Ordering decision for the merge:** packet 4 §2.14's `Rename…` is a document-management
   action; keep it with `Save` / `Open File…` **above** the export pair. Export with Notes
   stays last in the export group. The accessibility identifier must stay
   `toolbar.exportWithNotes` (identical to main's) whatever the position.

3. **The sheet**, attached to the same view as the `showSettings` sheet, immediately after it.

4. **`startBundleExport` / `buildBundle` / `loadAttachments`**, inserted between
   `exportVellumweb()` and `slugifiedTitle()`, plus the new top-level
   `struct ExportBundleSheet_iOS` placed just before `DocumentKey_iOS`.

Packet 7's G4 note explicitly says `moreMenu`'s `Menu { … } label: { Image… }` shape is left
alone, so the item should re-anchor cleanly. If packet 7 has re-ordered the menu wholesale,
re-apply hunk 2 by meaning, not by line.

### 2.2 `Vellum/Stores/AppStore.swift` — edit order 1 → 4 → 2 (packet 2 last)

Packet 4's AppStore hunks are the **close** path (`teardowns:` init parameter, teardown
invocation in `closeTab` / `closeOtherTabs` / `closeTabsToRight`), LiveTabRuntime/residency,
`findQuery`, and Save As. Packet 2's are all on the **open** path and in a new
`// MARK: - .vellum import` section. Verified: packet 4 does **not** port main's
`awaitTeardowns(ofDocumentAt:)`, so `openDocumentFile` is uncontended.

Packet 2's three hunks:

- `openOneFile(path:)` gains the `.vellum` branch; **its previous body is renamed
  `openDocumentFile(path: String) async throws` unchanged**. If a later packet wants to add
  `awaitTeardowns` to the open path, it goes in `openDocumentFile`, not `openOneFile`.
- A new section between `openOneFile` and `adoptOpenedDocument`:
  `writeImportedDocument`, `finishImportedBundle`, `importVellumBundleCore`,
  `importVellumBundle` + `importVellumBundleShowingErrors`.
- Nothing else. `CreateAnnotationInput.createdAt`, `openFiles`, `adoptOpenedDocument` and the
  `vellumAnnotationsUpdated` post after a `.vellumweb` open are untouched.

Packet 7's `restorePendingNote` insert still comes **after** all three, as the packet says.

### 2.3 `Vellum/Platform/iOS/PaneView_iOS.swift` — packet 4 owns the file

Packet 2 adds **one** `.onReceive` observer, immediately after the `vellumAnnotationsUpdated`
one and before the `vellumDocumentDataDeleted` one (packet 1's). If packet 4 §2.8's residency
work restructured the body, re-attach it to whatever view now carries the
`vellumAnnotationsUpdated` observer.

Do **not** also add main's `vellumDocumentDataDeleted` observer from the same upstream diff —
that already landed with packet 1.

### 2.4 `Vellum/Platform/iOS/ContentView_iOS.swift` — sequence 4 → 2

Packet 4 §2.11 works on `PaneShell_iOS.inspectorPresented` (~line 154). Packet 2 rewrites the
`.vellumOpenFile` receiver (~line 65) to understand a `userInfo["paths"]` payload. Disjoint
regions; a clean apply is expected.

The two existing posters (`ShortcutRouter_iOS`, `PaneView_iOS`) must keep posting with
`object: nil` and **no** `userInfo` — that is what keeps ⌘O and "Open File…" hitting the
`else` branch. Do not "tidy" them into passing a payload.

### 2.5 `Vellum/Platform/iOS/VellumApp_iOS.swift` — packet 4 is the sequencer

Packet 4 §2.9 works on `flushOnBackground()`. Packet 2 adds `.onOpenURL { url in
handleIncomingFile(url) }` to the `WindowGroup` content (right after the existing `.task`)
and the `handleIncomingFile(_:)` method above `launchMaintenance()`. Disjoint.

Packet 3 also routes hunks here (Stage G, already landed by then) — check the modifier chain
for a three-way pileup on the `WindowGroup` content before assuming a clean apply.

### 2.6 `Vellum/Platform/iOS/DocumentPicker_iOS.swift` — one word

`private static func topViewController()` → `static func topViewController()`, so
`BundleImportPrompts_iOS` shares one definition of the scene walk instead of duplicating it.
If any packet has meanwhile moved this helper out of the coordinator, point
`BundleImportPrompts_iOS` at the new home (three call sites in that file).

---

## 3. `project.yml` — untouched, no flag needed

Verified: `git diff 4fbce459..HEAD -- project.yml` is empty. The two new sources
(`Vellum/Services/VellumBundle.swift`, `Vellum/Platform/iOS/BundleImportPrompts_iOS.swift`)
and `Tests/VellumBundleTests.swift` are picked up by the existing recursive
`sources: - path: Vellum` / `- path: Tests`. `xcodegen generate` was re-run and the
regenerated `project.pbxproj` is committed (+12 lines: three file refs).

Packet 9 keeps sole ownership of `project.yml`.

---

## 4. Step 9 verification result (no code change)

All three parity claims hold on the iPad tree — recorded here because the packet asks for a
recorded result rather than a commit:

1. `WebStorage.assignFileName` (`WebStorage.swift:330`) still title-derives via
   `sanitizedBaseName(title:url:)` and de-duplicates against both the index's taken set and
   `WebICloud.itemExists(at: archivesDir/candidate)`.
2. `PdfChrome_iOS.exportVellumweb`'s default filename is `"\(slugifiedTitle()).vellumweb"` —
   same as main's `ToolbarView.exportVellumweb`. Both are the lowercase-dashed slug, not the
   raw title; that is intentional parity.
3. The bundle's web `documentFile` is likewise `"\(slugifiedTitle()).vellumweb"`
   (`buildBundle`), so a bundle imported on a Mac produces the same name.

---

## 5. Gate at landing — what this pre-bake did NOT cover

- **Full suite.** Only targeted `-only-testing` runs happened here (189 tests / 14 suites,
  green on iPad mini A17 Pro `E99174FA-7420-4038-BD1C-0FCE3F4AC59E` — the iPad Pro 13-inch is
  owned by the main worktree). Stage H's gate is the full suite on iPad Pro 13-inch (M5).
- **Files-app device check, on a CLEAN INSTALL.** Delete the app from the device/simulator
  first: LaunchServices keeps the stale `com.vellum.vellumweb` registration (and has never
  seen `com.vellum.bundle`) until a delete + reinstall. Then: tap a `.vellum` in Files, and
  round-trip an export with notes.
- **`.onOpenURL` cold-launch ordering.** The buffer described in packet 2 Step 6
  (`pendingOpenPaths` on `VellumApp_iOS`, drained in `ContentView_iOS.onAppear`) was
  deliberately **not** added — SwiftUI delivers `onOpenURL` after the first body pass in
  practice. If a cold-launch Files open is observed to drop on device, add it then.
- **Mac ↔ iPad fixture round-trip.** Packet 2 risk 1 asks for a bundle exported from the Mac
  build and imported on the iPad, and vice versa. Not doable from this worktree; do it at
  landing. The codec file is byte-identical to `main:Vellum/Services/VellumBundle.swift`
  (verified with `git diff --no-index`), so the risk is low but the check is cheap.

---

## 6. Notes for the PR body

- **Import destination differs from macOS by design.** The Mac asks with an `NSSavePanel`;
  the iPad writes into `DocumentImport.libraryDirectory`. Re-importing the same bundle
  updates the existing library copy when the doc ids match, and creates a `"<name> 2.pdf"`
  otherwise. Web bundles also leave a `.vellumweb` in the library (the WebLibrary owns the
  real storage) — visible and deletable in Files thanks to `UIFileSharingEnabled`.
- **UTI rename needs a reinstall** (see §5).
- **One deliberate divergence in the export path:** `VellumBundle.write` runs in a detached
  task on iPad. It hashes and deflates synchronously and `startBundleExport`'s `Task`
  inherits main-actor isolation, so a multi-hundred-MB bundle would otherwise freeze the UI
  for the whole zip. Main has the same latent issue on hardware where it is less noticeable.
  Output bytes are unaffected.
