# Vellum UI tests

`VellumUITests` is generated from `project.yml` and is part of the checked-in
`Vellum` scheme. No manual Xcode target setup or external PDF fixture is needed.

Each test launches with:

- the `UITesting` build configuration, whose
  `com.vellum.app.uitesting` bundle identifier isolates UserDefaults from the
  installed app;
- `--ui-testing`, which gates every test-only behavior;
- `--ui-test-reset-state`, which clears only that test bundle's persistent
  defaults before its stores are constructed; and
- `--ui-test-storage-root <path>`, which redirects Application Support,
  document data, web data, scratchpad attachments, and extracted-text caches to
  a per-test temporary directory.
- an inert Keychain backend under the reserved `com.vellum.ai.uitesting`
  service name, so UI tests never access the installed app's
  `com.vellum.ai` credentials.

Tests that need a document generate a small PDF in that directory and pass it
through `--ui-test-open-document <path>`. This avoids driving the system open
panel and makes the fixture available on every developer machine and in CI.

Run all UI tests:

```shell
xcodebuild test -project Vellum.xcodeproj -scheme Vellum \
  -destination 'platform=macOS' -only-testing:VellumUITests
```

External attachment drag-and-drop remains covered by
`VellumTests/AttachmentDropTests`; XCUITest must not synthesize Finder drags.
