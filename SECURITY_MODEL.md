# Vellum threat model

Vellum is a native SwiftUI reader and annotator for PDFs and web pages, built for macOS 26 (Developer ID with Sparkle updates) and iOS/iPadOS 26 (App Store). It adds offline web archives, per-document Scratchpads, read-later integrations (Raindrop, Readwise) and optional AI chat backed by OpenAI, Gemini, OpenRouter and OpenCode Zen with the user's own API keys. It has no server of its own. The only first-party network endpoints are `https://vellum.work/api/analytics` (an anonymous `first_launch` event, `Vellum/App/AnonymousAnalytics.swift`) and the Sparkle appcast `https://vellum.work/updates/appcast.xml`. There is no separate infrastructure repository. The website lives in `Distribution/website`.

## Components

| Component | Code |
|---|---|
| **App Shell & Routing** | `Vellum/App/`, `Vellum/Platform/macOS/VellumSystemRouteHandoff_macOS.swift`, `Vellum/Platform/iOS/VellumApp_iOS.swift`, `VellumSystemRouteHandoff.swift`, `VellumAppIntents.swift`, `Vellum/Services/Widgets/` (`VellumDeepLink`), `Vellum/Services/Capture/`, `VellumShare/`, `VellumMacShare/`, `VellumWidgets/`, `VellumChrome/` |
| **Web Reader** | `Vellum/Views/Web/` (`WebViewerView.swift`, `WebContentScript.swift`), `Vellum/Platform/iOS/WebViewerView_iOS.swift`, `Vellum/Services/Web/` (`WebPageExtractor.swift` / `VellumWebSchemeHandler`, `WebArchive.swift`, `WebLibrary*`, `VellumExternalWebLink.swift`) |
| **PDF Reader** | `Vellum/Services/Pdf/`, `Vellum/Views/PDF/`, `Vellum/Platform/iOS/Pdf*`, `Vellum/Services/Ink/`, `Vellum/Stores/AnnotationStore.swift` |
| **AI Assistant** | `Vellum/Services/Ai/`, `Vellum/Views/AI/`, `Vellum/Stores/AiStore.swift`, `Vellum/Resources/prompts`, `Vellum/Resources/katex` |
| **Storage & Sync** | `Vellum/Services/DocumentDataStore.swift`, `DocumentIdentity.swift`, `DocumentRenameService.swift`, `DocumentAccess*`, `SecurityScopedBookmark.swift`, `VellumBundle.swift`, `StorageHousekeeping.swift`, `Vellum/Services/Sync/`, `Scratchpad/`, `Position/`, `Search/`, Scratchpad panels (`ScratchpadAttachmentSchemeHandler`) |
| **Integrations & Secrets** | `Vellum/Services/Integrations/`, `Vellum/Services/KeychainStore.swift`, `Vellum/Stores/IntegrationsStore.swift`, Settings views |
| **Release & Distribution** | `Distribution/` (release scripts, `store-release.py`, website), `tools/`, `project.yml` signing/entitlements, Sparkle config in `Vellum/Resources/Info.plist` |

## Trust boundaries and entry points

1. **Web content to the app.** Arbitrary HTTP(S) pages load in WKWebView. The Mac app sets `NSAllowsArbitraryLoads` (and iOS sets `NSAllowsArbitraryLoadsInWebContent`), so plaintext HTTP is allowed. Vellum's content script runs in an isolated `WKContentWorld` named `VellumBridge` and posts messages (`init`, `scroll`, `selection`, `navigate`, ...) to native `WKScriptMessageHandler`s. Custom `WKURLSchemeHandler`s (`VellumWebSchemeHandler`, `ScratchpadAttachmentSchemeHandler`) serve archived pages and local attachments. Page scripts must not reach the bridge world, the native handlers, or local files outside the document they belong to.
2. **URL scheme `vellum://` (`vellum-dev://` in Debug).** Any website, local app or the Chrome extension can invoke `open-url` / `save-url?url=` (`VellumExternalWebLink.parse`, which accepts only http/https) and `open` widget/Shortcuts routes (`VellumDeepLink`, with 64-hex opaque ids). These links arrive without user intent.
3. **Files from other people.** PDFs (PDFKit), `.vellum` bundles (`VellumBundle.read`: hash-checked, name and traversal checks, 2 GiB cap, conversation and sidecar merge) and dropped attachments and images.
4. **Share extensions and capture.** The iOS Safari share extension writes capture records (DOM up to 1 MiB) to the App Group, and the app ingests them (`CaptureIngestion`). The Mac share extension is sandboxed and only passes a URL.
5. **Third-party APIs.** Responses from AI providers (streamed SSE) and read-later APIs (Raindrop, Readwise) are untrusted and get parsed and rendered (Markdown, KaTeX).
6. **AI model output to tools.** Document and page text, which an attacker may control, goes into prompts. The model can call `getPageText`, `searchDocument`, `getAnnotations`, `goToPage`, `addNote` and `addHighlight` (`AiToolEngine.swift`). Prompt injection can therefore drive tool calls and influence which content is sent to providers. Consent to share content is tracked in `AiSharingConsent`.
7. **Local machine.** The main Mac app runs **without App Sandbox** (`ENABLE_APP_SANDBOX: NO`, hardened runtime on), so a bug that writes or reads files can reach anything the user can. Other local apps can open `vellum://` URLs and read files in shared locations (App Group, iCloud container, custom storage folders).
8. **Updates.** Sparkle fetches the appcast over HTTPS, and updates are EdDSA-signed (`SUPublicEDKey`). Release tooling signs, notarizes and promotes artifacts.

## Assets (all rated equally important)

- Provider and integration API keys and tokens in the Keychain (`com.vellum.ai` service, `WhenUnlockedThisDeviceOnly` / `AfterFirstUnlockThisDeviceOnly`).
- The user's local files, documents, annotations, Scratchpads, AI conversations and reading history. On the Mac this extends to the whole home directory because the app is unsandboxed.
- Integrity of documents on disk: atomic PDF writes, docId-keyed state, and no destructive loss.
- Privacy of document content: it should go to AI providers only with consent and to no one else.
- Integrity of updates and release artifacts.

## Attackers (all in scope)

- Malicious web page, or a page modified on the network (HTTP is allowed).
- Malicious PDF, `.vellum` bundle, attachment or shared link from another person.
- Prompt injection embedded in document or page content.
- Malicious website or local app invoking `vellum://` routes.
- Other local apps or processes on the same device.
- Network attacker against API and update traffic.
- Compromised or malicious third-party API responses (AI providers, Raindrop, Readwise).

## Existing controls

- An isolated `VellumBridge` content world for native-bridge scripts.
- Strict URL route parsing: only http/https targets, one `url` query item, no user/password/port/fragment.
- `.vellum` bundle hash verification, safe-name and path-traversal checks, and size limits.
- Keychain storage with device-only accessibility.
- The sandboxed Mac share extension does not copy cookies.
- Sparkle EdDSA signing and Developer ID notarization.
- An AI sharing-consent gate. The AI tools are limited to reading the document and adding notes and highlights.
- `--disable-sync` and isolated test seams (`AppDefaults`, `KeychainStore.withBackend`, `DocumentDataStore.rootDirectoryOverride`).

## Out of scope / accepted risk

Nothing is out of scope: iOS/iPadOS code, release tooling, the website, and Debug and UI-testing paths are all in scope.

## Open questions

- No attacker or surface has been ruled out yet. Revisit this section if some risks become accepted.
