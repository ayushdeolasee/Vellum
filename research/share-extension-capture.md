# Research: capture on the go — a Save-to-Vellum share extension from Safari

_Issue: [ayushdeolasee/Vellum#143](https://github.com/ayushdeolasee/Vellum/issues/143) (sub-issue of the iPhone wayfinder map [#139](https://github.com/ayushdeolasee/Vellum/issues/139)). Researched 2026-08-01._

> **Note on convention:** this repo has no existing research-notes convention. `plans/` holds one HTML plan document; no `research/` directory existed before this file. This file establishes `research/<topic>.md` as a first instance, not as an existing standard. Human-facing plan documents stay HTML per `CLAUDE.md`; this is a findings file for issue threads and agents, so it is Markdown.

> **Source-quality note.** Apple's **App Extension Programming Guide** is the only first-party narrative document covering most of this ground. It lives under `developer.apple.com/library/archive/` and was last revised 2017-10-19 — *archived*, not deprecated-and-replaced. Nothing supersedes it and current API reference pages still link into it. Every claim below marks whether it comes from that archived guide, a current API reference page, a WWDC transcript, or a forum reply — and whether a forum reply is from Apple staff/DTS or from the community.
>
> Apple's `developer.apple.com/documentation/*` pages are a JavaScript single-page app that HTML fetchers cannot read. Quotes from those pages were pulled from Apple's own structured documentation payload at `developer.apple.com/tutorials/data/documentation/<path>.json` — the same data Xcode's documentation viewer consumes.

---

## TL;DR

**1. Safari hands you the URL reliably, and the full DOM only if you ask for it.** Declare `NSExtensionActivationSupportsWebPageWithMaxCount` + `NSExtensionJavaScriptPreprocessingFile`, and a JS `run()` function executes inside the live page and returns an arbitrary property-list-serializable dictionary — `document.title`, `document.baseURI`, `document.documentElement.outerHTML`. There is **no documented size cap** on that dictionary. Declaring only `NSExtensionActivationSupportsWebURLWithMaxCount` gets a bare `public.url` from any app, with no page content and no reliable title.

**2. A share extension *may* run a `WKWebView`, but Vellum shouldn't.** WebKit is not on Apple's unavailable-API list, so it's permitted. But Apple documents that extension memory limits are *"significantly lower"* than an app's, that the system *"may aggressively terminate extensions,"* and that you should launch in *"well under one second."*

**3. Apple has never published a memory number for share extensions.** The famous ~120 MB is a jetsam crash-log string (`EXC_RESOURCE ... limit=120 MB`) that developers paste into forum threads; Apple staff have declined to confirm it in writing. The only Apple-staff-confirmed number for any extension type is Notification Service Extension's 24 MB (and even that was caveated "current limit as of iOS 14"). Design as if the budget were far smaller than 120 MB.

**4. Vellum's existing capture pipeline would not fit in an extension.** It holds up to 64 MB of assets in memory as `Data`, then `MiniZip.write` builds the entire archive as a *second* in-memory `Data`. Peak comfortably exceeds 128 MB on a heavy page. Also worth correcting an assumption in the ticket: **capture does not use `WKWebView` at all** — it's `URLSession` + regex + zip, pure Foundation, which is what makes it portable in principle. The blocker is memory, not API availability.

**5. Write to the App Group container from the extension; never to the iCloud ubiquity container.** The App Group container is the documented hand-off channel. `url(forUbiquityContainerIdentifier:)` is documented as blocking (*"Do not call this method from your app's main thread"*) and as extending the process sandbox on first call — a per-process cost the extension pays fresh on every invocation, inside a ~1-second launch budget. There is a widget-extension regression on record where it silently returned `nil` for an entire OS version.

**6. Yes, the main app can genuinely be woken — via a background `URLSession` started in the extension.** Set `sharedContainerIdentifier` (mandatory: without it the session *"is invalidated upon creation"*) and `sessionSendsLaunchEvents`, and *"the system launches your containing app in the background and calls `application:handleEventsForBackgroundURLSession:completionHandler:`."* Everything else fails: Darwin notifications are dropped for a suspended app (DTS-confirmed), App Group writes are silent, and `NSExtensionContext.open(_:)` is documented as supported by Today and iMessage extension points only — an Apple engineer states flatly that *"Share Extensions are not allowed to open apps."*

**7. An extension can `submit()` a `BGTaskScheduler` request, but the handler always runs in the app.** WWDC 2019 Session 707, verbatim: *"it's always the main containing app that is launched to handle background tasks, never extensions."*

**8. App Groups do NOT require a paid Apple Developer Program membership. iCloud does.** Apple's own supported-capabilities table gives **App groups** a checkmark in the free "Apple Developer" column; **iCloud: CloudKit**, **iCloud: iCloud documents**, and **iCloud: iCloud key-value storage** are checked only for the paid ADP/ADEP columns. This is a genuine reversal of widely-repeated folklore, and it means the share extension can ship on the current free Personal Team (`DEVELOPMENT_TEAM: 9DCG97VASG`) — just not alongside iCloud storage.

---

## Q1 — What a Safari share extension actually receives

### The container objects

`NSExtensionContext.inputItems` is an array of `NSExtensionItem`; *"If the context has no input items, this array is empty."* ([inputItems](https://developer.apple.com/documentation/foundation/nsextensioncontext/inputitems))

Each `NSExtensionItem` carries `attachments` — *"An optional array of media data associated with the extension item… Populate this array with images, videos, URLs, and so on… These items are always typed `NSItemProvider`"* — plus `attributedTitle` and `attributedContentText`. ([attachments](https://developer.apple.com/documentation/foundation/nsextensionitem/attachments), [attributedTitle](https://developer.apple.com/documentation/foundation/nsextensionitem/attributedtitle), [attributedContentText](https://developer.apple.com/documentation/foundation/nsextensionitem/attributedcontenttext))

In the archived guide's prose: *"A Share extension uses its principal view controller's `extensionContext` property to get the `NSExtensionContext` object that contains the user's initial text and any attachments for a post, such as links, images, or videos."* ([Share.html](https://developer.apple.com/library/archive/documentation/General/Conceptual/ExtensibilityPG/Share.html)) And: *"in an item associated with a sharing request, the `attachments` property might contain a representation of the webpage a user wants to share."* ([ExtensionCreation.html](https://developer.apple.com/library/archive/documentation/General/Conceptual/ExtensibilityPG/ExtensionCreation.html))

### Two activation rules, two very different deals

| Info.plist key | Apple's definition | What you actually get |
|---|---|---|
| `NSExtensionActivationSupportsWebURLWithMaxCount` | *"The maximum number of HTTP URLs that the app extension supports."* ([ref](https://developer.apple.com/documentation/bundleresources/information-property-list/nsextension/nsextensionattributes/nsextensionactivationrule/nsextensionactivationsupportsweburlwithmaxcount)) | A `public.url` attachment. Activates from **any** app that shares a URL — Messages, Mail, Notes, a third-party browser. No page content, no reliable title. |
| `NSExtensionActivationSupportsWebPageWithMaxCount` | *"The maximum number of webpages that the app extension supports."* ([ref](https://developer.apple.com/documentation/bundleresources/information-property-list/nsextension/nsextensionattributes/nsextensionactivationrule/nsextensionactivationsupportswebpagewithmaxcount)) | Unlocks the JavaScript preprocessing path — the live DOM. Restricts activation to an actual Safari web page. |

The web-page key is explicitly the gate for JS: *"If a Share or iOS Action extension needs to access a webpage, you must include the `NSExtensionActivationSupportsWebPageWithMaxCount` key with a nonzero value, and you can use JavaScript to access a webpage from your extension."* ([AppExtensionKeys.html](https://developer.apple.com/library/archive/documentation/General/Reference/InfoPlistKeyReference/Articles/AppExtensionKeys.html))

`NSExtensionActivationRule` is a dictionary (*"Each key in the dictionary represents a data type… Add a key to this dictionary, and provide a nonzero value, if your app extension can handle files of the corresponding data type"* — [same source](https://developer.apple.com/library/archive/documentation/General/Reference/InfoPlistKeyReference/Articles/AppExtensionKeys.html)), so **both keys can be declared together**. Vellum should do that: get the rich path in Safari, and still appear for a bare link shared from Messages, handling the no-JS-results case.

### The JavaScript preprocessing file — this is how you get the DOM

Wiring, in `NSExtensionAttributes`:

```xml
<key>NSExtensionAttributes</key>
<dict>
    <key>NSExtensionJavaScriptPreprocessingFile</key>
    <string>VellumCapture</string> <!-- no ".js" extension -->
</dict>
```

*"Specifies the name of a JavaScript file supplied by a Share extension. If you provide a JavaScript file, Safari runs the functions in the file when your Share extension starts and stops. You might want to include a JavaScript file in your Share extension if you want to get information from a webpage to display in your extension, or update a webpage when your extension completes its task."* ([AppExtensionKeys.html](https://developer.apple.com/library/archive/documentation/General/Reference/InfoPlistKeyReference/Articles/AppExtensionKeys.html))

The file must expose a global `ExtensionPreprocessingJS`:

> *"On both platforms, your custom JavaScript class can define a `run()` function that Safari invokes as soon as it loads the JavaScript file. In the `run()` function, Safari provides an argument named `completionFunction`, with which you can pass results to your app extension in the form of a key-value object. In iOS, you can also define a `finalize()` function that Safari invokes when your app extension calls `completeRequestReturningItems:completion:` at the end of its task."*
> — [ExtensionScenarios.html](https://developer.apple.com/library/archive/documentation/General/Conceptual/ExtensibilityPG/ExtensionScenarios.html)

Apple's own example returns `document.baseURI`; nothing constrains *which* DOM values you return:

```javascript
var MyExtensionJavaScriptClass = function() {};
MyExtensionJavaScriptClass.prototype = {
    run: function(arguments) {
        arguments.completionFunction({"baseURI": document.baseURI});
    },
    finalize: function(arguments) { /* iOS only */ }
};
var ExtensionPreprocessingJS = new MyExtensionJavaScriptClass;
```
([ExtensionScenarios.html, Listing 4-1](https://developer.apple.com/library/archive/documentation/General/Conceptual/ExtensibilityPG/ExtensionScenarios.html))

Reading the results on the Swift side:

> *"To get the dictionary of results, specify the `kUTTypePropertyList` type identifier in the `NSItemProvider` method `loadItemForTypeIdentifier:options:completionHandler:`. In the dictionary, use the `NSExtensionJavaScriptPreprocessingResultsKey` key to get the result item."*
> — [ExtensionScenarios.html](https://developer.apple.com/library/archive/documentation/General/Conceptual/ExtensibilityPG/ExtensionScenarios.html); key reference: [NSExtensionJavaScriptPreprocessingResultsKey](https://developer.apple.com/documentation/foundation/nsextensionjavascriptpreprocessingresultskey)

**Can it carry the full HTML?** Yes. The transport is a `kUTTypePropertyList` item, so the payload must be property-list-serializable — strings, numbers, arrays, dictionaries, dates, data. `outerHTML` is a string; it qualifies. **No documented size limit exists** on the results dictionary in Apple's docs, WWDC sessions, or any staff forum reply. In practice it is bounded by the extension's own (undocumented) memory ceiling and by XPC payload behaviour.

**Build around that, don't bet on it.** Because the payload is *undocumented-unbounded* rather than *documented-unlimited*, Vellum should treat the JS-returned HTML as an opportunistic bonus and always be able to fall back to re-fetching from the URL. But it is a genuinely valuable bonus — see the architecture section: it captures the page **as Safari rendered it**, with the user's session, which a plain `URLSession` GET cannot do.

`finalize()` runs the other direction: pack a value under `NSExtensionJavaScriptFinalizeArgumentKey` in a `kUTTypePropertyList` `NSItemProvider` and pass it to `completeRequestReturningItems:completion:` to mutate the page. Vellum has no compelling use for this.

### Page title

Apple nowhere states that Safari populates `attributedTitle` with the page `<title>`. The reliable route is the same JS hop (`document.title`). Without JS preprocessing, plan on having only the URL and deriving a title in the app after fetching — which the existing `WebArchive.buildManifest(url:title:…)` already tolerates, since `title` is optional.

### What could not be confirmed

Apple nowhere itemises "Safari's default share sheet sends exactly `public.url`, plus `public.plain-text` if text is selected, and never HTML." That itemisation is community knowledge from testing, not a documented contract. Apple's wording (*"might contain a representation of the webpage"*) is deliberately vague because it varies with user selection and declared activation rule.

---

## Q1b — Running a `WKWebView` in the extension, and the real limits

### `WKWebView` is permitted

Apple's list of what an app extension *cannot* do is explicit and finite:

> *"An app extension cannot: Access a `sharedApplication` object, and so cannot use any of the methods on that object. Use any API marked in header files with the `NS_EXTENSION_UNAVAILABLE` macro, or similar unavailability macro, or any API in an unavailable framework… Access the camera or microphone on an iOS device… **Perform long-running background tasks**… Receive data using AirDrop."*
> — [ExtensionOverview.html](https://developer.apple.com/library/archive/documentation/General/Conceptual/ExtensibilityPG/ExtensionOverview.html)

WebKit is absent from that list and is not marked `NS_EXTENSION_UNAVAILABLE`. Enforcement is mechanical: extension targets build with `APPLICATION_EXTENSION_API_ONLY = YES`, *"which causes the compiler and linker to disallow use of APIs that are not available to app extensions. The App Store rejects any app extension that links to frameworks containing unavailable APIs or that otherwise uses unavailable APIs."* ([same source](https://developer.apple.com/library/archive/documentation/General/Conceptual/ExtensibilityPG/ExtensionOverview.html)) `WKWebView` compiles cleanly under that flag.

Corroboration: a November 2025 DTS-answered forum thread debugs a `WKWebView` crash inside an app extension, and the answer is a threading fix (call WebKit on the main thread) — never "WebKit isn't allowed here." ([forums thread 805658](https://developer.apple.com/forums/thread/805658))

Network access is not automatic: *"You might need to define additional capabilities for your extension if it needs to do things like use the network."* ([ExtensionCreation.html](https://developer.apple.com/library/archive/documentation/General/Conceptual/ExtensibilityPG/ExtensionCreation.html))

**Caveat: no Apple document affirmatively says "WKWebView is supported in share extensions."** The conclusion is inferred from the unavailable-API list's silence plus DTS troubleshooting behaviour.

### Memory: Apple's actual documented guidance

This is Apple's real, on-the-record statement, and it contains no number:

> *"Memory limits for running app extensions are significantly lower than the memory limits imposed on a foreground app. On both platforms, the system may aggressively terminate extensions because users want to return to their main goal in the host app. Some extensions may have lower memory limits than others: For example, widgets must be especially efficient because users are likely to have several widgets open at the same time."*
> — [ExtensionCreation.html, "Optimize Efficiency and Performance"](https://developer.apple.com/library/archive/documentation/General/Conceptual/ExtensibilityPG/ExtensionCreation.html)

From the same section: *"Design your app extension to launch quickly, aiming for well under one second. An extension that launches too slowly is terminated by the system,"* and *"App extensions do not get top priority for shared resources… The system is likely to terminate such an extension because of memory pressure."*

### The ~120 MB figure: folklore with a real crash log behind it

- **120 MB (share/action extensions) — not an Apple number.** It originates from the OS-generated jetsam string developers paste into forum posts: `EXC_RESOURCE RESOURCE_TYPE_MEMORY (limit=120 MB, unused=0x0)`. In the forum thread where an Action Extension developer raises it, Apple's staff reply **does not confirm the figure** and gives generic memory-reduction guidance instead. ([forums thread 115259](https://developer.apple.com/forums/thread/115259))
- **24 MB (Notification Service Extension) — Apple-staff-confirmed in writing**, with an explicit version caveat: *"it could be taking longer than 30 seconds (current limit as of iOS 14)… it could be using over 24MB (current limit as of iOS 14) memory and being terminated early."* ([forums thread 67202](https://developer.apple.com/forums/thread/67202))
- **20 MB (File Provider) — user-reported; DTS declined to engage with the number** and redirected to Feedback Assistant. ([forums thread 804378](https://developer.apple.com/forums/thread/804378))
- **Apple's general posture**, from DTS Engineer Quinn "The Eskimo!" on Network Extension limits: *"These limits have changed in the past and may well change in the future. I'm posting them to assist in your debugging. You should not hard code knowledge about these limits into your code. The only way to ensure that your provider can run within the system's memory limits is to thoroughly test it on a wide range of device and OS combinations."* ([forums thread 73148](https://developer.apple.com/forums/thread/73148))

**Honest answer:** Apple will not tell you the number, it varies by extension type and OS version, it is enforced by jetsam killing your process with no recoverable error, and the observed value for share/action extensions has been 120 MB.

### Lifetime

- *"An extension typically terminates soon after it completes the request it received from the host app… Shortly after the app extension performs its task (or starts a background session to perform it), the system terminates the extension."* ([ExtensionOverview.html](https://developer.apple.com/library/archive/documentation/General/Conceptual/ExtensibilityPG/ExtensionOverview.html))
- *"After your app extension calls `completeRequestReturningItems:completionHandler:` to tell the host app that its request is complete, **the system can terminate your extension at any time**."* ([ExtensionScenarios.html](https://developer.apple.com/library/archive/documentation/General/Conceptual/ExtensibilityPG/ExtensionScenarios.html))
- The **only** sanctioned way for work to outlive the extension is a background `URLSession`: *"Although you can set up a background URL upload or download task, other types of background tasks, such as supporting VoIP or playing background audio, are not available to extensions. If you include the `UIBackgroundModes` key in your app extension's Info.plist file, the extension will be rejected by the App Store."* ([ExtensionCreation.html](https://developer.apple.com/library/archive/documentation/General/Conceptual/ExtensibilityPG/ExtensionCreation.html))
- And: *"After your app extension initiates the upload or download task, the extension can complete the host app's request and be terminated without affecting the outcome of the task."* ([ExtensionScenarios.html](https://developer.apple.com/library/archive/documentation/General/Conceptual/ExtensibilityPG/ExtensionScenarios.html))

`completeRequest(returningItems:completionHandler:)` is documented minimally — *"Calling this method eventually dismisses the app extension's view controller"* ([API ref](https://developer.apple.com/documentation/foundation/nsextensioncontext/completerequest\(returningitems:completionhandler:\))) — with the guide adding *"provide a completionHandler block to, at minimum, suspend your app extension should the system ask you to."* ([ExtensionCreation.html](https://developer.apple.com/library/archive/documentation/General/Conceptual/ExtensibilityPG/ExtensionCreation.html))

---

## Q1c — What Vellum's capture actually costs (repo-grounded)

The ticket assumed capture means "full-page `WKWebView` load, resource inlining." **It doesn't.** Reading the current macOS pipeline:

- `WebSessionBackend.writeWebArchive` calls `WebFetch.fetchPage(url)` — a plain `URLSession` GET (`Vellum/Services/Web/WebPageExtractor.swift:456`), not a `WKWebView` render. No WebKit participates in capture at all.
- `WebArchive.captureSnapshot(pageUrl:rawHtml:)` (`Vellum/Services/Web/WebArchive.swift:320`) regex-scans the HTML for asset references and `URLSession`-fetches each, accumulating them as `CapturedAsset.bytes: Data` in an array.
- `MiniZip.write(entries:)` (`Vellum/Services/Web/WebArchive.swift:731`) then builds the **entire ZIP as a second in-memory `Data`** before anything touches disk.

**Good news:** capture is pure Foundation — `URLSession`, string manipulation, zip. No WebKit, no AppKit, no UI. Nothing in it is `NS_EXTENSION_UNAVAILABLE`, so it *could* link into an extension target.

**Bad news:** the tuned ceilings (`WebArchive.swift:142-146`, `WebPageExtractor.swift:436-437`) are desktop-sized:

| Constant | Value |
|---|---|
| `WebFetch.maxResponseBytes` (HTML) | 25 MB |
| `WebArchive.maxAssets` | 80 |
| `WebArchive.maxAssetBytes` | 8 MB |
| `WebArchive.maxTotalAssetBytes` | **64 MB** |
| `WebArchive.maxManifestBytes` | 4 MB |
| `WebArchive.maxAnnotationsBytes` | 32 MB |

Worst case: 64 MB of asset `Data` live in the array, plus up to 25 MB of HTML string, plus the full ZIP built as another `Data` of comparable size — **well over 128 MB peak**, against an undocumented-but-observed ~120 MB extension jetsam limit. Running this inside a share extension is a coin flip on heavy pages, and the failure mode is a silent process kill with no user-visible error.

**Verdict: capture in the app, not the extension.** Not because it's impossible, but because Vellum's constants would have to be cut roughly 4× to be safe there — producing worse archives *and* more risk. Meanwhile there is no upside, because the extension has a documented way to hand the work off (below).

---

## Q2 — The hand-off: App Group container, and how it meets iCloud

### App Groups are the documented channel

> *"App groups allow multiple apps produced by a single development team to access shared containers and keychain access groups, and communicate using interprocess communication (IPC)."*
> — [com.apple.security.application-groups entitlement](https://developer.apple.com/documentation/bundleresources/entitlements/com.apple.security.application-groups)

> *"You can also use an app group to share data between an app extension or App Clip and its host app."*
> — [Configuring app groups](https://developer.apple.com/documentation/xcode/configuring-app-groups)

The archived guide states the problem and the fix:

> *"Even though an app extension bundle is nested within its containing app's bundle, the running app extension and containing app have no direct access to each other's containers."*
> *"To enable data sharing, use Xcode or the Developer portal to enable app groups for the containing app and its contained app extensions… After you enable app groups, an app extension and its containing app can both use the `NSUserDefaults` API to share access to user preferences [via] `initWithSuiteName:`."*
> — [ExtensionScenarios.html](https://developer.apple.com/library/archive/documentation/General/Conceptual/ExtensibilityPG/ExtensionScenarios.html)

**Concurrency is your problem, and Apple says so:**

> *"When you set up a shared container, the containing app—and each contained app extension… have read and write access to the shared container. To avoid data corruption, you must synchronize data accesses. Use Core Data, SQLite, or Posix locks to help coordinate data access in a shared container… In iOS 9 and later, you can employ the `NSFileCoordinator` class directly for shared data access, but if you do this you **must** remove your `NSFilePresenter` objects when your app extension transitions into the background."*
> — [same source](https://developer.apple.com/library/archive/documentation/General/Conceptual/ExtensibilityPG/ExtensionScenarios.html)

Container mechanics: *"In iOS, the group identifier starts with the word `group` and a dot, followed by the group name. However, the system makes no guarantee about the group directory's name or location in the file system. Indeed, the directory is accessible only with the file URL returned by this method… If you call the method with an invalid group identifier in iOS, the method returns a `nil` value."* ([containerURL(forSecurityApplicationGroupIdentifier:)](https://developer.apple.com/documentation/foundation/filemanager/containerurl\(forsecurityapplicationgroupidentifier:\)))

Note also: *"when all the apps in a given app group are removed from the device, the system detects this condition and removes the corresponding group directory as well."* ([same source](https://developer.apple.com/documentation/foundation/filemanager/containerurl\(forsecurityapplicationgroupidentifier:\))) — the App Group container is **device-local staging**, not durable library storage. It is not synced.

### Ubiquity containers and extensions: technically callable, practically a bad idea

**There is no Apple statement forbidding it.** The API's documentation is extension-agnostic. But three things weigh against it:

1. **It blocks.** *"Do not call this method from your app's main thread. Because this method might take a nontrivial amount of time to set up iCloud and return the requested URL, you should always call it from a secondary thread. To determine if iCloud is available, especially at launch time, check the value of the `ubiquityIdentityToken` property instead."* ([url(forUbiquityContainerIdentifier:)](https://developer.apple.com/documentation/foundation/filemanager/url\(forubiquitycontaineridentifier:\)))
2. **The setup cost is per-process.** *"The first time you call this method for a given ubiquity container, the system extends your app's sandbox to include that container."* ([same source](https://developer.apple.com/documentation/foundation/filemanager/url\(forubiquitycontaineridentifier:\))) The app pays that once per launch and caches it — `ipad-app`'s `WebStorage.resolveICloudRoot()` does exactly this (`Vellum/Services/Web/WebStorage.swift:98-113`). A share extension is a fresh short-lived process on *every* invocation, so it pays the cost every single time, inside a budget Apple describes as *"well under one second."*
3. **It has silently broken before.** [Forum thread 715078](https://developer.apple.com/forums/thread/715078) records a widget extension where `url(forUbiquityContainerIdentifier:)` began returning `nil` in iOS 16.1 beta while the main app kept working. No DTS reply, no recorded resolution, Feedback filed (FB11529890). Not proof of an unsupported path, but strong evidence that extension-context ubiquity access is not a well-trodden, well-defended road.

`NSUbiquitousKeyValueStore` in extensions: **no definitive Apple statement either way.** Community threads (e.g. [767779](https://developer.apple.com/forums/thread/767779)) show provisioning fragility between app and extension targets, but nothing authoritative. Treat as unverified.

**Conclusion:** the App Group container is where the extension writes. Whatever the app's chosen `WebStorageLayout` is — local Application Support, ubiquity container, or a security-scoped custom folder — resolving and writing it stays in the main app, which already has the machinery.

### Capture-URL-in-extension vs. full-capture-in-extension

Apple's guidance consistently points at deferral. From [Choosing background strategies for your app](https://developer.apple.com/documentation/backgroundtasks/choosing-background-strategies-for-your-app): heavy workloads belong in a `BGProcessingTaskRequest`, where *"the system decides the best time to launch your background task,"* including overnight while charging; short refresh work belongs in `BGAppRefreshTaskRequest`, where the system *"provides your app up to 30 seconds of background runtime."*

Two flags matter, from [WWDC 2019 Session 707, "Advances in App Background Execution"](https://developer.apple.com/videos/play/wwdc2019/707/):

> *"requires network connectivity… actually defaults to false. You should make sure to set this to true if you actually require network connectivity for your task because otherwise we may launch your task at a time where there is no network."*
> *"requires external power… if you are requiring yourself to do intensive work and use a lot of resources, we highly recommend that you set this to true so that you can preserve your user's battery life."*

And scheduling is opportunistic with no SLA — the system gates on recent foreground use, and there is a hard queue cap: *"There can be a total of 1 refresh task and 10 processing tasks scheduled at any time. Trying to schedule more tasks returns `tooManyPendingTaskRequests`."* ([BGTaskScheduler.submit(_:)](https://developer.apple.com/documentation/backgroundtasks/bgtaskscheduler/submit\(_:\)))

**So: `BGProcessingTask` is a fine opportunistic catch-up mechanism, but it must not be the only path.** A user who saves five articles on a train and opens Vellum ten minutes later should find them already ingesting, not waiting for a system heuristic.

---

## Q3 — Waking the main app

### What does NOT work

**Darwin notifications** — DTS Engineer Quinn "The Eskimo!" is explicit:

> *"iOS will not resume your app to receive a Darwin notification. If your app is suspended in the background when someone posts a notification, one of two things should happen: If your app is resumed, it should receive the notification then. If your app is terminated while suspended, it will never receive the notification."*
> — [forums thread 769398](https://developer.apple.com/forums/thread/769398)

Reinforced by the API doc: *"the main thread's run loop must be running in one of the common modes… for Darwin-style notifications to be delivered"* ([CFNotificationCenterGetDarwinNotifyCenter()](https://developer.apple.com/documentation/corefoundation/cfnotificationcentergetdarwinnotifycenter\(\))) — a suspended app's run loop is not spinning.

Darwin notifications are still worth wiring: they make the "app is already open in the background behind Safari" case instant. They are just not a wake mechanism.

**App Group `UserDefaults`/file writes** do not wake anything. They are passive storage, read only when the app next runs.

**`NSExtensionContext.open(_:completionHandler:)`** — *"Each extension point determines whether to support this method… In iOS, the Today and iMessage app extension points support this method."* ([API ref](https://developer.apple.com/documentation/foundation/nsextensioncontext/open\(_:completionhandler:\))) The archived guide is blunter: *"A Today widget (and no other app extension type) can ask the system to open its containing app."* ([ExtensionOverview.html](https://developer.apple.com/library/archive/documentation/General/Conceptual/ExtensibilityPG/ExtensionOverview.html)) And an Apple WWDR engineer, in a "Recommended" forum answer: *"Share Extensions are not allowed to open apps and you should use completeRequest and not openURL (which is only available to Today Extensions)."* ([forums thread 758790](https://developer.apple.com/forums/thread/758790))

**`BGTaskScheduler` from the extension** — the extension *can* submit, but that doesn't wake it; it wakes the app, eventually, at the system's discretion. From WWDC 2019 Session 707, verbatim from the transcript:

> *"You can also submit requests from an extension while it's running. So, if our keyboard extension wants to do some learning based on the user's typing habits, it can create a BG processing task request and submit it too."*
> *"…note that that processing task requested from the keyboard extension was delivered to the main app, and that's because **it's always the main containing app that is launched to handle background tasks, never extensions**."*
> — [WWDC 2019 Session 707](https://developer.apple.com/videos/play/wwdc2019/707/)

Registration is app-side by construction: *"Registration of all launch handlers must be complete before the end of `applicationDidFinishLaunching(_:)`"* and the identifier must appear in `BGTaskSchedulerPermittedIdentifiers`. ([register(forTaskWithIdentifier:using:launchHandler:)](https://developer.apple.com/documentation/backgroundtasks/bgtaskscheduler/register\(fortaskwithidentifier:using:launchhandler:\)))

### What DOES work: background `URLSession` launch events

This is the one fully-documented path from "extension saved something" to "app is running."

> *"If your app extension initiates a background `NSURLSession` task, you must also set up a shared container that both the extension and its containing app can access. Use the `sharedContainerIdentifier` property of the `NSURLSessionConfiguration` class to specify an identifier for the shared container so that you can access it later."*
> *"In iOS, if your extension isn't running when a background task completes, **the system launches your containing app in the background and calls the `application:handleEventsForBackgroundURLSession:completionHandler:` app delegate method**."*
> *"Because only one process can use a background session at a time, you need to create a different background session for the containing app and each of its app extensions… It's recommended that your containing app only use a background session that was created by one of its extensions when the app is launched in the background to handle events for that extension."*
> — [ExtensionScenarios.html](https://developer.apple.com/library/archive/documentation/General/Conceptual/ExtensibilityPG/ExtensionScenarios.html)

The `sharedContainerIdentifier` requirement is hard, not advisory: *"To create a URL session for use by an app extension, set this property to a valid identifier for a container shared between the app extension and its containing app. If you try to create a URL session from your app extension but fail to set this property to a valid value, **the URL session is invalidated upon creation**."* ([sharedContainerIdentifier](https://developer.apple.com/documentation/foundation/urlsessionconfiguration/sharedcontaineridentifier))

The launch behaviour is controlled by `sessionSendsLaunchEvents`: *"When the value of this property is [true], the system automatically wakes up or launches the iOS app in the background when the session's tasks finish or require authentication. At that time, the system calls the app delegate's [`handleEventsForBackgroundURLSession`] method, providing it with the identifier of the session that needs attention."* ([sessionSendsLaunchEvents](https://developer.apple.com/documentation/foundation/urlsessionconfiguration/sessionsendslaunchevents))

**One important dampener:** you don't control the timing. *"The session object applies the value of this property only to transfers that your app starts while it is in the foreground. For transfers started while your app is in the background, the system always starts transfers at its discretion — in other words, the system assumes this property is [true] and ignores any value you specified."* ([isDiscretionary](https://developer.apple.com/documentation/foundation/urlsessionconfiguration/isdiscretionary)) A share extension is not the foreground app, so its background transfers are always discretionary. On Wi-Fi and decent battery this is usually prompt; on cellular with Low Power Mode it may not be.

### Verdict on Q3

**Ingest-on-next-foreground is the guaranteed floor, not the ceiling.** The realistic design is a three-tier ladder, all three cheap to implement:

1. **Foreground drain** (always works) — on app launch and on `scenePhase → .active`, drain the App Group inbox.
2. **Background `URLSession` launch event** (documented, opportunistic) — the extension kicks a background download of the page into the shared container; when it lands, iOS launches Vellum in the background and calls `handleEventsForBackgroundURLSession`, at which point Vellum drains the inbox.
3. **`BGProcessingTaskRequest`** (opportunistic catch-up) — `requiresNetworkConnectivity = true`, submitted by the app on foreground (and optionally by the extension, since submit-from-extension is documented as working even though the handler always runs in the app). Sweeps anything tiers 1 and 2 missed.

Plus a **Darwin notification** as a free fast-path for the "app is already alive" case.

---

## Q4 — Do App Groups need a paid developer account?

**No. App Groups work on a free Apple Account. iCloud does not.**

Apple's [supported capabilities (iOS)](https://developer.apple.com/help/account/reference/supported-capabilities-ios/) page has three columns, defined on the page itself:

> *"ADP: Apple Developer Program membership. Members of this paid program can distribute apps on the App Store. ADEP: Apple Developer Enterprise Program membership… **Apple Developer: Apple Account holders who have agreed to the Apple Developer Agreement to access certain resources on the Apple Developer website. No cost is associated with this agreement and developers can't distribute apps.**"*

That third column is the free "Personal Team" tier. Parsing the raw table markup (the rendered checkmarks are `<figure class="icon icon-checksolid" alt="yes">` elements):

| Capability | ADP | ADEP | Apple Developer (free) |
|---|:-:|:-:|:-:|
| **App groups** | ✅ | ✅ | **✅** |
| Background modes | ✅ | ✅ | ✅ |
| Keychain sharing | ✅ | ✅ | ✅ |
| **iCloud: CloudKit** | ✅ | ✅ | **—** |
| **iCloud: iCloud documents** | ✅ | ✅ | **—** |
| **iCloud: iCloud key-value storage** | ✅ | ✅ | **—** |
| Push notifications | ✅ | ✅ | — |
| Associated domains | ✅ | ✅ | — |
| Sign in with Apple | ✅ | — | — |

(Source: [developer.apple.com/help/account/reference/supported-capabilities-ios](https://developer.apple.com/help/account/reference/supported-capabilities-ios/), table parsed from raw HTML on 2026-08-01. Only 9 of 57 listed capabilities carry a free-tier checkmark; App groups is one of them.)

This **contradicts widely-repeated folklore** that App Groups is paid-only. Verify it again before betting a milestone on it, but Apple's own current capability table is about as primary as this gets.

### The Personal Team fine print

From [Choosing a Membership](https://developer.apple.com/support/compare-memberships/): on-device testing is included at the free tier, with these documented limits —

> *"The number of App IDs that can be registered [to] your account at one time is limited to 10 and each expires after 7 days."*
> *"The number of test devices that can be registered to your account for each platform is limited to 3 and each expires after 7 days."*
> *"Provisioning profiles will expire 7 days from issuance, which may require you to rebuild and re-install your app to your device after expiration."*

(The often-quoted "max 3 apps" limit does not appear in the current page; the documented cap is 10 App IDs.)

App Store distribution is blocked: Apple's Technical Q&A [QA1915](https://developer.apple.com/library/archive/qa/qa1915/_index.html) states a Personal Team *"cannot be used to Code Sign your App for submission to the App Store"* — the Validate/Export buttons are disabled and submission returns *"The selected team does not have a program membership that is eligible for this feature."*

**App Groups are provisioning-profile-gated but not membership-gated.** Quinn "The Eskimo!" (DTS): *"You then claim access to it by listing it in the App Groups entitlement. That claim must be authorised by a provisioning profile. The Developer website will only let you include your team's app group IDs in your profile."* ([forums thread 721701](https://developer.apple.com/forums/thread/721701))

**Scoping caveat for solo dev:** a DTS engineer confirms App Groups work with Personal Teams but are namespaced per team — *"Personal teams are isolated from each other; each personal team has its own namespace… There is no documented mechanism to share an explicit App ID across separate personal teams."* ([forums thread 834802](https://developer.apple.com/forums/thread/834802)) Irrelevant here: the app target and the extension target sign under the same Personal Team (`DEVELOPMENT_TEAM: 9DCG97VASG` in `project.yml`).

**Simulator:** Simulator builds do not validate entitlements against a provisioning profile the way device builds do, so App Groups behave permissively there regardless of team. **This specific point could not be pinned to a citable Apple DTS statement** — flagging it rather than asserting it.

### What this means for Vellum concretely

`ipad-app/project.yml` currently carries this comment:

> *"iCloud entitlement (Vellum/Vellum-iOS.entitlements) is intentionally NOT wired in: the free/Personal signing team can't provision the iCloud capability, which breaks device builds. Re-add CODE_SIGN_ENTITLEMENTS once on a paid Apple Developer account."*

That comment is **correct and confirmed** — and App Groups is the exception to it. The share extension can be built, signed, and device-tested on the current free team today. It just has to store into the local `WebStorageLayout` (Application Support) until a paid account unlocks the ubiquity container. This decouples #143 from the distribution-mechanics question that #139 lists as unspecified, and from the iCloud research in [#142](https://github.com/ayushdeolasee/Vellum/issues/142).

---

## Recommended architecture for Vellum

**Shape: capture cheap and structured in the extension → App Group inbox → the app does the real work.**

### Extension target (`VellumShare`, `type: app-extension` in `project.yml`)

`Info.plist` — declare both activation rules and the JS file:

```xml
<key>NSExtension</key>
<dict>
  <key>NSExtensionPointIdentifier</key><string>com.apple.share-services</string>
  <key>NSExtensionAttributes</key>
  <dict>
    <key>NSExtensionJavaScriptPreprocessingFile</key><string>VellumCapture</string>
    <key>NSExtensionActivationRule</key>
    <dict>
      <key>NSExtensionActivationSupportsWebPageWithMaxCount</key><integer>1</integer>
      <key>NSExtensionActivationSupportsWebURLWithMaxCount</key><integer>1</integer>
    </dict>
  </dict>
</dict>
```

**`VellumCapture.js`** returns a small, plist-safe dictionary:

```javascript
run: function(args) {
  args.completionFunction({
    url:   document.baseURI,
    title: document.title,
    html:  document.documentElement.outerHTML   // opportunistic; may be large
  });
}
```

**Extension Swift, in order, all of it cheap:**

1. Read the `kUTTypePropertyList` attachment; pull `NSExtensionJavaScriptPreprocessingResultsKey`. Fall back to `public.url` when JS results are absent (the Messages/Mail path).
2. Normalise via the existing `WebUrl.normalize` and derive the page key via `WebLibrary.pageKey` — both pure Foundation (`WebPageExtractor.swift:19`, `WebLibrary.swift:202`), so both link cleanly into an extension target and guarantee the key matches what the Mac and iPad produce. This preserves the non-negotiable byte-compatibility constraint from #139.
3. Resolve the inbox: `FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: "group.com.ayushdeolasee.vellum")` — nil-check it, since iOS returns `nil` for an invalid group.
4. Under `NSFileCoordinator`, write `Inbox/<uuid>.json` (`{rawUrl, normalizedUrl, pageKey, title, capturedAt}`) and, when the JS returned HTML, `Inbox/<uuid>.html` beside it. Write to a temp name, then rename — an interrupted extension must never leave a half-written record the app will try to parse.
5. Start a background `URLSession` (`sharedContainerIdentifier` = the group, `sessionSendsLaunchEvents = true`, unique per-extension session identifier) downloading the page URL into the container. Even when the JS already gave you the HTML, this transfer is what buys the launch event.
6. Post a Darwin notification (free fast-path for an already-running app).
7. `completeRequest(returningItems: [], completionHandler:)` immediately. **Never** run `WebArchive.captureSnapshot` or `MiniZip.write` here.

**Never in the extension:** `url(forUbiquityContainerIdentifier:)`, `WKWebView`, asset fetching, zip building.

### Main app

- Register a `BGProcessingTask` handler in `applicationDidFinishLaunching` (registration is app-only and must complete before that method returns).
- **Three drain triggers**, all calling one idempotent `WebInbox.drain()`:
  - `scenePhase → .active` (the guaranteed floor)
  - `application(_:handleEventsForBackgroundURLSession:completionHandler:)` (the real wake path)
  - the `BGProcessingTask` handler, `requiresNetworkConnectivity = true` (opportunistic catch-up)
  - plus the Darwin observer when already foregrounded
- **`drain()`** walks the inbox under `NSFileCoordinator` and, per item:
  - If a `.html` sidecar exists, feed it straight to `WebArchive.captureSnapshot(pageUrl:rawHtml:)` — **skipping `WebFetch.fetchPage` entirely**.
  - Otherwise fall back to the existing `WebFetch.fetchPage` path.
  - Then the unchanged pipeline: `buildManifest` → `MiniZip.write` → write into whatever `WebLibrary.activeLayout` is (Application Support today; ubiquity container once a paid account lands).
  - Delete the inbox item only after the archive is committed. Dedup on `pageKey`, which the extension already computed, so double-saving a page is a no-op.
- Per `CLAUDE.md` main-thread hygiene: `drain()` must hop off `@MainActor` before touching the filesystem, its `Task` handle must be retained and joinable so quit paths and tests can `await` it, and any `isIngesting` flag must clear on every exit path with a generation token guarding overlapping drains.

### Why the HTML sidecar is the actual killer feature

`WebFetch.session` is configured `URLSessionConfiguration.ephemeral` with `httpCookieAcceptPolicy = .never` and `httpShouldSetCookies = false` (`WebPageExtractor.swift:444-454`). It is a logged-out, JavaScript-free GET. The share extension's JS runs **inside the user's live Safari page** — after client-side rendering, and inside their session. Capturing `outerHTML` there means Vellum-on-iPhone can archive single-page apps, infinite-scroll articles, and logged-in content that the Mac app currently cannot. That's not parity; that's a capability the Mac app should probably borrow later.

The honest caveat: only the *HTML* benefits. Asset fetches still happen from the app without cookies, so images behind auth will be skipped (`captureSnapshot` already handles skips gracefully via `CapturedSnapshot.skipped`).

### Provisioning today

- Add **App Groups** to both targets. Free-tier-legal per Apple's capability table.
- Leave `CODE_SIGN_ENTITLEMENTS` for iCloud unwired, exactly as `ipad-app` documents. The extension does not need it.
- Consequence: on the free team the inbox drains into local Application Support. When a paid account arrives, `WebLibrary.activeLayout` swings to the ubiquity container and **the extension needs no change at all** — it only ever writes to the group container.

### Open questions to hand onward

- **→ [#146](https://github.com/ayushdeolasee/Vellum/issues/146) (storage/sync semantics):** the App Group container is device-local and is deleted when the last app in the group is removed. Should an undrained inbox item survive an app reinstall? (Answer is probably "no, and that's fine" — the transfer is seconds-to-minutes.)
- **→ [#142](https://github.com/ayushdeolasee/Vellum/issues/142) (iCloud mechanics):** confirm the ubiquity write path stays app-only under whatever sync design lands. Nothing here should push ubiquity access into an extension.
- **→ [#140](https://github.com/ayushdeolasee/Vellum/issues/140) (scope):** the JS-DOM capture is a strict superset of the Mac's capability. Worth deciding whether that's v1 or a fast-follow, and whether the Mac app eventually gets a Safari extension to match.
- **Untested assumption:** the size of `outerHTML` that survives the `kUTTypePropertyList` XPC hop. Undocumented. Needs an empirical probe on a heavy page (a long Substack post, a Twitter/X thread) before the spec commits to it. Recommend a size guard in the JS itself — drop the `html` key above some threshold and let the app re-fetch.
