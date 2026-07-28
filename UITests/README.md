# Vellum UI tests

`VellumUITests` is generated from `project.yml`. It is deliberately **not** part
of the `Vellum` scheme's test action: XCUITests launch and drive the real app,
so `xcodebuild test -scheme Vellum` keeps running only the hosted `VellumTests`
suite, in Debug, exactly as before. The UI tests get their own shared scheme.

Run them explicitly:

```shell
xcodebuild test -project Vellum.xcodeproj -scheme VellumUITests \
  -destination 'platform=macOS'
```

They drive the desktop (focus, clicks, keystrokes), so don't run them while
you're using the machine, and don't run them from an unattended agent.

## What makes a launch deterministic

Each test launches the app with:

- the `UITesting` build configuration, whose `com.vellum.app.uitesting` bundle
  identifier isolates UserDefaults from the installed app. `--ui-test-reset-state`
  refuses to wipe the domain if the running build ever turns out to carry the
  production identifier;
- `--ui-testing`, which gates every test-only behavior. Without it the seams in
  `UITestLaunchConfiguration`, `WebLibrary`, and `PageTextCache` are inert;
- `--ui-test-reset-state`, which clears that test identity's persistent defaults
  before any store is constructed;
- `--ui-test-storage-root <path>`, which redirects Application Support, document
  data, web data, scratchpad attachments, and extracted-text caches to a
  per-test temporary directory;
- `-ApplePersistenceIgnoreState YES`, so AppKit window restoration cannot leak
  state between runs.

`UITestLaunchConfiguration.prepare()` additionally pins web storage to `.local`
(suppressing the first-launch storage sheet) and marks #65's walkthrough as
seen, so neither sheet is ever modally covering the screen a test asserts
against. Pass `--ui-test-show-walkthrough` to opt back in and test that flow.

The Keychain is never touched: `KeychainStore.isRunningTests` treats
`--ui-testing` as "under test" alongside the XCTest environment markers that
hosted unit tests get, so a UI-test launch uses the same in-memory store. That
matters because the app is ad-hoc signed — its signature changes on every
rebuild, and a real Keychain read would re-prompt for the login password.

Tests that need a document generate a small PDF into the storage root and pass
it through `--ui-test-open-document <path>`, which avoids driving the system
open panel and works on any machine and in CI.

External attachment drag-and-drop remains covered by
`VellumTests/AttachmentDropTests`; XCUITest cannot synthesize a Finder drag.
