# Packet 8 — Read-later integrations (Readwise + Raindrop)

Parity phase 8 for issue #129 (sub-issue #137). Source of the delta: macOS worktree
`/Users/ayushdeolasee/Developer/Vellum/main`, commit range `a42705d1~1..7742a895`; the whole
feature landed in one commit, **`67d2ac67` "Adding integration with ReadWise and Raindrop (#128)"**.
Target: `/Users/ayushdeolasee/Developer/Vellum/ipad-app` (branch `ipad-app`, iOS-only, xcodegen).

Read this packet end-to-end before touching anything. There is **no counterpart to any of these
files on iPad** — the entire `Vellum/Services/Integrations/`, `Vellum/Services/Search/` and
`Vellum/Stores/IntegrationsStore.swift` tree is absent — so almost everything is an add, not a
merge. The two real merges are `RevealableSecureField.swift` and `project.yml`.

Useful commands while working:

```bash
# the authoritative source of every file below
git -C /Users/ayushdeolasee/Developer/Vellum/main show 67d2ac67:<path>
git -C /Users/ayushdeolasee/Developer/Vellum/main diff a42705d1~1..7742a895 -- <path>
```

---

## 1. Delta files claimed

### Services — `Vellum/Services/Integrations/` (all new)

| file | tag |
|---|---|
| `Vellum/Services/Integrations/ReadLaterModels.swift` | **[VERBATIM]** |
| `Vellum/Services/Integrations/ReadLaterHTTPClient.swift` | **[VERBATIM]** |
| `Vellum/Services/Integrations/IntegrationCredentials.swift` | **[VERBATIM]** |
| `Vellum/Services/Integrations/IntegrationPreferences.swift` | **[VERBATIM]** |
| `Vellum/Services/Integrations/ReadwiseClient.swift` | **[VERBATIM]** |
| `Vellum/Services/Integrations/RaindropClient.swift` | **[VERBATIM]** |
| `Vellum/Services/Integrations/IntegrationsCache.swift` | **[VERBATIM]** |
| `Vellum/Services/Integrations/IntegrationDownloadClient.swift` | **[VERBATIM]** |
| `Vellum/Services/Integrations/IntegrationsSyncEngine.swift` | **[VERBATIM]** |
| `Vellum/Services/Integrations/IntegrationThumbnailCache.swift` | **[REBUILD]** (AppKit `NSImage` → UIKit `UIImage`) |
| `Vellum/Services/Search/ReadLaterSearchProvider.swift` | **[VERBATIM]** |

### Stores

| file | tag |
|---|---|
| `Vellum/Stores/IntegrationsStore.swift` | **[VERBATIM]** (two-line platform edit: `import AppKit` → `import UIKit`, `NSImage` → `UIImage`) |

### Views

| file | tag |
|---|---|
| `Vellum/Views/Shared/Theme.swift` | **[MERGE, +`ThemePalette.success`]** (packet 10 §1.1 — the audit's headline gap: the one delta file no packet mentions at all, and packet 8 cannot compile `FloatingNotice.swift` without it) |
| `Vellum/Views/Shared/FloatingNotice.swift` | **[VERBATIM]** (needs `palette.success` — see §5) |
| `Vellum/Views/Shared/MoveToCollectionMenu.swift` | **[VERBATIM]** |
| `Vellum/Views/AI/RevealableSecureField.swift` | **[MERGE]** (iPad has a diverged UIKit rebuild) |
| `Vellum/Views/Settings/IntegrationsSettingsTab.swift` | **[REBUILD]** |
| `Vellum/Views/Settings/ConnectServiceSheet.swift` | **[REBUILD]** |
| `Vellum/Views/Settings/DisconnectServiceSheet.swift` | **[REBUILD]** |
| `Vellum/Views/Welcome/ExternalLibraryList.swift` | **[REBUILD]** |
| `Vellum/Views/Welcome/LibraryRowContent.swift` | **[REBUILD]** |

### Tests

| file | tag |
|---|---|
| `Tests/Integrations/TestSupport/FixtureLoader.swift` | **[VERBATIM]** |
| `Tests/Integrations/TestSupport/StubURLProtocol.swift` | **[VERBATIM]** |
| `Tests/Integrations/TestSupport/IntegrationTestDoubles.swift` | **[VERBATIM]** |
| `Tests/Integrations/ReadLaterModelsTests.swift` | **[VERBATIM]** |
| `Tests/Integrations/ReadLaterHTTPClientTests.swift` | **[VERBATIM]** |
| `Tests/Integrations/ReadwiseClientTests.swift` | **[VERBATIM]** |
| `Tests/Integrations/RaindropClientTests.swift` | **[VERBATIM]** |
| `Tests/Integrations/IntegrationsCacheTests.swift` | **[VERBATIM]** |
| `Tests/Integrations/IntegrationsSyncEngineTests.swift` | **[VERBATIM]** |
| `Tests/Integrations/IntegrationsStoreTests.swift` | **[VERBATIM]** |
| `Tests/Integrations/ExternalLibraryFilteringTests.swift` | **[VERBATIM]** |
| `Tests/Integrations/IntegrationDownloadClientTests.swift` | **[MERGE]** (one test uses `NSBitmapImageRep`) |
| `Tests/Integrations/Fixtures/Raindrop/collections-child.json` | **[VERBATIM]** |
| `Tests/Integrations/Fixtures/Raindrop/collections-root.json` | **[VERBATIM]** |
| `Tests/Integrations/Fixtures/Raindrop/item-minimal.json` | **[VERBATIM]** |
| `Tests/Integrations/Fixtures/Raindrop/items-page-0.json` | **[VERBATIM]** |
| `Tests/Integrations/Fixtures/Raindrop/items-page-final.json` | **[VERBATIM]** |
| `Tests/Integrations/Fixtures/Raindrop/malformed-among-valid.json` | **[VERBATIM]** |
| `Tests/Integrations/Fixtures/Raindrop/user.json` | **[VERBATIM]** |
| `Tests/Integrations/Fixtures/Readwise/item-minimal.json` | **[VERBATIM]** |
| `Tests/Integrations/Fixtures/Readwise/items-page-1.json` | **[VERBATIM]** |
| `Tests/Integrations/Fixtures/Readwise/items-page-final.json` | **[VERBATIM]** |
| `Tests/Integrations/Fixtures/Readwise/malformed-among-valid.json` | **[VERBATIM]** |
| `Tests/Integrations/Fixtures/Readwise/raw-source.json` | **[VERBATIM]** |

### Project

| file | tag |
|---|---|
| `project.yml` | **[MERGE — hunk only]** — packet 9 is the sole editor (packet 10 §2.2); the `VellumTests` fixture-resource hunk is packet 8's to hand over (§3). |

### Not mine

| file | tag |
|---|---|
| `Vellum/Services/KeychainStore.swift` | **[SKIP: owned by the packet 9]** (packet 10 §2.1) — but this packet **cannot compile** without its `service:` parameter. See §5, dependency D1. |
| `Tests/KeychainStoreTests.swift` | **[SKIP: same packet as KeychainStore.swift]** |
| `Vellum.xcodeproj/project.pbxproj` | **[SKIP: the iPad project is generated by xcodegen from `project.yml`; the checked-in pbxproj is macOS-only]** |
| `plans/read-later-integrations.html` | **[SKIP: design document, not shipped code]** — worth *reading* for background, not porting. |

---

## 2. Port order & instructions

Do the work in the order of the numbered stages below; each stage compiles on its own except
where noted.

### Stage 0 — prerequisites (blocking)

1. **`KeychainStore` must accept a `service:` argument.** `KeychainIntegrationCredentials` calls
   `KeychainStore.get(_:service:)`, `.set(_:_:service:)`, `.delete(_:service:)` with
   `service: "com.vellum.integrations"`. Today's iPad `KeychainStore` (`Vellum/Services/KeychainStore.swift`)
   has no `service:` parameter at all. **Do not land a stopgap shim for this.** Packet 9 is the sole
   owner of `KeychainStore.swift` (packet 10 §2.1), and a defaulted-parameter patch landed here would
   ship on top of — and get clobbered or conflict with — packet 9's real vault rewrite (packet 9 §5
   says the same). Wait for packet 9's Stage 0, which is the first thing to land in the whole parity
   effort.
2. **`AppDefaults` must exist** (`Vellum/Services/AppDefaults.swift`, packet 1).
   `IntegrationPreferences.defaults` is `injectedDefaults ?? AppDefaults.current`. If AppDefaults
   has not landed, temporarily substitute `UserDefaults.standard` **and leave a `// TODO(packet-1)`**;
   do not invent a second seam.
3. **`palette.success`** must exist on `ThemePalette` (`Vellum/Views/Shared/Theme.swift`) — one
   `let success: Color` plus `#2f7d46` (light) / `#5bbf77` (dark). `FloatingNotice` reads it. This is
   no longer an external prerequisite: packet 8 owns `Theme.swift` itself (packet 10 §1.1, Stage 6
   above) — land it there rather than treating it as a stopgap here.
4. **`RecentFilesService.remove(paths: Set<String>)`** must exist. iPad only has
   `remove(path: String)`. `IntegrationsSyncEngine.disconnect` calls the plural form.

### Stage 1 — pure-Foundation service layer (VERBATIM)

Copy these byte-for-byte from `main`. They are Foundation/CryptoKit/PDFKit only — no AppKit, no
`#if` needed — and they are the actor/`Sendable` core the issue says to adopt wholesale.

```
main:Vellum/Services/Integrations/ReadLaterModels.swift        → ipad-app: same path
main:Vellum/Services/Integrations/ReadLaterHTTPClient.swift    → ipad-app: same path
main:Vellum/Services/Integrations/IntegrationCredentials.swift → ipad-app: same path
main:Vellum/Services/Integrations/IntegrationPreferences.swift → ipad-app: same path
main:Vellum/Services/Integrations/ReadwiseClient.swift         → ipad-app: same path
main:Vellum/Services/Integrations/RaindropClient.swift         → ipad-app: same path
main:Vellum/Services/Integrations/IntegrationsCache.swift      → ipad-app: same path
main:Vellum/Services/Integrations/IntegrationDownloadClient.swift → ipad-app: same path
main:Vellum/Services/Integrations/IntegrationsSyncEngine.swift → ipad-app: same path
```

Notes per file (no code changes, but know what you are carrying):

* **`ReadLaterModels.swift`** — the whole persistence vocabulary. `ProviderSnapshot`,
  `TentativePagination`, `IntegrationQueryDescriptor` are the on-disk snapshot format; the ids
  `"<provider>:<vendorID>"` and `"<provider>:collection:<vendorID>"` are format-bearing. Do not
  rename anything. `IntegrationDownloadState.sequence` is what makes overlapping notices
  deterministic.
* **`ReadLaterHTTPClient.swift`** — the retry/rate-limit actor. 3 attempts, `Retry-After` honoured
  (numeric seconds or RFC-1123 date), 401 ⇒ `tokenRejected`, 403 ⇒ `server(403)` (deliberately not
  a token rejection), retry only for `idempotent` requests. Also carries
  `JSONEncoder.integrations` (`.iso8601`, `.sortedKeys`, `.withoutEscapingSlashes`) — **that
  encoder's settings are byte-format-bearing for the download manifests**.
* **`IntegrationCredentials.swift`** — protocol + `KeychainIntegrationCredentials`, service
  namespace `com.vellum.integrations`, account `read-later.<provider>`. Every call hops to
  `Task.detached(priority: .userInitiated)` so a keychain prompt cannot block the engine's actor.
  Keep that hop on iOS: a locked-device keychain read can still block.
* **`IntegrationPreferences.swift`** — the `UserDefaults` keys `integrations.autoRefresh`,
  `integrations.enabled.<provider>`, `integrations.generation.<provider>`,
  `integrations.accountFingerprint.<provider>`. **These key strings must stay byte-identical.**
* **`ReadwiseClient.swift`** — `readwise.io/api/v2/auth/` (expects 204), `api/v3/list/`,
  `api/v3/update/<id>/`. Keep the `+` → `%2B` percent-encoding fix-up and the
  `isValidVendorID` charset guard (path-injection defence). `locationCollections` seeds
  `ProviderSnapshot.empty` for Readwise.
* **`RaindropClient.swift`** — `api.raindrop.io/rest/v1/...`, offset pagination (`page`,
  `perpage=50`, `sort=-created`), `LosslessStringID` (Raindrop emits ids as ints *or* strings),
  collection flattening with cycle protection + orphan sweep.
* **`IntegrationsCache.swift`** — snapshot envelope **version 3**, primary + `.backup.json`,
  version-probe-before-decode, `.disconnect-<uuid>` staging with rollback, `downloadKey` =
  SHA256 of `"<provider>:<itemID>"`. Root is
  `WebLibrary.appDataDir/integrations/` — `WebLibrary.appDataDir` already resolves correctly on
  iOS (verified: `Vellum/Services/Web/WebLibrary.swift:67`, it has an `#else` branch for iOS).
* **`IntegrationDownloadClient.swift`** — the streaming `URLSessionDataDelegate` bridge with the
  mid-flight byte cap. This is the "download byte cap" the issue names. Pure Foundation; the
  `AsyncThrowingStream` + `withTaskCancellationHandler` + post-loop `Task.checkCancellation()`
  dance is load-bearing, do not "simplify" it.
* **`IntegrationsSyncEngine.swift`** — the resumable, rate-limit-aware, generation-guarded engine.
  Imports `CryptoKit`, `Foundation`, `PDFKit`; all three exist on iOS. One call needs Stage 0.4:
  `RecentFilesService.remove(paths: Set(managed.map(\.path)))` in `disconnect(...)`.
  Constants to keep: `pagesPerCheckpoint = 8`, `maximumPagesPerWalk = 5_000`,
  `maximumResumableWalkAge = 30 * 60`, `maximumSyncJoins = 4`, `maximumPDFBytes = 250 * 1024 * 1024`.
  Keep the 250 MB cap for parity — do **not** shrink it for iPad without a separate decision.

### Stage 2 — `IntegrationThumbnailCache.swift` [REBUILD]

Source: `main:Vellum/Services/Integrations/IntegrationThumbnailCache.swift` (81 lines).
Destination: `Vellum/Services/Integrations/IntegrationThumbnailCache.swift`.

Copy the file, then make exactly these changes — everything else (the actor, the staging download
through `IntegrationDownloading`, the 8 MB byte cap, the 40 Mpx decompression-bomb guard, the
SHA256 filename key, `removeUnreferenced`) is adopted unchanged:

1. `import AppKit` → `import UIKit`. Keep `CryptoKit`, `Foundation`, `ImageIO`.
2. `func image(for candidate: URL?) async -> sending NSImage?` →
   `func image(for candidate: URL?) async -> sending UIImage?`. Keep `sending` — `UIImage` is not
   `Sendable` either, and the instance is created here and never stored.
3. The return line
   `return NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))`
   → `return UIImage(cgImage: cgImage)`. (Scale 1 is correct: the CGImage is already downsampled
   to `maximumThumbnailPixelSize` and the SwiftUI row applies `.resizable().scaledToFill()` inside
   a fixed frame. Do **not** reach for `UIScreen.main.scale` — it is main-actor-bound and
   deprecated on iOS 26.)
4. In `validImageData(_:)`, the final `return NSImage(data: data) != nil` →
   `return UIImage(data: data) != nil`.
5. Keep `maximumThumbnailPixelSize = 256` — the iPad rows are larger than macOS's 34 pt well but
   256 px still covers a 44–52 pt well at 3×, and raising it costs memory per row.
6. Keep the doc comment, adjusting the two mentions of `NSImage` to `UIImage`.

### Stage 3 — `ReadLaterSearchProvider.swift` [VERBATIM]

`main:Vellum/Services/Search/ReadLaterSearchProvider.swift` → same path on iPad. Pure Foundation.
It defines `ReadLaterSearchSource` (an actor holding the corpus) and `ReadLaterSearchProvider`
conforming to `HomeSearchProvider`.

**Blocked on the packet 3**: it references `HomeSearchProvider`, `HomeSearchItem`,
`HomeSearchItemBuilder`, `HomeSearchHaystack`, `HomeSearchDateLabel`, and the `.readLater` section
case — none of which exist on iPad today (`Vellum/Services/Search/` does not exist). Port this file
*after* that packet lands `HomeSearchProvider.swift` / `HomeSearchItem.swift`. If you must land
packet 8 first, hold this one file (and only this one file) back; nothing else in the packet
depends on it.

Also adjust the comment "*lives nowhere else on this Mac*" → "*on this iPad*" (cosmetic, keeps the
file honest).

### Stage 4 — `IntegrationsStore.swift` [VERBATIM + 2-line platform edit]

`main:Vellum/Stores/IntegrationsStore.swift` (487 lines) → `Vellum/Stores/IntegrationsStore.swift`.

Changes:

1. `import AppKit` → `import UIKit`.
2. `func thumbnailImage(for item: ReadLaterItem) async -> NSImage?` →
   `... async -> UIImage?`.
3. **Add one new method** (iPad-only divergence, needed for the foreground refresh — see Stage 8):

```swift
    /// iOS has no "app is running continuously" guarantee: the auto-refresh
    /// timer's sleep is suspended with the process, so returning to the
    /// foreground is the moment to re-check staleness. macOS gets this for free
    /// from the always-running timer.
    func foregroundRefresh() async { await refreshStaleProviders() }
```

Everything else is adopted as-is, and everything else matters:

* `start()` — loads snapshots, classifies `tokenRejected` / `connected` / `.failed("cache damaged")`,
  restarts auto-refresh, then `refreshStaleProviders()`. This is the **startup sync**.
* `refreshStaleProviders()` / `restartAutoRefresh()` — `staleInterval` 30 min, `refreshInterval`
  30 min, weekly (`7 * 24 * 60 * 60`) authoritative full sweep. This is the **staleness sync**.
* `sync(_:forceFull:)` — the **manual sync** entry point ("Sync Now").
* `run(_:)` / `awaitQuiescence()` — the joinable-background-work registry and the quit barrier.
  On iPad the "quit barrier" becomes the scene-background barrier (Stage 8).
* `route(for:)` + `downloads` + `moveNotices` + `newestNotice(for:)` + `notice(forItem:)` —
  progress/notice plumbing.
* `readLaterItem(forOpenDocumentPath:)` + the lazily-rebuilt `ItemLookupIndex` +
  `comparableWebAddress` / `strippingQuery` — how an open tab is mapped back to an item.
* `pendingMoves` + `pendingMoveTTL` (15 min) + `apply(_:connection:cleanThumbnails:)` — the
  optimistic-move reconciliation.
* `searchableItems` / `searchRevision` — the seam the home screen uses to publish into search.

### Stage 5 — `RevealableSecureField.swift` [MERGE]

**What main changed** (`git diff a42705d1~1..7742a895 -- Vellum/Views/AI/RevealableSecureField.swift`):

* added `let accessibilityLabel: String` as the **first** stored property (so it is the first
  argument in the memberwise initialiser);
* added `var credentialName = "API key"` (defaulted, third position);
* threaded `accessibilityLabel` into the AppKit representable and onto the field itself via
  `field.setAccessibilityLabel(...)` in both `makeNSView` and `updateNSView`;
* changed the eye button's help/accessibility text from the hard-coded "API key" to
  `"Hide \(credentialName)" / "Show \(credentialName)"`;
* added `.accessibilityElement(children: .contain)` on the `HStack`.

**What the iPad counterpart looks like today**: `Vellum/Views/AI/RevealableSecureField.swift` is a
full iOS rebuild — `SecureTextFieldRep: UIViewRepresentable` over a single `UITextField` whose
`isSecureTextEntry` flips in place (with the re-seat trick that stops iOS dropping the string), a
`palette.surface`/`palette.border` chrome, 30 pt field height, 28 pt eye button. Its signature is
`RevealableSecureField(placeholder:text:)`.

**Preserve**: the entire UIKit rebuild — the single-field `isSecureTextEntry` toggle, the
`textContentType = .none` / autocorrect-off / smart-quotes-off configuration, the `clearButtonMode`,
the re-seat in `updateUIView`, the palette chrome, and the 28 pt (touch-legal) eye hit target.
Do **not** import main's AppKit version.

**Merge instructions** (additive only):

1. Add `let accessibilityLabel: String` as the **first** stored property, above `placeholder`.
2. Add `var credentialName = "API key"` immediately after `placeholder`.
3. In `SecureTextFieldRep`, add `let accessibilityLabel: String` and set
   `field.accessibilityLabel = accessibilityLabel` in `makeUIView` **and** `updateUIView`
   (UIKit property, not the AppKit `setAccessibilityLabel(_:)` selector).
4. Change the eye `Button`'s `.accessibilityLabel(isRevealed ? "Hide API key" : "Show API key")`
   to `"Hide \(credentialName)" / "Show \(credentialName)"`.
5. Add `.accessibilityElement(children: .contain)` to the outer `HStack` (after the
   `.overlay(...)` chrome modifiers).
6. **Update the two existing call sites** — both currently pass only `placeholder:` and `text:`:
   * `Vellum/Views/Settings/SettingsView.swift:223`
   * `Vellum/Views/AI/AiSettingsPanel.swift:144`
   Both become
   `RevealableSecureField(accessibilityLabel: "\(aiStore.providerDisplayName) API key", placeholder: aiStore.keyFieldPlaceholder, text: aiStore.apiKeyBinding)`
   — use whatever provider-name property `AiStore` already exposes; if none reads well, pass
   `"API key"`. Keep the existing `.id(provider)` if the call site has one.

### Stage 6 — `Theme.swift` [MERGE] then `FloatingNotice.swift` + `MoveToCollectionMenu.swift` [VERBATIM]

Land `Theme.swift` first — `FloatingNotice.swift` does not compile without it.

**`Vellum/Views/Shared/Theme.swift` [MERGE, +`ThemePalette.success`]** (packet 10 §1.1). Add only
the 3-line `success` property to both the light and dark `ThemePalette` values — light `#2f7d46`,
dark `#5bbf77` — and touch nothing else in the file. This is the audit's headline gap: the one delta
file no packet claimed, and it blocks the next two files below.

```
main:Vellum/Views/Shared/FloatingNotice.swift      → ipad-app: same path
main:Vellum/Views/Shared/MoveToCollectionMenu.swift → ipad-app: same path
```

Both are pure SwiftUI and compile unmodified on iOS.

* `FloatingNotice` needs `palette.success` (now Stage 6, above — no longer Stage 0.3, see §5 D3) and `Radius.md` (already on iPad,
  `Theme.swift:127`). Its dismiss button already puts `.frame`/`.contentShape` **inside** the
  label, which is exactly the touch-target rule iPad needs; do not move them out. Consider bumping
  the dismiss `.frame(width: 22, height: 22)` to `44×44` for the iPad build — flag it, do not do it
  silently, it changes the notice's visual density.
* `MoveToCollectionMenu` is a `Menu` + inline `Picker`; both render natively on iOS. Keep the
  explicit `integrations` injection (not `@Environment`) — the same "context-menu content is built
  outside the owning environment" hazard exists on iOS, and a missing `@Environment` observable is
  a `fatalError`.

### Stage 7 — touch rebuilds of the UI

Convention followed here (matching what already exists in this worktree): **settings surfaces keep
main's paths** because `Vellum/Views/Settings/SettingsView.swift` is already a shared,
`#if`-guarded file on iPad; **the home/library surface goes under `Vellum/Platform/iOS/`** because
`Vellum/Views/Welcome/WelcomeScreen.swift` is macOS-gated on iPad with
`Vellum/Platform/iOS/WelcomeScreen_iOS.swift` as its counterpart.

#### 7a. `Vellum/Views/Settings/IntegrationsSettingsTab.swift` [REBUILD]

**What main's version does** (107 lines): a `Form { }` with two sections — a *Refresh* section
(`Toggle("Refresh automatically")` bound through `integrations.setAutoRefresh`, a
`LabeledContent("Schedule", value: "Every 30 minutes")`, a footer sentence) and a
*Read-later services* section with one `providerRow` per `IntegrationProvider.allCases`. Each row:
symbol + name + status line (`status(_:)`), a `ProgressView` while `.syncing`/`.connecting`, then
either **Sync Now** + an `ellipsis.circle` `Menu` (Reconnect… / Disconnect…) when connected, or a
**Connect…** button when not. A second line shows `Cached items: N` and `Last sync: <relative>`.
`.frame(height: 460)` and `.sheet(item:)` for both sheets.

**Rebuild for touch** (same information, same store calls, same accessibility identifiers):

* Keep the file name, type name `IntegrationsSettingsTab`, and `@Environment(IntegrationsStore.self)`.
* Keep `Form { Section { … } header: { } footer: { } }` and `.formStyle(.grouped)` — both render as
  an inset-grouped table on iPadOS. **Drop `.frame(height: 460)`** (the iPad settings sheet fills
  its presentation).
* Keep the `status(_:)` and `color(_:)` helpers **verbatim** — the strings are user-visible parity.
* Provider row: make the whole row a `NavigationLink`-free plain row; replace the AppKit
  `Menu { … } .menuStyle(.borderlessButton).fixedSize()` with a plain
  `Menu { Button("Reconnect…") …; Button("Disconnect…", role: .destructive) … } label: { Image(systemName: "ellipsis.circle").frame(width: 44, height: 44).contentShape(Rectangle()) }`
  — `.menuStyle(.borderlessButton)` does not exist on iOS, and the 44 pt frame **must** be inside
  the label.
* "Sync Now" and "Connect…" become `Button` with `.buttonStyle(.bordered)` and a minimum 44 pt
  height; keep the exact titles and the `.disabled(state?.connection == .syncing)` guard.
* Keep `integrations.run { await integrations.sync(provider, forceFull: true) }` for Sync Now — the
  store-owned task is what the scene-background drain joins.
* Keep `.accessibilityLabel("More options for \(provider.name)")`.
* Keep both `.sheet(item: $connectProvider)` / `.sheet(item: $disconnectProvider)` presentations and
  add `.presentationDetents([.medium, .large])` inside each sheet's content (see 7b/7c).
* Register the tab in `Vellum/Views/Settings/SettingsView.swift` (shared four-packet file — **edit
  order 3 → 1 → 5 → 8, packet 8 goes last**, packet 10 §2.3) — add, after the Storage tab:

```swift
            IntegrationsSettingsTab()
                .tabItem { Label("Integrations", systemImage: "link") }
```

  iPad's `SettingsView` has no `WorkspaceStore.SettingsSection` enum (macOS-only there), so no
  `.tag(...)` is needed.

#### 7b. `Vellum/Views/Settings/ConnectServiceSheet.swift` [REBUILD]

**What main's version does** (57 lines): a `VStack` with icon + "Connect \(provider.name)" +
per-provider instruction line, a `RevealableSecureField` (`accessibilityIdentifier
"integrations.connect.token"`), a `Link` to the provider's token page, an inline error
(`"integrations.connect.error"`), and Cancel/Connect buttons. `connect()` bumps a
`validationGeneration`, cancels any prior attempt, and runs `integrations.connect(provider:token:)`
inside `integrations.run { }` while keeping the handle so `.onDisappear` can cancel it. The `defer`
releases `isValidating` only when the generation still matches. `resignAndDismiss()` calls
`NSApp.keyWindow?.makeFirstResponder(nil)` before `dismiss()`.

**Preserve exactly**: the generation fencing, the `defer { if generation == validationGeneration { isValidating = false } }`,
the `catch is CancellationError` silent branch, the `.onDisappear { connectionTask?.cancel() }`,
the two accessibility identifiers, both help URLs
(`https://readwise.io/access_token`, `https://app.raindrop.io/settings/integrations`) and both
instruction strings. Keychain-only token paste stays: **no OAuth for either provider.**

**Rebuild for touch**:

* Wrap the body in `NavigationStack { … }` with `.navigationTitle("Connect \(provider.name)")`,
  `.navigationBarTitleDisplayMode(.inline)`, and toolbar `Cancel` (`.cancellationAction`) /
  `Connect` (`.confirmationAction`) items instead of the trailing `HStack` of buttons. Keep
  `.keyboardShortcut(.cancelAction)` / `.keyboardShortcut(.defaultAction)` on them — the iPad
  keyboard-shortcut router makes those real.
* Replace `.padding(24).frame(width: 430)` with `.padding(20)` +
  `.presentationDetents([.medium, .large])` + `.presentationDragIndicator(.visible)`.
* `RevealableSecureField` now takes the label first:
  `RevealableSecureField(accessibilityLabel: "\(provider.name) access token", placeholder: "Paste access token", credentialName: "access token", text: $token)`.
* Replace `resignAndDismiss()`'s AppKit first-responder reset with a `@FocusState private var
  tokenFocused: Bool` set to `false` before `dismiss()` (bind it to the field with
  `.focused($tokenFocused)`), or, if the `UIViewRepresentable` does not accept `.focused`, call
  `UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)`.
  Either way the keyboard must be down before the sheet dismisses or the sheet animates over a
  live keyboard.
* Add `.textInputAutocapitalization(.never)` / `.autocorrectionDisabled()` only if the
  representable does not already do it — it does (`Vellum/Views/AI/RevealableSecureField.swift:56-63`),
  so nothing to add.
* Optional but recommended for touch: a "Paste" button next to the field
  (`UIPasteboard.general.string`), since typing a 40-char token on a tablet is miserable. Guard it
  with `@Environment(\.scenePhase)`-free plain `UIPasteboard.general.hasStrings`.

#### 7c. `Vellum/Views/Settings/DisconnectServiceSheet.swift` [REBUILD]

**What main's version does** (41 lines): title, an explanatory paragraph, a
`Toggle("Also delete downloaded PDFs")`, a caption that turns red and changes text when the toggle
is on, an inline error, and Cancel / Disconnect (`role: .destructive`). `disconnect()` collects the
open PDF paths from `workspace.root.allLeaves()` and calls
`integrations.disconnect(provider:deleteDownloads:openDocumentPaths:)` inside `integrations.run { }`
with `defer { isDisconnecting = false }`.

**Preserve exactly**: the two caption strings, the open-document path collection (it is what makes
the engine throw `IntegrationError.downloadsAreOpen` instead of deleting a file someone is reading),
`integrations.run` ownership, and the `defer`.

**Rebuild for touch**: same `NavigationStack` + toolbar treatment as 7b; drop
`.frame(width: 420)`; `.presentationDetents([.medium])`. Keep `role: .destructive` on the
Disconnect button and add `.disabled(isDisconnecting)`. The workspace lookup is unchanged —
`WorkspaceStore.root.allLeaves()` exists identically on iPad.

#### 7d. `Vellum/Platform/iOS/ExternalLibraryList_iOS.swift` [REBUILD]

Source: `main:Vellum/Views/Welcome/ExternalLibraryList.swift` (107 lines).
Destination: **`Vellum/Platform/iOS/ExternalLibraryList_iOS.swift`**, wrapped in `#if os(iOS) … #endif`
like every other file in that directory.

**Must keep at top level, unconditionally reachable by the test target** (it is what
`Tests/Integrations/ExternalLibraryFilteringTests.swift` asserts on):

```swift
enum ExternalLibraryFilter {
    static func reconciledCollectionID(_ selected: String?, availableIDs: [String]) -> String? {
        guard let selected else { return nil }
        return availableIDs.contains(selected) ? selected : nil
    }
}
```

**What main's view does**: a controls row (search `TextField`, a collection `Menu` labelled
"All locations"/current title with `String(repeating: "  ", count: depth)` indentation, a
`Toggle("Name", isOn:).toggleStyle(.button)` sort switch), a `Divider`, then either a
`ContentUnavailableView` for the three empty states (authentication required / sync failed /
nothing saved-or-no-results) or a `List(selection:)` of `ExternalLibraryRow`s with
`.contextMenu(forSelectionType:)` offering Open / Open Original in Browser / Copy Link /
`MoveToCollectionMenu`, `primaryAction:` opening the selection, and `.onKeyPress(.return)`.
Modifiers: `.task(id: provider) { await integrations.providerSelected(provider) }` (a 5-minute
freshness check on selection), `.onChange(of: collections)` reconciling the collection filter, and
a bottom-trailing `FloatingNotice` overlay from `integrations.newestNotice(for: provider)`.

**Preserve, verbatim, as behaviour**:

* the `items` computed property (collection filter + case-insensitive title/author/tag match +
  optional name sort) — `ExternalLibraryFilteringTests` documents these fields;
* the three empty-state titles/messages/symbols and the `warningMessage` strings;
* `.task(id: provider) { await integrations.providerSelected(provider) }`;
* the `.onChange(of: state?.collections.map(\.id) ?? [])` → `ExternalLibraryFilter.reconciledCollectionID` reconciliation;
* the `FloatingNotice` overlay including the two accessibility identifiers
  (`integrations.notice` / `integrations.downloadNotice`) and the correct dismiss call per kind;
* `open(_:)` routing through `integrations.route(for:)` → `appStore.openUrl` / `appStore.openFile`.
  **This is the "opening a synced item → ordinary Vellum tab" requirement**: an article opens as a
  normal web tab, a PDF is downloaded into the integrations cache and opened as a normal PDF tab.
  Do not add a bespoke reader path;
* the row accessibility identifiers `welcome.external.row.<item.id>`, the list identifier
  `welcome.external.library`, the search-field identifier `welcome.external.search`.

**Touch rebuild specifics**:

* Replace `List(selection:) + .contextMenu(forSelectionType:) + primaryAction:` with a plain
  `List { ForEach(items) { item in Button { open(item) } label: { ExternalLibraryRow_iOS(item: item) } .buttonStyle(.plain) .contextMenu { … } } }`.
  The per-row `.contextMenu` (long-press) carries the same four entries; `primaryAction` becomes the
  row tap. Drop `.onKeyPress(.return)` unless the keyboard router already owns Return in this
  context.
* `NSWorkspace.shared.open(item.sourceURL)` → `UIApplication.shared.open(item.sourceURL)`.
* `NSPasteboard.general.clearContents(); NSPasteboard.general.setString(...)` →
  `UIPasteboard.general.string = item.sourceURL.absoluteString`.
* `.listStyle(.inset)` → `.listStyle(.plain)`; keep `.scrollContentBackground(.hidden)` and
  `.background(palette.well)`. Raise `.environment(\.defaultMinListRowHeight, 52)` to `60`.
* Add `.swipeActions(edge: .trailing) { Button("Open in Browser") { … } }` as the touch-discoverable
  twin of the context menu (optional but strongly recommended — long-press is the only other route).
* Controls row: `TextField` → `.textFieldStyle(.roundedBorder)` still works; add
  `.submitLabel(.search)` and `.autocorrectionDisabled()`. The collection `Menu` works unchanged
  (drop `.fixedSize()`). Replace `Toggle("Name").toggleStyle(.button).help(...)` with a
  `Button` that flips `sortByName` and shows `Image(systemName: sortByName ? "textformat.abc" : "clock")`
  inside a 44 pt frame, plus `.accessibilityLabel("Sort by name")`.
* `ExternalLibraryRow` → `ExternalLibraryRow_iOS`: `@State private var image: UIImage?`,
  `Image(uiImage: image)`, and the same
  `.task(id: item.thumbnailURL) { image = await integrations.thumbnailImage(for: item) }`. Keep
  the comment explaining why the decode is inside the actor — it is a battery/main-thread argument
  that matters more on iPad, not less.

#### 7e. `Vellum/Platform/iOS/LibraryRowContent_iOS.swift` [REBUILD]

Source: `main:Vellum/Views/Welcome/LibraryRowContent.swift` (28 lines). Only `ExternalLibraryList`
uses it in main. Rebuild as a touch row:

* Keep the generic shape `LibraryRowContent_iOS<Leading: View>` with
  `title`, `subtitle`, `badge`, and the `@ViewBuilder leading`. **Drop the `tooltip` parameter**
  (there is no hover on iPad) or keep it and feed it to `.accessibilityLabel` — pick one and be
  consistent with the call site in 7d.
* Delete `@State private var hovering`, `.onHover`, the hover background, and `.help(tooltip)`.
* Replace the hover background with a pressed/selected highlight: let the enclosing `Button`'s
  `.buttonStyle(.plain)` handle it, or apply
  `.background { RoundedRectangle(cornerRadius: Radius.md).fill(palette.muted.opacity(0.0)) }`
  and let the `List` row selection colour do the work.
* Keep the leading `.frame(width: 34, height: 34)` thumbnail well but raise the row's vertical
  padding so the total row height clears 60 pt.
* Keep the badge capsule ("PDF") and the two-line title/subtitle typography
  (14 pt medium / 12 pt `palette.mutedForeground`, both `lineLimit(1)`).

### Stage 8 — app wiring (iPad-only files, not in the delta)

These files have no macOS counterpart in the delta; the edits below are the iPad translation of
what main did in `VellumApp.swift` / `WorkspaceStore.swift` / `WelcomeScreen.swift` /
`ToolbarView.swift` / `PaneView.swift`.

**8a. `Vellum/Stores/WorkspaceStore.swift`** (shared file — coordinate; packets 5 and 4 also
touches it). Mirror main's change at `main:Vellum/Stores/WorkspaceStore.swift:24,260,334`:

```swift
    let integrations: IntegrationsStore
    // …
    init(sessions: SessionService, integrations: IntegrationsStore, …) { … self.integrations = integrations … }
    convenience init(sessions: SessionService) { self.init(sessions: sessions, integrations: IntegrationsStore()) }
```

The convenience initialiser keeps every existing `WorkspaceStore(sessions:)` call site compiling.

**8b. `Vellum/Platform/iOS/VellumApp_iOS.swift`**:

1. In `init()`, after `let sessions = DocumentSessionManager()`:
   `let integrations = IntegrationsStore(engine: IntegrationsSyncEngine())` and
   `let workspace = WorkspaceStore(sessions: sessions, integrations: integrations)`.
   Also add `KeychainStore.prewarm()` as the first statement of `init()` **if** the foundation
   packet has landed it (it moves the first vault read off the main thread).
2. Add `.environment(workspace.integrations)` to the `WindowGroup`'s environment chain — the
   settings tab, the sheets and the library list all read it via `@Environment(IntegrationsStore.self)`.
   Also add it to the `SettingsView()` presentation inside
   `Vellum/Platform/iOS/PdfChrome_iOS.swift:179-196` (that sheet builds its own environment chain).
3. Startup sync: extend the existing `.task { await launchMaintenance() }` (or add a second
   `.task`) with `await workspace.integrations.start()`. Put it **before** the detached maintenance
   work so the providers' cached items are on screen quickly.
4. Foreground staleness: in the existing `.onChange(of: scenePhase)`, add

```swift
            if phase == .active {
                workspace.integrations.run { await workspace.integrations.foregroundRefresh() }
            }
```

   (needs the `foregroundRefresh()` added in Stage 4.3). This replaces the macOS assumption that
   the 30-minute `restartAutoRefresh` timer keeps ticking — on iOS the process is suspended and the
   `Task.sleep` does not fire in the background.
5. Background drain: inside `flushOnBackground()`'s `Task { @MainActor in defer { token.end() } … }`,
   add `await workspace.integrations.awaitQuiescence()` **after** the existing
   `PageTextPersister` / `ScratchpadPersistence` / `AiPersistence` drains. This is the iOS analogue
   of main's `applicationShouldTerminate` barrier: it cancels in-flight syncs and waits for the
   store-owned writes (preference flips, moves, disconnects, thumbnail cleanup).

**8c. Home source switcher — `Vellum/Platform/iOS/WelcomeScreen_iOS.swift`**:

`WelcomeLibrary_iOS` is the iPad home screen (used full-screen from `ContentView_iOS.swift:141` and
compact from `PaneView_iOS.swift:116`). Add, mirroring `main:Vellum/Views/Welcome/WelcomeScreen.swift`:

1. `@Environment(IntegrationsStore.self) private var integrations` and
   `@State private var source: HomeSource = .library`.
2. Port the `HomeSource` enum from `main:Vellum/Views/Welcome/WelcomeScreen.swift:1035-1090`
   (`case library`, `case provider(IntegrationProvider)`, `title`, `systemImage`,
   `accessibilityIdentifier` — `welcome.source.library` / `welcome.source.<rawValue>` —
   `options(connected:)`, `reconciled(_:connected:)`). If the packet 3 also ports
   `HomeSource`, **let them own it and delete your copy** — it is their file's type.
3. Render the switcher only when `sources.count > 1`, using the existing
   `GlassSegmentedPicker` in `Vellum/Views/Shared/Controls.swift:108` (it already takes
   `options: [(value:label:)]`, a `selection` binding, and an
   `accessibilityIdentifierPrefix`) — that is the iPad's native segmented idiom and matches what
   main rebuilt its macOS switcher into.
4. When `source == .provider(p)`, replace the recents grid with
   `ExternalLibraryList_iOS(provider: p).id(p)` (the `.id` is load-bearing: it resets the search
   text and collection filter when switching accounts).
5. `.onChange(of: integrations.connectedProviders) { _, connected in source = HomeSource.reconciled(source, connected: connected) }`
   — a disconnected account must not leave the reader parked on a permanently empty list.
6. Port `sourceStatus(for:)` / `syncLabel(for:)` from
   `main:Vellum/Views/Welcome/WelcomeScreen.swift:469-521` as a one-line status + refresh
   `IconButton` above the list. Keep the `welcome.source.status` / `welcome.source.sync`
   identifiers and the exact label strings.
7. **Search wiring — only after the packet 3 lands `HomeSearchStore` on iPad.** Then add
   the debounced publish from `main:…/WelcomeScreen.swift:165-169`:

```swift
        .task(id: integrations.searchRevision) {
            try? await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled else { return }
            await store.updateReadLater(integrations.searchableItems)
        }
```

   plus the `.section == .readLater` branch of `open(_:)` and `openExternal(_:)`
   (`…/WelcomeScreen.swift:895-940`), and the `readLaterNotice` overlay
   (`…/WelcomeScreen.swift:522-541`) for downloads started from a search row.

**8d. Notices over an open document — `Vellum/Platform/iOS/PaneView_iOS.swift`**:

Port `main:Vellum/Views/Panes/PaneView.swift:296-310`: overlay the pane's document viewer with

```swift
        if let item = integrations.readLaterItem(forOpenDocumentPath: path),
           let notice = integrations.notice(forItem: item.id) {
            FloatingNotice(message: notice.state.message, progress: notice.state.progress,
                           isActive: notice.state.isActive, isSuccess: notice.state.isSuccess,
                           accessibilityID: notice.isMove ? "integrations.notice" : "integrations.downloadNotice") {
                if notice.isMove { integrations.dismissMoveNotice(item.id) } else { integrations.dismissDownloadNotice(item.id) }
            }
        }
```

where `path` is the focused tab's `document?.pdfPath`. Place it bottom-trailing, inset far enough
to clear the ink palette.

**8e. Move-to-collection from the reader — `Vellum/Platform/iOS/PdfChrome_iOS.swift`**:

Port `main:Vellum/Views/PDF/ToolbarView.swift:964-973` into the existing **More** menu
(`PdfChrome_iOS.swift:222`, `moreMenu`), just above the final `Divider()` + "Settings…":

```swift
            if let item = integrations.readLaterItem(forOpenDocumentPath: path) {
                Divider()
                MoveToCollectionMenu(item: item, integrations: integrations)
            }
```

Requires `@Environment(IntegrationsStore.self) private var integrations` on the chrome view.

---

## 3. `project.yml` / `Info-iOS.plist` / entitlements

### `project.yml` — one required hunk, applied by packet 9

`project.yml` is tagged MERGE by three packets (1, 8, 9). Packet 10 §2.2 resolves that to **packet 9
as the sole editor** — one `xcodegen generate` per landing, not five. Packet 8's job is to hand this
hunk to packet 9, not to edit the file directly; packet 9's own §D4 already flags this same fixtures
hunk as shared, so coordinate there.

The fixture JSON must ship as **bundle resources** of the test target, not as compilable sources.
The hunk main applied (`git diff a42705d1~1..7742a895 -- project.yml`), adapted to the
iPad target block, for packet 9 to apply:

```yaml
  VellumTests:
    type: bundle.unit-test
    platform: iOS
    sources:
      - path: Tests
        excludes:
          - Integrations/Fixtures
      - path: Tests/Integrations/Fixtures
        type: folder
        buildPhase: resources
    dependencies:
      - target: Vellum
    settings:
      base:
        PRODUCT_BUNDLE_IDENTIFIER: com.ayushdeolasee.vellum.tests
        GENERATE_INFOPLIST_FILE: "YES"
        TEST_HOST: $(BUILT_PRODUCTS_DIR)/Vellum.app/Vellum
        BUNDLE_LOADER: $(TEST_HOST)
```

`type: folder` (a folder reference, not a group) is what preserves the
`Fixtures/Raindrop/…` / `Fixtures/Readwise/…` subdirectory layout that
`FixtureLoader` looks up via `bundle.url(forResource:withExtension:subdirectory:)`. Do **not**
change `TEST_HOST` — the iOS path has no `Contents/MacOS`.

Packet 9 regenerates afterwards (`xcodegen generate` at the repo root) as part of its own landing —
packet 8 does not run this.

**Explicitly NOT ported from main's `project.yml` diff** (they belong to other packets or to
macOS): the `configs: Debug/Release/UITesting` block, the `VellumUITests` target and scheme, the
`CODE_SIGN_IDENTITY: "Apple Development"` change (the iPad file already has
`CODE_SIGN_STYLE: Automatic` + `DEVELOPMENT_TEAM: 9DCG97VASG`), and the
`SWIFT_TREAT_WARNINGS_AS_ERRORS` flags (adopt those with the packet that owns the warning cleanup —
turning them on here would fail the build on unrelated pre-existing warnings).

### `Info-iOS.plist` — no changes required

* Outbound HTTPS to `readwise.io` / `api.raindrop.io` needs nothing: `NSAppTransportSecurity →
  NSAllowsArbitraryLoads = true` is already set.
* No background-mode key is needed. The design here is foreground sync + a
  `beginBackgroundTask` drain (already in `VellumApp_iOS.flushOnBackground`). If someone later
  wants true background refresh they would add `UIBackgroundModes → fetch` and a
  `BGAppRefreshTask` — **out of scope for parity; do not add it.**
* No new document types or exported UTIs — downloaded PDFs open through the existing
  `com.adobe.pdf` path.

### Entitlements — none

iOS keychain access for the app's own default access group comes from the `application-identifier`
entitlement that automatic signing already injects; `CODE_SIGN_ENTITLEMENTS` stays unwired (the
existing comment about the un-provisionable iCloud capability remains true). Do not add a
`keychain-access-groups` entitlement — a single-app group is the default and adding one explicitly
would change the group and orphan any already-stored token.

---

## 4. Tests to port

> **Ownership rule (packet 10 §2.1).** **Packet 9 is the only packet that writes into `Tests/`;
> every other packet's test claim is a specification, not an edit.** Everything in this section is
> the adaptation list packet 9 applies — do not create or modify these files yourself.

Destination is `Tests/Integrations/**` (same relative layout as main). The iPad test target already
picks up everything under `Tests/`, so only the fixtures need the `project.yml` change in §3.

| file | adaptation |
|---|---|
| `TestSupport/FixtureLoader.swift` | none. The `#filePath` fallback still resolves (`Tests/Integrations/Fixtures/...`). |
| `TestSupport/StubURLProtocol.swift` | none. `URLProtocol`, `AsyncThrowingStream`, `nonisolated(unsafe)` all behave identically on iOS. |
| `TestSupport/IntegrationTestDoubles.swift` | none. Imports `CoreGraphics`/`CryptoKit`/`Foundation`; `integrationTestPDFData()` uses `CGDataConsumer` + `CGContext(consumer:mediaBox:)`, both iOS-available. `NSMutableData` is Foundation, fine. |
| `ReadLaterModelsTests.swift` | none. |
| `ReadLaterHTTPClientTests.swift` | none. |
| `ReadwiseClientTests.swift` | none. |
| `RaindropClientTests.swift` | none. |
| `IntegrationsCacheTests.swift` | none. |
| `IntegrationsSyncEngineTests.swift` | none (947 lines; imports `Foundation`/`Testing`/`PDFKit`-free). It is the resumability / rate-limit / generation-guard suite — the highest-value file in the packet. |
| `IntegrationsStoreTests.swift` | none. `@MainActor struct` + `UserDefaults(suiteName:)` per test; works unchanged. |
| `ExternalLibraryFilteringTests.swift` | none, **provided** `ExternalLibraryFilter` survives the 7d rebuild at top level. |
| `IntegrationDownloadClientTests.swift` | **two edits.** (1) `import AppKit` → `import UIKit`. (2) `thumbnailMetadataRejectsImagesAboveThePixelLimit` builds a 2×2 PNG via `NSBitmapImageRep(bitmapDataPlanes:…)` + `representation(using: .png, properties: [:])`. Replace with `UIGraphicsImageRenderer(size: CGSize(width: 2, height: 2)).pngData { $0.fill(CGRect(x: 0, y: 0, width: 2, height: 2)) }` (no `#require` needed — it returns non-optional `Data`) and keep the `maximumPixelCount: 3` assertion. The other five tests in the file need no change. |
| `Tests/Integrations/Fixtures/**.json` (12 files) | copy byte-for-byte. They are the vendor-shape contract; re-minifying or reformatting them would weaken the malformed-record tests. |

Run with `xcodebuild test -scheme Vellum -destination 'platform=iOS Simulator,name=iPad Pro 13-inch (M4)'`
(or whatever simulator the repo standardises on).

**Not ported here**: `Tests/KeychainStoreTests.swift` (412 lines) belongs with `KeychainStore.swift`
in the packet 9; it drives `KeychainStore.Backend` / `withBackend`, which this packet does
not introduce.

---

## 5. Risks & cross-packet dependencies

### Hard dependencies (this packet does not compile without them)

* **D1 — `KeychainStore` `service:` parameter** (packet 9, `Vellum/Services/KeychainStore.swift`,
  packet 10 §2.1). `KeychainIntegrationCredentials` needs `get/set/delete(_:service:)`. **Packet 8's
  D1 stopgap shim must not ship on top of packet 9's real `KeychainStore`** — packet 9 §5 says the
  same. Do not land Stage 0.1's defaulted-parameter patch; wait for packet 9's Stage 0, which is the
  first thing to land in the whole parity effort. Note main's version also adds the single-item
  "vault" (one keychain item holding a JSON map) and `prewarm()`; on iOS the ad-hoc-signing prompt
  storm that motivated the vault does not exist, so the vault is a nice-to-have, but the `service:`
  parameter is mandatory.
* **D2 — `AppDefaults`** (packet 1, `Vellum/Services/AppDefaults.swift` + `TestEnvironment.swift`).
  `IntegrationPreferences.defaults` falls back to `AppDefaults.current`. Without it, the
  `IntegrationsStoreTests` / `IntegrationsSyncEngineTests` suites can leak connection state into the
  simulator's real defaults domain (they inject their own suite, so the leak is only via any code
  path that constructs `IntegrationPreferences()` with no argument — i.e. the app's own default
  init).
* **D3 — `palette.success`** on `ThemePalette` (`Vellum/Views/Shared/Theme.swift`). **No longer a
  blocker.** Packet 10 §1.1 identifies `Theme.swift` as the audit's headline gap — no packet
  claimed it — and assigns it to packet 8 itself (see §1 Views table + Stage 6). `FloatingNotice`
  will not compile without it, but packet 8 now owns the fix in-house instead of waiting on a
  "theme packet" that was never cut.
* **D4 — `RecentFilesService.remove(paths: Set<String>)`** (packet 1,
  `Vellum/Services/RecentFilesService.swift`). Called by `IntegrationsSyncEngine.disconnect`.
* **D5 — home-search types** (`HomeSearchProvider`, `HomeSearchItem`, `HomeSearchItemBuilder`,
  `HomeSearchHaystack`, `HomeSearchDateLabel`, section case `.readLater`, and `HomeSearchStore`).
  Blocks Stage 3 (`ReadLaterSearchProvider.swift`) and Stage 8c.7 only. Everything else can land
  first.

### Ownership overlaps to negotiate before writing

* `project.yml` — three packets (1, 8, 9) tag it MERGE. Packet 9 is the sole editor (packet 10 §2.2);
  packet 8 hands over only the `VellumTests` sources/excludes + fixtures-resources hunk (§3).
* `Vellum/Views/Settings/SettingsView.swift` — a four-packet file (3, 1, 5, 8). Land order is
  **3 → 1 → 5 → 8** (packet 10 §2.3) — **packet 8 goes last**. Your edit is three lines (register
  the Integrations tab), so land it after the other three tabs exist.
* `Vellum/Stores/WorkspaceStore.swift` — add the `integrations` property + initialiser parameter +
  convenience init only.
* `Vellum/Views/Welcome/LibraryRowContent.swift` / `HomeSource` — if the packet 3 claims
  either, drop your copy and consume theirs.

### Behavioural risks

* **R1 — keychain accessibility while locked.** `KeychainStore` never sets `kSecAttrAccessible`, so
  items default to `kSecAttrAccessibleWhenUnlocked`. On iPad, a sync triggered while the device is
  locked (e.g. the tail of a `beginBackgroundTask` drain after the screen locks) will read `nil`
  for the token and the engine will report `IntegrationError.disconnected`, which the store turns
  into a `.failed` connection state and a visible error. Recommend the packet 9 set
  `kSecAttrAccessibleAfterFirstUnlock` on the vault/legacy items. Flag it there; do not change
  keychain attributes from this packet.
* **R2 — background suspension mid-walk.** iOS suspends `URLSession` tasks on backgrounding. The
  engine checkpoints every 8 pages and on every exit path, and a resumed walk older than 30 minutes
  or owned by a previous process downgrades itself to `mergeOnly` (so absences are never read as
  deletions). This is correct as written — the risk is only that iPad hits the `mergeOnly` path far
  more often than macOS does, so the authoritative full sweep (which is what actually removes
  deleted items) may lag. Do not "fix" it by relaxing the `walkOwnerID` check.
* **R3 — auto-refresh timer does not fire in the background.** Handled by Stage 8b.4's
  `scenePhase == .active` refresh. Without it, an iPad that has been backgrounded for a day shows
  stale items until the user taps Sync Now.
* **R4 — downloaded PDFs are replaced on revision change.** `IntegrationsCache.installDownload`
  calls `replaceItemAt` when the provider's `updatedAt` moved, which discards any annotations the
  reader embedded in that downloaded file. This is main's behaviour and stays for parity, but on
  iPad the downloaded copy is the *only* copy (no Finder-visible original), so the loss is more
  severe. Worth an issue; not a change to make here.
* **R5 — 250 MB download cap on a device.** `maximumPDFBytes = 250 * 1024 * 1024` plus the
  temporary `.download` part file means up to ~500 MB of container churn per download. Kept for
  parity; if the iPad build ever needs a lower cap, change it at the single
  `IntegrationsSyncEngine.init` default, not at the download client.
* **R6 — container-path stability.** Downloads live under `WebLibrary.appDataDir/integrations/<provider>/downloads/`,
  which is inside the app container. `appDataDir` is recomputed at runtime, so paths stay valid
  across launches; but a path recorded into recents (via the normal open flow) will break after a
  reinstall, exactly like every other iPad recent. The recents packet's
  `DocumentImport.resolveExistingPath` fallback covers it.
* **R7 — `PdfFileGate`.** Opening a downloaded PDF goes through the ordinary
  `AppStore.openFile(path:)` → session path, so it inherits the iPad's `PdfFileGate` serialisation
  automatically. Nothing in this packet may bypass it.
* **R8 — accessibility identifiers are a contract.** `welcome.external.search`,
  `welcome.external.library`, `welcome.external.row.<id>`, `welcome.source.*`,
  `integrations.connect.token`, `integrations.connect.error`, `integrations.moveMenu`,
  `integrations.notice`, `integrations.downloadNotice` are all asserted by main's UI tests. Even
  though this packet does not port those UI tests, keep the identifiers so a later UI-test port is
  free.
* **R9 — iPad-only features this packet must not disturb.** Nothing here touches ink, the palette,
  scribble-to-erase, Pencil double-tap, the shortcut router, Safari-style zoom, touch selection
  reporting, the ink-write coalescing / web-observer throttling battery fixes, the drag watchdog, or
  `CreateAnnotationInput.createdAt`. The only shared files it edits are `WorkspaceStore.swift`
  (add a stored property), `SettingsView.swift` (add a tab), `Theme.swift` (add a colour),
  `RecentFilesService.swift` (add an overload), `RevealableSecureField.swift` (add two parameters),
  `VellumApp_iOS.swift`, `PaneView_iOS.swift`, `PdfChrome_iOS.swift` and `WelcomeScreen_iOS.swift`
  (additive hooks). Review each of those diffs for accidental deletions before committing.
