# Plan 003: Store AI provider API keys in the Keychain instead of plaintext UserDefaults

> **Executor instructions**: Follow this plan step by step. Run every
> verification command and confirm the expected result before moving to the
> next step. If anything in the "STOP conditions" section occurs, stop and
> report — do not improvise. When done, update the status row for this plan
> in `plans/README.md` — unless a reviewer dispatched you and told you they
> maintain the index.
>
> **Drift check (run first)**: `git diff --stat bff7de4..HEAD -- Vellum/Services/Ai/AiPersistence.swift Vellum/Stores/AiStore.swift`
> If any in-scope file changed since this plan was written, compare the
> "Current state" excerpts against the live code before proceeding; on a
> mismatch, treat it as a STOP condition.

## Status

- **Priority**: P1
- **Effort**: S
- **Risk**: LOW
- **Depends on**: none
- **Category**: security
- **Planned at**: commit `bff7de4`, 2026-07-14

## Why this matters

The user's Gemini and OpenAI API keys are JSON-encoded inside the whole `AiSettings` struct and written to `UserDefaults` — an unencrypted plist under `~/Library/Preferences`. The app also runs unsandboxed (`ENABLE_APP_SANDBOX: NO` in `project.yml`), so any process running as the same user can read those keys off disk. macOS has a purpose-built answer — the Keychain — and the change is narrow: two string fields move to Keychain-backed storage, everything else stays in UserDefaults. The migration must also *delete* the plaintext copy, otherwise the exposure remains while looking fixed.

## Current state

- `Vellum/Stores/AiStore.swift:29-40` — the settings model:

  ```swift
  struct AiSettings: Codable, Equatable, Sendable {
      ...
      var apiKey: String = ""        // line 32 — Gemini key
      ...
      var openaiApiKey: String = ""  // line 34 — OpenAI key
      ...
  }
  ```

- `Vellum/Services/Ai/AiPersistence.swift` — settings persistence. Key facts:
  - `settingsKey = "research-reader-ai-settings-v1"` (line 4) — note the legacy prefix; **do not rename it**, existing installs depend on it.
  - `loadSettings()` (lines 15–34) reads the UserDefaults string, parses with `JSONSerialization`, and copies fields including `value["apiKey"]` and `value["openaiApiKey"]` into `AiSettings`.
  - `saveSettings(_:)` (lines 36–40) `JSONEncoder`-encodes the **entire** struct — keys included — and writes it to UserDefaults:

    ```swift
    static func saveSettings(_ settings: AiSettings) {
        guard let data = try? JSONEncoder().encode(settings),
              let raw = String(data: data, encoding: .utf8) else { return }
        UserDefaults.standard.set(raw, forKey: settingsKey)
    }
    ```

- Consumption sites (do not change; they read the in-memory `AiSettings` fields, which keep working): `Vellum/Services/Ai/OpenAIClient.swift:37` (`Authorization: Bearer <apiKey>` header) and `Vellum/Services/Ai/GeminiClient.swift:40` (`x-goog-api-key` header). The Settings UI fields live in `Vellum/Views/Settings/SettingsView.swift` (`AiSettingsTab`, ~line 155) and also just bind to `AiSettings` fields.

- Code signing is ad-hoc (`CODE_SIGN_IDENTITY: "-"` in `project.yml`), no sandbox — `SecItemAdd`/`SecItemCopyMatching` for a `kSecClassGenericPassword` item work fine in this configuration. Be aware that ad-hoc re-signing on every rebuild can trigger a one-time keychain confirmation prompt in dev; that's expected, not a bug.

- Repo convention: services are small files under `Vellum/Services/`; after adding a file run `xcodegen generate` (sources are globbed from `Vellum/`).

## Commands you will need

| Purpose | Command | Expected on success |
|---|---|---|
| Regenerate project (after adding the new file) | `xcodegen generate` | exit 0 |
| Build | `xcodebuild -project Vellum.xcodeproj -scheme Vellum -configuration Debug build` | `BUILD SUCCEEDED` |
| Unit tests | `xcodebuild -project Vellum.xcodeproj -scheme Vellum test -only-testing:VellumTests` | `TEST SUCCEEDED` |

## Scope

**In scope** (the only files you should modify/create):
- `Vellum/Services/Ai/KeychainStore.swift` (create)
- `Vellum/Services/Ai/AiPersistence.swift`
- `Tests/KeychainStoreTests.swift` (create)
- `Vellum.xcodeproj/*` (regenerated)

**Out of scope** (do NOT touch):
- `Vellum/Stores/AiStore.swift` — `AiSettings` keeps its `apiKey`/`openaiApiKey` **in-memory** fields so clients and the Settings UI are untouched. (See step 2 for how they're excluded from the persisted JSON without changing the struct's Codable behavior elsewhere.)
- `OpenAIClient.swift`, `GeminiClient.swift`, `CodexAiClient.swift`, `SettingsView.swift`.
- The `settingsKey` string and the rest of the persisted settings JSON shape (provider, models, voice fields) — only the two key fields move.

## Git workflow

- Fresh worktree: from the repo's parent folder, `git worktree add 003-api-keys-keychain`. The shared worktree has uncommitted scratchpad work — don't touch it.
- Commit style: sentence-case imperative, e.g. "Move AI provider API keys to the Keychain".
- Do NOT push or open a PR unless the operator instructed it.
- **Never commit a real API key** — not in code, tests, or the plan status. Tests use obviously fake values like `"test-key-123"`.

## Steps

### Step 1: Create `KeychainStore`

New file `Vellum/Services/Ai/KeychainStore.swift`: a small enum wrapping Security.framework generic passwords.

- API: `static func read(account: String) -> String?`, `static func write(account: String, value: String)` (empty value ⇒ delete), `static func delete(account: String)`.
- Query base: `kSecClass: kSecClassGenericPassword`, `kSecAttrService: "com.vellum.app.ai"`, `kSecAttrAccount: account`. Write = delete-then-add (simplest upsert). Read uses `kSecReturnData: true`, `kSecMatchLimit: kSecMatchLimitOne`.
- Add a test seam matching the repo's existing pattern (`ScratchpadAttachmentStore.directoryOverride` in `Vellum/Services/Scratchpad/ScratchpadPersistence.swift:84` is the exemplar): `nonisolated(unsafe) static var serviceOverride: String?` so tests use a throwaway service name and clean up after themselves.
- Account names: `"gemini-api-key"`, `"openai-api-key"`.

**Verify**: `xcodegen generate && xcodebuild ... build` → `BUILD SUCCEEDED`.

### Step 2: Route the two key fields through `KeychainStore` in `AiPersistence`

- `loadSettings()`: after building `settings` from the UserDefaults JSON, overwrite the key fields from the Keychain: `settings.apiKey = KeychainStore.read(account: "gemini-api-key") ?? ""` (same for openai). Then the **migration**: if the UserDefaults JSON contained a non-empty `apiKey`/`openaiApiKey` and the Keychain had none, write the UserDefaults value into the Keychain, adopt it into `settings`, and immediately call `saveSettings(settings)` so the plaintext copy is purged (see next bullet).
- `saveSettings(_:)`: write the keys to the Keychain first, then persist the JSON **without** them — make a copy of the struct with `apiKey = ""` and `openaiApiKey = ""` before encoding. (This keeps `AiSettings` untouched and guarantees the plist never carries key material again.)

**Verify**: `xcodebuild ... build` → `BUILD SUCCEEDED`.

**Verify** (plaintext purge, run after launching the app once with a fake key set in Settings, or via the unit test in step 3):
`defaults read com.vellum.app research-reader-ai-settings-v1 | grep -c "test-key"` → `0`.

### Step 3: Tests

`Tests/KeychainStoreTests.swift`, using `serviceOverride` with a unique test service and a `tearDown` that deletes both accounts:

1. write → read round-trip returns the value.
2. write empty ⇒ read returns nil (delete semantics).
3. Migration: seed `UserDefaults.standard` under `AiPersistence.settingsKey` with a JSON string containing `"apiKey":"test-key-123"`; call `AiPersistence.loadSettings()`; assert the returned settings carry the key, `KeychainStore.read` now returns it, and the UserDefaults string no longer contains `test-key-123`. Restore/remove the defaults key in teardown.

Model the file structure on `Tests/ScratchpadImportTests.swift` (same target, plain XCTest).

**Verify**: `xcodebuild ... test -only-testing:VellumTests` → `TEST SUCCEEDED`, 3 new tests pass.

## Test plan

Covered in step 3. Cases: round-trip, delete-on-empty, one-time migration incl. plaintext purge. No live-network or real-key tests.

## Done criteria

Machine-checkable. ALL must hold:

- [ ] `xcodebuild ... build` → `BUILD SUCCEEDED`
- [ ] `xcodebuild ... test -only-testing:VellumTests` → `TEST SUCCEEDED` with the 3 new tests
- [ ] `grep -n "KeychainStore" Vellum/Services/Ai/AiPersistence.swift` → matches in both `loadSettings` and `saveSettings`
- [ ] The persisted settings JSON written by `saveSettings` contains empty strings for both key fields (asserted by test 3)
- [ ] `git status` shows no modified files outside the in-scope list
- [ ] `plans/README.md` status row updated

## STOP conditions

Stop and report back (do not improvise) if:

- `AiPersistence.swift` no longer matches the excerpts (drift).
- `SecItemAdd` fails in the test environment with `errSecMissingEntitlement` or similar (would mean the test bundle's signing context can't use the Keychain — report; do not weaken the implementation to a file-based fallback on your own).
- You find any *real-looking* key value already present in UserDefaults or committed files while testing: do not copy it anywhere (not into logs, tests, or your report beyond "a value was present"); note its location and type and recommend rotation.

## Maintenance notes

- If a third provider is added, its key goes through `KeychainStore` with a new account name — never a new UserDefaults field; a reviewer should reject any future `AiSettings` field named `*Key` that reaches `saveSettings` unstripped.
- SECURITY-04 (enabling App Sandbox before distribution) will require an explicit keychain-access-group decision; this plan's plain generic-password items migrate cleanly.
- Deferred: encrypting or scoping the rest of the settings JSON — nothing else in it is secret.
