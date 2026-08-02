# Packet 9 — Test & build infrastructure (cross-cutting catch-all)

Parity phase 9 for issue #129. Source of the delta: macOS worktree
`/Users/ayushdeolasee/Developer/Vellum/main`, commit range `a42705d1~1..7742a895`.
Target: `/Users/ayushdeolasee/Developer/Vellum/ipad-app` (branch `ipad-app`, iOS-only, xcodegen,
forked at the 2026-07-15 parity cutoff).

This packet owns everything that is *not* a feature: the keychain vault + its test fake (#97, #128),
the `AppDefaults` scratch-domain trait (#124/#102), the UI-test launch seams (#87) that other
packets' files reference, `project.yml`, `Info-iOS.plist`, the repo-level docs/CI files, and **the
entire `Tests/` tree except `Tests/Integrations/**`** (owned by packet 8). One owner for `Tests/`
because the test bundle is a single compile unit: a half-ported `Tests/` directory does not build,
so the ordering below is load-bearing.

> **The literal rule (packet 10 §2.1): packet 9 is the only packet that writes into `Tests/`;
> every other packet's test claim is a specification, not an edit.**
>
> Packets 1, 3, 4, 5, 6 and 7 also name individual test files, usually with a *different* tag —
> almost always `[MERGE]` where this packet said `[VERBATIM]`, **and they specify deletions that a
> verbatim copy would undo** (Integrations tests that do not exist until packet 8, a
> `HomeSourceTests` suite that is deleted on iPad, a relocated GC-cutoff test that a verbatim copy
> would duplicate, a `MarkdownParserTests` that does not compile at all against iPad's current
> `MarkdownParser`). **Resolution: this packet stays the file owner** — it creates, adapts and
> sequences every file and owns `project.yml`'s test sources — but **every `[VERBATIM]` listed in
> packet 10 §2.1 is downgraded to `[MERGE — content per <feature packet> §N]`.** The feature
> packet supplies the adaptation list; this packet applies it. Each feature packet carries the
> same rule at the top of its §4.

Commands you will use constantly:

```bash
MAIN=/Users/ayushdeolasee/Developer/Vellum/main
IPAD=/Users/ayushdeolasee/Developer/Vellum/ipad-app
git -C $MAIN show 7742a895:<path>            # authoritative new content
git -C $MAIN diff a42705d1~1..7742a895 -- <path>
git -C $MAIN show a42705d1~1:<path>          # the version the iPad forked from
```

After adding **any** new file under `Vellum/` or `Tests/`, run `xcodegen generate` in `$IPAD` and
commit the regenerated `Vellum.xcodeproj/project.pbxproj` (the iPad tracks its generated pbxproj).
Never hand-edit the pbxproj.

---

## 1. Delta files claimed

### 1.1 Infrastructure source files

| file | tag |
|---|---|
| `Vellum/Services/TestEnvironment.swift` | **[VERBATIM]** |
| `Vellum/Services/KeychainStore.swift` | **[VERBATIM]** (iPad copy is byte-identical to main's pre-delta version — overwrite) |
| `Vellum/App/UITestLaunchConfiguration.swift` | **[REBUILD]** (iOS has no XCUITest target; trimmed variant, still required to compile) |
| `Vellum/Resources/Info.plist` | **[MERGE]** → apply to `Vellum/Resources/Info-iOS.plist`; see §3. **This packet owns the plist outright** (packet 10 §2.2): packet 2 had claimed a `[VERBATIM]` cosmetic copy of main's macOS plist "to keep the trees comparable" — that is dropped, it is a needless write to a file excluded from the iOS target (`project.yml` `excludes: Resources/Info.plist`). |
| `Vellum/Services/Web/WebPageExtractor.swift` | **[MERGE]** — the whole diff is `nonisolated(unsafe)` removals on `WebFetch.session` and four `WebHtml` regexes. Assigned here by packet 10 §1.1: the "warnings packet" that packets 2 and 7 deferred to was never cut, and the flag decision and the removals must be made by the same owner. See §3.5. |
| `Vellum/Services/Web/WebArchive.swift` (removals only) | **[MERGE, `nonisolated(unsafe)` removals only]** — packet 2 deferred the identical removals in this file to the same phantom packet; they move here. Packet 2 keeps only the two `MiniZip` pre-parse accessors (`entryCount`, `totalDeclaredUncompressedSize`). See §3.5. |

### 1.2 Build configuration

| file | tag |
|---|---|
| `project.yml` | **[MERGE]** — **this packet is the SOLE editor** (packet 10 §2.2). Three packets had tagged it MERGE; xcodegen re-reads it for every target, so packets 1 and 8 hand their hunks here instead of editing it (packet 8's `VellumTests` sources/excludes + `Tests/Integrations/Fixtures` resource wiring is the same hunk as §D4's). **One `xcodegen generate` per landing, not five.** Only two hunks apply; the macOS/UITesting hunks are dropped. See §3.1 |
| `.gitignore` | **[MERGE]** — one added stanza. **This packet owns it** (packet 10 §2.2); packet 2 SKIPs. |

### 1.3 Tests — infrastructure (mine outright)

| file | tag |
|---|---|
| `Tests/ScratchDefaultsTrait.swift` | **[VERBATIM]** |
| `Tests/AppDefaultsGuardTests.swift` | **[VERBATIM]** |
| `Tests/KeychainStoreTests.swift` | **[VERBATIM]** |
| `Tests/UITestLaunchConfigurationTests.swift` | **[REBUILD]** |

### 1.4 Tests — new feature suites (this packet ports them; production code comes from other packets)

| file | tag | production dependency (packet) |
|---|---|---|
| `Tests/AiAddAsNoteTests.swift` | **[MERGE — content per packet 5 §4]** | **Three-way conflict, resolved (packet 10 §2.1):** packet 5 said MERGE, packet 7 REBUILD, this packet VERBATIM. **This packet creates the file with packet 5's content**; packet 7's 14 web-dismissal cases go to a NEW `Tests/WebNoteDraftTests.swift` (not in `delta-files.txt`, needs no claim), spec at packet 7 §4.3. Nobody ports it twice. |
| `Tests/AiConversationStoreTests.swift` | **[MERGE — content per packet 5 §4]** | `AiPersistence` per-message decode. Needs `DocumentDataStore.rootDirectoryOverride` (packet 1). |
| `Tests/AiMarkdownRenderingTests.swift` | **[REBUILD]** — sole owner, but **BLOCKED** | AI markdown renderer (AppKit `NSHostingView`/`NSTextView` harness). **Do not start this before packet 5 §I.1 lands `Vellum/Views/AI/InlineMarkdown.swift`** (packet 10 §2.1 — the file was an orphan with no owner until packet 10 folded it into packet 5; there is no production type to test without it). |
| `Tests/AiReferencePersistenceTests.swift` | **[MERGE — content per packet 5 §4]** | AI references. Needs `DocumentDataStore.rootDirectoryOverride` (packet 1). |
| `Tests/AiToolSummaryTests.swift` | **[VERBATIM]** | `AiToolSummary` |
| `Tests/AiTranscriptFollowTests.swift` | **[MERGE — content per packet 5 §4]** | AI transcript scroll-follow; packet 5 specifies the mechanical `AiPanel.` → `AiPanel_iOS.` rename. |
| `Tests/AttachmentDropTests.swift` | **[REBUILD]** (partial) | AI attachment drop — AppKit `NSDraggingInfo`/`NSPasteboard` harness |
| `Tests/DocumentActionsTests.swift` | **[MERGE — content per packet 4 §2.14]** | **Resolved (packet 10 §3.2):** the "document-actions packet (#82/#113)" was never cut and every owner disclaimed its hunks. The orchestrator **assigned that work to packet 4 as a named sub-scope (§2.14)** — `TabTeardownRegistry` hunks in `WorkspaceStore`/`AppStore`/`PaneTree`, the close half of #113, Save As state. **This suite stays in Stage 4 and lands AFTER that sub-scope.** |
| `Tests/DocumentDataStoreTests.swift` | **[MERGE — content per packet 1 §4 + packet 6 §4.5]** | `DocumentDataStore`. Packet 1 needs `ScratchpadPersistence` v2; **packet 6 relocates one GC-cutoff test into `SafeClearTests`** — a verbatim copy would leave the relocated test in both files. |
| `Tests/DocumentIdentityTests.swift` | **[MERGE — content per packet 1 §4]** | `DocumentIdentity`. iPad keeps `PdfFileGate` where main uses `PdfDocumentIO`, so the suite adapts to `PdfFileGate` stamping. Verbatim will not compile. |
| `Tests/DocumentRenameTests.swift` | **[VERBATIM]** | `DocumentRenameService` + `.scratchDefaults` |
| `Tests/DocumentsRelocationTests.swift` | **[VERBATIM]** | storage relocation |
| `Tests/HelpCenterTests.swift` | **[MERGE]** | Help centre — one `NSImage(systemSymbolName:)` line |
| `Tests/HomeSearchEngineTests.swift` | **[VERBATIM]** | `HomeSearchEngine` |
| `Tests/HomeSearchRankerTests.swift` | **[VERBATIM]** | `HomeSearchRanker` |
| `Tests/HomeSearchStoreTests.swift` | **[MERGE — content per packet 3 §4.3]** | `HomeSearchStore` + `.scratchDefaults`. Packet 3 drops the `HomeSourceTests` suite — the read-later seam does not exist on iPad until packet 8. |
| `Tests/InspectorPresentationTests.swift` | **[MERGE — content per packet 4 §4.3]** | inspector state + `.scratchDefaults`. |
| `Tests/InspectorTabSwitcherTests.swift` | **[MERGE]** | `InspectorLayout` (iPad inspector is an iOS rebuild) |
| `Tests/PageTextExtractionGateTests.swift` | **[VERBATIM]** | `PageTextExtractionGate` |
| `Tests/RecentsResolveTests.swift` | **[VERBATIM]** | recents resolve + `SecurityScopedBookmark` |
| `Tests/SafeClearTests.swift` | **[MERGE — content per packet 6 §4.4]** | recoverable destructive clears; packet 6's adaptation drops 2 tests and receives the GC-cutoff test relocated out of `DocumentDataStoreTests`. |
| `Tests/ScratchpadDropRegistrationTests.swift` | **[SKIP: AppKit-only harness — `NSWindow` + AppKit drag registration on the WebKit editor; the iPad editor registers drops through UIKit]** |
| `Tests/ScratchpadMarkdownExporterTests.swift` | **[VERBATIM]** | `ScratchpadMarkdownExporter` |
| `Tests/SettingsNavigationTests.swift` | **[MERGE — content per packet 3 §4.7]** | Settings tab enum (iPad settings is a rebuild — see §4.4). Packet 3 drops the updateChecker test: no Sparkle/updater on iPad. |
| `Tests/SheetPresenceTests.swift` | **[SKIP — dropped, confirmed]** | **Decision (packet 10 §3.3):** packet 4 had claimed this [REBUILD] and `Vellum/App/SheetPresenceMonitor.swift` with it. **Both are dropped entirely.** iOS has no attached sheets and therefore no menu-bar-disabling contract to preserve. **Packet 4 owns the replacement**: its iOS-native sheet-presence gate (`SheetPresence_iOS`, consulted by the iPad shortcut router, `.dismiss` handled by dismissing `topPresented`) plus a **new iOS test** — spec at packet 4 §4.5, name `Tests/SheetPresenceIOSTests.swift`, written by this packet like every other `Tests/` file. |
| `Tests/SidebarDropRoutingTests.swift` | **[SKIP: AppKit-only harness — `NSHostingView` + `NSPasteboard` drag routing; the iPad sidebar drop is an iOS-native rebuild]** |
| `Tests/StorageManagementTests.swift` | **[MERGE — content per packet 1 §4]** | storage inventory / housekeeping. Packet 1 drops the two Integrations tests — verbatim references `Tests/Integrations` types that do not exist until packet 8. |
| `Tests/TabResidencyTests.swift` | **[MERGE — content per packet 4 §4.1]** | `TabResidency` + `LiveTabRuntime`; packet 4 retunes three literal constants to the iPad numbers and adds `noteMemoryWarning()` coverage. |
| `Tests/VellumBundleTests.swift` | **[MERGE — content per packet 2 §4]** | `VellumBundle`; packet 2 specifies 3 iOS adaptations. |
| `Tests/WalkthroughLayoutTests.swift` | **[MERGE — content per packet 3 §4.5]** | walkthrough layout — `NSHostingView` → `UIHostingController` measurement. Packet 10 §2.1: this packet's REBUILD and packet 3's MERGE are the same intent, different word; normalised to MERGE. |
| `Tests/WalkthroughTests.swift` | **[MERGE]** | `WalkthroughContent` — two `NSImage(systemSymbolName:)` lines |

### 1.5 Tests — modified suites that exist on iPad

| file | tag | iPad state today |
|---|---|---|
| `Tests/AiPipelineTests.swift` | **[MERGE]** | iPad = base + 125 diff-lines (UIKit `bitmap` helper, container-path migration tests, §6 image tests that main *also* adds — **overlap, dedupe required**) |
| `Tests/MarkdownParserTests.swift` | **[MERGE — content per packet 5 §I.2 + packet 7 §4.2]** | byte-identical to main's pre-delta version, **but VERBATIM does not compile at all** (packet 10 §1.1/§2.1): main's new `testLists` asserts `.list([MarkdownListItem(depth:marker:text:)])` and iPad's `MarkdownParser` still has `case unordered`/`case ordered` until packet 5 §I.2 lands `MarkdownMessage.swift`. Packet 7 adds 11 `#127` cases on top. **Blocked on packet 5 §I.2.** |
| `Tests/PageTextCacheTests.swift` | **[MERGE — content per packet 1 §4]** | byte-identical to base; packet 1's docId re-key changes every call site. |
| `Tests/PaneTreeTests.swift` | **[MERGE — content per packet 4 §4.2]** | byte-identical to base; packet 4 adds the 25 new tests from #74/#83/#108 onto iPad's diverged 11. |
| `Tests/PdfPersistenceTests.swift` | **[MERGE]** | iPad = base + iOS touch-selection resize suite + perf tests (451 diff-lines) |
| `Tests/ScratchpadImportTests.swift` | **[MERGE]** | iPad = base with UIKit bitmap helpers (`UIGraphicsImageRenderer`) |
| `Tests/SelectableMessageTests.swift` | **[REBUILD — content per packet 5 §I.3]** | iPad is already a full iOS rebuild (82 lines vs main's 128 base); main adds 399 AppKit-hosted lines. **This suite had no production owner until packet 10 §1.1 folded `SelectableMessageText.swift` into packet 5** — its spec is packet 5 §I.3 (`AttachmentText`, `fittedAttachments(in:width:)`, `measureSize`, `mathMaxWidth`, the new `attributedString(for:)` signature). |
| `Tests/WebLibraryStorageTests.swift` | **[MERGE — content per packet 6 §4.2 + packet 7 §4.4]** | byte-identical to base; packet 6 adds the `is_pinned` case, packet 7 the offline case. |
| `Tests/WebProxyUrlTests.swift` | **[MERGE — content per packet 7 §4.5]** | byte-identical to base; one-line `@MainActor` on the class. |

### 1.6 Repo docs, CI and macOS project artifacts (all SKIP)

| file | tag |
|---|---|
| `.github/workflows/claude.yml` | **[SKIP: GitHub only dispatches `issue_comment` / `issues` workflows from the repository's DEFAULT branch, so this file works for `ipad-app` PRs as soon as it is on `main` — nothing to port onto the branch]** |
| `AGENTS.md` | **[SKIP: docs — the only added section documents the macOS `NSDraggingInfo` drop harness, which does not exist on iPad]** |
| `CLAUDE.md` | **[SKIP: docs — the iPad `CLAUDE.md` is a different, user-authored file; do not overwrite it]** |
| `CHANGELOG.md` | **[SKIP: docs — the iPad worktree has no `CHANGELOG.md`]** |
| `Vellum.xcodeproj/project.pbxproj` | **[SKIP: macOS-generated project; the iPad regenerates its own via xcodegen]** |
| `Vellum.xcodeproj/xcshareddata/xcschemes/VellumUITests.xcscheme` | **[SKIP: no `VellumUITests` target on iOS]** |
| `UITests/README-setup.md` (deleted) | **[SKIP: macOS UITests target, out of scope]** |
| `UITests/README.md` | **[SKIP: macOS UITests target]** — read it once for the launch-argument contract §2.2 implements |
| `UITests/ScratchpadSnapshotUITests.swift` | **[SKIP: macOS UITests target]** |
| `UITests/VellumConsistencyUITests.swift` | **[SKIP: macOS UITests target]** |
| `UITests/VellumUITestCase.swift` | **[SKIP: macOS UITests target]** |
| `plans/001-verification-baseline.md` … `plans/008-restore-window-open-interception.md` (8 deleted) | **[SKIP: plans/docs]** |
| `plans/README.md` (deleted) | **[SKIP: plans/docs]** |
| `plans/storage-design.html` (deleted) | **[SKIP: plans/docs]** |
| `plans/read-later-integrations.html` (added) | **[SKIP: plans/docs — background reading for packet 8]** |

`tools/`: **no delta**. Main's range touches nothing under `tools/`; the iPad's `tools/scratchpad-editor`
stays as-is. Nothing to do.

**Not claimed here** (owned elsewhere; see Appendix A for the full sweep): every file under
`Vellum/Services/`, `Vellum/Stores/`, `Vellum/Views/`, `Vellum/Models/`, `Vellum/App/` except the
three named in §1.1, plus all of `Tests/Integrations/**` (packet 8).

---

## 2. Port order & instructions

### Stage 0 — unblocks every other packet (do this first, no dependencies)

Three files. `WebLibrary.swift` and `PageTextCache.swift` on main both reference
`UITestLaunchConfiguration.storageRoot`, and `KeychainStore` references both new types, so packet 7
and packet 5 **cannot compile their verbatim copies** until Stage 0 lands.

#### 0.1 `Vellum/Services/TestEnvironment.swift` — [VERBATIM]

```
src : git -C $MAIN show 7742a895:Vellum/Services/TestEnvironment.swift
dest: $IPAD/Vellum/Services/TestEnvironment.swift
```

Pure Foundation, 24 lines, zero platform code. Copy byte-for-byte, no edits. It exposes one thing:

```swift
enum TestEnvironment { static let isHostedTestProcess: Bool }
```

detected from `XCTestConfigurationFilePath` / `XCTestSessionIdentifier` / `XCTestBundlePath` /
`NSClassFromString("XCTestCase")`. All four markers behave identically on iOS.

#### 0.2 `Vellum/App/UITestLaunchConfiguration.swift` — [REBUILD]

Main's file (79 lines) is Foundation-only but wires four things that do not all exist on iPad yet
(`WebStorageSettings.setMode` ✓ exists, `WalkthroughSettings.markSeen()` ✗ arrives with the
packet 3, `AppDefaults.current` ✗ arrives with the packet 1) and hard-codes the
macOS bundle id `com.vellum.app` (the iPad's is `com.ayushdeolasee.vellum`).

Because the iPad has **no XCUITest target and no `UITesting` build configuration**, `isEnabled` is
always `false` in every real launch, so the body is dead code that exists only so the verbatim
copies of `WebLibrary`/`PageTextCache`/`KeychainStore` compile. Write this trimmed version now:

```swift
import Foundation

/// Process-boundary configuration for a UI-test runner.
///
/// The iPad target has no XCUITest bundle today (macOS #87 added one; iOS did
/// not), so `isEnabled` is always false here and every switch below is inert.
/// The type is still ported verbatim-in-shape because `WebLibrary.appDataDir`,
/// `PageTextCache` and `KeychainStore` read it, and because an iOS UI-test
/// target would need exactly these seams.
enum UITestLaunchConfiguration {
    static let isEnabled = ProcessInfo.processInfo.arguments.contains("--ui-testing")

    /// The shipping app's bundle identifier. If a UI-test configuration is ever
    /// added it must carry a DIFFERENT identifier; the reset below refuses to
    /// run under the production one rather than wipe a real user's library.
    private static let productionBundleIdentifier = "com.ayushdeolasee.vellum"

    static var storageRoot: URL? {
        guard isEnabled,
              let path = value(after: "--ui-test-storage-root"),
              !path.isEmpty
        else { return nil }
        return URL(fileURLWithPath: path, isDirectory: true)
    }

    /// Runs before any store reads UserDefaults. Returns a document path to open.
    @discardableResult
    static func prepare() -> String? {
        guard isEnabled else { return nil }

        if ProcessInfo.processInfo.arguments.contains("--ui-test-reset-state"),
           let bundleIdentifier = Bundle.main.bundleIdentifier {
            if bundleIdentifier == productionBundleIdentifier {
                FileHandle.standardError.write(Data("""
                    [UITest] Refusing --ui-test-reset-state: this build uses the \
                    production bundle identifier \(productionBundleIdentifier).

                    """.utf8))
            } else {
                UserDefaults.standard.removePersistentDomain(forName: bundleIdentifier)
            }
        }

        // Avoid the first-launch storage sheet and all iCloud/custom storage
        // resolution. The app-data root itself is redirected by `storageRoot`.
        WebStorageSettings.setMode(.local)

        // TODO(packet: walkthrough) once WalkthroughSettings lands, restore:
        //   if !ProcessInfo.processInfo.arguments.contains("--ui-test-show-walkthrough") {
        //       WalkthroughSettings.markSeen()
        //   }
        // TODO(packet: foundation/AppDefaults) once AppDefaults lands, restore:
        //   if ProcessInfo.processInfo.arguments.contains("--ui-test-corrupt-restoration") {
        //       AppDefaults.current.set("{not valid workspace json", forKey: "vellum.workspace")
        //   }

        if let root = storageRoot {
            try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        }

        return value(after: "--ui-test-open-document")
    }

    private static func value(after switchName: String) -> String? {
        let arguments = ProcessInfo.processInfo.arguments
        guard let index = arguments.firstIndex(of: switchName),
              arguments.indices.contains(index + 1)
        else { return nil }
        return arguments[index + 1]
    }
}
```

Come back and un-comment the two `TODO(packet: …)` blocks the moment `WalkthroughSettings` and
`AppDefaults` exist (they are one-line restorations of main's exact code). Do **not** invent an iOS
UI-test target.

`VellumApp.swift` on main calls `UITestLaunchConfiguration.prepare()` from `init()` (line 105) and
guards a restoration path with `isEnabled` (line 186). `VellumApp.swift` is normalised to
`[REBUILD → Platform/iOS/VellumApp_iOS.swift]` with **packet 4 as the named sequencer** (packet 10
§2.2) — tell packet 4 the symbol exists; on iPad `prepare()` is a no-op and calling it is optional.
**This packet owns `Vellum/App/UITestLaunchConfiguration.swift` and
`Tests/UITestLaunchConfigurationTests.swift` outright** — packet 4 SKIPs both, so there is no
conflict (packet 10 §2.1).

#### 0.3 `Vellum/Services/KeychainStore.swift` — [VERBATIM]

```
src : git -C $MAIN show 7742a895:Vellum/Services/KeychainStore.swift
dest: $IPAD/Vellum/Services/KeychainStore.swift   (overwrite)
```

The iPad's file is **byte-identical to main's pre-delta version** — verify with
`diff <(git -C $MAIN show a42705d1~1:Vellum/Services/KeychainStore.swift) $IPAD/Vellum/Services/KeychainStore.swift`
(must print nothing) and then overwrite. There is nothing to hand-merge.

What main's 486-line replacement adds (three commits: `377bcfd1` #97, `67d2ac67` #128, plus the
prewarm/lock hardening):

1. **Test fake (#97, the reason this file is in my scope).**
   ```swift
   private static var isRunningTests: Bool {
       UITestLaunchConfiguration.isEnabled || TestEnvironment.isHostedTestProcess
   }
   private static let testStore = OSAllocatedUnfairLock<[String: String]>(initialState: [:])
   ```
   Under test, `get`/`set`/`delete` round-trip through an in-memory dictionary and never touch the
   real keychain. This is what stops `xcodebuild test` from re-prompting for the login keychain
   password on every rebuild and stops tests reading the developer's real API keys.
2. **Service namespaces**: `get/set/delete` gain `service: String = service`. Packet 8's
   `KeychainIntegrationCredentials` calls these with `service: "com.vellum.integrations"` — this is
   packet 8's dependency **D1**, satisfied by Stage 0.3.
3. **Single-item "vault"**: every secret lives in one generic-password item
   (`com.vellum.vault`/`vault`) holding JSON `["service/account": secret]`, cached in memory, with
   a mod-date probe for cross-instance freshness, an `flock`-based cross-process commit lock
   (3 s deadline, 20 ms poll) on `WebLibrary.appDataDir/keychain-vault.lock`, and a legacy
   reconciler that folds pre-vault per-secret items in `com.vellum.ai` / `com.vellum.integrations`
   into the vault (later-write-wins by mod date; never deletes a value it cannot prove is
   preserved).
4. **`prewarm()`**: loads the vault on `DispatchQueue.global(qos: .userInitiated)` so the first
   `@MainActor` `get` is a cache hit. No-op under test.
5. **`Backend` seam + `#if DEBUG withBackend(_:_:)`**: the injection point `KeychainStoreTests`
   drives. Keep the `#if DEBUG` — the tests are Debug-only.

iOS compatibility check (all verified, no edits needed):

* `import os` → `OSAllocatedUnfairLock` is iOS 16+; deployment target is iOS 26. ✓
* `flock`, `open`, `usleep`, `LOCK_EX|LOCK_NB` come from Darwin via Foundation. ✓
* `WebLibrary.appDataDir` exists on iPad (`Vellum/Services/Web/WebLibrary.swift:67`). ✓
* `Security` generic-password APIs are identical on iOS; there is no login-keychain prompt, so the
  prompt-avoidance machinery is inert but harmless. ✓
* `Account` enum is unchanged (`gemini`, `openai`, `openrouter`, `opencode`, `opencode-go`,
  `chatgpt-tokens`) — the iPad's ChatGPT OAuth-on-`ASWebAuthenticationSession` path keeps working
  through `Account.chatgptTokens`. ✓

Optional cosmetic edit: the header comment says "macOS Keychain" — change to "Keychain". Nothing
functional.

**Behavioural consequence on real iPads**: an existing install's per-account items under service
`com.vellum.ai` are migrated into the vault on the first `get` after this ships, and the legacy
items are deleted only once the vault provably holds their value. This is the intended path; do not
"simplify" the reconciler away. Verify on a device that already has a Gemini/OpenAI key saved.

#### 0.4 `project.yml` — Stage 0 half

Only one hunk is needed before tests can build; see §3 for the full treatment. Add the
`Tests/Integrations/Fixtures` resource wiring (shared with packet 8 — apply once, coordinate) and
re-run `xcodegen generate`.

---

### Stage 1 — defaults isolation (needs `AppDefaults` from the packet 1)

`Vellum/Services/AppDefaults.swift` is **not** mine (packet 1), but all three files here
are dead without it. Confirmed state today: the iPad has **no `AppDefaults` at all** —
`RecentFilesService`, `WorkspaceService` and `ScratchpadPersistence` still read
`UserDefaults.standard` directly. Do not start Stage 1 until `AppDefaults.swift` is in and those
three services have been re-pointed at `AppDefaults.current`.

#### 1.1 `Tests/ScratchDefaultsTrait.swift` — [VERBATIM]

```
src : git -C $MAIN show 7742a895:Tests/ScratchDefaultsTrait.swift
dest: $IPAD/Tests/ScratchDefaultsTrait.swift
```

59 lines, Foundation + Swift Testing only. Provides:

* `struct ScratchDefaultsTrait: TestTrait, SuiteTrait, TestScoping` with `isRecursive = true`,
  whose `provideScope` opens `UserDefaults(suiteName: "vellum.scratch.<UUID>")`, runs the test body
  inside `AppDefaults.withDefaults(...)`, and removes the suite afterwards;
* the free function `removeSuite(_:named:)` — which also unlinks
  `~/Library/Preferences/<name>.plist` (on iOS that is inside the app/test container, so it works
  the same and stops per-test plists accumulating);
* `extension Trait where Self == ScratchDefaultsTrait { static var scratchDefaults: Self }`.

No iOS edits. Consumers in this delta: `DocumentRenameTests`, `HomeSearchStoreTests`,
`InspectorPresentationTests` (`@Suite(..., .scratchDefaults)`), plus `AppDefaultsGuardTests` which
calls `removeSuite` directly.

**This is the first Swift Testing file in the iPad `Tests/` target** — today every iPad test is
XCTest (`grep -rl "import Testing" Tests/` returns nothing). See §5 R2.

#### 1.2 `Tests/AppDefaultsGuardTests.swift` — [VERBATIM]

118 lines, Swift Testing. Asserts the floor: `AppDefaults.current !== UserDefaults.standard` in a
hosted test process, and that a `WorkspaceService.save`, a `RecentFilesService.record` and a
`ScratchpadPersistence.removeLegacyEntry` cannot land in `.standard`. Each write test calls
`requireFloor()` first so it fails **before** writing if the guard regressed.

APIs it needs on iPad (all present or arriving with the packet 1):
`WorkspaceService.save(_:)` / `.load()` / `.clear()` ✓ exist;
`RecentFilesService.storageKey` ✓ is internal on iPad; `RecentFilesService.record(DocumentInfo)` ✓;
`ScratchpadPersistence.notesKey` ✓ / `removeLegacyEntry(key:)` ✓;
`WorkspaceState(root: .leaf(tabs: [], activeTabIndex: nil), focusedLeafIndex: 0)` — check the
iPad's `PaneTree`/`WorkspaceState` initializer signature still matches after the packet 4 lands
and adjust the literal if it diverged. Everything else is verbatim.

#### 1.3 `Tests/UITestLaunchConfigurationTests.swift` — [REBUILD]

Main's 64-line XCTest file has three tests. Port it as follows (keep the file name — it is the
regression guard for both #97 and #87 seams):

* `testDisabledWithoutTheLaunchArgument` — **keep verbatim**. Asserts `--ui-testing` is absent,
  `isEnabled == false`, `storageRoot == nil`.
* `testPrepareIsANoOpWhenDisabled` — **rebuild**. Main saves/restores `WalkthroughSettings.seenKey`
  and `WebStorageSettings.modeKey` and asserts `WalkthroughSettings.hasSeenWalkthrough == false`
  after `prepare()`. Until the packet 3 lands, reduce to: snapshot
  `UserDefaults.standard.object(forKey: WebStorageSettings.modeKey)`, assert
  `XCTAssertNil(UITestLaunchConfiguration.prepare())`, assert the mode key is unchanged, restore.
  Re-add the walkthrough half when `WalkthroughSettings` exists.
* `testKeychainUsesTheInMemoryStoreUnderTest` — **keep verbatim**. This is the #97 guard: asserts a
  hosted test process is detectable from its environment, then round-trips a random account through
  `KeychainStore.set/get/delete`. It works unchanged on iOS.

---

### Stage 2 — the keychain vault suite (needs Stage 0.3)

#### 2.1 `Tests/KeychainStoreTests.swift` — [VERBATIM]

412 lines, Swift Testing, `@Suite("Keychain vault", .serialized)`, Foundation only. Copy
byte-for-byte. It drives `KeychainStore.withBackend(_:_:)` with a private `FakeKeychain` class that
implements all nine `Backend` closures over in-memory dictionaries with a monotonic mod-date clock.
Coverage: legacy migration, newer-legacy-wins, undecidable-conflict-keeps-both, redundant-legacy
cleanup, unreadable-legacy retry, cross-instance freshness, fail-closed on unreadable vault, commit
lock unavailable, empty-value delete, `prewarm` off-main-thread, and — the last test — that the
in-memory stand-in is back in force once `withBackend` returns.

iOS notes: nothing to change. `.serialized` matters (the backend override and vault cache are
process-global); keep it. The suite asserts exact read/write counts, so do not let another Swift
Testing suite touch `KeychainStore` — if a future iPad suite needs credentials, give it a double.

---

### Stage 3 — merge the nine modified suites

#### 3.1 `Tests/AiPipelineTests.swift` — [MERGE] ⚠ overlap

* **iPad today (575 lines)** = base (452) + `import UIKit` + two iOS-only tests
  (`testConversationSurvivesContainerPathChange`, `testWebPdfUrlDoesNotMigrateLocalConversation` —
  the iOS data-container-UUID migration) + a `// MARK: - §6 Arbitrary image attachments` block +
  a UIKit `static func bitmap(width:height:alpha:)` built on `UIGraphicsImageRendererFormat`.
* **main adds 871 lines**, including a §6 block that **duplicates four tests the iPad already has**
  (`testAttachedImageIsDownscaledAndTranscoded`, `testAttachedImageWithAlphaStaysPng`,
  `testAttachedImageRejectsNonImageBytes`, `testReferenceLineForAttachedImageHasNoPage`,
  `testSupportsVisionResolution`) plus main's AppKit `bitmap` helper
  (`NSBitmapImageRep(...).representation(using: .png)`).

Merge recipe:

1. **Keep** the iPad's `import UIKit`, both container-path tests, and the iPad's `bitmap` helper.
   **Do not** copy main's `NSBitmapImageRep` version — duplicate method names in the same
   `XCTestCase` subclass is a compile error, and `NSBitmapImageRep` does not exist on iOS.
2. **Skip** main's five §6 tests that the iPad already has (identical bodies).
3. **Add** the two §6 tests the iPad lacks: `testFileAttachmentClassification` and
   `testBinaryFileIsRejectedByName` — both use `Self.bitmap(...)` and `aiFileAttachment(from:)`,
   both are pure Foundation once the helper is the iPad's.
4. **Add** main's new blocks verbatim (all XCTest, no AppKit):
   * `// MARK: - §5 OpenAI reasoning effort (#94)` — 8 tests plus
     `testOpenAIOutputBudgetIsFlatForNonReasoningModels`,
     `testOpenAIAutoGetsAMidRangeBudgetNotTheMinimalOne`;
   * `testOpenRouterResolvesOpenAIEffortsThroughTheSharedTable` + its local `effort(_:_:)` helper;
   * `// MARK: - Tool loop vs. the output-token limit (#107)` — 5 tests +
     `toolCallFixture(truncated:text:)`;
   * `// MARK: - Composer focus requests` — 3 tests;
   * `// MARK: - Capture targets survive the await` — 3 tests + `static func tab(id:document:)`;
   * `// MARK: - §5 Gemini thinking levels & output budget (#96)` — with
     `static func geminiBody(_:_:)`.
5. **Apply the rename**: `testComposeAssistantContentWithoutReceiptsIsJustTheReply` →
   `testAssistantAnswerIsTheTrimmedReplyAndNothingElse`, taking main's new body.
6. Port **after** the packet 5 (needs `AiModelCatalog` effort tables, the tool-loop truncation
   handling, composer focus requests and capture-target guards) and **after** the packet 4
   (`PdfTab` fixture helper).

#### 3.2 `Tests/PdfPersistenceTests.swift` — [MERGE]

iPad diverged: it renamed the selection-resize tests (`testDragEndPastStartHolds` →
`testDragEndPastStartHoldsLastFrame`, `midY` → `midpointY`, etc.), made them non-`throws`, added
`import CoreText`, a `record(_ gap:)` gap tracker, `makeLargePdf`, and two iPad-only tests
(`testUnrelatedCreateDoesNotClaimForeignAnnotation`,
`testCreateAnnotationKeepsMainActorResponsiveOnLargePdf`). **Preserve all of that.**

Main adds exactly three tests (+142 lines) — append them, nothing else changes:

* `testBookmarkTitleCreateUpdateClear()` (from #61, editable PDF bookmark titles);
* `testPinHighlightPersistsAndSortsFirst()`;
* `testPinBookmarkPersistsAndSortsFirst()`.

All three assert `/Vellum*` PDF key round-trips, so they double as byte-compatibility guards. Port
after packet 6 lands bookmark titles + pinning. Keep the iPad's `CreateAnnotationInput`
`createdAt` argument wherever main's new tests construct annotations — main's call sites omit it, so
add the label if the iPad's initializer requires it.

#### 3.3 `Tests/ScratchpadImportTests.swift` — [MERGE] (trivial, 6 lines)

iPad differs only in the image helpers (`UIGraphicsImageRenderer`/`pngData()`/
`jpegData(compressionQuality:)` instead of `NSBitmapImageRep`) — keep those. Apply main's two hunks:

```swift
// in tearDown(), after `ScratchpadAttachmentStore.directoryOverride = nil`
ScratchpadAttachmentStore.activeDirectory = nil
// This suite calls `addImage`, which claims a GC exemption for each id it
// writes (#105). Harmless if it leaks — the keys are UUIDs — but the
// registry is process-global, so leave it as we found it.
ScratchpadAttachmentStore.resetPending()
```

and the call-site change `ScratchpadAttachmentStore.collectGarbage(referencedIds:)` →
`collectGarbage(in: tempDir, referencedIds:)`. Needs the packet 6's
`activeDirectory` / `resetPending()` / `collectGarbage(in:referencedIds:)` API first.

#### 3.4 `Tests/SelectableMessageTests.swift` — [REBUILD]

The iPad file is already an iOS-native rebuild: it drops `MessageContainerView`/`NSHostingView`
reentrancy tests and tests `SelectableTextView.sizeThatFits`, `AiAttributedRenderer` with
`.label`/`.secondaryLabel`, and `appliedContent`. **Keep it.**

Main's +399 lines are three AppKit-hosted groups; treat them as follows:

* `testBubbleGrowsPastTheOldFixedCapWhenGivenAWiderMaxWidth`,
  `testShortReplyHugsWhileALongOneStillFillsTheColumn`, `testHuggingNeverClipsTypesetMath`,
  `testDisplayMathScalesWithTheBubbleWidth`, `testWidthOnlyUpdateSkipsRerenderForAReplyWithNoMath`,
  `testWidthOnlyUpdateRerendersAReplyThatContainsMath` — mounted via `NSHostingView` +
  `mountedBubble`/`measureBubble`. **Rebuild** on `UIHostingController(rootView:)` +
  `view.systemLayoutSizeFitting(_:withHorizontalFittingPriority:verticalFittingPriority:)`, or
  `sizeThatFits(in:)` on the hosting controller, once the packet 5 ports the resizable-bubble
  sizing. If the iPad's AI sidebar is not resizable, **skip** this group and say so in a comment.
* The `measure(offered:_:)` SwiftUI-only group (`testDefaultStillFillsTheOfferedWidth`,
  `testOptingOutHugsTheContent`, `testOptingOutStillWrapsAtTheOfferedWidth`,
  `testBubbleWidthCapLimitsWithoutStretching`, `testBubbleWidthCapNeverExceedsANarrowerProposal`,
  `testDegenerateMeasurementsFallBackToTheFixedWidth`, `testBubbleWidthsAtTheSidebarExtremes`,
  `testBubbleNeverExceedsItsColumnAcrossTheSidebarRange`) measures SwiftUI views — port these by
  swapping the `NSHostingView` measurement helper for a `UIHostingController` one; the assertions
  themselves are platform-neutral.
* The chips group (`testChipsWrapAtTheCapNotTheOfferedWidth`,
  `testChipsNeverExceedTheUserBubbleAcrossTheSidebarRange`) depends on
  `Vellum/Views/AI/SentReferenceChips.swift` (packet 5). Port with the same measurement swap.

Anything using `NSAttributedString` attachment introspection (`firstAttachmentWidth(in:)`) works on
iOS as-is — `NSAttributedString`/`NSTextAttachment` are Foundation/UIKit types there.

#### 3.5 Five suites whose iPad copy is byte-identical to base

⚠ **These are no longer "clean adoptions".** Packet 10 §2.1 downgraded all five from `[VERBATIM]`
to `[MERGE — content per the named feature packet]`: byte-identity with *base* does not imply the
incoming file compiles against the iPad's *current* production code. `MarkdownParserTests` is the
worst case — it does not compile at all until packet 5 §I.2 lands. Take the content spec from the
owner column, not from main's file alone.

| file | what main added | port after |
|---|---|---|
| `Tests/MarkdownParserTests.swift` | `testLists` rewritten for the new `.list([MarkdownListItem(depth:marker:text:)])` shape; 12 new `MathRenderer.segments`/`codeSpanRanges` tests for #99 (code spans vs the math splitter, escaped `\(`/`\)`, astral-plane offsets, mismatched backtick runs) | **packet 5 §I.2** (`MarkdownParser` list model — a hard compile dependency) **then packet 7 §2.5/§4.2** (`MathRenderer.codeSpanRanges` + its 11 `#127` cases). **Not a clean adoption** — see §1.5. |
| `Tests/PageTextCacheTests.swift` | every call re-keyed to `cache.lookup(key:path:data:title:)` / `write(key:path:…)`; `PageTextCache.pathKey(_:)`; renamed `testEvictStaleRespectsCutoffAndKeyExclusions`; new `testLookupMigratesLegacyPathKeyEntry`, `testLookupUpdatesPathWhenSeenAtNewLocation` | **packet 1** (`PageTextCache` docId re-key — packets 5 and 7 both SKIP it to packet 1) |
| `Tests/PaneTreeTests.swift` | `import PDFKit`; +597 lines: tab-ownership transfer on merge, find-state follows its tab, the whole `LiveTabRuntime` residency suite (LRU eviction, memory pressure, per-pane pinning, cost accounting), pane pruning, workspace close routing, serialization of transient tabs, per-tab pending note/region capture | packet 4 (`LiveTabRuntime`, `TabResidency`) |
| `Tests/WebLibraryStorageTests.swift` | `testKeepOfflineStatusRequiresAnActualSnapshot`, `testPinAnnotationPersistsAndSortsFirst` (asserts the literal `is_pinned` snake_case key in the JSON sidecar — a byte-compat guard, keep it exactly) | **packet 6 §4.2** (`is_pinned`) **+ packet 7 §4.4** (offline) — two owners, one file |
| `Tests/WebProxyUrlTests.swift` | one line: `@MainActor` on the class | packet 7 (or immediately — it is a one-line edit) |

---

### Stage 4 — new feature suites

Port each **after** its production packet. Adaptation rules in §4. Suggested order (cheapest and
least dependent first):

1. Pure-logic Swift Testing suites, no UI: `AiToolSummaryTests`, `HomeSearchEngineTests`,
   `HomeSearchRankerTests`, `HomeSearchStoreTests`, `InspectorPresentationTests`,
   `DocumentRenameTests`, `TabResidencyTests`.
2. Pure-logic XCTest suites: `AiConversationStoreTests`, `AiReferencePersistenceTests`,
   `AiAddAsNoteTests`, `AiTranscriptFollowTests`, `PageTextExtractionGateTests`,
   `DocumentDataStoreTests`, `DocumentIdentityTests`, `DocumentActionsTests`,
   `DocumentsRelocationTests`, `RecentsResolveTests`, `SafeClearTests`, `StorageManagementTests`,
   `VellumBundleTests`, `ScratchpadMarkdownExporterTests`, `SettingsNavigationTests`.
3. One-line platform swaps: `HelpCenterTests`, `WalkthroughTests`, `InspectorTabSwitcherTests`.
4. Measurement rebuilds: `WalkthroughLayoutTests`, `AiMarkdownRenderingTests`,
   `AttachmentDropTests` (partial).
5. Never: `SheetPresenceTests` (**dropped by decision** — packet 10 §3.3; replaced by
   `Tests/SheetPresenceIOSTests.swift`, spec at packet 4 §4.5, which belongs in group 2),
   `SidebarDropRoutingTests`, `ScratchpadDropRegistrationTests`.

**Ordering constraints inside Stage 4** (packet 10 §2.1/§3.2):
* `AiMarkdownRenderingTests` — **blocked** until packet 5 §I.1 lands `InlineMarkdown.swift`.
* `MarkdownParserTests` — **blocked** until packet 5 §I.2 lands the `MarkdownListItem` model.
* `SelectableMessageTests` — **blocked** until packet 5 §I.3.
* `DocumentActionsTests` — lands **after** packet 4 §2.14 (the document-actions sub-scope).
* `AiAddAsNoteTests` — packet 5's content only; packet 7's 14 web-dismissal cases are a separate
  new file, `Tests/WebNoteDraftTests.swift`.

---

### Stage 5 — plist + build settings

See §3. **This packet owns `Info-iOS.plist`, `.gitignore` and `project.yml` outright** (packet 10
§2.2). Do the `Info-iOS.plist` document-type work alongside packets 1 and 2 (`VellumBundle` — it is
what makes `.vellum` files openable from Files.app), taking their changes as specifications rather
than letting them write the file; packet 2's cosmetic `Info.plist` copy is dropped. The
`.gitignore` line lands whenever. **The warnings-as-errors decision is §3.5** — state it once,
here, and nowhere else.

---

## 3. `project.yml` / `Info-iOS.plist` / entitlements

### 3.1 `project.yml` — what applies and what does not

> **This packet is the SOLE editor of `project.yml`** (packet 10 §2.2). Packets 1, 2, 4, 6 and 8
> all named it; three of them tagged it MERGE. xcodegen re-reads the whole file for every target,
> so **packets 1 and 8 hand their hunks here** rather than editing it — packet 8's is the
> `VellumTests` sources/excludes + `Tests/Integrations/Fixtures` resource wiring, which is the
> same hunk §D4 already flagged as shared; packet 1 has no concrete hunk of its own. **One
> `xcodegen generate` per landing, not five.**

Main's diff has six changes. The iPad project is **iOS-only and must not gain a macOS target**.

| main's change | apply to iPad? |
|---|---|
| `configs: {Debug: debug, Release: release, UITesting: debug}` | **NO** — the `UITesting` config exists only for the macOS XCUITest bundle-id split. Adding it forces every iPad target to declare a third config for no benefit. |
| `CODE_SIGN_IDENTITY: "Apple Development"` + `CODE_SIGN_STYLE: Automatic` + `DEVELOPMENT_TEAM: 9DCG97VASG` (replacing ad-hoc `-`) | **ALREADY DONE** — the iPad `project.yml` already has `CODE_SIGN_STYLE: Automatic` and `DEVELOPMENT_TEAM: 9DCG97VASG` (lines 16-17) and never used ad-hoc signing. No change. Do **not** add `CODE_SIGN_IDENTITY: "Apple Development"` explicitly; automatic signing picks the iOS identity. |
| new `VellumUITests` target (`type: bundle.ui-testing`, `platform: macOS`) + `VellumUITests` scheme | **NO** — out of scope (no iOS UI-test target). |
| `VellumTests` sources: exclude `Integrations/Fixtures`, then re-add it as a `type: folder` resource build phase | **YES** — required by packet 8's `FixtureLoader`. **This packet applies it, once** (packet 10 §2.2); packet 8 hands over the hunk and verifies afterwards. |
| `SWIFT_TREAT_WARNINGS_AS_ERRORS: "YES"` + `GCC_TREAT_WARNINGS_AS_ERRORS: "YES"` on both `Vellum` and `VellumTests` | **NO — decided, see §3.5.** From #86 ("make builds warning-free"), which was macOS-only cleanup. **The iPad does NOT adopt warnings-as-errors in #129.** |
| `Vellum` target `configs: UITesting: PRODUCT_BUNDLE_IDENTIFIER: com.vellum.app.uitesting` | **NO** — depends on the `UITesting` config. |

Resulting iPad `VellumTests` target (the only edit):

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

Leave `PRODUCT_BUNDLE_IDENTIFIER`, `TEST_HOST` and `BUNDLE_LOADER` exactly as they are (they are
iPad-specific and correct). Note the iPad's `Vellum` target keeps its `Resources/katex` folder
reference and its `Info-iOS.plist` exclusion — do not let a copy-paste from main's file drop those.

No new Swift packages: main's range adds none (`SwiftMath 1.7.3` is still the only one).

Run `xcodegen generate` and commit the regenerated `Vellum.xcodeproj/project.pbxproj`.

### 3.2 `Info-iOS.plist`

Main's `Info.plist` diff does four things; map them like this:

1. **Removes `NSMicrophoneUsageDescription` and `NSSpeechRecognitionUsageDescription`** (voice/TTS
   deletion). **Already satisfied** — `Info-iOS.plist` never declared either. Verify with
   `grep -i "microphone\|speech" Vellum/Resources/Info-iOS.plist` → no hits. Nothing to do.
2. **Adds a `CFBundleDocumentTypes` entry for `com.vellum.bundle`** (`.vellum`) and, on macOS,
   entries for PDF + web archive. The iPad already declares PDF and web-archive document types.
   **ADD** the bundle entry (drop `CFBundleTypeRole`, which is macOS-only; the iPad's existing
   entries omit it too):

   ```xml
   <dict>
       <key>CFBundleTypeName</key>
       <string>Vellum Bundle</string>
       <key>LSHandlerRank</key>
       <string>Owner</string>
       <key>LSItemContentTypes</key>
       <array>
           <string>com.vellum.bundle</string>
       </array>
   </dict>
   ```

3. **Adds `UTExportedTypeDeclarations` for `com.vellum.bundle`** (conforms to `public.data`,
   `public.zip-archive`; extension `vellum`). **ADD verbatim** — the `VellumBundle` import/export
   path (packet 1) needs a declared type for the Files.app / share-sheet round trip:

   ```xml
   <dict>
       <key>UTTypeIdentifier</key>
       <string>com.vellum.bundle</string>
       <key>UTTypeDescription</key>
       <string>Vellum Bundle</string>
       <key>UTTypeConformsTo</key>
       <array>
           <string>public.data</string>
           <string>public.zip-archive</string>
       </array>
       <key>UTTypeTagSpecification</key>
       <dict>
           <key>public.filename-extension</key>
           <array>
               <string>vellum</string>
           </array>
       </dict>
   </dict>
   ```

4. **Adds `com.vellum.webarchive`** (`.vellumweb`). ⚠ **Identifier mismatch**: the iPad already
   declares the same extension under a *different* identifier, `com.vellum.vellumweb`
   (`Info-iOS.plist:66,74`). **Recommended**: rename the iPad's to `com.vellum.webarchive` and add
   `public.zip-archive` to its `UTTypeConformsTo`, so a `.vellumweb` AirDropped between the Mac and
   the iPad resolves to the same type. This is safe: **no Swift code on either side references
   either identifier** (verified — only `com.vellum.tab` is referenced, from
   `Vellum/Views/Panes/TabDrag.swift`). If the packet 7 has since introduced a
   `UTType("com.vellum.vellumweb")` call site, update it in the same commit. The **file format is
   untouched** — the `.vellumweb` zip layout stays byte-compatible either way.

Leave everything else in `Info-iOS.plist` alone (`UILaunchScreen`, `UIApplicationSceneManifest`,
`UISupportedInterfaceOrientations~ipad`, `LSSupportsOpeningDocumentsInPlace`, `UIFileSharingEnabled`,
`com.vellum.tab`, `NSAppTransportSecurity`). Never add `NSPrincipalClass: NSApplication`.

### 3.3 Entitlements

**No change.** Main's delta touches no entitlements file; the iPad deliberately leaves
`Vellum/Vellum-iOS.entitlements` unwired (see the comment at `project.yml:71-74` — the free signing
team can't provision iCloud). The new `KeychainStore` needs **no** explicit entitlement: automatic
signing gives the app its default `keychain-access-groups` (`$(AppIdentifierPrefix)$(CFBundleIdentifier)`),
which is enough for its own generic-password items. Verify once on a real device that `set` →
`get` round-trips after a cold launch (see §5 R1).

### 3.4 `.gitignore` — [MERGE]

**This packet owns it** (packet 10 §2.2 — packet 2 SKIPs). Append main's one stanza (the iPad
file otherwise already matches main):

```
# Agent scratch (mutation scripts, build logs)
.logs/
```

### 3.5 Warnings-as-errors — **the decision, stated once**

> **DECISION: the iPad does NOT adopt `SWIFT_TREAT_WARNINGS_AS_ERRORS` (or
> `GCC_TREAT_WARNINGS_AS_ERRORS`) in issue #129.**

**Why this lives here.** Packet 2 deferred the `nonisolated(unsafe)` removals in
`WebArchive.swift` to a "warnings-free packet"; packet 7 deferred the identical removals in
`WebPageExtractor.swift`, `WebLibrary.swift` and `WebArchive.swift` to "the warnings packet".
**No such packet was ever cut** (packet 10 §1.1, §3.2). Because this packet is the sole editor of
`project.yml`, the flag decision and the source removals have to be made by the same owner —
otherwise the removals land against a flag nobody turned on, or the flag lands against a tree
nobody cleaned.

**Rationale for declining the flag.** Main turned it on *after* a dedicated warning-cleanup pass
(#86) that was macOS-only. The iPad tree has never had that pass and still carries ≥20
`nonisolated(unsafe)` declarations across `WebLibrary`, `WebStorage`, `WebArchive` and
`RecentFilesService`, plus whatever else a clean build surfaces. Flipping the flag mid-parity
turns every pre-existing warning into a build break for every other packet at once. Parity of
*behaviour* is the goal of #129; parity of *build settings* is a separate, sequenceable follow-up.

**What this packet DOES do** (the removals are cheap and independently correct):

1. **`Vellum/Services/Web/WebPageExtractor.swift` — [MERGE].** Remove `nonisolated(unsafe)` from
   `WebFetch.session` and the four `WebHtml` regexes, exactly as main's +5/−5 diff does.
2. **`Vellum/Services/Web/WebArchive.swift` — [MERGE, removals only].** The same removals packet 2
   deferred. Packet 2 keeps only the two `MiniZip` pre-parse accessors.

**What this packet does NOT do.** It does not sweep the remaining `nonisolated(unsafe)`
declarations in `WebLibrary`, `WebStorage` or `RecentFilesService` — those files belong to
packets 7 and 1 and their owners take the removals only if they are already rewriting the
declaration. **Do not open a repo-wide sweep inside #129.**

**Follow-up (out of scope for #129).** File a separate issue: run a clean build, fix the
warnings, then flip both flags in `project.yml`. Reference this section from it.

**Stop citing a packet that does not exist.** If you find a `// TODO(warnings packet)` marker or
a "deferred to the warnings packet" line anywhere in packets 1–8, it means *this section*.

---

## 4. Tests to port — adaptation rules

### 4.1 Global rules

* **XCTest vs Swift Testing**: keep whichever framework main used. Both run in the same iOS unit-test
  bundle under Xcode 26. Do not convert suites between frameworks.
* **`import AppKit` → `import UIKit`**, and check every `NS*` symbol: `NSAttributedString`,
  `NSParagraphStyle`, `NSTextAttachment`, `NSRange`, `NSMutableData`, `NSURLFileSizeKey`,
  `NSClassFromString` are cross-platform (Foundation/UIKit) and need no change. `NSImage`,
  `NSColor`, `NSFont`, `NSView`, `NSWindow`, `NSHostingView`, `NSPasteboard`, `NSDraggingInfo`,
  `NSBitmapImageRep`, `NSGraphicsContext`, `NSTextView`, `NSLayoutManager`, `NSEvent` are AppKit.
* **Bitmap fixtures**: use the iPad's established pattern, already in
  `Tests/ScratchpadImportTests.swift` and `Tests/AiPipelineTests.swift`:
  ```swift
  let format = UIGraphicsImageRendererFormat.default()   // or .preferred()
  format.scale = 1
  format.opaque = !alpha
  let image = UIGraphicsImageRenderer(size: size, format: format).image { ctx in
      UIColor.systemBlue.setFill(); ctx.fill(CGRect(origin: .zero, size: size))
  }
  return image.pngData()!     // or image.jpegData(compressionQuality: 0.9)!
  ```
* **SF Symbols**: `NSImage(systemSymbolName: name, accessibilityDescription: nil)` →
  `UIImage(systemName: name)`.
* **Colors**: `.labelColor` → `.label`, `.secondaryLabelColor` → `.secondaryLabel`.
* **Hosted-view measurement**: `NSHostingView(rootView:)` + `layoutSubtreeIfNeeded()` +
  `fittingSize` → `UIHostingController(rootView:)` and either
  `sizeThatFits(in: CGSize(width: w, height: .greatestFiniteMagnitude))` or
  `view.systemLayoutSizeFitting(...)` after `view.layoutIfNeeded()`. Off-screen is fine; no window
  is needed on iOS.
* **Do not port** anything whose subject is an AppKit contract (attached sheets, dragging
  destinations, pasteboard type negotiation, `NSEvent` monitors). Those behaviours have iOS-native
  rebuilds on the iPad side and, where they matter, iPad-native tests already exist
  (`InkPersistenceTests`, `KeyboardShortcutsTests`, `ScratchOutRecognizerTests`,
  `ZoomHandlerTests`, `WebStorageLocationTests`) — **never delete those five**.
* **Persistence assertions are byte-compat guards.** Any test asserting a literal key
  (`is_pinned`, `/Vellum*`, `vellum.workspace`, `vellum.recent-pdfs`,
  `vellum.scratchpad.notes.v1`, `web.storage.mode`) must be ported with the literal unchanged.

### 4.2 Per-file adaptation notes (new suites)

| file | adaptation |
|---|---|
| `AiAddAsNoteTests` | Content per packet 5 §4; `NSEvent` appears only inside a comment, imports are XCTest only. Packet 7's 14 web-dismissal cases do **not** go here — new file `Tests/WebNoteDraftTests.swift`, spec at packet 7 §4.3 (packet 10 §2.1). |
| `AiConversationStoreTests` | Verbatim. |
| `AiMarkdownRenderingTests` | **Blocked on packet 5 §I.1 (`InlineMarkdown.swift`)** — do not start before it lands (packet 10 §2.1). Heaviest rebuild (786 lines). Keep the pure `AiAttributedRenderer` assertions and the `NSAttributedString` attachment-width helper. Rebuild the `NSHostingView`/`NSWindow` mounts on `UIHostingController`, and re-target `NSTextView` measurement at the iPad's `SelectableTextView` (`UITextView` subclass) — the same swap the iPad already made in `SelectableMessageTests`. If a group's subject is TextKit-1-vs-2 layout-manager behaviour that has no iOS analogue, drop that group with a comment saying why. |
| `AiReferencePersistenceTests` | Verbatim. |
| `AiToolSummaryTests` | Verbatim (Foundation + Testing; `NSHostingView` is only in a comment). |
| `AiTranscriptFollowTests` | Verbatim (SwiftUI + XCTest, no AppKit). |
| `AttachmentDropTests` | Partial rebuild. The `FakeDraggingInfo`/`NSPasteboard` harness (Finder/Preview/browser pasteboard fixtures, `assertForwardsFinderDrop`) has no iOS analogue — the iPad uses a `UIDropInteraction`/`onDrop` rebuild. Port only the payload-classification assertions (`aiFileAttachment`, image normalization) using the iPad `bitmap` helper, and add a header comment recording that live-drag routing is covered by the iPad's own drop path. If nothing survives the filter, skip the file and note it. |
| `DocumentActionsTests` | Content per packet 4 §2.14 (CoreGraphics/CoreText/PDFKit); `NSSavePanel` appears only in comments. **Lands after** packet 4's document-actions sub-scope, which is where `TabTeardownRegistry` / the close half of #113 / Save As now live (packet 10 §3.2). |
| `DocumentDataStoreTests` | Verbatim. |
| `DocumentIdentityTests` | Verbatim (CryptoKit/PDFKit). |
| `DocumentRenameTests` | Verbatim; needs `.scratchDefaults` (Stage 1.1). |
| `DocumentsRelocationTests` | Verbatim; relocation across containers behaves the same on iOS. |
| `HelpCenterTests` | One swap: `NSImage(systemSymbolName: topic.symbol, accessibilityDescription: nil)` → `UIImage(systemName: topic.symbol)`; `import AppKit` → `import UIKit`. |
| `HomeSearchEngineTests` / `HomeSearchRankerTests` | Verbatim. |
| `HomeSearchStoreTests` | Verbatim; needs `.scratchDefaults`. |
| `InspectorPresentationTests` | Verbatim; needs `.scratchDefaults`. If the iPad's inspector rebuild does not have the same presentation states, adjust the expectations rather than the production code. |
| `InspectorTabSwitcherTests` | Merge: keep the `InspectorLayout` constant assertions (280/360/700) only if the iPad's inspector uses the same envelope — check `InspectorLayout` after the inspector packet lands and update the literals if the iPad chose different widths. Keep the accessibility-identifier test (`sidebarTab.*`) — it is a cheap contract guard — but delete the comment's reference to `UITests/ScratchpadSnapshotUITests`, which does not exist on iPad. |
| `PageTextExtractionGateTests` | Verbatim. |
| `RecentsResolveTests` | Verbatim, but the security-scoped-bookmark path differs on iOS (no user-selected-file TCC prompts; `URL.bookmarkData` options differ). If `SecurityScopedBookmark` gets an iOS variant in the packet 1, mirror it here. |
| `SafeClearTests` | Verbatim. |
| `ScratchpadMarkdownExporterTests` | Verbatim. |
| `SettingsNavigationTests` | Verbatim if the iPad keeps the same settings-tab enum; otherwise adjust the expected tab set to the iOS rebuild's. |
| `StorageManagementTests` | Verbatim (`NSURLFileSizeKey` is Foundation). |
| `TabResidencyTests` | Verbatim (Swift Testing); needs `TabResidency` + `LiveTabRuntime`. |
| `VellumBundleTests` | Verbatim (CoreGraphics + `NSMutableData`, both cross-platform; `NSSavePanel` only in comments). |
| `WalkthroughLayoutTests` | Rebuild the two `NSHostingView` measurements on `UIHostingController.sizeThatFits(in:)`. The assertions (that the walkthrough's text column and image do not overflow at the sizes it can be shown at) carry over; re-pick the widths to the iPad sheet's real width. |
| `WalkthroughTests` | Two `NSImage(systemSymbolName:)` → `UIImage(systemName:)`; `import AppKit` → `import UIKit`. Rest verbatim (asserts every walkthrough page/point has a resolvable symbol and non-empty copy). |

### 4.3 iPad-only tests that must survive untouched

`Tests/InkPersistenceTests.swift`, `Tests/KeyboardShortcutsTests.swift`,
`Tests/ScratchOutRecognizerTests.swift`, `Tests/ZoomHandlerTests.swift`,
`Tests/WebStorageLocationTests.swift`, plus the iPad-only additions inside `AiPipelineTests` and
`PdfPersistenceTests` described in §3.1/§3.2. If a ported suite collides with one of these on a
method name, rename the **incoming** test, never the iPad one.

### 4.4 Sanity command

```bash
cd $IPAD && xcodegen generate && \
xcodebuild test -project Vellum.xcodeproj -scheme Vellum \
  -destination 'platform=iOS Simulator,name=iPad Pro 13-inch (M4)' \
  -only-testing:VellumTests/KeychainStoreTests \
  -only-testing:VellumTests/AppDefaultsGuardTests \
  -only-testing:VellumTests/UITestLaunchConfigurationTests
```

Run that trio after Stage 2; it is the whole "tests never touch real state" floor in one command.

---

## 5. Risks & cross-packet dependencies

### Dependencies this packet has on others

* **D1 — `AppDefaults` (packet 1, `Vellum/Services/AppDefaults.swift`).** Hard blocker for
  Stage 1 (`ScratchDefaultsTrait`, `AppDefaultsGuardTests`) and for the un-commenting of
  `UITestLaunchConfiguration.prepare()`'s corrupt-restoration branch. The iPad has **nothing**
  today: `RecentFilesService`, `WorkspaceService` and `ScratchpadPersistence` all read
  `UserDefaults.standard` directly, so until that packet lands the iPad test bundle is still writing
  into the *simulator app's* real defaults (contained, but shared across suites).
* **D2 — `WalkthroughSettings` (packet 3).** Needed to restore two lines in
  `UITestLaunchConfiguration.prepare()` and half of `UITestLaunchConfigurationTests`.
* **D3 — every feature packet.** Each Stage-4 suite compiles only after its production types exist.
  Because the test bundle is one compile unit, **do not commit a test file whose subject is not yet
  ported** — it breaks the build for everyone. Land tests in the same commit as their feature, or
  immediately after.
* **D4 — `project.yml`: this packet is the SOLE editor** (packet 10 §2.2). Packets 1, 2, 4, 6 and 8
  all named the file and three tagged it MERGE; they hand their hunks here instead. Packet 8 needs
  the same `Tests/Integrations/Fixtures` hunk — apply the `VellumTests` sources block **once**,
  here, and packet 8 verifies afterwards. One `xcodegen generate` per landing, not five.

### Dependencies other packets have on this one

* **Packets 7 and 5 cannot compile `WebLibrary.swift` / `PageTextCache.swift` verbatim
  without Stage 0.2** — main's `WebLibrary.appDataDir` (line 68) and `PageTextCache` (line 102) both
  read `UITestLaunchConfiguration.storageRoot`.
* **Packet 8 (integrations) needs Stage 0.3** — `KeychainIntegrationCredentials` calls
  `KeychainStore.get/set/delete(_:service:)`; that is packet 8's dependency D1, and Stage 0.3 is the
  real fix (do not ship packet 8's stopgap two-line shim on top of the old file).
* **Packet 4** (the named sequencer for `VellumApp.swift` → `VellumApp_iOS.swift`) may call
  `UITestLaunchConfiguration.prepare()` and `KeychainStore.prewarm()` from `VellumApp.init()`
  (main does both). `prewarm()` is worth calling
  on iPad — it moves the first vault read (and its legacy migration) off the main thread.

### Risks

* **R1 — keychain vault migration on real hardware.** Stage 0.3 changes where every API key and
  OAuth token physically lives (per-account items under `com.vellum.ai` → one JSON item under
  `com.vellum.vault`). The reconciler is designed to never destroy a value it cannot prove is
  preserved, and `KeychainStoreTests` covers all six conflict cases — but the first run on a device
  with real keys is still the moment of truth. Test on a device/simulator that already has a Gemini
  or OpenAI key saved, and confirm the ChatGPT OAuth blob (`Account.chatgptTokens`) survives, since
  the iPad's `ASWebAuthenticationSession` flow stores through the same door. Also confirm the
  `flock` file lands in the app container (`WebLibrary.appDataDir/keychain-vault.lock`) and that
  `commitLockFD >= 0` — if the directory can't be created, **every `set` fails closed** and key
  entry silently stops working.
* **R2 — first Swift Testing code in the iPad test target.** The iPad `Tests/` tree is 100% XCTest
  today; roughly fifteen ported suites use `import Testing`, `@Suite`, `#expect`, `#require` and —
  for `ScratchDefaultsTrait` — the `TestTrait`/`SuiteTrait`/`TestScoping` protocols. Verify the
  first Swift Testing suite actually runs on the iOS simulator destination before porting the other
  fourteen (a single `xcodebuild test -only-testing:VellumTests/KeychainStoreTests` is the cheap
  probe). If the runner does not pick them up, check that the test target is a plain
  `bundle.unit-test` with no stale `OTHER_LDFLAGS`, and that the Xcode version is 26.x.
* **R3 — AppKit-harness suites are a build hazard.** Eight ported files touch AppKit; three of them
  (`SheetPresenceTests`, `SidebarDropRoutingTests`, `ScratchpadDropRegistrationTests`) are pure
  AppKit contracts with no iOS meaning. Copying any of them in "to fix later" fails the whole test
  bundle compile. Skip them at the file level, and record the skip in the packet's commit message so
  a later parity audit does not read the absence as an oversight.
* **R4 — `SWIFT_TREAT_WARNINGS_AS_ERRORS` — resolved, see §3.5.** Main turned it on after a
  dedicated warning-cleanup pass (#86) that the iPad branch never had; turning it on in the same
  commit as the port would bury real porting failures under pre-existing warnings. **DECIDED: the
  iPad does not adopt it in #129.** This packet also takes the orphaned `nonisolated(unsafe)`
  removals in `WebPageExtractor.swift` and `WebArchive.swift` that packets 7 and 2 had deferred to
  a packet that was never cut. The flag itself is a separate follow-up issue.
* **R5 — `.serialized` semantics.** `KeychainStoreTests` asserts exact read/write counts against a
  process-global backend override; `ScratchDefaultsTrait`'s doc comment warns that a write still in
  flight when the test body returns (a debounced `WorkspaceStore` save, say) lands in the *base*
  domain and can recreate a removed suite. When porting suites that arm background saves, join them
  before returning (`await …awaitPendingFlush()` style) exactly as main does.
* **R6 — UTI rename fallout.** If you take the §3.2(4) recommendation and rename
  `com.vellum.vellumweb` → `com.vellum.webarchive`, an already-installed iPad build's Launch
  Services registration for `.vellumweb` changes. Harmless (re-registered on install) but worth one
  manual "open a .vellumweb from Files" check after the change.

---

## Appendix A — full delta sweep: files owned by other packets

Recorded so nothing in `delta-files.txt` is unaccounted for. **Not claimed by this packet.**

| area | files | likely owner |
|---|---|---|
| Foundation / defaults | `Vellum/Services/AppDefaults.swift` | packet 1 (this packet's D1) |
| App shell & commands | `Vellum/App/ContentView.swift`, `Vellum/App/VellumApp.swift`, `Vellum/App/VellumCommands.swift` | **packet 4** is the named sequencer (packet 10 §2.2); all three are macOS-gated dead files normalised to `[REBUILD → *_iOS.swift]`, with packets 2 and 3 rebasing their hunks onto packet 4's. |
| ~~`Vellum/App/SheetPresenceMonitor.swift`~~ | dropped | **DECISION (packet 10 §3.3): dropped entirely, along with `Tests/SheetPresenceTests.swift`.** The earlier note here ("if no packet claims it, drop it") was stale — packet 4 *did* claim it [REBUILD]. Resolved in favour of dropping both: iOS has no attached sheets and therefore no menu-bar-disabling contract. **Packet 4 owns the replacement** (`SheetPresence_iOS` + the router `.dismiss` handling) and a new iOS test, spec at packet 4 §4.5. |
| Models | `Vellum/Models/Models.swift`, `PaneTree.swift`, `AiToolSummary.swift`, `LiveTabRuntime.swift` | packets 4 and 5 |
| AI services | `Vellum/Services/Ai/*` (incl. `PageTextExtractionGate.swift`, `AiFileAttachment.swift`, `AiImageAttachment.swift`; `SpeechService.swift` is **deleted** — the iPad already has no voice/TTS, so nothing to do) | packet 5 |
| AI views | `Vellum/Views/AI/*` | packet 5. **Includes `InlineMarkdown.swift`, `MarkdownMessage.swift` and `SelectableMessageText.swift`** — packet 10 §1.1/§3.2 folded them in from the "markdown / math / text-selection packet" that was never cut; they are packet 5 §I. `MathRenderer.swift` is packet 7 §2.5. `RevealableSecureField.swift` is shared with packet 8. |
| PDF | `Vellum/Services/Pdf/*`, `Vellum/Views/PDF/*` | packets 1, 6 and 7 (`PdfSessionBackend.swift` order **1 → 6 → 7**). `PdfViewerView.swift` / `PdfKitView.swift` are SKIP only because packet 4 §2.0's interface-only contract commit exists — **do not delete it**. `PdfOverlays.swift` is **packet 5 §I.4** (2-line adaptation applied to `Platform/iOS/RegionCaptureOverlay_iOS.swift`). |
| Web | `Vellum/Services/Web/*`, `Vellum/Views/Web/*` | packet 7 (`WebLibrary.swift` needs Stage 0.2). **Exceptions claimed by this packet**: the `nonisolated(unsafe)` removals in `WebPageExtractor.swift` and `WebArchive.swift` — see §3.5. `WebSessionBackend.swift` is packets 1 → 6 → 7. |
| Storage / documents | `DocumentDataStore.swift`, `DocumentIdentity.swift`, `DocumentRenameService.swift`, `DocumentSessionManager.swift`, `StorageHousekeeping.swift`, `SecurityScopedBookmark.swift`, `VellumBundle.swift`, `RecentFilesService.swift`, `SessionService.swift`, `WorkspaceService.swift`, `TabResidency.swift`, `Vellum/Views/Settings/Storage*` | packet 1 |
| Search / home | `Vellum/Services/Search/*`, `Vellum/Stores/HomeSearchStore.swift`, `Vellum/Views/Welcome/*` | packet 3 |
| Help / walkthrough | `Vellum/Views/Help/*`, `Vellum/Services/WalkthroughSettings.swift` | packet 3 (this packet's D2) |
| Stores | `AiStore.swift` (packets 5, 6 — packet 6 takes **only** its six named symbols), `AnnotationStore.swift` (packets 1, 6), `AppStore.swift` (packets 1, 4, 2 — **order 1 → 4 → 2**, then packet 7's `restorePendingNote` insert), `ScratchpadStore.swift` (packets 2, 6), `WorkspaceStore.swift` (packets 4, 8) | multiple owners; see packet 10 §2.3 for the edit orders |
| Shared views | `Controls.swift`, `FindBar.swift`, `InspectorTabSwitcher.swift` | **packet 4** (`FindBar.swift` is shared with packet 7 — order 4 → 7) |
| Shared views | `Vellum/Views/Shared/Theme.swift`, `FloatingNotice.swift`, `MoveToCollectionMenu.swift` | **packet 8.** `Theme.swift` was the one delta file **no packet mentioned at all** (packet 10 §1.1); it is now packet 8 `[MERGE, +ThemePalette.success]`, and packet 8's `FloatingNotice.swift` does not compile without it. The "shared-UI packet" this row used to cite never existed. |
| Shared views | `SidebarDropCatcher.swift` | **SKIP** — AppKit drag/drop harness; standing decision that the iPad keeps its iOS-native drop rebuild (packets 4, 5 and 9 all agree). |
| Scratchpad | `ScratchpadMarkdownExporter.swift`, `ScratchpadPersistence.swift`, `Vellum/Views/Scratchpad/ScratchpadPanel.swift` | packet 6 |
| Prompts | `Vellum/Resources/prompts/tool-mode-native.md` | packet 5 |
| Integrations | `Vellum/Services/Integrations/*`, `Vellum/Stores/IntegrationsStore.swift`, `Vellum/Views/Settings/{Connect,Disconnect}ServiceSheet.swift`, `IntegrationsSettingsTab.swift`, `Tests/Integrations/**` | **packet 8** |
