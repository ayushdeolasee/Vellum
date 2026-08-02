# Packet 3 — Home & Onboarding (parity phase 3, issue #132)

Source of truth: macOS worktree `/Users/ayushdeolasee/Developer/Vellum/main`, delta range
`a42705d1~1..7742a895`.
Target: iPad worktree `/Users/ayushdeolasee/Developer/Vellum/ipad-app` (branch `ipad-app`, iOS-only,
xcodegen from `project.yml`).

Everything below was read from the real diffs and the real iPad files. Paths are repo-relative to
each worktree root.

---

## Tag legend (used in §1)

| Tag | Meaning |
|---|---|
| `[VERBATIM]` | `cp` main's file into the iPad tree. Only import/availability tweaks, and any *mechanical* substitutions explicitly enumerated in §2. |
| `[MERGE]` | Real content surgery: an iPad counterpart exists (possibly under a different filename), or main's file must be copied and then have blocks deleted/rewritten. |
| `[REBUILD]` | AppKit-shaped UI. Re-derive the same behaviour with iOS-native idioms; do not copy the file. |
| `[SKIP: …]` | Out of this packet's scope. |

Two files in §1 are **shared with other packets** (`SettingsView.swift`, `VellumApp.swift`,
`VellumCommands.swift`). I claim only the hunks named in §2; the rest belongs to packets 5 (AI), 1 (storage),
8 (integrations) and 4 (shortcuts). Coordinate: land the other packets' hunks first, then apply mine
(mine are additive and small).

---

## 1. Delta files claimed

### Services / stores (pure Swift — adopt as-is)

```
A  Vellum/Services/Search/HomeSearchItem.swift          [VERBATIM]
A  Vellum/Services/Search/HomeSearchRanker.swift        [VERBATIM]
A  Vellum/Services/Search/HomeSearchEngine.swift        [VERBATIM]
A  Vellum/Services/Search/HomeSearchProvider.swift      [VERBATIM]  ⚠ one iOS default-closure change, §2.4
A  Vellum/Stores/HomeSearchStore.swift                  [MERGE]     read-later seam deleted until integrations lands, §2.5
A  Vellum/Services/WalkthroughSettings.swift            [VERBATIM]
A  Vellum/Services/DocumentRenameService.swift          [VERBATIM]  (PR #82 rename core)
A  Vellum/Services/Search/ReadLaterSearchProvider.swift [SKIP: read-later integrations (Readwise/Raindrop) — belongs to the packet 8; depends on ReadLaterItem/IntegrationsStore which do not exist on iPad]
```

### Content data (copy is the feature)

```
A  Vellum/Views/Help/WalkthroughContent.swift           [VERBATIM]  + enumerated platform-noun swaps, §2.6
A  Vellum/Views/Help/HelpTopic.swift                    [VERBATIM]  + enumerated platform-noun swaps, §2.7
```

### UI

```
M  Vellum/Views/Welcome/WelcomeScreen.swift             [REBUILD]   → Vellum/Platform/iOS/WelcomeScreen_iOS.swift, §2.8
A  Vellum/Views/Welcome/HomeResultViews.swift           [REBUILD]   → Vellum/Platform/iOS/HomeResultViews_iOS.swift, §2.9
A  Vellum/Views/Welcome/RenameDocumentSheet.swift       [REBUILD]   → Vellum/Platform/iOS/RenameDocumentSheet_iOS.swift, §2.10
A  Vellum/Views/Help/WalkthroughSheet.swift             [REBUILD]   → Vellum/Platform/iOS/WalkthroughSheet_iOS.swift, §2.11
A  Vellum/Views/Help/HelpCenterView.swift               [REBUILD]   → Vellum/Platform/iOS/HelpCenterView_iOS.swift, §2.12
M  Vellum/Views/Settings/SettingsView.swift             [MERGE]     ONLY the settingsSection routing hunk, §2.13
M  Vellum/App/VellumApp.swift                           [MERGE]     → Vellum/Platform/iOS/VellumApp_iOS.swift, ONLY first-run sheet sequencing, §2.14
M  Vellum/App/VellumCommands.swift                      [MERGE]     → KeyboardShortcuts_iOS + ShortcutRouter_iOS + VellumCommands_iOS, ONLY the Help group, §2.15
A  Vellum/Views/Welcome/ExternalLibraryList.swift       [SKIP: read-later integrations UI — packet 8]
A  Vellum/Views/Welcome/LibraryRowContent.swift         [SKIP: only consumer is ExternalLibraryList — packet 8]
M  Vellum/Views/Settings/StorageLocationChoiceSheet.swift [SKIP: the diff is WebStorageRelocator.Status/notification plumbing = packet 1. The two copy edits it also carries ("…highlights, notes, AI conversations, and reading positions…") should ride along with the packet 1's port. My packet only depends on this sheet's EXISTING presentation, which iPad already has.]
```

### Tests

```
A  Tests/HomeSearchRankerTests.swift                    [VERBATIM]
A  Tests/HomeSearchEngineTests.swift                    [VERBATIM]  (blocked on RecentDocument.docId + DocumentDataStore, §5)
A  Tests/HomeSearchStoreTests.swift                     [MERGE]     drop HomeSourceTests suite, §4.3
A  Tests/WalkthroughTests.swift                         [MERGE]     NSImage→UIImage, §4.4
A  Tests/WalkthroughLayoutTests.swift                   [MERGE]     NSHostingView→UIHostingController, §4.5
A  Tests/HelpCenterTests.swift                          [MERGE]     NSImage→UIImage, §4.6
A  Tests/SettingsNavigationTests.swift                  [MERGE]     drop the updateChecker test, §4.7
```

**Total claimed: 22 files** (7 verbatim, 7 merge, 5 rebuild, 3 skip).

---

## 2. Port order & instructions

Order matters. Do the phases in sequence; each compiles on its own.

### Phase A — search core (no UI)

#### 2.1 `Vellum/Services/Search/HomeSearchItem.swift` — VERBATIM

`cp main/Vellum/Services/Search/HomeSearchItem.swift → ipad-app/Vellum/Services/Search/HomeSearchItem.swift`

Pure Foundation. `import Foundation` only. No AppKit. Defines `HomeSearchSection`,
`HomeSearchTarget`, `HomeSearchBadges`, `HomeSearchHaystack`, `HomeSearchItem`,
`HomeSearchLinkDetector`, `HomeSearchDateLabel`, `HomeSearchText`. **No changes at all.**

Dependencies already present on iPad: `DocumentKind` (Models.swift). Nothing else.

`HomeSearchSection.readLater` stays even though iPad has no integrations — it is an unreachable
enum case, and keeping it means the ranker/engine/tests port byte-identically and the integrations
packet drops in later with zero edits here.

`HomeSearchLinkDetector.url(in:)` **is** the "URL detection as address bar" behaviour the iPad Home
rebuild needs — don't re-derive it in the view.

#### 2.2 `Vellum/Services/Search/HomeSearchRanker.swift` — VERBATIM

`cp` straight across. Pure Foundation. Defines `HomeSearchFilter`, `HomeSearchSortOrder`,
`HomeSearchResultSection`, `HomeSearchRanker`. **No changes.**

#### 2.3 `Vellum/Services/Search/HomeSearchEngine.swift` — VERBATIM

`cp` straight across. `actor HomeSearchEngine`. **No changes.**

Note `defaultProviders()` returns `[RecentDocumentsSearchProvider(), SavedWebpagesSearchProvider(),
LibraryDocumentsSearchProvider()]` — that list is correct for iPad as-is (the read-later provider was
never in it; `HomeSearchStore` appended it).

#### 2.4 `Vellum/Services/Search/HomeSearchProvider.swift` — VERBATIM + one iOS adaptation

`cp` across, then make exactly one change, in `RecentDocumentsSearchProvider`'s default arguments.

**Why.** On iPad, recents store an absolute path rooted in the app data container
(`…/Application/<UUID>/Documents/Documents/<name>`) and that UUID changes across reinstalls. The
iPad already solves this with `DocumentImport.resolveExistingPath(_:)`
(`Vellum/Platform/iOS/DocumentImport.swift:35`). If you ship main's defaults
(`FileManager.default.fileExists(atPath:)` + `RecentFilesService.resolvedPath`), every recent PDF
gets the `.missing` badge and `canRevealInFinder == false` after any reinstall. This is an
iPad-only behaviour that must survive.

Main (lines 64–76):

```swift
    init(
        load: @escaping @Sendable () -> [RecentDocument] = { RecentFilesService.getRecent() },
        resolvePath: @escaping @Sendable (RecentDocument) -> String = {
            RecentFilesService.resolvedPath(for: $0)
        },
        fileExists: @escaping @Sendable (String) -> Bool = {
            FileManager.default.fileExists(atPath: $0)
        }
    ) {
```

iPad — replace the two closures with `#if os(iOS)`-free versions (the target is iOS-only, so just
write the iOS bodies):

```swift
    init(
        load: @escaping @Sendable () -> [RecentDocument] = { RecentFilesService.getRecent() },
        // iPad: the container UUID in a stored path changes across reinstalls, so
        // fall back to the same-named file in the current library directory before
        // giving up. `RecentFilesService.resolvedPath` still runs first — it is the
        // docId-based re-resolve for a MOVED document (design §7) — and this only
        // rescues the path when that answer no longer exists on disk.
        resolvePath: @escaping @Sendable (RecentDocument) -> String = { entry in
            let byIdentity = RecentFilesService.resolvedPath(for: entry)
            guard entry.kind == .pdf else { return byIdentity }
            return DocumentImport.resolveExistingPath(byIdentity) ?? byIdentity
        },
        fileExists: @escaping @Sendable (String) -> Bool = {
            DocumentImport.resolveExistingPath($0) != nil
        }
    ) {
```

Everything else in the file (`SavedWebpagesSearchProvider`, `LibraryDocumentsSearchProvider`,
`HomeSearchItemBuilder`, the protocol) is **verbatim**.

`LibraryDocumentsSearchProvider` needs `DocumentDataStore` — see §5, cross-packet dependency D1. If
`DocumentDataStore` has not landed yet, do **not** stub it; land D1 first or this whole packet's
search corpus is only two of three sources.

#### 2.5 `Vellum/Stores/HomeSearchStore.swift` — MERGE (copy, then delete the read-later seam)

`cp` across, then make exactly these changes (only if the packet 8 has NOT landed;
if it has, take the file verbatim):

1. Delete the stored property and its doc comment:
   ```swift
   /// The read-later corpus the engine's provider snapshots. …
   private let readLaterSource: ReadLaterSearchSource
   ```
2. Replace the initialiser:
   ```swift
   // main
   init(engine: HomeSearchEngine? = nil) {
       let source = ReadLaterSearchSource()
       readLaterSource = source
       self.engine = engine ?? HomeSearchEngine(
           providers: HomeSearchEngine.defaultProviders()
               + [ReadLaterSearchProvider(source: source)])
   }
   // iPad
   /// Passing an engine (tests) skips the default providers entirely.
   /// A read-later provider is appended here once the packet 8 lands.
   init(engine: HomeSearchEngine? = nil) {
       self.engine = engine ?? HomeSearchEngine()
   }
   ```
3. Delete `func updateReadLater(_ items: [ReadLaterItem]) async`.

**Preserve everything else exactly**, in particular:
- `HomeSearchRemoval` (`.recent` / `.saved`, `requiresConfirmation`, `menuLabel`,
  `confirmationTitle(for:)`, `confirmationMessage`) — this IS the "confirmation for disk deletes"
  requirement.
- `HomeRecentRemovalTransaction`, `removeFromRecent`, `undoRecentRemoval`, `redoRecentRemoval` —
  the session-undo requirement.
- `canRename` returning `item.section != .readLater` (harmless and forward-compatible).
- `rename(_:to:)`, which calls `DocumentRenameService` (§2.16).
- `debounce = .milliseconds(120)`, `refreshKey`, `moveSelection`, `reconcileSelection`,
  `clearQuery`, `resetSearch`, `removalOptions(for:)`.

`removeFromSaved` calls `WebLibrary.removeSaved(rawUrl:)` — present on iPad. Good.

#### 2.16 `Vellum/Services/DocumentRenameService.swift` — VERBATIM

`cp` across. Pure Foundation, no platform code. Writes a title to up to three stores:
`DocumentDataStore.setTitle(forKey:title:)`, `WebLibrary.setTitle(rawUrl:title:)`,
`RecentFilesService.updateTitle(path:title:)`.

**This is the "rename without touching the file on disk" guarantee** — the whole file's header
comment explains why the on-disk filename is never touched. Do not "improve" it into an
`FileManager.moveItem`.

Blocked on cross-packet deps D1 (`DocumentDataStore`), D2 (`RecentFilesService.updateTitle`), D3
(`WebLibrary.setTitle`). See §5.

#### 2.17 `Vellum/Services/WalkthroughSettings.swift` — VERBATIM

`cp` across. `import Foundation`. Defines `Notification.Name.vellumShowWalkthrough` and the
`walkthrough.seen` defaults key.

**Byte-compatibility:** the defaults key is the literal string `"walkthrough.seen"`. Do not rename.

Note it reads `UserDefaults.standard`, not `AppDefaults.current`. Main left it that way on purpose
(the launch gate runs before any scoped domain exists) and `WalkthroughTests` asserts against
`UserDefaults.standard` directly. Keep as-is even after `AppDefaults` lands.

---

### Phase B — content data

#### 2.6 `Vellum/Views/Help/WalkthroughContent.swift` — VERBATIM + enumerated noun swaps

`cp` across. `import Foundation` only. Defines `WalkthroughPoint`, `WalkthroughPage`,
`WalkthroughPage.all` (6 pages: welcome / annotate / notes / connect / assistant / storage).

Standing decision says settings/content verbatim, so **change nothing except these mechanical
substitutions** (shipping "this Mac" inside an iPad app is a bug, not a copy preference):

| Page | Original | iPad |
|---|---|---|
| `connect` summary | "nothing from your documents leaves this Mac until you do" | "…leaves this iPad until you do" |
| `storage` last point | "in a folder you choose, or only on this Mac." | "…or only on this iPad." |
| `notes` point 3 | "or drop in an image from Finder." | "or drop in an image from Files." |

Also revise the iPad-inaccurate shortcut claims (the iPad shortcut catalogue in
`Vellum/Platform/iOS/KeyboardShortcuts_iOS.swift` is the authority — check each before shipping):
- `welcome` point 2 shortcut `⌘\` (splitRight) — present on iPad, keep.
- `welcome` point 3 shortcut `⌘⌥S` (toggleInspector) — present on iPad, keep.
- `annotate` point 2 shortcut `"N"` — on macOS this is `ContentView`'s local `NSEvent` monitor. On
  iPad, `.toggleNoteMode` exists in the catalogue; verify its chord and use whatever the catalogue
  says. If iPad binds it differently, change the shortcut string, **not** the surrounding sentence.
- `annotate` points 3/4 `⌘D`, `⌘F` — present on iPad, keep.
- `welcome` point 1 `⌘O` — present on iPad, keep.

The last page's footnote says "Reopen this any time from Help ▸ Vellum Walkthrough… open Help ▸
Vellum Help (⌘?)". On iPad there is no menu bar unless a hardware keyboard is attached, but there
IS the ⌘-hold HUD / iPadOS 26 menu bar. Reword to name both routes:

> "Reopen this any time from the Help menu, or the ? button on the Home screen. For a searchable
> list of every feature and shortcut, open Help ▸ Vellum Help (⌘?)."

**Test constraints on this copy** (`Tests/WalkthroughTests.swift` — port it, so these must keep
passing):
- last page id must be `"storage"`;
- exactly the last page has a non-nil `footnote`, all others nil;
- every page: non-empty title/summary, **3–5** points, unique point texts;
- storage page must contain a point with the substring `"six months"` and one with
  `"Settings ▸ Storage"`;
- the "Kept indefinitely" point must NOT contain "conversation" or "Only you delete";
- the footnote must contain `"Vellum Help"` (asserted by `HelpCenterTests`);
- every `symbol` must resolve as an SF Symbol (adapted to `UIImage`, §4.4).

#### 2.7 `Vellum/Views/Help/HelpTopic.swift` — VERBATIM + enumerated noun swaps

`cp` across. `import Foundation`. 22 topics + `HelpTopic.search(_:)` (AND-of-terms, case-insensitive,
empty query returns everything).

Mechanical substitutions only:

| Topic id | Original | iPad |
|---|---|---|
| `storage-location` | "iCloud Drive, a folder you choose, or this Mac only." | "…or this iPad only." |
| `switch-tabs` | keep as-is | verify `⌘1–⌘9` / `⌘⇧[` / `⌘⇧]` against `KeyboardShortcuts_iOS`'s catalogue; the iPad has `showTab(Int)`, `previousTab`, `nextTab`. |
| `note-mode` | "Press N to enter note mode, then click anywhere on the page." | "…then tap anywhere on the page." (and the chord per the iPad catalogue) |
| `highlight` | "Select text and choose a highlight from the popover" | keep (touch selection popover exists on iPad) |
| `open-pdf` | keep | keep |

Consider **adding** iPad-only topics later — Pencil ink + palette, scribble-to-erase, Pencil
double-tap, Safari-style zoom. That is a nice-to-have, NOT required by this packet, and every added
topic must satisfy `HelpTopicContentTests` (unique slug id, unique title, non-empty summary, no
"cmd"/"command"/"shift" spelled out in the shortcut string, symbol resolves).

**Test constraints** (`Tests/HelpCenterTests.swift`):
- `search("")` and `search("   ")` return the whole catalogue in order;
- `search("wraps around") == ["switch-tabs"]`, `search("⌘⌥S") == ["inspector"]`,
  `search("llm") == ["ai-setup"]`, `search("eviction") == ["retention"]`;
- `search("split").count > search("split down").count` and `search("split down") == ["split-down"]`;
- retention topic summary must contain `"six months"`, `"1, 3, 6 or 12 months"`, `"Never"`;
- ai-actions summary must contain `"jump to a page"`, `"add a note"`, `"highlight text"`;
- walkthrough topic summary must contain `"Vellum Walkthrough"`.

If you change `switch-tabs`'s prose, keep the phrase "wraps around". If you change `inspector`'s
shortcut, update that assertion in the ported test.

---

### Phase C — Home rebuild

#### 2.9 `Vellum/Views/Welcome/HomeResultViews.swift` → `Vellum/Platform/iOS/HomeResultViews_iOS.swift` — REBUILD

**What main added.** A new file of small view components:
- `enum HomeLayout` — `contentMaxWidth = 900`, `columnPadding = 24`, `rowInset = 16` — plus
  `View.homeContentColumn()`, so the header block and the list are the same column by construction.
- `HomeResultRow` — single-click-opens button; icon tile; title + `HomeBadgeStrip`; subtitle;
  right-aligned `detail` date column pinned with `.fixedSize(horizontal: true …)`; hover state;
  `.help(item.tooltip)`; `.selectionSurface(selected:hovering:in:palette:)`; context menu with
  Open / Rename… / Show in Finder / divider / one item per removal (`removal.menuLabel`,
  `role: .destructive`).
- `HomeBadgeStrip` — four badges in a fixed order: `.missing` (exclamationmark.triangle.fill, red),
  `.saved` (bookmark.fill, gold), `.offline` (arrow.down.circle.fill), `.notes` (note.text).
- `HomeLinkActionRow` — the pinned "Open this webpage" row with the trailing `Keycap("↩")`.
- `HomeSectionHeader` — uppercase, kerned, section glyph + title + count, painted on `palette.well`
  because it is used as a pinned header.
- `HomeFilterChip` — capsule chip using `SelectionStyle`.

**iPad counterpart today.** None. The iPad's `WelcomeScreen_iOS.swift` has a private
`RecentCard_iOS` grid card and nothing else.

**iOS rebuild instructions.**

1. Keep `HomeLayout` and `homeContentColumn()` **verbatim** — pure numbers, no platform code. Bump
   `contentMaxWidth` if you like, but 900 is right for a 13" iPad in landscape and matches the
   iPad's existing `WelcomeLibrary_iOS` `.frame(maxWidth: 900)`.
2. `HomeResultRow`:
   - drop `@State hovering` and `.onHover` entirely — replace the `selectionSurface(selected:
     hovering:…)` call with `selectionSurface(selected: isSelected, hovering: false, …)`. Touch has
     no hover; a `Button(action:)` with `.buttonStyle(.plain)` already gives the press highlight.
   - drop `.help(item.tooltip)` (no-op on iOS; it compiles, but remove it so the tooltip string is
     not silently dead — surface `item.tooltip` in the context menu preview instead if useful).
   - raise the row's minimum height to a touch target: add `.frame(minHeight: 52)` inside the
     padding chain (the iPad's existing list rows use 52pt via `defaultMinListRowHeight`).
   - keep `.accessibilityIdentifier("welcome.result")`, `.accessibilityLabel(item.title)`,
     `.accessibilityValue(item.subtitle)` verbatim.
   - **replace "Show in Finder"** — there is no Finder. Two options, pick one and be consistent:
     (a) drop the item entirely and drop the `reveal:` parameter; or (b) keep the parameter and
     render `ShareLink(item: URL(fileURLWithPath: path))` labelled "Share…". Recommended: (b) —
     it's the closest iPad analogue and keeps the `canRevealInFinder` field meaningful.
   - keep the `.contextMenu` — on iPad it is reached by long-press, which is the standard
     destructive-action affordance.
3. `HomeBadgeStrip` — verbatim except `.help(help)` → drop it, keep `.accessibilityLabel(help)`.
4. `HomeLinkActionRow` — verbatim except hover. Keep the `Keycap(keys: "↩")` (it is meaningful with
   a Magic Keyboard attached) but keep it `.accessibilityHidden(true)` as main does.
5. `HomeSectionHeader` — verbatim.
6. `HomeFilterChip` — verbatim except hover: pass `hovering: false`, drop `.onHover`. Add
   `.frame(minHeight: 32)` for the touch target (main's 26pt is mouse-sized).
7. `Keycap` is **not on iPad** — see cross-packet dependency D4 in §5. If the packet 4
   has not landed it, add it to `Vellum/Views/Shared/Controls.swift` yourself; the source is
   `main/Vellum/Views/Shared/Controls.swift:109-136`, pure SwiftUI, palette-driven, no AppKit.

File header: `#if os(iOS)` … `#endif`, `import SwiftUI`.

#### 2.8 `Vellum/Views/Welcome/WelcomeScreen.swift` → `Vellum/Platform/iOS/WelcomeScreen_iOS.swift` — REBUILD

This is the biggest piece. **Do not touch `ipad-app/Vellum/Views/Welcome/WelcomeScreen.swift`** —
that file is entirely wrapped in `#if os(macOS)` and is dead reference code on this branch.

**What main changed (PR #68 + #70 + #82 + #103 + integrations).** The old macOS screen was a `List`
of Recent/Saved built from `recentDocuments` + `savedPages`. The new one:

- Owns `@State private var store = HomeSearchStore()` and *no matching logic at all*.
- `body` = `VStack { homeHeader; Divider(); showsFirstRun ? firstRunLayout : libraryLayout }`.
- `showsFirstRun` = `!store.isLoading && store.libraryIsEmpty && !store.isSearching` (plus
  integrations terms). Crucially it waits for the first load rather than reading two arrays, so it
  can't flash "welcome" at someone with a full library.
- `.task { await store.load() }` and `.task(id: store.refreshKey) { await store.refresh() }` — the
  latter gives free debounce/cancellation on every keystroke.
- Reload on app foreground: `.onReceive(NSApplication.didBecomeActiveNotification) { Task { await store.load() } }`.
- `searchField` — capsule, magnifyingglass glyph, placeholder "Search your library — or paste a
  link", `.focused($searchFocused)`, `onKeyPress(.downArrow/.upArrow/.return/.escape)` driving
  `store.moveSelection(±1)` / `openSelection()` / `store.clearQuery()`; trailing `Keycap("⌘F")`
  when empty, else a clear button.
- `controlBar` — source switcher (integrations), then the four `HomeFilterChip`s
  (`HomeSearchFilter.allCases`), then either the "N results" count (while searching) or `sortMenu`.
- `resultList` — `ScrollViewReader` + `ScrollView` + `LazyVStack(pinnedViews: [.sectionHeaders])`:
  the pinned link row first, then `ForEach(store.sections)` with `HomeSectionHeader` headers and
  `HomeResultRow` rows, then `emptyResults`. `.onChange(of: store.selectedId) { proxy.scrollTo(id, anchor: .center) }`.
- `emptyResults` — two different messages (searching vs. filtered), one "Clear search" /
  "Search everything" button calling `store.resetSearch()`, and a `ForEach(store.failures)` warning
  list.
- `firstRunLayout` — hero + open controls + URL field + error banner + `walkthroughLink`.
- `homeHeader` (#70) — "Home" title, update affordances, and a **gear button that opens Settings**.
- Sheet + dialog plumbing: `.sheet(item: $renamingItem) { RenameDocumentSheet(...) }` and
  `.confirmationDialog(Text(confirmingTitle), …, presenting: confirmingRemoval)` for the destructive
  removal, with `confirmingTitle` held in separate `@State` so it doesn't blank mid-animation.
- `removalActions(for:)` → `performRemoval(_:from:)`: `.recent` removes synchronously, registers
  undo **before** `store.load()`, then reloads; `.saved` goes through
  `store.removeFromSaved` (which confirms first).
- Free functions `registerRecentRemovalUndo` / `registerRecentRemovalRedo` at file scope — each step
  registers its counterpart so ⌘Z/⇧⌘Z alternate, and a step reporting `false` ends the chain.
- `.onDisappear { undoManager?.removeAllActions(withTarget: store) }` — `registerUndo(withTarget:)`
  does not retain, and `store` is `@State` on a view that gets swapped out when a document opens.

**iPad counterpart today** (`Vellum/Platform/iOS/WelcomeScreen_iOS.swift`, 142 lines):
`WelcomeLibrary_iOS(onOpen:onAddWebpage:compact:)` — a `ScrollView` with a `Wordmark`, an
"AI-powered reading for iPad" subtitle, two big buttons, and a `LazyVGrid` of `RecentCard_iOS`
reading `RecentFilesService.getRecent()` directly. It is used from **two** places:
`ContentView_iOS.swift:141` (full-screen, nothing open) and `PaneView_iOS.swift:116`
(`compact: true`, as the content of a start tab).

**iPad rebuild — concrete instructions.**

Keep the public shape `WelcomeLibrary_iOS(onOpen:onAddWebpage:compact:)` so both call sites keep
compiling unchanged. Rewrite the body:

```swift
struct WelcomeLibrary_iOS: View {
    var onOpen: () -> Void
    var onAddWebpage: () -> Void
    var compact = false

    @Environment(AppStore.self) private var appStore
    @Environment(WorkspaceStore.self) private var workspace
    @Environment(\.palette) private var palette
    @Environment(\.undoManager) private var undoManager
    @Environment(\.scenePhase) private var scenePhase

    @State private var store = HomeSearchStore()
    @State private var renamingItem: HomeSearchItem?
    @State private var confirmingRemoval: PendingRemoval?
    @State private var confirmingTitle = ""
    @State private var showSettings = false
    @State private var showHelp = false
    @FocusState private var searchFocused: Bool
    …
}
```

Do this piece by piece:

1. **Ownership swap.** Delete `@State private var recents = RecentFilesService.getRecent()` and
   `RecentCard_iOS`'s direct reads. Everything comes from `store`.
2. **Lifecycle.** Add `.task { await store.load() }` and `.task(id: store.refreshKey) { await store.refresh() }`
   exactly as main. **Replace** main's `NSApplication.didBecomeActiveNotification` with:
   ```swift
   .onChange(of: scenePhase) { _, phase in
       guard phase == .active else { return }
       Task { await store.load() }
   }
   ```
   (Rationale identical to main's: the corpus is a snapshot of on-disk sources that a Files.app
   move, another pane, or the storage pane can invalidate while backgrounded.) Note `compact` start
   tabs: two start tabs in a split each own their own `HomeSearchStore`, which is fine — each does
   its own reload. If that shows up as battery drain in profiling, gate the scene-phase reload on
   `!compact`.
3. **Search field.** Rebuild as an iOS-native capsule (main's version is fine visually; the
   AppKit-shaped parts are the key handling):
   - `TextField("Search your library — or paste a link", text: $store.query)` with
     `.textFieldStyle(.plain)`, `.textInputAutocapitalization(.never)`, `.autocorrectionDisabled()`,
     `.submitLabel(.go)`, `.keyboardType(.webSearch)`, `.focused($searchFocused)`.
   - `.onSubmit { _ = openSelection() }` replaces main's `onKeyPress(.return)`.
   - `.onKeyPress(.downArrow/.upArrow/.escape)` **works on iOS 17+** and is what makes the Magic
     Keyboard path good — keep all three verbatim. `.onKeyPress(.return)` is redundant with
     `.onSubmit` but harmless; drop it.
   - Trailing: keep `Keycap(keys: "⌘F")` when `store.query.isEmpty` (meaningful with a keyboard) and
     the clear `IconButton` otherwise. Consider hiding the keycap when
     `GCKeyboard.coalesced == nil`; not required.
   - **Do not** auto-focus the field on appear. Main does (`onAppear { if isPaneFocused { searchFocused = true } }`)
     because focusing a Mac text field costs nothing. On iPad it summons the software keyboard over
     half the screen every time Home appears. Leave the field unfocused; ⌘F focuses it (step 9).
4. **Filter chips + sort.** `ForEach(HomeSearchFilter.allCases, id: \.self) { HomeFilterChip(...) }`
   verbatim, but drop the `focusSearchField()` call in the chip's action (it exists on macOS only to
   return first responder from the button; on iOS it would raise the keyboard). `sortMenu` is a
   plain `Menu` + inline `Picker` — works as-is; replace `.menuStyle(.borderlessButton)` with
   `.menuStyle(.button).buttonStyle(.plain)` (borderlessButton is macOS-only) and drop `.help(...)`.
   On a narrow (compact/split) pane, wrap the chip row in a horizontal `ScrollView` with
   `.scrollIndicators(.hidden)` so four chips + sort never clip.
5. **Result list.** Port `resultList` almost verbatim — `ScrollViewReader` + `ScrollView` +
   `LazyVStack(alignment: .leading, spacing: 0, pinnedViews: [.sectionHeaders])`, the pinned
   `HomeLinkActionRow`, `ForEach(store.sections) { Section { rows } header: { HomeSectionHeader } }`,
   the `emptyResults` fallback, `.homeContentColumn()`, and the
   `.onChange(of: store.selectedId) { proxy.scrollTo(id, anchor: .center) }`. All of that is
   cross-platform SwiftUI. Add `.scrollDismissesKeyboard(.interactively)`.
6. **Empty state.** `emptyResults` verbatim (it is `Text`/`Image`/`TextButton` only).
7. **First-run hero.** Keep the iPad's existing hero identity (`Wordmark(size: compact ? 40 : 60)`,
   the two big `TextButton`s wired to `onOpen`/`onAddWebpage`) rather than main's, because the iPad
   cannot show an `NSOpenPanel` and already routes opening through
   `DocumentPickerCoordinator_iOS`. Add to it:
   - the URL field from main's `urlControls` (iPad already has an `AddWebpageSheet_iOS`, so this is
     optional — prefer routing "Add Webpage" to the existing sheet and skipping the inline field);
   - main's `errorBanner` (verbatim, reads `appStore.error`);
   - main's `walkthroughLink` ("How Vellum works", `questionmark.circle`) posting
     `.vellumShowWalkthrough`.
   Gate it on the same `showsFirstRun` rule as main, minus the integrations terms:
   ```swift
   private var showsFirstRun: Bool {
       !store.isLoading && store.libraryIsEmpty && !store.isSearching
   }
   ```
8. **Home chrome (#70).** Port `homeHeader` but strip the update affordances — `UpdateChecker` is a
   Sparkle-style self-updater that is meaningless on the App Store, iPad's `WorkspaceStore` has no
   `updateChecker`, and adding one is out of scope. What survives:
   ```swift
   private var homeHeader: some View {
       HStack(spacing: 8) {
           Text("Home").font(.headline).foregroundStyle(palette.foreground)
           Spacer()
           Button { showHelp = true } label: {
               Label("Help", systemImage: "questionmark.circle").labelStyle(.iconOnly)
           }
           .accessibilityIdentifier("welcome.help")
           Button { workspace.settingsSection = .general; showSettings = true } label: {
               Label("Settings", systemImage: "gearshape").labelStyle(.iconOnly)
           }
           .accessibilityIdentifier("welcome.settings")
       }
       .padding(.horizontal, 16)
       .frame(height: 44)
       .background(palette.background)
   }
   ```
   `showSettings` presents the **same** sheet body `PdfChrome_iOS.swift:178-195` already uses
   (`NavigationStack { SettingsView().navigationTitle("Settings")… }` with the
   `workspace.settingsAi` / `openRouterCatalog` / `chatgptAuth` environments and
   `.presentationDetents([.large])`). **Extract that sheet body into one reusable view** —
   `SettingsSheet_iOS` in `Vellum/Platform/iOS/` — and have both `PdfChrome_iOS` and this screen
   present it, so the two can never drift. Setting `workspace.settingsSection` before presenting is
   what makes #70's "route Home to a specific tab" work (§2.13).

   `showHelp` presents `HelpCenterView_iOS` (§2.12).

   In `compact` mode (start tab inside a pane) the pane already has its own chrome — render
   `homeHeader` only when `!compact`, and keep the help/settings entry points reachable from the
   pane's existing more-menu.
9. **⌘F = "search my library".** Main installs a hidden `Button(…).keyboardShortcut("f", modifiers: .command)`
   in a `.background`. On iPad, ⌘F is already claimed by `.find` in the shortcut catalogue and routed
   by `VellumShortcutRouter` to `app.showFind()`, which no-ops when `app.document == nil`. Extend the
   router rather than adding a competing SwiftUI shortcut:
   ```swift
   // ShortcutRouter_iOS.swift, case .find:
   case .find:
       guard app.document != nil else {
           // Home is on screen: ⌘F means "search my library".
           NotificationCenter.default.post(name: .vellumFocusHomeSearch, object: nil)
           return
       }
       app.showFind()
   ```
   Declare `.vellumFocusHomeSearch` next to `.vellumShowWalkthrough` in `WalkthroughSettings.swift`
   or (better) alongside the other names in the iOS notification file, and in the Home screen:
   ```swift
   .onReceive(NotificationCenter.default.publisher(for: .vellumFocusHomeSearch)) { _ in
       searchFocused = true
   }
   ```
   Main's `isPaneFocused` guard and `.disabled(!isPaneFocused)` trick have no analogue here — the
   router already targets `workspace.focusedPane`, so route the notification with the focused pane's
   id in `object` and have the screen compare against its own pane id when `compact`.
10. **Rename (PR #82).** `.sheet(item: $renamingItem) { item in RenameDocumentSheet_iOS(currentTitle: item.title, fallbackName: item.subtitle) { newTitle in Task { await store.rename(item, to: newTitle) } } }`
    — identical wiring to main; only the sheet's layout differs (§2.10). Gate the context-menu item
    on `store.canRename(item)` exactly as main's `renameAction(for:)` does.
11. **Removals + confirmation + undo.** Port `PendingRemoval`, `removalActions(for:)`,
    `performRemoval(_:from:)`, `registerRecentRemovalUndo`, `registerRecentRemovalRedo` and the
    `.confirmationDialog` **verbatim**, including the separate `confirmingTitle` state. All of it is
    cross-platform (`UndoManager` and `\.undoManager` both exist on iOS; `confirmationDialog`
    renders as an action sheet / popover on iPad).
    - Keep `.onDisappear { undoManager?.removeAllActions(withTarget: store) }` — the reasoning is
      even stronger on iPad, where opening a document swaps the whole `WelcomeLibrary_iOS` out.
    - iPad has no menu-bar Edit ▸ Undo unless a keyboard is attached; the undo is still reachable
      via shake-to-undo and ⌘Z on a Magic Keyboard. **Add a `.recent`-removal toast** as the primary
      affordance: after `performRemoval(_:from:)` for `.recent`, show a transient banner
      "Removed from Recent — Undo" wired to `store.undoRecentRemoval(transaction)`. Use the same
      overlay position main uses for `readLaterNotice` (`.overlay(alignment: .bottomTrailing)`).
      This is the iPad-native equivalent of the Mac's Edit-menu undo and is required for the
      session-undo requirement to actually be reachable.
12. **Opening a result.** Port `open(_:)` minus the read-later branch, and route file opens through
    the iPad's container-aware resolver:
    ```swift
    private func open(_ item: HomeSearchItem) {
        guard !appStore.isLoading else { return }
        switch item.target {
        case .url(let url):
            Task { await appStore.openUrl(url) }
        case .file(let path, let recordedPath):
            if path != recordedPath { _ = RecentFilesService.remove(path: recordedPath) }
            let resolved = DocumentImport.resolveExistingPath(path) ?? path
            Task { await appStore.openFiles(paths: [resolved]) }
        }
    }
    ```
    Keep the `path != recordedPath → remove(path: recordedPath)` line — it is design §7's
    stale-duplicate guard and the reason `HomeSearchTarget.file` carries two paths.
13. **`openLink(_:)`** — verbatim (`store.query = ""`, then `appStore.openUrl(link)`).
14. **Delete** `RecentCard_iOS` and `LibraryItem`-style local models. All of that is now
    `HomeSearchItem` + `HomeResultRow`.
15. **Do not port**: `HomeSource`, `HomeSourceSwitcher`, `sourceStatus`, `syncLabel`,
    `readLaterNotice`, `ExternalLibraryList`, `openExternal`, `browsedProvider`,
    `hasConnectedLibrary`, the `integrations.searchRevision` task, the `connectedProviders`
    `onChange`. All integrations — the packet 8 re-adds them.
16. **Do not port** `openDocuments()` (`NSOpenPanel`). The iPad already has
    `DocumentPickerCoordinator_iOS` behind the `onOpen` closure.

Accessibility identifiers to keep verbatim so any future UI tests port cleanly:
`welcome.search`, `welcome.clearSearch`, `welcome.filter.<label>`, `welcome.resultCount`,
`welcome.sort`, `welcome.results`, `welcome.result`, `welcome.section`, `welcome.openLink`,
`welcome.emptyResults`, `welcome.resetSearch`, `welcome.openPdf`, `welcome.addWebpage`,
`welcome.urlField`, `welcome.openUrl`, `welcome.walkthrough`, `welcome.settings`.

#### 2.10 `Vellum/Views/Welcome/RenameDocumentSheet.swift` → `RenameDocumentSheet_iOS.swift` — REBUILD

**What main has.** A 380pt-wide `VStack` with a heading "Rename", the crucial subtitle *"Changes the
name shown in Vellum. The file on disk keeps its own name."*, a `.plain` `TextField` with a manual
rounded background, and three buttons: "Use original name" (clears the draft), "Cancel"
(`.cancelAction`), "Rename" (`.defaultAction`). `onAppear { draft = currentTitle; fieldFocused = true }`.

**iPad rebuild.** Same three inputs (`currentTitle`, `fallbackName`, `commit`), same semantics,
iOS-native chrome:

```swift
struct RenameDocumentSheet_iOS: View {
    let currentTitle: String
    let fallbackName: String
    let commit: (String) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var draft = ""
    @FocusState private var fieldFocused: Bool

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField(fallbackName, text: $draft)
                        .focused($fieldFocused)
                        .submitLabel(.done)
                        .onSubmit(save)
                        .accessibilityIdentifier("rename.field")
                    Button("Use original name") { draft = ""; fieldFocused = true }
                        .accessibilityIdentifier("rename.reset")
                } footer: {
                    Text("Changes the name shown in Vellum. The file on disk keeps its own name.")
                }
            }
            .navigationTitle("Rename")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }.accessibilityIdentifier("rename.cancel")
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Rename", action: save).accessibilityIdentifier("rename.commit")
                }
            }
            .onAppear { draft = currentTitle; fieldFocused = true }
        }
        .presentationDetents([.medium])
    }

    private func save() { commit(draft); dismiss() }
}
```

Keep the footer sentence **verbatim** — it is the user-facing statement of the PR-#82 guarantee.
Keep all four `rename.*` accessibility identifiers. Note "Use original name" clears the draft to
`""`, and `DocumentRenameService.normalized("")` returns `nil`, which is what drops the override —
do not "helpfully" refill the field with the fallback name.

Match the existing iPad sheet idiom (`AddWebpageSheet_iOS` in `ContentView_iOS.swift:164`) — same
`NavigationStack` + toolbar + `.presentationDetents` shape.

---

### Phase D — walkthrough & help

#### 2.11 `Vellum/Views/Help/WalkthroughSheet.swift` → `WalkthroughSheet_iOS.swift` — REBUILD

**What main has.** A paged sheet, `VStack { titleBar; Divider; pageContent; Divider; footer }`, with:
- named geometry: `sheetWidth = 620`, `maxSheetHeight = 620`, `titleBarHeight = 44`,
  `footerHeight = 50`, `chromeHeight = titleBarHeight + footerHeight + 2`;
- `.frame(width: sheetWidth).frame(maxHeight: maxSheetHeight)`;
- `.focusable().focusEffectDisabled().focused($keyboardFocused)` + `onAppear { keyboardFocused = true }`
  purely so `onKeyPress` fires (Full Keyboard Access is off by default on macOS);
- `onKeyPress(.leftArrow/.rightArrow/.escape)`;
- `pageContent` = `ScrollView { ZStack(topLeading) { all pages `.hidden()` for sizing; the current
  page with an asymmetric slide transition keyed on `page.id` } }` with
  `.scrollBounceBehavior(.basedOnSize)` — this is the trick that makes the sheet size to its tallest
  page and hold still while paging;
- `titleBar`: `Wordmark(14)` + "Walkthrough" + "N of M" + a close `IconButton` carrying
  `.keyboardShortcut(.cancelAction)`;
- `footer`: Skip (hidden on last page) / page-dot indicator (dots are direct navigation, styled with
  `palette.borderStrong` — NOT `.quaternary`, which is invisible on the light parchment) / Back /
  Next-or-Done carrying `.keyboardShortcut(.defaultAction)`;
- `onAppear { WalkthroughSettings.markSeen() }` — presented means seen, deliberately NOT tied to Done;
- `WalkthroughPageBody` is a **separate top-level struct** specifically so `WalkthroughLayoutTests`
  can host and measure it.

**iPad counterpart today.** None.

**iOS rebuild instructions.**

1. **Keep the static geometry constants and `chromeHeight`** — the layout tests assert against them
   (§4.5) and they must stay derivable. Change the *values* for iPad:
   ```swift
   static let sheetWidth: CGFloat = 640     // still a reading-width column; the sheet is
                                            // presented as a formSheet, so this is the content
                                            // width, not a window width
   static let maxSheetHeight: CGFloat = 720
   static let titleBarHeight: CGFloat = 52  // 44pt is below the iOS touch target once the close
   static let footerHeight: CGFloat = 60    // button and the Back/Next buttons live in them
   static var chromeHeight: CGFloat { titleBarHeight + footerHeight + 2 }
   ```
   Present it with `.presentationDetents([.large])` (or a fixed `.height(...)`) rather than a hard
   `.frame(width:)` — on iPad a `.sheet` is a form sheet, and pinning the width to 620 inside it is
   fine, but let the sheet own the outer size.
2. **Delete** `.focusable()`, `.focusEffectDisabled()`, `@FocusState keyboardFocused` and the
   `keyboardFocused = true` line. iOS `onKeyPress` does not need the focus dance, and `.focusable()`
   on iOS makes the container a Full Keyboard Access stop for no benefit.
3. **Keep** `onKeyPress(.leftArrow)` / `onKeyPress(.rightArrow)` — they work on iOS 17+ and are the
   Magic Keyboard path. **Delete** `onKeyPress(.escape)`; the close button plus the sheet's own
   swipe-down dismissal cover it. Keep `.keyboardShortcut(.cancelAction)` on the close button and
   `.keyboardShortcut(.defaultAction)` on Next/Done.
4. **Add a swipe gesture** — a paged sheet on iPad that cannot be swiped is wrong:
   ```swift
   .gesture(
       DragGesture(minimumDistance: 30)
           .onEnded { value in
               guard abs(value.translation.width) > abs(value.translation.height) else { return }
               if value.translation.width < 0, !isLast { go(to: index + 1) }
               if value.translation.width > 0, !isFirst { go(to: index - 1) }
           })
   ```
   Alternatively use `TabView { … }.tabViewStyle(.page)` — but then you lose the "size to the
   tallest page" ZStack, and `WalkthroughLayoutTests` becomes meaningless. **Prefer the ZStack +
   drag gesture**, keeping main's structure.
5. **Keep** the `ZStack` sizing trick, the `.id(page.id)` transition, the `ScrollView` +
   `.scrollBounceBehavior(.basedOnSize)`, `pageIndicator` (raise the dot hit area:
   `.contentShape(Capsule().inset(by: -12))` instead of `-6`).
6. **Keep** `WalkthroughPageBody` as a separate top-level struct with the same name. Verbatim body
   except: drop `.help(...)` if any, and keep the `Keycap` for shortcuts (D4).
7. **Keep** `onAppear { WalkthroughSettings.markSeen() }` and `.accessibilityIdentifier("walkthrough.sheet")`,
   plus `walkthrough.close`, `walkthrough.skip`, `walkthrough.back`, `walkthrough.next`,
   `walkthrough.dot.<id>`.
8. Bump `TextButton` sizes from `.sm` to `.md` in the footer for touch targets.

#### 2.12 `Vellum/Views/Help/HelpCenterView.swift` → `HelpCenterView_iOS.swift` — REBUILD

**What main has.** `enum HelpScene { windowId, title }` plus `HelpCenterView` — a `VStack { header;
Divider; body(for: results) }`, `.frame(minWidth: 520, minHeight: 420)`,
`.searchable(text: $query, placement: .toolbar, prompt: "Search features and shortcuts")`, a
`LazyVStack` of topic cards, and `ContentUnavailableView.search(text:)` when empty. It is declared as
its own `Window` scene in `VellumApp.swift:250` precisely so it can sit open beside a document.

**iOS constraint (standing decision): no extra `Window` scenes on iOS.** Do not port `HelpScene` or
add a scene.

**iOS rebuild instructions.**

1. Delete `enum HelpScene` entirely (nothing else references it once §2.15 is done).
2. Wrap the view in a `NavigationStack` so `.searchable` has a navigation bar to attach to:
   ```swift
   struct HelpCenterView_iOS: View {
       @Environment(\.dismiss) private var dismiss
       @Environment(\.palette) private var palette
       @State private var query = ""

       private var results: [HelpTopic] { HelpTopic.search(query) }

       var body: some View {
           NavigationStack {
               content
                   .navigationTitle("Vellum Help")
                   .navigationBarTitleDisplayMode(.inline)
                   .searchable(text: $query, prompt: "Search features and shortcuts")
                   .toolbar {
                       ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } }
                       ToolbarItem(placement: .primaryAction) {
                           Button("Walkthrough") {
                               dismiss()
                               NotificationCenter.default.post(name: .vellumShowWalkthrough, object: nil)
                           }
                           .accessibilityIdentifier("help.openWalkthrough")
                       }
                   }
           }
           .accessibilityIdentifier("help.window")
       }
   }
   ```
   Drop `placement: .toolbar` (macOS-only placement) — the iOS default is right. Drop
   `.frame(minWidth:minHeight:)`.
3. **`dismiss()` before posting `.vellumShowWalkthrough`** — this is the "one sheet at a time" rule.
   Both sheets are presented from `VellumApp_iOS`'s root, and presenting the walkthrough while Help
   is up will silently do nothing on iOS. Post *after* dismissal completes; if the race bites, post
   from `.onDisappear` of the help sheet using a `pendingWalkthrough` flag.
4. Keep `body(for:)`, `row(_:)`, the `LazyVStack`, and every accessibility identifier
   (`help.window`, `help.results`, `help.noResults`, `help.topic.<id>`, `help.openWalkthrough`)
   verbatim. `ContentUnavailableView.search(text:)` exists on iOS.
5. Drop `.help(...)` calls. Keep `.accessibilityElement(children: .contain)` on the row — the comment
   about the `Keycap` label being shadowed applies on iOS too.
6. **Presentation** — a `.sheet` presented from the Home screen's `showHelp` (§2.8 step 8) and from
   the shortcut router (§2.15). `.presentationDetents([.large])`. Alternatively, when Home is on
   screen, push it as a navigation destination; the sheet is simpler and works from a document
   context too. Recommended: sheet.

#### 2.14 `Vellum/App/VellumApp.swift` → `Vellum/Platform/iOS/VellumApp_iOS.swift` — MERGE (my hunks only)

**Hunks I claim** (`main/Vellum/App/VellumApp.swift:99-100`, `163-170`, `193-209`):

```swift
@State private var showWalkthrough = false
…
showStorageChoice = WebStorageSettings.needsFirstLaunchChoice
// Only one sheet at a time. On a true first launch the storage choice goes
// first — it decides where everything the walkthrough describes gets written —
// and hands off to the walkthrough when it closes.
if !showStorageChoice {
    showWalkthrough = WalkthroughSettings.needsFirstRun
}
…
.sheet(isPresented: $showStorageChoice,
       onDismiss: { showWalkthrough = WalkthroughSettings.needsFirstRun }) { StorageLocationChoiceSheet()… }
.onReceive(NotificationCenter.default.publisher(for: .vellumShowWalkthrough)) { _ in showWalkthrough = true }
.sheet(isPresented: $showWalkthrough) { WalkthroughSheet()… }
```

Everything else in that diff (UI-test launch configuration, `IntegrationsStore` construction,
`StorageHousekeeping.runCleanup`, the Settings/Help scenes, `KeychainStore.prewarm`) belongs to
other packets.

**iPad counterpart today** (`Vellum/Platform/iOS/VellumApp_iOS.swift`): already has
`@State private var showStorageChoice = false`, presents `StorageLocationChoiceSheet()` at
`:32-37`, and sets `showStorageChoice = WebStorageSettings.needsFirstLaunchChoice` at the end of
`launchMaintenance()` (`:92`).

**Exact edits:**

1. Add `@State private var showWalkthrough = false` next to `showStorageChoice` (line 16).
2. Add `@State private var showHelp = false`.
3. In `launchMaintenance()`, replace line 92:
   ```swift
   // BEFORE
   showStorageChoice = WebStorageSettings.needsFirstLaunchChoice
   // AFTER
   showStorageChoice = WebStorageSettings.needsFirstLaunchChoice
   // Only one sheet at a time. On a true first launch the storage choice goes
   // first — it decides where everything the walkthrough describes gets written
   // — and hands off to the walkthrough when it closes.
   if !showStorageChoice {
       showWalkthrough = WalkthroughSettings.needsFirstRun
   }
   ```
   This preserves the required ordering: **storage-location choice BEFORE walkthrough**, and it is
   already correct on iPad because `launchMaintenance` `await`s
   `WebStorageSettings.resolveICloudRoot()` first.
4. Add `onDismiss:` to the existing storage sheet:
   ```swift
   .sheet(isPresented: $showStorageChoice,
          onDismiss: { showWalkthrough = WalkthroughSettings.needsFirstRun }) {
       StorageLocationChoiceSheet()
           .environment(\.palette, themeStore.palette)
           .preferredColorScheme(themeStore.colorScheme)
           .tint(themeStore.palette.primary)
   }
   ```
5. Add the walkthrough sheet and its notification listener, immediately after:
   ```swift
   .onReceive(NotificationCenter.default.publisher(for: .vellumShowWalkthrough)) { _ in
       showWalkthrough = true
   }
   .sheet(isPresented: $showWalkthrough) {
       WalkthroughSheet_iOS()
           .environment(\.palette, themeStore.palette)
           .preferredColorScheme(themeStore.colorScheme)
           .tint(themeStore.palette.primary)
   }
   .onReceive(NotificationCenter.default.publisher(for: .vellumShowHelp)) { _ in
       showHelp = true
   }
   .sheet(isPresented: $showHelp) {
       HelpCenterView_iOS()
           .environment(\.palette, themeStore.palette)
           .preferredColorScheme(themeStore.colorScheme)
           .tint(themeStore.palette.primary)
   }
   ```
   Presentation at the **root** (not on the Home screen) is what makes the walkthrough re-entrant
   from anywhere — including with a document open — and matches main's reasoning that the sheet
   outlives the welcome screen.

   ⚠ **One sheet at a time**: three root-level `.sheet` modifiers on the same view will conflict on
   iOS if two flags go true. Two mitigations, apply both:
   - the `if !showStorageChoice` gate above;
   - in the `.vellumShowWalkthrough` / `.vellumShowHelp` handlers, guard
     `guard !showStorageChoice, !showHelp else { return }` / `guard !showStorageChoice, !showWalkthrough else { return }`.

   Note `ContentView_iOS` already owns `.sheet(isPresented: $addWebpagePresented)` one level down;
   that is a different view so it does not conflict with these, but a *simultaneous* presentation
   still won't work — the same guards cover it in practice.

#### 2.15 `Vellum/App/VellumCommands.swift` → iPad shortcut system — MERGE (my hunk only)

**Hunk I claim** (`main/Vellum/App/VellumCommands.swift:283-290`):

```swift
CommandGroup(replacing: .help) {
    Button("Vellum Help") { openWindow(id: HelpScene.windowId) }
        .keyboardShortcut("?", modifiers: .command)
    Button("Vellum Walkthrough") {
        NotificationCenter.default.post(name: .vellumShowWalkthrough, object: nil)
    }
}
```

Neither is gated on document focus — someone who just closed their last tab is exactly who wants them.

**iPad port.** The iPad routes everything through the three-file shortcut system. Add two rows:

1. `Vellum/Platform/iOS/KeyboardShortcuts_iOS.swift`:
   - add `case showHelp` and `case showWalkthrough` to `VellumShortcutAction`;
   - add their `identifier` strings (`"showHelp"`, `"showWalkthrough"`);
   - add `case help` to `VellumShortcutMenu`;
   - add two rows to the catalogue:
     ```swift
     VellumShortcut(.showHelp, "Vellum Help", .init(.character("?"), .command), menu: .help,
                    installOnDocumentSurface: false, overridesSystemBehavior: false),
     VellumShortcut(.showWalkthrough, "Vellum Walkthrough", <no chord — see below>, menu: .help, …),
     ```
     `VellumShortcut` requires a `combo`; if the struct has no "menu-item without a chord" affordance,
     surface Walkthrough as a plain `Button` in `VellumCommands_iOS`'s help group instead of adding a
     catalogue row (main leaves it unbound too).
2. `Vellum/Platform/iOS/ShortcutRouter_iOS.swift` — add to the switch, **before** any `guard app.document != nil`:
   ```swift
   case .showHelp:
       NotificationCenter.default.post(name: .vellumShowHelp, object: nil)
   case .showWalkthrough:
       NotificationCenter.default.post(name: .vellumShowWalkthrough, object: nil)
   ```
3. `Vellum/Platform/iOS/VellumCommands_iOS.swift` — add:
   ```swift
   CommandGroup(replacing: .help) {
       item(.showHelp)
       Button("Vellum Walkthrough") {
           NotificationCenter.default.post(name: .vellumShowWalkthrough, object: nil)
       }
   }
   ```
4. Declare `Notification.Name.vellumShowHelp = Notification.Name("vellum.show-help")` next to
   `.vellumShowWalkthrough`.

#### 2.13 `Vellum/Views/Settings/SettingsView.swift` — MERGE (my hunk only)

**Sequencing (packet 10 §2.3).** `SettingsView.swift` is a four-packet file (3, 1, 5, 8); each
hunk is <10 lines in the `TabView`. Land **3 → 1 → 5 → 8**, or accept a mechanical conflict.
**Packet 3 goes FIRST** — it is the one that restructures the `TabView` to
`$workspace.settingsSection`, and every other packet's hunk is additive against that shape.

**Hunks I claim** (PR #70 — the settings-section routing):

```swift
+    @Environment(WorkspaceStore.self) private var workspace
     var body: some View {
+        @Bindable var workspace = workspace
-        TabView {
+        TabView(selection: $workspace.settingsSection) {
             GeneralSettingsTab().tabItem { … }
+                .tag(WorkspaceStore.SettingsSection.general)
             …same for reading / annotations / ai / storage…
         }
+        .accessibilityIdentifier("settings.content")
```

**Hunks I do NOT claim** (leave to their packets):
- the AI tab's `AiConnectionValidator` / `validationState` / `configurationSummary` block and the
  `RevealableSecureField(accessibilityLabel:)` argument → **packet 5**;
- the deletion of the Voice section → voice/TTS is already gone on iPad; verify and no-op;
- `IntegrationsSettingsTab()` + its `.tag(.integrations)` → **packet 8**;
- moving `StorageSettingsTab` out into its own file (942 lines on main) → **packet 1**. On
  iPad, `StorageSettingsTab` currently lives *inside* `SettingsView.swift`; whoever ports the storage
  tab decides whether to split it. My hunk must survive that split — it only touches the `TabView`.

**iPad-specific:** keep the existing `#if os(macOS) .frame(width: 480) #endif`. On iPad the TabView
renders as a bottom tab bar inside the sheet, which is what the sheet's `.presentationDetents([.large])`
already assumes. Add `.tag(WorkspaceStore.SettingsSection.integrations)` only when the integrations
packet lands.

**Blocked on:** `WorkspaceStore.SettingsSection` — cross-packet dependency D5 (§5).

---

## 3. project.yml / Info-iOS.plist / entitlements changes

**None required.**

Reasoning, verified against `ipad-app/project.yml`:

- The `Vellum` target's sources are a **directory glob** (`- path: Vellum` with three excludes), so
  every new file under `Vellum/Services/Search/`, `Vellum/Views/Help/`, `Vellum/Platform/iOS/`, and
  `Vellum/Stores/` is picked up automatically by `xcodegen generate`. No target entries to add.
- The `VellumTests` target is `- path: Tests`, also a glob — new test files are picked up
  automatically.
- Main's `project.yml` diff in this range is (a) `configs: Debug/Release/UITesting` + a
  `VellumUITests` target/scheme, and (b) the ad-hoc-signing → Apple Development change. **(a) is
  out of scope** (deterministic macOS UI-test target, PR #87 — iPad has no XCUITest target and the
  issue does not ask for one). **(b) is already true on iPad** (`CODE_SIGN_STYLE: Automatic`,
  `DEVELOPMENT_TEAM: 9DCG97VASG`).
- Main's `Info.plist` diff in this range is `CFBundleDocumentTypes` + `UTExportedTypeDeclarations`
  for `com.vellum.webarchive` / `com.vellum.bundle`, and the **removal** of
  `NSMicrophoneUsageDescription` / `NSSpeechRecognitionUsageDescription`. Neither is mine:
  - the UTI/document-type work belongs to the **documents/packet 1** (`.vellum` bundle
    support);
  - the microphone/speech keys are the voice/TTS removal — check `Vellum/Resources/Info-iOS.plist`
    and, if either key is present, drop it (voice/TTS stays removed). That is a one-line hygiene fix,
    not a packet dependency.
- No entitlement changes. The Help centre is a sheet, not a scene, so no new window/scene
  declarations. Nothing here touches iCloud, and `Vellum/Vellum-iOS.entitlements` stays unwired for
  the reason documented in `project.yml`.

**Run `xcodegen generate` after adding files** — that is the only build-system step.

---

## 4. Tests to port

> **Ownership rule (packet 10 §2.1).** **Packet 9 is the only packet that writes into `Tests/`;
> every other packet's test claim is a specification, not an edit.** Everything in this section is
> the adaptation list packet 9 applies — do not create or modify these files yourself.

The iPad `Tests/` directory currently holds 14 files and uses **both** XCTest and Swift Testing, so
either framework is fine.

### 4.1 `Tests/HomeSearchRankerTests.swift` — VERBATIM

571 lines, Swift Testing (`import Testing`), `import Foundation` only. Every fixture is built inline
from `HomeSearchItem`. **No iOS adaptation.** Copy as-is.

### 4.2 `Tests/HomeSearchEngineTests.swift` — VERBATIM

710 lines, Swift Testing, `import Foundation`. All providers are driven by injected closures and
stub `HomeSearchProvider` conformances; nothing touches disk. **No iOS adaptation.**

Blocked on:
- `RecentDocument(…, docId:)` — the `recent()` fixture passes `docId: nil` (dependency D2);
- `DocumentDataStore.Meta(version:kind:title:lastKnownPath:lastOpened:)` and
  `DocumentDataStore.DocumentMetaEntry(key:meta:hasUserData:)` — the `meta()` fixture (dependency D1).

If D1/D2 land after this packet, port the two dependent suites (`LibraryDocumentsSearchProvider` and
the recents fixtures) in a follow-up rather than stubbing the types.

### 4.3 `Tests/HomeSearchStoreTests.swift` — MERGE

**Resolved tag (packet 10 §2.1).** Packet 9's `[VERBATIM]` on this file is downgraded to
`[MERGE — content per packet 3 §4.3]`: packet 3 supplies the adaptation ("drop the `HomeSourceTests`
suite," below) and packet 9 applies it when it writes the file.

465 lines, Swift Testing, `@MainActor` suites. Port with these changes:

1. **Delete the `HomeSourceTests` suite entirely** (lines ~395–437): it asserts
   `HomeSource.options(connected:)` / `HomeSource.reconciled(_:connected:)` against
   `IntegrationProvider.readwise` / `.raindrop`, none of which exist on iPad. The packet 8
   re-adds `HomeSource` and can re-add this suite.
2. Suites tagged `.scratchDefaults` (`HomeRemovalGuardTests`, `HomeRemovalCapTests`) need
   `Tests/ScratchDefaultsTrait.swift`, which is **dependency D6** (packet 1). Until it
   lands, either port `ScratchDefaultsTrait.swift` yourself (it is 60 lines and depends only on
   `AppDefaults.withDefaults`) or hold those two suites back. **Do not** strip the trait and let
   them write to the real defaults domain — they call `RecentFilesService.record` in a loop and
   would clobber the developer's real recents list.
3. Everything else (`HomeSearchStoreRemovalTests`, `HomeSearchStoreSelectionTests`) is pure
   main-actor state manipulation with an engine constructed as `HomeSearchEngine(providers: [])`.
   Verbatim.

### 4.4 `Tests/WalkthroughTests.swift` — MERGE

181 lines, XCTest. Two adaptations:

1. `import AppKit` → `import UIKit`.
2. In `testEverySymbolResolvesOnThisSystem`:
   ```swift
   // main
   NSImage(systemSymbolName: page.symbol, accessibilityDescription: nil)
   // iPad
   UIImage(systemName: page.symbol)
   ```
   (both places — page symbols and point symbols).
3. `testStoragePageMatchesTheShippedRetentionDefault` asserts `StorageHousekeeping.defaultMonths == 6`
   — **dependency D7**. Hold that one test back until `StorageHousekeeping` lands, or port
   `StorageHousekeeping` with the packet 1 first.
4. `testStoragePageNeverClaimsConversationsArePermanent` asserts
   `AiPersistence.maxMessagesPerDocument == 120` — verify that constant exists on iPad
   (`Vellum/Services/Ai/AiPersistence.swift`); if the packet 5 renamed it, follow.
5. `WalkthroughSettingsTests` reads/writes `UserDefaults.standard` directly and restores the prior
   value in `tearDown` — verbatim, no change.

### 4.5 `Tests/WalkthroughLayoutTests.swift` — MERGE (the interesting one)

**Resolved tag (packet 10 §2.1).** Packet 9 says `[REBUILD]`, packet 3 says `[MERGE]`
(`NSHostingView` → `UIHostingController`) — packet 10 rules these the same intent, different word.
The resolved tag is **[MERGE — content per packet 3 §4.5]**: packet 3 supplies the adaptation below
and packet 9 applies it when it writes the file.

150 lines, XCTest, `@MainActor`. It measures the **real** views off-screen rather than re-deriving
heights from constants. Adaptations:

1. `import AppKit` → `import UIKit`.
2. Replace `NSHostingView(rootView:).fittingSize.height` with a `UIHostingController` measurement:
   ```swift
   private func measure<V: View>(_ view: V, width: CGFloat) -> CGFloat {
       let host = UIHostingController(rootView: view)
       host.view.frame = CGRect(x: 0, y: 0, width: width, height: .greatestFiniteMagnitude)
       // sizeThatFits is the UIKit analogue of NSHostingView.fittingSize; the
       // unconstrained height asks SwiftUI for the intrinsic one.
       return host.sizeThatFits(in: CGSize(width: width,
                                           height: UIView.layoutFittingCompressedSize.height)).height
   }
   ```
   Then:
   ```swift
   private func measuredSheetHeight() -> CGFloat {
       measure(WalkthroughSheet_iOS()
                   .environment(\.palette, .light)
                   .tint(ThemePalette.light.primary),
               width: WalkthroughSheet_iOS.sheetWidth)
   }

   private func requiredHeight(of page: WalkthroughPage) -> CGFloat {
       measure(WalkthroughPageBody(page: page)
                   .environment(\.palette, .light)
                   .tint(ThemePalette.light.primary),
               width: WalkthroughSheet_iOS.sheetWidth)
   }
   ```
3. Retarget every `WalkthroughSheet.` static to `WalkthroughSheet_iOS.` (`sheetWidth`,
   `maxSheetHeight`, `chromeHeight`).
4. **Keep all four tests unchanged in substance** — they are exactly the "walkthrough layout tests"
   this packet is asked for:
   - `testNoPageIsClipped`
   - `testSheetHeightTracksTheTallestPage`
   - `testTallestPageFitsUnderTheBackstopWithoutScrolling`
   - `testChromeHeightIsTheSheetMinusItsTallestPage`
5. The `setUp`/`tearDown` pair saving `WalkthroughSettings.seenKey` **must be kept** — hosting the
   real sheet runs its `onAppear`, which calls `markSeen()`, and without the restore the suite eats
   the developer's first run.
6. ⚠ **Expect the accuracy-1 assertions to need re-tuning after the iPad rebuild.** The chrome bar
   heights change (§2.11), and if you add the drag gesture or change `TextButton` sizes the footer
   grows. Run the suite, read the failure message (they print the real numbers), and adjust the
   *constants in the sheet*, not the tolerances in the test.

### 4.6 `Tests/HelpCenterTests.swift` — MERGE

174 lines, XCTest. Adaptations:

1. `import AppKit` → `import UIKit`; `NSImage(systemSymbolName:accessibilityDescription:)` →
   `UIImage(systemName:)` in `testEverySymbolResolvesOnThisSystem`.
2. `testRetentionTopicMatchesTheShippedPolicy` asserts `StorageHousekeeping.defaultMonths == 6` and
   `StorageHousekeeping.monthOptions == [1, 3, 6, 12]` — dependency D7; hold back or land D7 first.
3. If you changed any topic copy per §2.7, update the corresponding assertion in the same commit.
   The four search assertions that pin exact result arrays (`"wraps around"`, `"⌘⌥S"`, `"llm"`,
   `"eviction"`, `"split down"`) are the ones most likely to break.
4. Everything else verbatim.

### 4.7 `Tests/SettingsNavigationTests.swift` — MERGE

**Resolved tag (packet 10 §2.1).** Packet 9's `[VERBATIM]` on this file is downgraded to
`[MERGE — content per packet 3 §4.7]`: packet 3 supplies the adaptation ("drop the updateChecker
test," below) and packet 9 applies it when it writes the file.

82 lines, XCTest, `@MainActor`. Adaptations:

1. `testWorkspaceDefaultsToGeneralSettingsAndCanRouteToAi` — **port verbatim**. It constructs
   `WorkspaceStore(sessions: DocumentSessionManager())`, which is exactly the iPad initialiser (main
   has an extra `integrations:` parameter, which this test doesn't pass either). This is the test
   that pins #70's routing.
2. `testUpdateCheckerIsWorkspaceOwnedAndAutomaticCheckIsClaimedOnce` — **delete**. It asserts
   `workspace.updateChecker` / `workspace.didStartAutomaticUpdateCheck` /
   `workspace.claimAutomaticUpdateCheck()`, none of which exist on iPad, and a Sparkle-style
   self-updater is meaningless in an App Store app.
3. `testApiKeyProvidersRequireCredentialsAndModels` (and any remaining AI-validation tests in the
   file) belong to the **packet 5** — either leave them out and let the packet 5 add them back, or
   port them if `AiConnectionValidator` has landed. Coordinate; do not delete work the packet 5
   expects to find.

### 4.8 New test worth adding (not in the delta)

The link-detector-as-address-bar behaviour has coverage in `HomeSearchRankerTests` /
`HomeSearchItem`'s tests, but the **iPad** container-path resolution added in §2.4 does not. Add a
small suite pinning that `RecentDocumentsSearchProvider`'s injected `fileExists` treats a stale
container path with a live same-named file in `DocumentImport.libraryDirectory` as present.

---

## 5. Risks & cross-packet dependencies

### Hard dependencies (this packet does not compile without them)

| id | Needed | Needed by | Which packet |
|---|---|---|---|
| **D1** | `Vellum/Services/DocumentDataStore.swift` — specifically `listDocumentMetas()`, `DocumentMetaEntry`, `Meta`, `loadMeta(forKey:)`, `setTitle(forKey:title:)` | `LibraryDocumentsSearchProvider`, `DocumentRenameService`, `HomeSearchEngineTests` | packet 1 (`A Vellum/Services/DocumentDataStore.swift`) |
| **D2** | `RecentFilesService` delta: `docId` on `RecentDocument`, `restore(_:)`, `removeIfUnchanged(_:)`, `updateTitle(path:title:)`, `resolvedPath(for:)`, `remove(paths:)` | `HomeSearchStore` undo/redo, `RecentDocumentsSearchProvider`, `DocumentRenameService` | packet 1 (`M Vellum/Services/RecentFilesService.swift`, `M Vellum/Models/Models.swift`) |
| **D3** | `WebLibrary.setTitle(rawUrl:title:)` | `DocumentRenameService` step 2 | packet 1 (`M Vellum/Services/Web/WebLibrary.swift`) |
| **D4** | `Keycap` view in `Vellum/Views/Shared/Controls.swift` | search field, `HomeLinkActionRow`, `WalkthroughPageBody`, `HelpCenterView` rows | packet 4 (`M Vellum/Views/Shared/Controls.swift`). **Source: `main/Vellum/Views/Shared/Controls.swift:109-136`** — 28 lines, pure SwiftUI, palette-driven, no AppKit. Land it yourself if the chrome packet is behind. |
| **D5** | `WorkspaceStore.SettingsSection` enum + `var settingsSection: SettingsSection = .general` | `SettingsView` tags, Home's gear button, `SettingsNavigationTests` | packet 4 (`M Vellum/Stores/WorkspaceStore.swift`). **Source: `main/Vellum/Stores/WorkspaceStore.swift`** — the enum has 6 cases (`general/reading/annotations/ai/storage/integrations`); ship all 6 even though `integrations` is unreachable on iPad, so the packet 8 needs no edit here. |
| **D6** | `Tests/ScratchDefaultsTrait.swift` + `Vellum/Services/AppDefaults.swift` | two `HomeSearchStoreTests` suites | packet 1 (`A Vellum/Services/AppDefaults.swift`, `A Tests/ScratchDefaultsTrait.swift`) |
| **D7** | `StorageHousekeeping.defaultMonths` / `.monthOptions` | one test each in `WalkthroughTests` and `HelpCenterTests` | packet 1 (`A Vellum/Services/StorageHousekeeping.swift`) |

**Recommended landing order:** D1+D2+D3 (storage/documents) → D4+D5 → this packet's Phase A → Phase
B → Phase C → Phase D → tests (D6/D7 gate two suites).

If D1/D2 are far out, this packet can still land in a reduced form: ship
`RecentDocumentsSearchProvider` + `SavedWebpagesSearchProvider` only (drop
`LibraryDocumentsSearchProvider` from `defaultProviders()`), drop `DocumentRenameService` and the
rename sheet, and drop the undo/redo half of `HomeSearchStore`. The search-first Home, the
walkthrough, and the Help catalogue all work without them. Say so in the PR if you take that route.

### Soft dependencies / coordination

- **`SettingsView.swift` is contended** by this packet (§2.13), the packet 5, the packet 1
  and the packet 8. My hunk is 8 lines and touches only the `TabView` declaration.
  **Resolved landing order (packet 10 §2.3): 3 → 1 → 5 → 8 — packet 3 goes FIRST**, since it
  restructures the `TabView` to `$workspace.settingsSection` and the other three hunks are additive
  against that shape. (Supersedes the earlier "land it last, or first, either works" guidance.)
- **`VellumApp.swift`/`VellumApp_iOS.swift`** is contended by the packet 1 (housekeeping
  cleanup) and possibly the packet 1. My hunks are the two `@State` flags, the
  `if !showStorageChoice` gate, the `onDismiss:`, and two `.sheet` + two `.onReceive` modifiers.
- **`VellumCommands.swift` / the iOS shortcut trio** is contended by the keyboard-shortcuts packet
  (already merged as commit `927f030b`, so the trio exists — my §2.15 edits are additive rows). If
  another packet is also adding shortcut rows, expect a mechanical conflict in the catalogue array.
- **`Tests/SettingsNavigationTests.swift`** is contended by the packet 5 (the
  `AiConnectionValidator` tests in the same file).

### Risks

1. **The `.task(id: store.refreshKey)` debounce vs. battery.** The iPad packet's standing
   requirement is that battery-drain fixes survive. `HomeSearchStore.refresh()` sleeps 120ms then
   ranks; `load()` does three disk walks. On iPad, `WelcomeLibrary_iOS` appears in **two** places at
   once when a split has a start tab, and my §2.8 step 2 adds a scene-phase reload. Profile it: if
   two panes each reload on every foreground it is two full corpus rebuilds. Mitigation if needed:
   gate the scene-phase reload on `!compact`, or hoist a single `HomeSearchStore` into
   `WorkspaceStore` and share it (main deliberately does not, so only do this with measurements).
2. **`onKeyPress` on iOS.** `.onKeyPress(.upArrow/.downArrow)` inside a focused `TextField` is
   supported on iOS 17+, but its interaction with the software keyboard's own arrow handling is less
   battle-tested than on macOS. Verify with a Magic Keyboard on device before claiming the keyboard
   navigation works. If arrow keys don't reach the field, fall back to `UIKeyCommand`s installed via
   the existing `VellumShortcutResponder` machinery.
3. **Three root-level sheets.** The storage-choice / walkthrough / help sheets all hang off
   `ContentView_iOS` in `VellumApp_iOS`. iOS silently drops a second simultaneous presentation. The
   guards in §2.14 cover the known paths; test the nasty one: first launch with
   `needsFirstLaunchChoice == true` **and** `needsFirstRun == true`, then dismiss the storage sheet
   and confirm the walkthrough appears.
4. **`WalkthroughLayoutTests` will fail on the first run after the iPad rebuild.** That is expected
   and correct — it is measuring the real view. Tune `titleBarHeight` / `footerHeight` /
   `maxSheetHeight` in `WalkthroughSheet_iOS` until it passes; do not relax the `accuracy: 1`.
5. **Copy drift.** `WalkthroughContent.swift` and `HelpTopic.swift` make behavioural claims that
   `WalkthroughTests`/`HelpCenterTests` pin to real constants. Every noun swap in §2.6/§2.7 must be
   checked against the assertion list in those sections in the same commit, or the suite fails for a
   reason that points at the wrong file.
6. **`showsFirstRun` and the start-tab.** `PaneView_iOS` renders `WelcomeLibrary_iOS(compact: true)`
   for a document-less start tab. With a full library the compact form now shows the whole
   search-first Home inside a possibly-narrow split pane. Verify the chip row, the sort menu and the
   date column at 1/3-width; the horizontal `ScrollView` in §2.8 step 4 and the
   `.truncationMode(.middle)` on the title are the two mitigations already specified.
7. **Rename write path.** `HomeSearchStore.rename` runs `DocumentRenameService.apply` in a
   `Task.detached(priority: .userInitiated)` then `await load()`. On iPad the `documents/<key>/`
   folder may live in the app container or (with iCloud selected) the ubiquity container — the write
   is best-effort per store and already tolerates a stranded record. No change needed, but a rename
   of an iCloud-placeholder page will silently not stick to the web record; the reload shows the
   truth, which is main's documented behaviour.
