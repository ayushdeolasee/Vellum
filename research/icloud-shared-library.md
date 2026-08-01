# One library across Mac, iPad, iPhone — iCloud mechanics and constraints

Research findings for [issue #142](https://github.com/ayushdeolasee/Vellum/issues/142) (wayfinder map [#139](https://github.com/ayushdeolasee/Vellum/issues/139); unblocks [#146](https://github.com/ayushdeolasee/Vellum/issues/146)).

> **File location note.** The repo has no existing research-notes convention, so this file is parked at `research/icloud-shared-library.md` on branch `research/icloud-shared-library`. If a convention lands later, move it.

**Source discipline.** Every claim cites a URL. Apple Developer documentation, Apple archived guides, Technical Notes and Technical Q&As are primary. Apple Developer Forums replies are used only where an Apple staff member (DTS Engineer) answered, and are labelled **[DTS]**. Observations made on this machine are labelled **[empirical]** and are explicitly *not* citations. Where Apple documents nothing, this file says so — those gaps are findings too, and there is a consolidated table of them at the end.

---

## TL;DR

**1. Yes, they can share one container — but not the way Vellum is built today, and the ticket's premise is off by one folder.** The Mac app does not write to `~/Library/Mobile Documents/iCloud~<container>/`; it writes to `com~apple~CloudDocs/Vellum/`, the *user's* iCloud Drive, which iOS cannot reach by path at all. **The supported pattern is one container identifier declared in both apps' entitlements, with every app passing that identifier explicitly to `url(forUbiquityContainerIdentifier:)` — Apple says in so many words "Do not pass `nil`"** ([iCloud Fundamentals](https://developer.apple.com/library/archive/documentation/General/Conceptual/iCloudDesignGuide/Chapters/iCloudFundametals.html)). iPad currently passes `nil`. Visibility in Files/Finder comes from `NSUbiquitousContainers` in Info.plist plus a `CFBundleVersion` bump; only `Documents/` is user-visible. **Bonus finding: Apple explicitly blesses the no-entitlement path on macOS** — *"On OS X v10.11 and later, you can store documents in the user's iCloud Drive folder without needing to set the signing identity and enable iCloud in the Xcode project. Just specify your app's containers in the `Info.plist` file"* ([iCloud Design Guide](https://developer.apple.com/library/archive/documentation/General/Conceptual/iCloudDesignGuide/Chapters/DesigningForDocumentsIniCloud.html)). Writing *raw bytes at the path* instead of through the API remains undocumented in both directions.

**2. iCloud is paid-only on every platform; App Groups is free on every platform; TestFlight is paid-only.** Apple's per-platform capability tables settle it: the free "Apple Developer" column checks **App groups, Background modes, Data protection, HealthKit, HomeKit, Inter-App Audio, Keychain sharing, Maps, Wireless Accessory Configuration** on iOS and nothing else — **iCloud: CloudKit / iCloud documents / iCloud key-value storage are ADP-only** ([supported capabilities (iOS)](https://developer.apple.com/help/account/reference/supported-capabilities-ios/), [(macOS)](https://developer.apple.com/help/account/reference/supported-capabilities-macos/)); **[DTS]** Quinn confirms *"the Apple Developer column shows the capabilities for a Personal Team"* ([thread 128767](https://developer.apple.com/forums/thread/128767)). So **yes, App Groups now works with a free team** — the old App Distribution Guide list is partly obsolete. Free-team limits: **10 App IDs, 3 devices, 3 apps per device, all expiring after 7 days; profiles expire 7 days from issuance** ([About your developer account](https://developer.apple.com/help/account/basics/about-your-developer-account)). TestFlight and App Store Connect are unchecked for free accounts *and* for Enterprise. The one documented exception for iCloud: the macOS "Mac Note" above, which works precisely because it claims **no** iCloud entitlement — and per [TN3125](https://developer.apple.com/documentation/technotes/tn3125-inside-code-signing-provisioning-profiles), *"A Mac app that uses no restricted entitlements doesn't need a provisioning profile."*

**3. Coordination is mandatory, and Vellum uses none of it.** *"The use of file coordinators and presenters is mandatory when working with iCloud documents"* ([iCloud Design Guide](https://developer.apple.com/library/archive/documentation/General/Conceptual/iCloudDesignGuide/Chapters/DesigningForDocumentsIniCloud.html)); *"every file access in your app, unless it is in the context of the reading or writing methods of `UIDocument` or `NSDocument`, should go through `NSFileCoordinator`"* ([TN2336](https://developer.apple.com/library/archive/technotes/tn2336/_index.html)). The decisive consequence: *"Your presenter objects are **not** notified about changes made directly using low-level read and write calls to the file. **Only changes that go through a file coordinator result in notifications.**"* ([NSFilePresenter](https://developer.apple.com/documentation/foundation/nsfilepresenter)). On materialization: **`FileManager.fileExists(atPath:)` and `contentsOfDirectory(atPath:)` both materialize dataless files** ([TN3150](https://developer.apple.com/documentation/technotes/tn3150-getting-ready-for-data-less-files)) — so Vellum's own "don't materialize" guard is built from the exact calls that materialize. Documented opt-out: `setiopolicy_np(IOPOL_TYPE_VFS_MATERIALIZE_DATALESS_FILES, IOPOL_SCOPE_THREAD, IOPOL_MATERIALIZE_DATALESS_FILES_OFF)`.

**4. Not silent latest-wins — a winner is picked and the losers are kept forever until resolved.** *"one file is chosen as the current version and any other versions are tagged as being in conflict"* ([NSFileVersion](https://developer.apple.com/documentation/foundation/nsfileversion)). Unresolved, *"iCloud continues to sync them to all a user's devices and those versions continue to consume user iCloud quota"* ([isResolved](https://developer.apple.com/documentation/foundation/nsfileversion/isresolved)). For a sidecar that already exists on both devices this is a **version conflict** (invisible version store), not a bounced `foo 2.json` — bounced names only happen for *new-file* conflicts in document scope ([TN2336](https://developer.apple.com/library/archive/technotes/tn2336/_index.html)). With no coordinator and no presenter, **Vellum is never told**, so the user experiences it as "my iPad highlights vanished."

---

## Where Vellum actually stands today (code survey, 2026-08-01)

Established by reading the worktrees, not from Apple docs. Two of these contradict the framing in the ticket.

| | macOS (`main`) | iPad (`ipad-app`) |
|---|---|---|
| iCloud root | `~/Library/Mobile Documents/com~apple~CloudDocs/Vellum/` | `url(forUbiquityContainerIdentifier: nil)` + `/Documents/Vellum/` |
| Bundle ID | `com.vellum.app` | `com.ayushdeolasee.vellum` |
| Team | `9DCG97VASG` | `9DCG97VASG` |
| Entitlements wired? | none (`ENABLE_APP_SANDBOX: NO`, no `CODE_SIGN_ENTITLEMENTS`) | file exists, deliberately not wired |
| `NSUbiquitousContainers` in Info.plist? | no | no |
| `NSFileCoordinator` / `NSFilePresenter` / `NSMetadataQuery` / `NSFileVersion`? | **none** | **none** |
| Write pattern | tmp file + `rename(2)` | same |

Sources: `main/Vellum/Services/Web/WebStorage.swift:82-94`, `main/project.yml:30-32,109`, `ipad-app/Vellum/Services/Web/WebStorage.swift:102-115`, `ipad-app/project.yml:66-75`, `ipad-app/Vellum/Vellum-iOS.entitlements`. Atomic writers: `ipad-app/Vellum/Services/Web/WebLibrary.swift:229-253` (`saveRecord`), `ipad-app/Vellum/Services/Pdf/PdfAtomicWriter.swift:135-176`.

Three consequences fall out immediately:

- **The two roots are different directories.** `com~apple~CloudDocs` is the user's iCloud Drive; `iCloud~com~ayushdeolasee~vellum` would be an app container. Siblings under Mobile Documents, not the same place.
- **The bundle IDs differ**, so `iCloud.$(PRODUCT_BUNDLE_IDENTIFIER)` expands to two *different* container identifiers. Even if both apps adopted containers today they would not meet. (The team matches, which is the part that would have been hard to fix.)
- **iPad passes `nil`.** Apple explicitly says not to, for exactly this use case — §1.3.

**[empirical]** `~/Library/Mobile Documents/` on this machine holds 116 container directories in three shapes:

```
com~apple~CloudDocs/                       <- the user's iCloud Drive (Vellum/ lives here)
iCloud~app~readkit/Documents/              <- container id "iCloud.app.readkit"
5UAR78B6YU~com~goodnotesapp~goodnotes/     <- legacy team-prefixed container id
com~apple~Keynote/                         <- Apple first-party
```

Dots become tildes. **Apple documents neither the `Mobile Documents` path nor this mangling** — see the gaps table. Treat the path shape as reverse-engineered, never as an API.

---

## 1. Can the Mac's folder and an iOS ubiquity container be the same directory?

### 1.1 What a ubiquity container is

Container identity is cloud-side and platform-independent — this is the documented basis for cross-platform sharing:

> "To save data to iCloud, your app places data in special file system locations known as iCloud containers. An *iCloud container* (also referred to as a *ubiquity container*) **serves as the local representation of the corresponding iCloud storage.** It is separate from the rest of your app's data"

— [iCloud Fundamentals](https://developer.apple.com/library/archive/documentation/General/Conceptual/iCloudDesignGuide/Chapters/iCloudFundametals.html); restated in [Configuring iCloud services](https://developer.apple.com/documentation/xcode/configuring-icloud-services/): *"a container — alternatively known as a ubiquity container — serves as a local representation of the corresponding iCloud storage."*

The API contract, verbatim:

> "Returns the URL for the iCloud container associated with the specified identifier and establishes access to that container."
>
> "You use this method to determine the location of your app's ubiquity container directories and to configure your app's initial iCloud access. **The first time you call this method for a given ubiquity container, the system extends your app's sandbox to include that container.** In iOS, you must call this method at least once before trying to search for cloud-based files in the ubiquity container."
>
> "Each app that syncs documents to the cloud must have at least one associated ubiquity container in which to put those files. **This container can be unique to the app or shared by multiple apps.**"
>
> "**Important:** Do not call this method from your app's main thread."

— [FileManager.url(forUbiquityContainerIdentifier:)](https://developer.apple.com/documentation/foundation/nsfilemanager/1411653-urlforubiquitycontaineridentifie)

That last line is already respected: `ipad-app` resolves it off-main and caches (`WebStorage.swift:98-115`). Good instinct, correctly documented.

**The `Documents` subdirectory is the load-bearing structural rule:**

> "**The `Documents` subdirectory is the public face of an iCloud container.** When a user examines the iCloud storage for your app (using Settings in iOS or System Preferences in OS X), files or file packages in the `Documents` subdirectory are listed and can be deleted individually."
>
> "The structure of a newly created iCloud container is minimal—having only a `Documents` subdirectory."

— [iCloud Fundamentals](https://developer.apple.com/library/archive/documentation/General/Conceptual/iCloudDesignGuide/Chapters/iCloudFundametals.html)

> "Place files in the `Documents` subdirectory of an iCloud container to make them visible to the user and make it possible for the user to delete them individually. **Files you place outside of the `Documents` subdirectory are grouped together as "data."**"

— [Designing for Documents in iCloud](https://developer.apple.com/library/archive/documentation/General/Conceptual/iCloudDesignGuide/Chapters/DesigningForDocumentsIniCloud.html)

> "In iCloud, the contents of the `Documents` directory are made visible to the user so that individual documents can be deleted. Everything outside of the `Documents` directory is grouped together and treated as a single entity that a user can keep or delete."

— [iCloud File Management](https://developer.apple.com/library/archive/documentation/FileManagement/Conceptual/FileSystemProgrammingGuide/iCloud/iCloud.html)

So `ipad-app` appending `Documents` (`WebStorage.swift:108-110`) is correct. Note the implication for layout: `.vellum/` and `Web Pages/` both land under `Documents/Vellum/`, so both are individually user-deletable in Files. Anything you *don't* want the user picking apart belongs outside `Documents/` — where it becomes one opaque all-or-nothing "data" blob.

Apple also prescribes create-local-then-move:

> "All documents must be created on a local disk initially and moved to a user's iCloud account later." … "First, it is moved from its current location in the file system to a local system-managed directory where it can be monitored by the iCloud service. After that transfer, the file is transferred to iCloud and to the user's other devices as soon as possible."

— [iCloud File Management](https://developer.apple.com/library/archive/documentation/FileManagement/Conceptual/FileSystemProgrammingGuide/iCloud/iCloud.html), prescribing `setUbiquitous:itemAtURL:destinationURL:error:`. Vellum follows this nowhere. Apple describes it as how the mechanism works rather than stating it as a hard requirement.

### 1.2 Container identifier format and the entitlement keys

**Modern format rule:**

> "You must begin the container's name with `iCloud.` and use a unique string in reverse DNS notation."

— [Configuring iCloud services](https://developer.apple.com/documentation/xcode/configuring-icloud-services/). The current sample docs add: *"An iCloud container identifier is case-sensitive and must begin with `iCloud.`"* ([Synchronizing documents in the iCloud environment](https://developer.apple.com/documentation/uikit/synchronizing-documents-in-the-icloud-environment)).

**An unreconciled contradiction in Apple's own docs.** The runtime API page says something different:

> "The string you specify must not contain wildcards and must be of the form `<TEAMID>.<CONTAINER>`, where `<TEAMID>` is your development team ID and `<CONTAINER>` is the bundle identifier of the container you want to access."

— [url(forUbiquityContainerIdentifier:)](https://developer.apple.com/documentation/foundation/nsfilemanager/1411653-urlforubiquitycontaineridentifie)

Apple never reconciles `iCloud.com.example.app` (Xcode/entitlements docs) with `<TEAMID>.<CONTAINER>` (API doc) on any page. In practice the `iCloud.`-prefixed string is what goes into the entitlement; the **[empirical]** on-disk survey showing both `iCloud~…` and `<TEAMID>~…` folder shapes is consistent with both forms existing historically.

**The old "must match your bundle ID" rule is dead.** The archived reference said:

> "As the value for this entitlement, provide an array of one or more strings. One of these strings must be the bundle identifier for your app, or for another app that you submit using the same team identifier." … "You must not use a wildcard ("`*`") character in the string for an iCloud container entitlement value."

— [Entitlement Key Reference: Enabling iCloud Storage](https://developer.apple.com/library/archive/documentation/Miscellaneous/Reference/EntitlementKeyReference/Chapters/EnablingiCloud.html)

**[DTS]** Asked directly whether that first sentence still holds, a DTS Engineer answered: **"No, that is not the case anymore."** — [thread 765461](https://developer.apple.com/forums/thread/765461). This matters for Vellum: it means a shared literal container ID that matches *neither* app's bundle ID is legitimate.

**The three keys in `Vellum-iOS.entitlements`:**

| Key | Status |
|---|---|
| `com.apple.developer.icloud-container-identifiers` | [Documented](https://developer.apple.com/documentation/bundleresources/entitlements/com.apple.developer.icloud-container-identifiers): *"The container identifiers for the iCloud production environment."* String array. iOS 3.0+, macOS 10.7+. |
| `com.apple.developer.icloud-services` | [Documented](https://developer.apple.com/documentation/bundleresources/entitlements/com.apple.developer.icloud-services): *"The iCloud services used by the app."* Values `CloudDocuments`, `CloudKit`, `CloudKit-Anonymous`. Vellum's `CloudDocuments` is right. |
| `com.apple.developer.ubiquity-container-identifiers` | **No modern documentation page exists** — absent from the [entitlements index](https://developer.apple.com/documentation/bundleresources/entitlements); the docs JSON endpoint 404s. Described only in the archived Entitlement Key Reference, and referenced by the `url(forUbiquityContainerIdentifier:)` page and [Configuring iCloud services](https://developer.apple.com/documentation/xcode/configuring-icloud-services/), which confirms Xcode still writes it for iCloud Documents. |

What Xcode writes, per [Configuring iCloud services](https://developer.apple.com/documentation/xcode/configuring-icloud-services/): iCloud Documents → `icloud-services` + `ubiquity-container-identifiers`; CloudKit → `icloud-services`; key-value → `ubiquity-kvstore-identifier`. Plus: *"Xcode updates your target's entitlements file to include the `com.apple.developer.icloud-container-identifiers`, which is an array that comprises the containers you select."* So all three keys in Vellum's file are the correct set for `CloudDocuments`.

**What the entitlement actually gates:**

> "For example, an app must have the iCloud entitlement before it is allowed to access iCloud APIs at runtime. The OS enforces that by checking the app for an iCloud entitlement" … "When a code signed app is installed or launched, the OS validates its entitlements. If the entitlements do not pass inspection, the install or launch will fail with an entitlement related error."

— [TN2415: Entitlements Troubleshooting](https://developer.apple.com/library/archive/technotes/tn2415/_index.html)

Note the precise wording: the entitlement gates **API access**, not sync. That distinction is the whole reason §1.5 is ambiguous.

### 1.3 The supported pattern for an app family sharing one container

This is the direct answer, and Apple documents it as a named procedure:

> "In the Xcode target editor's Summary pane, you can request access to as many iCloud containers as you need for your app. **This feature is useful if you want multiple apps to share documents.** For example, if you provide a free and paid version of your app, you might want users to retain access to their iCloud documents when they upgrade from the free version to the paid version. In such a scenario, configure both apps to write their data to the same iCloud container.
>
> To configure a common iCloud container
> 1. Designate one of your iCloud-enabled apps as the primary app. That app's iCloud container becomes the common container.
> 2. Enable the iCloud capability for each app.
> 3. Configure the primary app with only the default container identifier.
> 4. For each secondary app, enable the "Specify custom container identifiers" option and add the container identifier of the primary app to the list of containers.
>
> When reading and writing files in both your primary and secondary apps, build URLs and search for files only in the common storage container. To retrieve the URL for the common storage container, pass the container identifier of your primary app to the `URLForUbiquityContainerIdentifier:` method of `NSFileManager`. **Do not pass `nil` to that method because doing so returns the app's default container, which is different for each app.** Explicitly specifying the container identifier always yields the correct container directory."

— [iCloud Fundamentals](https://developer.apple.com/library/archive/documentation/General/Conceptual/iCloudDesignGuide/Chapters/iCloudFundametals.html)

`ipad-app/Vellum/Services/Web/WebStorage.swift:109` passes `nil`. That is exactly the call Apple warns against. It is harmless today because there is one iOS app and no sharing; it becomes a defect the moment the iPhone app exists.

Also documented:

> "In addition to writing to its own ubiquity container, an app can write to any container directory for which it has the appropriate permission. Each additional ubiquity container should be listed as an additional value in the `com.apple.developer.ubiquity-container-identifiers` entitlement array."

— [url(forUbiquityContainerIdentifier:)](https://developer.apple.com/documentation/foundation/nsfilemanager/1411653-urlforubiquitycontaineridentifie)

**Same-team requirement:**

> "You can also use containers to share files and data between multiple apps **belonging to the same developer.**"

— [Configuring iCloud services](https://developer.apple.com/documentation/xcode/configuring-icloud-services/)

The enforcement mechanism is registration + provisioning: containers are registered as team-scoped Identifiers ([Create an iCloud container](https://developer.apple.com/help/account/identifiers/create-an-icloud-container/)), and entitlements must match the embedded provisioning profile ([TN2415](https://developer.apple.com/library/archive/technotes/tn2415/_index.html)), which is team-scoped. `main` and `ipad-app` already share `DEVELOPMENT_TEAM: 9DCG97VASG`, so this box is ticked.

**Apple never explicitly addresses Mac + iOS builds of the same app sharing a container.** The guide's example is free/paid variants. But: `NSUbiquitousContainers` is documented as "iOS and macOS", the entitlement keys are documented for both platforms, and the mechanism ("local representation of the corresponding iCloud storage", registered per team) contains nothing platform-specific. The inference is strong and the mechanism supports it, but Apple does not say it in words.

### 1.4 Making the container visible in iCloud Drive / Files

Verbatim shape from Apple:

```xml
<key>NSUbiquitousContainers</key>
<dict>
    <key>iCloud.com.example.MyApp</key>
    <dict>
        <key>NSUbiquitousContainerIsDocumentScopePublic</key>
        <true/>
        <key>NSUbiquitousContainerSupportedFolderLevels</key>
        <string>Any</string>
        <key>NSUbiquitousContainerName</key>
        <string>MyApp</string>
    </dict>
</dict>
```

> "**These settings allow iCloud Drive to provide public access to the files stored in your app's container. iCloud Drive will create a folder for your app in the user's iCloud Drive folder to store these documents.**"

— [Designing for Documents in iCloud](https://developer.apple.com/library/archive/documentation/General/Conceptual/iCloudDesignGuide/Chapters/DesigningForDocumentsIniCloud.html); current-era restatement: *"Publishing an iCloud container to iCloud Drive makes the container's `Documents` folder appear in iCloud Drive so the user can access the folder from other apps."* ([Synchronizing documents in the iCloud environment](https://developer.apple.com/documentation/uikit/synchronizing-documents-in-the-icloud-environment)).

Key definitions, verbatim:

> `NSUbiquitousContainers` (Dictionary — iOS and macOS) "Specifies the iCloud Drive settings for each container. This dictionary's keys are the container identifiers for your app's iCloud containers. […] **You must specify the sharing permissions separately for each container.**"
>
> `NSUbiquitousContainerIsDocumentScopePublic` (Boolean — iOS and macOS) "Specifies whether the iCloud drive should share the contents of this container. **Defaults to `NO`.**"
>
> `NSUbiquitousContainerName` (String — iOS and macOS) "Specifies the name that the iCloud Drive displays for your container. By default, the iCloud Drive will use the name of the bundle that owns the container."
>
> `NSUbiquitousContainerSupportedFolderLevels` (String — iOS and macOS) "Specifies the maximum number of folder levels inside your container's Documents directory. […]
> - **`None`** — The iCloud Drive only has access to the container's Documents directory. Your app promises that it does not create any directories inside the Document's directory. In macOS, the Finder prevents users from creating subdirectories inside your iCloud Drive directory.
> - **`One`** — […] one additional layer of subdirectories. […] the Finder prevents users from creating more than one layer of subdirectories […]
> - **`Any`** — The iCloud Drive has complete access to your container's Documents directory. Both your app and the Finder can create as many layers of subdirectories as you (or the user) desire."

— [Cocoa Keys, Information Property List Key Reference](https://developer.apple.com/library/archive/documentation/General/Reference/InfoPlistKeyReference/Articles/CocoaKeys.html)

Vellum's layout (`Documents/Vellum/Web Pages/…` and `Documents/Vellum/.vellum/records/…`) is ≥2 levels deep, so it requires **`Any`**. Note "Your app promises that…" is a contract the Finder *actively enforces against the user* — pick `None`/`One` and Finder blocks subfolder creation.

**The CFBundleVersion trap**, documented twice — archived and current:

> "The first time your app is installed and launched […] the metadata specified in the `NSUbiquitousContainers` entry […] will be extracted, associated with your iCloud containers, and used by iCloud Drive. **After that, the metadata won't be updated until a newer build of your app is detected.** […] Be sure that the new value is higher than the previous one by string comparison with `NSNumericSearch` option, and only contains numeric (0-9) and period (.) characters."
>
> "**Note:** Only the containers used by the user are being displayed in iCloud Drive. So even after you setting `NSUbiquitousContainerIsDocumentScopePublic` to `YES` and bumping the `Bundle version` of your app, **your iCloud container will not appear in iCloud Drive if it has never been used.** Try to copy at least one file to your iCloud container if it doesn't show up as expected."

— [QA1893](https://developer.apple.com/library/archive/qa/qa1893/_index.html)

> "Increase the bundle version […] The new value must be larger than the previous value when using the `compare(_:options:range:)` method with the `numeric` option […] **The system only updates an app's iCloud container metadata when detecting a new version, so perform this step every time the metadata changes.**" … "Make sure the `Documents` folder exists in the iCloud container and has at least one document."

— [Synchronizing documents in the iCloud environment](https://developer.apple.com/documentation/uikit/synchronizing-documents-in-the-icloud-environment) (current, non-archived — cite this one)

`ipad-app/project.yml:68` pins `CURRENT_PROJECT_VERSION: "1"`. Any `NSUbiquitousContainers` change must ship with a bump or it silently does not take. And an empty `Documents/` means the folder never appears no matter how correct the plist is.

**[DTS]** A DTS Engineer answering "how do I make my app's iCloud folder appear" pointed straight at this mechanism via the ["Publish an iCloud container to iCloud Drive"](https://developer.apple.com/documentation/uikit/synchronizing-documents-in-the-icloud-environment#Publish-an-iCloud-container-to-iCloud-Drive) sample section — [thread 772632](https://developer.apple.com/forums/thread/772632).

### 1.5 Does writing directly into Mobile Documents actually sync?

Three sub-questions with three different evidentiary footings. Keeping them separate is the whole answer.

**(a) Is the entitlement required on macOS? No — Apple says so explicitly.** This is the strongest single citation for Vellum's current Mac architecture:

> "**Mac Note:** On OS X v10.11 and later, you can store documents in the user's iCloud Drive folder **without needing to set the signing identity and enable iCloud in the Xcode project. Just specify your app's containers in the `Info.plist` file.**"

— [Designing for Documents in iCloud § Enabling Document Storage in iCloud Drive](https://developer.apple.com/library/archive/documentation/General/Conceptual/iCloudDesignGuide/Chapters/DesigningForDocumentsIniCloud.html)

Read carefully. It says `NSUbiquitousContainers` in Info.plist alone is sufficient on macOS — no `com.apple.developer.ubiquity-container-identifiers`, no provisioning profile, no paid team. It does **not** say "and you may write at the path instead of calling the API," and it does **not** promise sync semantics. Caveats: the note lives in an archived, 10.11-era guide; Apple has neither restated nor retracted it.

**(b) Is direct path-based writing (bypassing the API) supported? Apple is silent.** No Apple statement exists in either direction. Every documented route is API-first: *"You must put files in one of the container directories associated with your app. Call the `URLForUbiquityContainerIdentifier:` method"* ([iCloud File Management](https://developer.apple.com/library/archive/documentation/FileManagement/Conceptual/FileSystemProgrammingGuide/iCloud/iCloud.html)). The string `Mobile Documents` does not appear anywhere in Apple's developer documentation — checked against [File System Basics](https://developer.apple.com/library/archive/documentation/FileManagement/Conceptual/FileSystemProgrammingGuide/FileSystemOverview/FileSystemOverview.html) (whose Table 1-3 of `Library` subdirectories lists only `Application Support`, `Caches`, `Frameworks`, `Preferences`), the iCloud chapter, and the iCloud Design Guide. A targeted forum sweep found no Apple-staff answer to this question either.

**(c) Is coordination required for the *daemon* to notice changes? Apple says coordination is mandatory but gives a different reason.** These are the sentences in Apple's corpus that describe the daemon relationship, all from [iCloud File Management](https://developer.apple.com/library/archive/documentation/FileManagement/Conceptual/FileSystemProgrammingGuide/iCloud/iCloud.html):

> "While in iCloud storage, changes made on one device are stored locally and then pushed to iCloud **using a local daemon**."
>
> "**File coordinators mediate changes between your app and the daemon that facilitates the transfer of the document to and from iCloud.**"
>
> "Your app might not be the only app trying to manipulate the local file at any given moment. **The daemon that transfers the document to and from iCloud also needs to manipulate it periodically.** […] **To prevent large numbers of conflicting changes from occurring at the same time, apps are expected to use file coordinator objects to perform all changes.**"
>
> "your app and the daemon may both read the document at the same time but only one may write to the file at any single time."

Apple's stated rationale for coordination is **mutual exclusion and conflict avoidance** — serializing your writes against the daemon's. Apple does **not** say coordination is the *discovery* mechanism by which the daemon notices a changed file. The documented risk of skipping it is corruption and conflicts, not "your file never uploads."

**And there is no way to force or observe the upload. [DTS]:** *"There is no API for app developers to force an iCloud Drive synchronization. When using iCloud services, the system decides when to synchronize data. This is as-designed to better balance the use of system resources and achieve the best overall user experience on the devices."* — Ziqiao Chen, Worldwide Developer Relations, [thread 771643](https://developer.apple.com/forums/thread/771643).

**Honest summary.** The Mac's entitlement-free approach has real documentary support (the Mac Note). What has *none* is (i) writing at the literal path rather than through the API, and (ii) skipping coordination. It empirically works — this machine has a populated `com~apple~CloudDocs/Vellum/` — but Apple publishes no contract that it keeps working, no way to trigger or observe sync, and an explicit "mandatory" on coordination. Acceptable for one Mac with an iCloud-backed folder. A poor foundation for three devices writing the same sidecar.

**Separately, it cannot serve as the *shared* root regardless.** iOS has no path-based access to `com~apple~CloudDocs`. An iOS app reaches the user's iCloud Drive only through `UIDocumentPickerViewController` and security-scoped URLs — which `ipad-app` already implements for custom-folder mode (`WebStorage.swift:14-18`). There is no iOS equivalent of "just write to the iCloud Drive folder."

**One modern-architecture caveat.** On current macOS, iCloud Drive is widely believed to be mediated by the FileProvider subsystem, which brings materialization semantics that differ from the 10.11-era model the archived docs describe. [WWDC21 "Sync files to the cloud with FileProvider on macOS"](https://developer.apple.com/videos/play/wwdc2021/10182/) is entirely about *third-party* providers and says nothing about iCloud Drive's own implementation. **Not substantiated** — flagged as a known unknown that could invalidate the archived guidance on newer OS versions.

### 1.6 Sandboxed vs unsandboxed access

**Sandboxed apps do not get the tree.** Primary:

> "The operating system creates a container directory when launching your sandboxed app, to which the app has unrestricted read and write access. **The sandboxed app doesn't have unrestricted access to the user's home folder.**"

— [Protecting user data with App Sandbox](https://developer.apple.com/documentation/security/protecting-user-data-with-app-sandbox)

Combined with *"The first time you call this method for a given ubiquity container, the system extends your app's sandbox to include that container"* ([url(forUbiquityContainerIdentifier:)](https://developer.apple.com/documentation/foundation/nsfilemanager/1411653-urlforubiquitycontaineridentifie)) — a sandboxed app gets its *own* declared container grafted in, and nothing else.

**[DTS]** Quinn "The Eskimo!" (Apple DTS), [thread 727902](https://developer.apple.com/forums/thread/727902), correcting a developer who thought sandboxed apps get free iCloud Drive access:

> "That's incorrect. **From the perspective of a sandboxed app, iCloud Drive is like any other external volume. Access to it is mediated by sandbox extensions.** So, if the app brings up a open panel and the user selects an item on iCloud Drive, the app will have access to it."

with a reproducible test in the same thread: sandboxed read of a file at the iCloud Drive root fails `NSCocoaErrorDomain Code=257` / `EPERM`; removing the App Sandbox capability makes the identical code succeed.

**Unsandboxed is broad but not unlimited. [DTS]** Same engineer, [thread 663889](https://developer.apple.com/forums/thread/663889), correcting "non-sandboxed apps should have access to everything that the user can access": *"That is not correct. 10.15 and later introduce additional access control for the desktop and the Documents directory… 10.14 introduces the concept of Full Disk Access… And data vaults, something we've never formally documented, were introduced in later 10.13 releases."*

**[empirical]** An unsandboxed `ls` of `~/Library/Mobile Documents/` here returned all 116 containers with no TCC prompt.

There is no Apple *documentation page* stating "unsandboxed apps can read the whole Mobile Documents tree" — the DTS quotes get there by implication (sandbox blocks it; removing the sandbox unblocks it), and that is the best evidence available.

**Load-bearing consequence for Vellum: the Mac app's current approach dies the moment it is sandboxed.** Which means no Mac App Store on that path.

---

## 2. Free personal team vs the paid Apple Developer Program

### 2.1 The canonical comparison

| Feature | Apple Account (free) | Apple Developer Program |
|---|---|---|
| Xcode developer tools | ● | ● |
| Xcode beta releases | ● | ● |
| On-device testing | ● | ● |
| Apple Developer Forums | ● | ● |
| Bug reporting with Feedback Assistant | ● | ● |
| OS beta releases | ● | ● |
| Full access to a comprehensive set of development tools | | ● |
| **Advanced app capabilities and services** | | ● |
| Code-level support | | ● |
| **App distribution** | | ● |
| **App management, testing, and analytics with App Store Connect** | | ● |
| Safari Extensions distribution | | ● |
| Notarization & Developer ID for Mac apps | | ● |
| Custom app distribution with Apple Business and Apple School Manager | | ● |
| Ad hoc distribution for testing and internal use | | ● |
| Cost | Free | 99 USD |

— [Choosing a Membership](https://developer.apple.com/support/compare-memberships/)

"Advanced app capabilities and services" is the row covering entitlement-gated capabilities. **This page deliberately does not itemize them** — it lumps iCloud, App Groups, Push, IAP, Sign in with Apple and the rest into that single row. For the per-capability breakdown you need §2.2.

A second Apple table adds the portal dimension ([About your developer account](https://developer.apple.com/help/account/basics/about-your-developer-account)):

| Feature | Free | ADP | ADEP |
|---|---|---|---|
| Beta Xcode and OS releases · On-device testing · Forums · Feedback Assistant | ✓ | ✓ | ✓ |
| Code-level support | — | ✓ | ✓ |
| **Certificates, Identifiers & Profiles** | — | ✓ | ✓ |
| Mac software notarization | — | ✓ | ✓ |
| **App Store Connect** | — | ✓ | — |
| **TestFlight** | — | ✓ | — |
| Xcode Cloud | — | ✓ | — |

> "To build more advanced app capabilities and distribute apps, you'll need to be an Apple Developer Program member or Apple Developer Enterprise Program member."

Note that **Certificates, Identifiers & Profiles is itself unavailable to free accounts** — which is why container registration (§2.3) is out of reach.

### 2.2 The authoritative per-capability tables

The right pages are Account Help → Reference, not the membership comparison:

- [Supported capabilities (iOS)](https://developer.apple.com/help/account/reference/supported-capabilities-ios/) — *"The capabilities available to an iOS provisioning profile depend on your program membership."*
- [Supported capabilities (macOS)](https://developer.apple.com/help/account/reference/supported-capabilities-macos/) — *"…depend on your program membership and signing certificate."*

Column legend, verbatim:

> **ADP:** Apple Developer Program membership. Members of this paid program can distribute apps on the App Store.
> **ADEP:** Apple Developer Enterprise Program membership. Members of this paid program can distribute apps to employees within an organization.
> **Apple Developer:** Apple Account holders who have agreed to the Apple Developer Agreement to access certain resources on the Apple Developer website. No cost is associated with this agreement and developers can't distribute apps.

**[DTS]** That the "Apple Developer" column *is* the Personal Team is confirmed by Quinn "The Eskimo!" ([thread 128767](https://developer.apple.com/forums/thread/128767)): *"That capability is not supported by a free accounts (what Xcode calls a Personal Team)… For information about which capabilities are supported by which account types, see Developer Account Help > Reference > Supported capabilities (macOS)… **In this context the Apple Developer column shows the capabilities for a Personal Team.**"*

> **Methodology note.** These tables render their checkmarks as CSS icon glyphs (`<figure class="icon icon-checksolid">`), which markdown converters silently drop or invent. The readings below come from parsing the raw HTML per cell. Two naive text conversions of the same page produced contradictory answers, so do not trust a text-converted rendering of these pages — including any earlier draft of this file.

**iOS — the complete free-column list (nine capabilities):**

> App groups · Background modes · Data protection · HealthKit · HomeKit · Inter-App Audio · Keychain sharing · Maps · Wireless Accessory Configuration

**macOS — the complete free-column list (five):**

> App groups · App Sandbox · Hardened runtime · Keychain sharing · Maps

**Paid-only on both, and relevant here:** `iCloud: CloudKit`, `iCloud: iCloud documents`, `iCloud: iCloud key-value storage`, Push notifications, Sign in with Apple, In-App Purchase, Apple Pay, Game Center, Siri, Personal VPN, Wallet, Associated domains, Network extensions.

**Correcting the folklore.** The historical App Distribution Guide list (iCloud, App Groups, Apple Pay, Game Center, HealthKit, HomeKit, IAP, Inter-App Audio, Keychain Sharing, Push, Siri, VPN, Wallet, Wireless Accessory Configuration as paid-only) is **partly obsolete**. Still paid-only: iCloud, Apple Pay, Game Center, IAP, Push, Siri, Personal VPN, Wallet. **No longer paid-only on iOS: App Groups, HealthKit, HomeKit, Inter-App Audio, Keychain Sharing, Wireless Accessory Configuration.** (The original guide itself can no longer be cited — its archive URLs now 301 to `help.apple.com/xcode` and the text is gone.)

Xcode's own docs corroborate the gating: *"The platform, and whether you're a member of the Apple Developer Program, may limit the capabilities available to your app… The Capabilities library displays only the capabilities available to the target platform and your program membership."* ([Adding capabilities to your app](https://developer.apple.com/documentation/xcode/adding-capabilities-to-your-app)).

### 2.3 iCloud specifically

**On iOS: paid.** The decisive mechanical fact is that iCloud requires a **registered container identifier**, and registering one is role-gated:

> Required role: **Account Holder or Admin.** "In Certificates, Identifiers & Profiles, click Identifiers in the sidebar, then click the add button (+)… Select iCloud Containers… Enter a description and identifier, click Continue, then click Register." … "You must have one or more iCloud containers to enable iCloud."

— [Create an iCloud container](https://developer.apple.com/help/account/identifiers/create-an-icloud-container/)

Account Holder and Admin are membership roles. A free Apple Account has no membership, therefore no such role, no container registration, and no provisioning profile carrying `com.apple.developer.icloud-container-identifiers` — and TN2415 is clear that an app whose entitlements don't validate *"will fail with an entitlement related error"* at install or launch. This matches the behaviour recorded in `ipad-app/project.yml:71-74`: wiring the entitlements file in "breaks device builds."

**On macOS: possibly not.** The Mac Note in §1.5(a) documents an Info.plist-only path that explicitly does not require a signing identity or the Xcode iCloud capability. If that still holds on current macOS, the Mac app can publish a container to iCloud Drive without the $99. It is archived guidance and unverified on modern OS versions.

**Restricted vs unrestricted entitlements — the macOS mechanism.** [TN3125](https://developer.apple.com/documentation/technotes/tn3125-inside-code-signing-provisioning-profiles) enumerates the *complete* set of macOS entitlements an app may claim without a provisioning profile:

> "A macOS app can claim certain entitlements without them being authorized by a provisioning profile. These unrestricted entitlements include: `com.apple.security.get-task-allow`, `com.apple.security.application-groups`, Those used to enable and configure the App Sandbox, Those used to configure the Hardened Runtime."
>
> "In contrast, **restricted entitlements must be authorized by a provisioning profile.**"
>
> "**A Mac app that uses no restricted entitlements doesn't need a provisioning profile.** This is true even if the app is distributed on the App Store. The only exception to this rule is TestFlight, which always requires a profile."

The iCloud entitlement keys are **not** on the unrestricted list, so they are restricted and require a profile. This is exactly why `main`'s current approach works without one: it claims no iCloud entitlement at all, relying on the Info.plist-only path of §1.5(a). The two sources are consistent.

**Net for Vellum:** shipping the iOS/iPadOS apps with a real ubiquity container requires the membership. The Mac is the only leg with a documented free path — and it is the leg that already works.

### 2.4 Free-provisioning limits and the 7-day expiry

> "To install and test your apps on a personal device, you'll need to sign in to your Apple Account in Xcode. If your account is not associated with a developer program membership, Xcode will indicate it's a Personal Team… you'll be required to reprovision your apps to a device periodically.
> - You can register up to **10 App IDs**, which expire after **7 days**.
> - You can register up to **3 devices**, which expire after **7 days**.
> - You can install up to **3 apps per device**.
> - Provisioning profiles that enable apps to be installed on a device will expire **7 days** from issuance. You'll need to rebuild and reinstall your app to your device after expiration."

— [About your developer account](https://developer.apple.com/help/account/basics/about-your-developer-account); the same limits appear in the "Xcode Personal Team" footnote on [Choosing a Membership](https://developer.apple.com/support/compare-memberships/), which qualifies devices as "3 … for each platform" and omits the 3-apps-per-device limit. Minor discrepancy between two Apple pages; note it, don't resolve it.

And from [QA1915](https://developer.apple.com/library/archive/qa/qa1915/_index.html) (archived but live): *"This team allows you to build apps for your personal use on devices owned by you, but it does not allow you to code sign apps destined for the App Store or for enterprise use."* … *"the Validate and Export buttons will be unavailable in the Xcode organizer and you won't be able to upload your app to the App Store."*

A free-team iPhone build must be re-installed from Xcode weekly. Fine for a dev loop; fatal for "reading on the go."

### 2.5 App Groups on a free team — **yes**

"App groups" is checked in the free **Apple Developer** column on **all five** platform tables (iOS, macOS, tvOS, watchOS, visionOS). Combined with Quinn's statement that this column is the Personal Team (§2.2), that is directly substantiated. The old folklore that App Groups requires a paid account is out of date.

**One caveat Apple leaves undocumented.** The registration help page says *"Required role: Account Holder or Admin. In Certificates, Identifiers & Profiles, click Identifiers…"* — and that portal is unavailable to free accounts (§2.1). The only other documented route is *"Alternatively, you can create app groups when you enable app groups in Xcode"*, and Apple never explicitly confirms that path works for a Personal Team. So: **the capability table says supported; the workflow docs never spell out the free-tier mechanism.**

**The iOS/macOS prefix difference is fully documented** ([App Groups Entitlement](https://developer.apple.com/documentation/bundleresources/entitlements/com.apple.security.application-groups)):

> "Format the identifier as follows: `group.<group name>`. Apple ensures that the group name you choose is unique when you register the app group on the Apple Developer website."
>
> "In macOS, you can also create app groups or add apps to existing app groups using this identifier format: `<team identifier>.<group name>`. **You don't need to register app groups that use this format on the Apple Developer website.**"

And [Configuring app groups](https://developer.apple.com/documentation/xcode/configuring-app-groups): *"By using this naming scheme, macOS checks that the code signature of processes that try to access the app group container contains the same `Developer-Team-ID` as app group container ID."* … *"You need to register app groups for iOS, iPadOS, tvOS, visionOS, and watchOS apps."*

**[DTS]** Quinn's standing writeup ["App Groups: macOS vs iOS: Working Towards Harmony"](https://developer.apple.com/forums/thread/721701) (last revised 2025-08-12) adds two things that matter if Vellum ever ships a share extension:

> "Starting in Feb 2025, **iOS-style app group IDs are fully supported on macOS for all product types**… If you're writing new code that uses app groups, use an iOS-style app group ID."

and **App Group Container Protection (macOS 15+)** — to reach the container without a per-launch consent prompt, the app must meet one of: Mac App Store distribution (A), TestFlight on 15.1+ (B), **an app group ID starting with the app's Team ID (C)**, or **a claim authorized by an embedded provisioning profile (D)**. *"If your app doesn't follow these rules, the system prompts the user to approve its access to the container. If granted, that consent applies only for the duration of that app instance."* A Personal Team has a real Team ID, so criterion (C) is reachable; a purely ad-hoc-signed app is not (inference, not Apple's words).

### 2.6 TestFlight

Paid, confirmed from three directions. The [About your developer account](https://developer.apple.com/help/account/basics/about-your-developer-account) table leaves TestFlight and App Store Connect unchecked for free accounts **and for Enterprise**. [Distributing your app for beta testing and releases](https://developer.apple.com/documentation/xcode/distributing-your-app-for-beta-testing-and-releases): *"If you want to distribute your app to registered devices, to beta testers using TestFlight, or through the App Store, join the Apple Developer Program."* And TN3125: *"The only exception to this rule is TestFlight, which always requires a profile."*

### 2.7 Locally-signed unsandboxed Mac apps and iCloud

**No** — by a chain of primary sources, though Apple never says it in one sentence:

1. iCloud entitlements are **restricted** on macOS (not on TN3125's unrestricted list), so they require a provisioning profile.
2. TN3125: *"A standalone executable can't claim a restricted entitlement because there's no place to embed the provisioning profile that authorizes that claim."*
3. Even with a profile, the macOS capability table leaves all three iCloud rows unchecked for the free column.
4. [Configuring iCloud services](https://developer.apple.com/documentation/xcode/configuring-icloud-services/) routes container creation through the developer account portal, which free accounts cannot reach.

Worth knowing if CloudKit is ever considered: *"Xcode automatically adds the Push Notifications capability to your target if you enable the CloudKit service because CloudKit uses push notifications to inform your app of server-side changes to your data."* — same page. Push is paid-only on every platform, so CloudKit drags a second paid capability along with it.

**Not substantiated:** no Apple page states the conclusion above in words; it is a chain, not a citation. Nor does any Apple documentation page equate Xcode's "Sign to Run Locally" with ad-hoc signing — that equivalence is forum-level only.

---

## 3. File coordination and materialization

### 3.1 Coordination is mandatory

> "**The use of file coordinators and presenters is mandatory when working with iCloud documents.**"
> "**When accessing files and directories in a container, iCloud apps are required to use *file coordination* to do so.**"
> "If you are not using document objects to access files, **you must handle the file coordination yourself.**"

— [Designing for Documents in iCloud](https://developer.apple.com/library/archive/documentation/General/Conceptual/iCloudDesignGuide/Chapters/DesigningForDocumentsIniCloud.html)

> "**Note:** In the iCloud environment, **every file access in your app, unless it is in the context of the reading or writing methods of `UIDocument` or `NSDocument`, should go through `NSFileCoordinator`** so that it can be queued up and coordinated."

— [TN2336](https://developer.apple.com/library/archive/technotes/tn2336/_index.html)

> "**All file-related operations must be performed through a file coordinator object.**" … "**Registration is essential. The system can notify only registered presenter objects.**"

— [iCloud File Management](https://developer.apple.com/library/archive/documentation/FileManagement/Conceptual/FileSystemProgrammingGuide/iCloud/iCloud.html)

> "You can write files and create subdirectories within the `Documents` subdirectory… **Perform all such operations using an `NSFileManager` object using file coordination.**"

— [iCloud Fundamentals](https://developer.apple.com/library/archive/documentation/General/Conceptual/iCloudDesignGuide/Chapters/iCloudFundametals.html)

No documented carve-out for "small files", "atomic writes", or "we're the only writer." The sanctioned escape hatch is `UIDocument`/`NSDocument`, which coordinate internally — *"the easiest way to manage documents in iCloud is to use the `NSDocument` class… handles the creation and use of file coordinators… You are not required to use the `NSDocument` class, but using it requires less effort"* ([iCloud File Management](https://developer.apple.com/library/archive/documentation/FileManagement/Conceptual/FileSystemProgrammingGuide/iCloud/iCloud.html)).

Vellum uses neither. Both worktrees sit outside the documented contract for iCloud file access.

### 3.2 Is tmp + rename safe?

Two properties get conflated. Separating them is the answer.

**Atomicity on the volume: yes.** `rename(2)` is atomic within a filesystem, so a concurrent local reader sees the old file or the new one, never a torn write. `PdfAtomicWriter.save` and `WebLibrary.saveRecord` are correct on this axis, and the reasoning in `PdfSessionBackend.swift:29` is sound.

**Visibility to the coordination layer: no — and this is stated flatly.**

> "You can use file presenters to coordinate access to a file or directory among your application's objects. If another process uses a file coordinator for the same file or directory, your presenter objects are similarly notified whenever the other process makes its changes. **Your presenter objects are not notified about changes made directly using low-level read and write calls to the file. Only changes that go through a file coordinator result in notifications.**"

— [NSFilePresenter](https://developer.apple.com/documentation/foundation/nsfilepresenter)

So an uncoordinated `rename(2)`:
- does not notify presenters in other processes (Files.app, the sync daemon, another Vellum instance);
- does not announce the move — `NSFileCoordinator` has dedicated APIs for exactly this: `item(at:willMoveTo:)` *"Announces that your app is moving a file to a new URL"*, `item(at:didMoveTo:)` *"Notifies relevant file presenters that the location of a file or directory changed"*;
- forfeits mutual exclusion against the daemon (§1.5(c)).

Why the coordinator exists, per its own overview:

> "The `NSFileCoordinator` class coordinates the reading and writing of files and directories among multiple processes and objects in the same process. […] before your code to perform those actions executes, the file coordinator lets registered file presenter objects perform any tasks that they might require to ensure their own integrity."

— [NSFileCoordinator](https://developer.apple.com/documentation/foundation/nsfilecoordinator)

The right shape for Vellum's writer is a coordinated write with `.forReplacing` wrapping the existing tmp+rename. Options, verbatim:

> **Writing** — `forDeleting`: "…in preparation for deleting the file or directory." · `forMoving`: "…in preparation for moving…" · `forMerging`: "…in preparation for merging the contents…" · `forReplacing`: "…in preparation for replacing the file or directory."
>
> **Reading** — `withoutChanges`: "The file coordinator should prevent other processes from writing to the file or directory." · `resolvesSymbolicLink`: "…resolve symbolic links to their targets before performing the read…" · `immediatelyAvailableMetadataOnly`: "The file coordinator should only use metadata that is immediately available." · `forUploading`: see §4.5 — **not what it sounds like.**

— [NSFileCoordinator](https://developer.apple.com/documentation/foundation/nsfilecoordinator)

`immediatelyAvailableMetadataOnly` is the "tell me about this file but do not go to the network" option — the natural fit for Vellum's listing and serve paths.

### 3.3 What triggers materialization — the important part

> "In a modern file system, a file's content may not be available locally on the device. A file that contains only metadata is known as a *dataless* file. […] when a person taps the same file, or an app accesses it, the system redownloads the file's content and makes it available again — a process known as **materialization**."

Operations that materialize:

> - `FileManager.contentsOfDirectory(atPath:)` — enumerating a directory's contents
> - `FileManager.fileExists(atPath:)` — checking whether a file exists
> - `stat()` and `getattrlist()` — both trigger materialization of intermediate folders in the file's path if they are dataless

Guidance:

> "The system, or a person using the device, can make dataless files whenever they determine it's appropriate, and your app needs to be ready to handle them. Specifically, **avoid unnecessarily materializing dataless files and, when your app requires access to a file's contents, perform that work asynchronously off the main thread.**"

— [TN3150: Getting ready for dataless files](https://developer.apple.com/documentation/technotes/tn3150-getting-ready-for-data-less-files)

**This directly implicates Vellum's materialization guard.** `WebICloud.itemExists(at:)` and `WebICloud.materialize(at:)` (`ipad-app/.../WebStorage.swift:389-410`) are built on `FileManager.fileExists(atPath:)` — the very call TN3150 lists as materializing. `materialize` then polls `fileExists` in a `Thread.sleep` loop for up to 10 seconds. **The function meant to *control* materialization triggers it on entry**, so the parity plan's "no materialization on serve paths" rule is not actually enforced by the code that claims to enforce it. `WebICloud.requestDownload` (line 414) has the same defect: it calls `fileExists` on the placeholder before deciding not to block.

Apple documents two mitigations.

**Option 1 — detect dataless state** (still materializes intermediate directories):

```c
struct stat fileStat;
if (stat(yourFilePath, &fileStat) == 0) {
    if ((fileStat.st_flags & SF_DATALESS) > 0) {
        // The file is dataless.
    } else {
        // SF_DATALESS is a feature of APFS;
        // don't assume IO is local here because network IO can happen on NFS.
    }
}
```

> "Be aware that `stat` and `getattrlist` both trigger the materialization of any intermediate folders in the file's path, if they themselves are dataless."

**Option 2 — opt out per thread or per process:**

```c
int iopolicy = getiopolicy_np(IOPOL_TYPE_VFS_MATERIALIZE_DATALESS_FILES, IOPOL_SCOPE_THREAD);
if (iopolicy >= 0) {
    if (setiopolicy_np(IOPOL_TYPE_VFS_MATERIALIZE_DATALESS_FILES, IOPOL_SCOPE_THREAD,
                       IOPOL_MATERIALIZE_DATALESS_FILES_OFF) == 0) {
        // Do your work here.
        // Detect the EDEADLK error and handle the I/O failure when accessing dataless files.
    }
    setiopolicy_np(IOPOL_TYPE_VFS_MATERIALIZE_DATALESS_FILES, IOPOL_SCOPE_THREAD, iopolicy);
}
```

Scope is `IOPOL_SCOPE_THREAD` or `IOPOL_SCOPE_PROCESS`; with the policy off, accesses to dataless files fail with **`EDEADLK`**, which the caller must handle. — [TN3150](https://developer.apple.com/documentation/technotes/tn3150-getting-ready-for-data-less-files)

This is the API that lets the serve path make a *hard, enforced* promise instead of a convention.

**[DTS]** Same guidance for enumeration: *"accessing a directory in a file provider triggers the enumeration in the file provider, which enumerates the items in the directory and may take a while. You can probably opt out the dataless file materialization by following the Prepare your app for dataless file access in TN 3150."* — Ziqiao Chen, DTS, [thread 756129](https://developer.apple.com/forums/thread/756129).

And Apple's preferred answer: *"`UIDocument` and `NSDocument` automatically access the file system in a coordinated and asynchronous manner. If your app uses those classes to read and write files (and document packages), it will automatically do the right thing with dataless files."* — [TN3150](https://developer.apple.com/documentation/technotes/tn3150-getting-ready-for-data-less-files).

### 3.4 The `.icloud` placeholder convention

`WebICloud.placeholderURL(for:)` constructs `.<name>.icloud` beside the real file (`ipad-app/.../WebStorage.swift:382-385`). **This convention is not documented by Apple anywhere I found.** TN3150 frames evicted files as *dataless files* carrying `SF_DATALESS` **at the original path** — not as a renamed sibling. The dot-prefixed placeholder is legacy/observed behaviour.

Documented, forward-compatible checks instead: `SF_DATALESS` (§3.3), or the resource key `NSURLUbiquitousItemDownloadingStatusKey`, *"the key for the current download state for an item"* ([reference](https://developer.apple.com/documentation/foundation/nsurlubiquitousitemdownloadingstatuskey)). Apple's own testing guidance points at `NSURLUbiquitousItemIsUploadedKey` / `NSURLUbiquitousItemIsDownloadedKey` ([Testing and Debugging for iCloud](https://developer.apple.com/library/archive/documentation/General/Conceptual/iCloudDesignGuide/Chapters/TestingandDebuggingforiCloud.html)).

`WebICloud.size(ofItemAt:)` (lines 427-442) parses `NSURLFileSizeKey` out of the placeholder plist — entirely undocumented structure, and the most fragile code in the iCloud path.

### 3.5 Enumeration and download without blocking

Apple documents both an implicit and an explicit download trigger:

> "In iOS, apps must ask the system (either explicitly or implicitly) to download the file. **You implicitly download a file by trying to access that file by using methods in the `NSFileCoordinator` class**, or you explicitly download the file by invoking the `startDownloadingUbiquitousItemAtURL:error:` method"

— [Designing for Documents in iCloud](https://developer.apple.com/library/archive/documentation/General/Conceptual/iCloudDesignGuide/Chapters/DesigningForDocumentsIniCloud.html)

**So a coordinated read is itself a materialization trigger.** Adopting coordination on the serve path without `immediatelyAvailableMetadataOnly` would reintroduce exactly the blocking the parity plan bans.

For discovery, `NSMetadataQuery` with the ubiquitous scopes is the documented mechanism and is metadata-only by construction — as against `contentsOfDirectory`, which TN3150 lists as materializing. Status lives in the metadata domain too: `NSMetadataUbiquitousItemDownloadingStatusKey`, with `NSMetadataUbiquitousItemDownloadingStatusNotDownloaded` among the values ([reference](https://developer.apple.com/documentation/foundation/nsmetadataubiquitousitemdownloadingstatuskey)).

### 3.6 Threading, cancellation, and process death

> "Each file coordinator object you create should be used on a single thread only. If you need to coordinate file operations across multiple objects in different threads, each object should create its own file coordinator."
>
> "A coordinated read or write will automatically begin a background task when granted… **If a process is suspended while waiting for a coordinated read or write to be granted, the request is canceled, and an `NSError` object with the code `NSUserCancelledError` is produced. If the background task expires, the process is terminated.**"

— [NSFileCoordinator](https://developer.apple.com/documentation/foundation/nsfilecoordinator)

Two things follow for the iPhone. Coordinated I/O must be treated as **cancellable** — `NSUserCancelledError` is a normal outcome when the app backgrounds mid-write, not an exception. And a long coordinated write held across suspension can get the process **killed** — a hard argument for keeping sidecar writes small and short, which Vellum's per-record JSON design already is.

With TN3150's "off the main thread," this reinforces the existing `CLAUDE.md` main-thread rule. `WebICloud.materialize` uses `Thread.sleep`, and the comment at `WebLibrary.swift:132-138` already correctly flags it must never run on a cooperative thread.

---

## 4. Conflict semantics for the JSON sidecars

### 4.1 What iCloud does when two devices write the same file

> "For files in the cloud, there is usually only one version of the file at any given time. However, additional file versions may be created in cases where two different computers attempt to save the file to the cloud at the same time. In that case, **one file is chosen as the current version and any other versions are tagged as being in conflict with the original. Conflict versions are reported to the appropriate file presenter objects** and should be resolved as soon as possible so that the corresponding files can be removed from the cloud."

— [NSFileVersion](https://developer.apple.com/documentation/foundation/nsfileversion)

> "**Its solution is to make the most recently modified file the *current file* and to mark any other versions of the file as *conflict versions*.**" … "**When conflict versions exist, all of the versions remain in a user's iCloud storage (and locally on any computers and iOS devices) until your app resolves them.**"

— [iCloud File Management](https://developer.apple.com/library/archive/documentation/FileManagement/Conceptual/FileSystemProgrammingGuide/iCloud/iCloud.html)

> "When two or more versions of a file are written at the same time… **the system attempts to resolve the conflict automatically. It does this by picking one of the file versions to be the current file and setting this property to `true` for the other file versions that are in conflict.**"

— [isConflict](https://developer.apple.com/documentation/foundation/nsfileversion/isconflict)

**Two distinct conflict kinds — and the distinction decides what the user sees.** TN2336 is the precise source:

> "when getting a new file from a different peer that has the same name as an existing file, iCloud Drive detects a **new-file conflict** and automatically handles it by giving the new file a **bounced file name**, which is generated by appending a number suffix to original file name (such as "abc 2.txt" based on "abc.txt")."
>
> "Creating a bounced file when a new-file conflict occurs is **only applied to iCloud documents … locating in the `Documents` folder**, also known as the "document scope"."
>
> "**When conflicts happen in the data scope, iCloud Drive won't create bounced files – it instead resolves them automatically by picking up a winning version and keeping the other changes in a losing version. So except for the new-file conflicts happening in the document scope causing bounced files to be generated, iCloud Drive automatically creates new versions for all other conflicts.**"
>
> "**Note:** When handling a new-file conflict, iCloud Drive looks into the contents of the files. If they are the same, iCloud Drive will determine that there is no conflict, thus won't create a bounced file"

— [TN2336](https://developer.apple.com/library/archive/technotes/tn2336/_index.html)

**This is the case that matters for Vellum.** A sidecar that already exists on both devices and gets rewritten concurrently is a **version conflict**, not a new-file conflict — so even under `Documents/` you get a winner plus invisible `NSFileVersion` conflict versions, **not** a visible `<key> 2.json`. A bounced name only appears if two devices independently *create* the same-named record while unaware of each other — plausible for a first annotation on a document opened on both devices while offline.

The API surface ([NSFileVersion](https://developer.apple.com/documentation/foundation/nsfileversion)):

| Symbol | Quote |
|---|---|
| `currentVersionOfItem(at:)` | "Returns the most recent version object for the file at the specified URL." |
| `otherVersionsOfItem(at:)` | "Returns all versions of the specified file except the current version." … "**For documents residing in the cloud, this property typically returns zero or more file versions representing conflicting versions of a file that need to be resolved with the current version.**" |
| `unresolvedConflictVersionsOfItem(at:)` | "Returns an array of version objects that are currently in conflict for the specified URL." |
| `isConflict` | "A Boolean value indicating whether the contents of the version are in conflict with the contents of another version." |
| `isResolved` | "**When the system detects a conflict… it sets this property to `false`… After you resolve the conflict, set this property to `true`… you must then remove any versions of the file that are no longer useful.**" · "**Important:** Never set the value of this property to `false`. If you do, **the system raises an exception.**" |
| `removeOtherVersionsOfItem(at:)` | "Removes all versions of a file, except the current one, from the version store." … "**You should always remove file versions as part of a coordinated write operation to a file.**" |
| `remove()` | "**You must not call this method for the current file version.**" |
| `replaceItem(at:options:)` | "Replace the contents of the specified file with the contents of the current version's file." |
| `url` | "**Do not display any part of this URL to the user. The location of file versions is managed by the system and should not be exposed to the user.**" |

### 4.2 What the app must do

The canonical five-step flow:

> "- If the chosen version is a conflict version, replace the current document file with the conflict-version document file… call `replaceItemAtURL:options:error:`…
> - …revert the document so that it displays the new data… call `revertToContentsOfURL:completionHandler:`…
> - Disassociate all conflict versions with the document's file URL… call `removeOtherVersionsOfItemAtURL:error:`…
> - Mark each conflict version as resolved so that iOS doesn't raise it again… set the `resolved` property… **This step should always be done last.**
> - Remove the resolved versions of the document… call `removeAndReturnError:`… **Document revisions remain on the server until you delete them.**"

The three sanctioned strategies:

> "- Merge the changes from the conflicting versions.
> - Choose one of the document versions based on some pertinent factor, such as the version with the latest modification date.
> - Enable the user to view conflicting versions of a document and select the one to use."
>
> "Generally, you should try to resolve the conflict without involving the user, but for some applications that might not be possible."

— [Resolving Document Version Conflicts](https://developer.apple.com/library/archive/documentation/DataManagement/Conceptual/DocumentBasedAppPGiOS/ResolveVersionConflicts/ResolveVersionConflicts.html)

**⚠️ A doc-vs-doc contradiction worth knowing.** The File System Programming Guide claims *"Setting this property to `YES` causes the conflict version objects (and their corresponding files) to be removed from the user's iCloud storage"* ([source](https://developer.apple.com/library/archive/documentation/FileManagement/Conceptual/FileSystemProgrammingGuide/iCloud/iCloud.html)). The current `isResolved` reference says the opposite: you *"must then remove any versions of the file that are no longer useful,"* and if you don't, they keep syncing and consuming quota. **Follow the current reference and TN2336: `resolved = true` clears the flag, it does not reclaim the storage.**

**Detection depends on architecture.** `UIDocument` *is* an `NSFilePresenter` and surfaces `UIDocument.State.inConflict` — *"Conflicts exist for the document file located at the file URL"* — via `stateChangedNotification`; `NSDocument` on macOS *"handles conflict resolution automatically… presents a sheet asking the user to resolve the conflict"* and *"always keeps the conflicting versions"* ([Managing the Document Life Cycle](https://developer.apple.com/library/archive/documentation/DataManagement/Conceptual/DocBasedAppProgrammingGuideForOSX/ManagingLifecycle/ManagingLifecycle.html)). The iCloud Design Guide summarises macOS bluntly: *"In OS X, rely on the system to resolve document conflicts."*

**Vellum is neither.** For non-document-based apps TN2336 prescribes `NSFilePresenter`:

```swift
// For a file or file package
presentedItemDidGainVersion(_:)
presentedItemDidLoseVersion(_:)
presentedItemDidResolveConflictVersion(_:)

// For a folder
presentedSubitemAtURL(_:didGainVersion:)
presentedSubitemAtURL(_:didLoseVersion:)
presentedSubitemAtURL(_:didResolveConflictVersion:)
```

The **folder-level** variants are the interesting ones: a single presenter on `Documents/Vellum/.vellum/records/` would report conflicts across every sidecar without one presenter per file.

### 4.3 If conflicts are never resolved

They accumulate, sync everywhere, and cost the user quota. Apple says this four times:

> "**Important:** If you do not explicitly remove versions of a file that are no longer useful, **iCloud continues to sync them to all a user's devices and those versions continue to consume user iCloud quota.**" — [isResolved](https://developer.apple.com/documentation/foundation/nsfileversion/isresolved)

> "**Important:** If you do not explicitly remove the versions that are no longer useful, they will continue to synchronize to all iCloud peers and consume the user's iCloud quota. So apps working heavily with iCloud files or file packages should observe the version conflicts and remove the useless versions, **even though they don't have to do a custom merge.**" — [TN2336](https://developer.apple.com/library/archive/technotes/tn2336/_index.html)

> "**Document revisions remain on the server until you delete them.**" — [Resolving Document Version Conflicts](https://developer.apple.com/library/archive/documentation/DataManagement/Conceptual/DocumentBasedAppPGiOS/ResolveVersionConflicts/ResolveVersionConflicts.html)

> "When done resolving a conflict, **be sure to delete any out-of-date document versions; if you don't, you needlessly consume capacity in the user's iCloud storage.**" — [Designing for Documents in iCloud](https://developer.apple.com/library/archive/documentation/General/Conceptual/iCloudDesignGuide/Chapters/DesigningForDocumentsIniCloud.html)

Note the concession in TN2336's last clause: an app is not obliged to **merge**, only to **observe and clean up**. That is a meaningfully cheaper bar than three-way merge and is probably the right v1 target — but it still requires a presenter Vellum does not have.

**Where do the losers live?** The system-managed version store, not visible dot-files. Apple's only statement about the location is the prohibition on exposing it (`url`, above). **I could not substantiate any Apple claim that write-conflict losers appear as `.<name>` siblings** — the only user-visible sibling Apple documents is the bounced filename for *new-file* conflicts in document scope.

**What the user sees on macOS** ([Apple Support](https://support.apple.com/guide/mac-help/document-versions-conflict-icloud-drive-mac-mh40780/mac)): a message asking which versions to keep; unselected versions are deleted across all devices; kept duplicates get a number appended.

**What the user sees in Files.app on iOS: not substantiated.** Apple's iOS-side statements are all app-mediated. The plain reading — the user sees only the winning file, with nothing indicating a conflict — is inference, not evidence.

### 4.4 Avoiding conflicts structurally

**Apple documents no file-per-device or append-only-log pattern.** Searched the iCloud Design Guide (all chapters), the File System Programming Guide iCloud chapter, TN2336, and both Document-Based App Programming Guides. No such section exists. Do not attribute one to Apple.

What Apple *does* say:

**1. Use a file package so pieces sync independently:**

> "**If your document data format consists of multiple distinct pieces, use a file package for your document file format.** […] The iCloud upload and download machinery makes use of this factoring of content within a file package; **only changed elements are uploaded or downloaded.**"

**2. The strongest conflict-avoidance guidance Apple gives — and it lands squarely on Vellum:**

> "Whichever scheme you choose, take care, in an app that supports editing, to **never save document state unless document content was edited. Otherwise, you invite trivial and unhelpful conflict scenarios that consume network bandwidth and battery power.**"
>
> "This badly behaved example app aggressively saves the end-of-document scroll position—even though the user made no other changes. When the user later opens the document on her iPad to resume editing, **there is a needless conflict due to scroll position data.** […] **To be a well-behaved iCloud app, this text editor should have ignored the change in scroll position on the iPhone because the user did not edit the content.**"
>
> "Take care with state like: Document scroll position · Element selection · Last-opened timestamps · Table sort order · Window size (in OS X)"

**3. State kept outside the document is your problem:**

> "Associated with the document but outside of its file package (or file format)… **such state is not tracked by a document's conflict resolution functionality. It is up to you to do so.**"

— all three: [Designing for Documents in iCloud](https://developer.apple.com/library/archive/documentation/General/Conceptual/iCloudDesignGuide/Chapters/DesigningForDocumentsIniCloud.html)

**Quote 2 describes Vellum's sidecar exactly.** The records carry reading position and `openedAt`, and `WebSessionBackend.swift:41` "read + touch + rewrite the sidecar" on *open*. Merely opening a document on the iPhone rewrites the shared sidecar and can conflict with the iPad — a "needless conflict" of precisely the kind Apple names. **Splitting volatile per-device state (reading position, `openedAt`, recents) out of the shared annotation sidecar is the single highest-leverage structural change available**, and it maps directly onto the open question in #146 about whether reading position syncs in v1.

**`NSUbiquitousKeyValueStore` as the alternative for small state.** It is documented latest-wins, so it never produces conflict versions:

> "Key-value storage: **The most recent value set for a key wins and is pushed to all devices attached to the same iCloud account. The timestamps provided by each device are used to compare modification times.**" — [iCloud Fundamentals](https://developer.apple.com/library/archive/documentation/General/Conceptual/iCloudDesignGuide/Chapters/iCloudFundametals.html)

Documented limits ([NSUbiquitousKeyValueStore](https://developer.apple.com/documentation/foundation/nsubiquitouskeyvaluestore)):

> - "no more than **1024 keys**"
> - "total amount of available storage space for all values is **1 megabyte**"
> - "maximum size for a single value is **1 megabyte**"
> - "maximum length for each key string is **128 characters using the UTF-16 encoding**. Key strings don't count against the 1 megabyte quota for values."
> - Exceeding limits: "the operation fails and the system doesn't add the keys or values"; an over-long key "**raises an exception**"; a quota-exceeding write posts `didChangeExternallyNotification` with reason `NSUbiquitousKeyValueStoreQuotaViolationChange`.

(The archived guide gives conflicting numbers — 64-byte UTF-8 keys. Use the current reference.)

**But Apple explicitly disqualifies KVS for document state:**

> "Do **not** use key-value storage for: **1.** Document-specific state in document-based apps (e.g., current page, current selection). Instead, store document-specific state with each document. **2.** Data essential to your app's behavior when offline."
>
> "**Key-value storage, in most cases, is not appropriate for storing document-specific state.**"
>
> "**Transfer overhead:** Every change to a large data object requires sending the entire object to iCloud. **Better approach:** Break data into small pieces and store separately using transparent types."

— [Designing for Key-Value Data in iCloud](https://developer.apple.com/library/archive/documentation/General/Conceptual/iCloudDesignGuide/Chapters/DesigningForKey-ValueDataIniCloud.html) and [Designing for Documents in iCloud](https://developer.apple.com/library/archive/documentation/General/Conceptual/iCloudDesignGuide/Chapters/DesigningForDocumentsIniCloud.html)

So KVS is right for app-level preferences (storage mode, UI settings) and **wrong** for per-document reading position — which is the exact thing you'd most want to move out of the sidecar. Apple's answer there is "store it with the document," which is where it already is.

**Vellum's current design, scored:** friendly, in that state is split per document into `records/<key>.json`, so two devices annotating *different* documents never collide. Hostile, in that within one document the whole record is rewritten on every mutation (`WebSessionBackend.swift:7-8`: *"every mutation rewrites the sidecar immediately"*), so any concurrent edit is a whole-file conflict — and the per-path lock in `WebLibrary.withRecord` serializes writers **within one process only**. It does nothing across devices.

### 4.5 Timing, and whether coordination is a prerequisite for conflict detection

**No numeric latency or debounce is documented anywhere.** Only qualitative statements:

> "The first step is to send the document's metadata… **This metadata transfer takes place quickly.** The second step is to send the document's data." … "**After a document's data is on the server, iCloud optimizes future transfers… Instead of sending the entire file or file package each time it changes, iCloud sends only the metadata and the pieces that changed.**" … "**On iOS devices, changes are pulled at appropriate times, such as when the app that owns the files comes to the foreground. In OS X, changes are pulled immediately.**"

— [Designing for Documents in iCloud](https://developer.apple.com/library/archive/documentation/General/Conceptual/iCloudDesignGuide/Chapters/DesigningForDocumentsIniCloud.html)

> "**When testing, don't expect changes to instantly propagate from one device to another.**"

— [Testing and Debugging for iCloud](https://developer.apple.com/library/archive/documentation/General/Conceptual/iCloudDesignGuide/Chapters/TestingandDebuggingforiCloud.html)

That "pulled when the app comes to the foreground" line is directly relevant to a phone: the iPhone will typically be *behind* until launched, so a cold-launch reconciliation step is not optional.

**⚠️ Correction: `forUploading` is not an upload trigger.** It is a *reading* option for when **your app** uploads bytes somewhere else:

> "Specify this content when reading an item for the purpose of uploading its contents."
> "**When this option is used, the file coordinator creates a temporary snapshot of the item being read and relinquishes its claim on the original file.** This action prevents the read operation from blocking other coordinated writes during a potentially long upload."
> "If the item being read is a directory (such as a document package), then the snapshot is a new file containing the zipped contents of the directory."
> "**The file coordinator unlinks the file after the block returns, rendering it inaccessible through the URL.**"

— [ReadingOptions.forUploading](https://developer.apple.com/documentation/foundation/nsfilecoordinator/readingoptions/foruploading)

There is **no documented way to force an immediate iCloud Drive upload** — no `synchronize()` equivalent for document storage (unlike KVS, which has one). **[DTS]** *"There is no API for app developers to force an iCloud Drive synchronization. When using iCloud services, the system decides when to synchronize data."* — Ziqiao Chen, [thread 771643](https://developer.apple.com/forums/thread/771643), citing [TN3162](https://developer.apple.com/documentation/technotes/tn3162-understanding-cloudkit-throttles).

**The crux: does conflict detection work with uncoordinated atomic writes?**

*Substantiated:*
- **Push notification of conflicts absolutely requires coordination.** *"Your presenter objects are not notified about changes made directly using low-level read and write calls to the file. Only changes that go through a file coordinator result in notifications."* ([NSFilePresenter](https://developer.apple.com/documentation/foundation/nsfilepresenter)); *"Registration is essential. The system can notify only registered presenter objects."* ([iCloud File Management](https://developer.apple.com/library/archive/documentation/FileManagement/Conceptual/FileSystemProgrammingGuide/iCloud/iCloud.html)). No presenter → no `presentedItemDidGainVersion:`, no `UIDocument` `inConflict`, no notification of any kind.
- Coordination is stated as mandatory (§3.1), with no exception for atomic writes.
- Uncoordinated writes race the daemon: *"Two different processes acting on the same file might make changes that the other is not expecting, which could lead to more serious problems like crashes or data corruption."* ([The Role of File Coordinators and Presenters](https://developer.apple.com/library/archive/documentation/FileManagement/Conceptual/FileSystemProgrammingGuide/FileCoordinators/FileCoordinators.html)).

*Not substantiated:* **whether the version store still records a conflict version for an uncoordinated write.** Every Apple description attributes conflict-version creation to the cloud/system, not the app's write path — *"the system attempts to resolve the conflict… by picking one of the file versions"*, *"iCloud Drive automatically creates new versions for all other conflicts"* — and none of it conditions on the app having coordinated. The pull-based query APIs (`unresolvedConflictVersionsOfItem(at:)` etc.) document no precondition of a registered presenter or active coordinator. So the *defensible* reading is that conflict versions are produced by the sync layer and remain queryable, and what uncoordinated writing costs you is (i) all push notification and (ii) mutual exclusion against the daemon. **But Apple never says this, and I found no source confirming or denying it. Do not design against the inference.**

**[DTS] — a real-world caveat on the invariant.** Asked in October 2025 why `currentVersionOfItem` was *inconsistent across devices* after a simultaneous edit (Device B's `unresolvedConflictVersionsOfItem` never surfacing Device A's version), DTS Engineer Ziqiao Chen did not defend the archived guide's "the current file is the same across all devices" claim: *"`presentedItemDidGain(_:)` is supposed to be called after a new version was added, which does seem to conflict with your observation. **I'd hence suggest that you file a feedback report.**"* and, on the developer's proposed flow, *"Yes, the above flow sounds right, **assuming `presentedItemDidGain` is called at the documented timing.**"* — [thread 804253](https://developer.apple.com/forums/thread/804253). **Plan for transient divergence even when you do everything right.**

**Bottom line for the iPhone decision: with today's uncoordinated tmp+rename writes and no presenter anywhere, Vellum has no conflict detection at all** — whether or not the version store is being populated underneath. Nobody ever asks. To the user this presents as "my highlights from the iPad disappeared."

---

## Consolidated gaps — what Apple does NOT document

| Claim | Status |
|---|---|
| `~/Library/Mobile Documents` is the macOS container root | **Undocumented.** The string appears nowhere in Apple's developer docs. |
| iOS ubiquity container path under `/var/mobile/Library/Mobile Documents/` | **Undocumented.** |
| `iCloud.com.x.y` → `iCloud~com~x~y` folder mangling | **Undocumented.** No Apple doc, no Apple-staff post. Empirically true. |
| Writing at the container path (bypassing the API) is supported | **Apple is silent.** No blessing, no prohibition. |
| Uncoordinated writes are/aren't picked up by the sync daemon | **Apple is silent.** Coordination is "mandatory" but justified by *conflict avoidance*, not *change discovery*. |
| Uncoordinated writes do/don't produce `NSFileVersion` conflict records | **Apple is silent.** The crux of Q4. |
| The `.<name>.icloud` placeholder filename convention | **Undocumented.** TN3150 describes dataless files at the original path via `SF_DATALESS`. |
| Modern reference page for `com.apple.developer.ubiquity-container-identifiers` | **Does not exist** (absent from the entitlements index; JSON endpoint 404s). Archived docs only. |
| Current rule for which container IDs an app may claim | **Not restated in modern docs.** Only a DTS reply says the old bundle-ID rule is gone. |
| Mac + iOS builds of the same app sharing one container | **Not stated.** Mechanism supports it; Apple's example is free/paid variants. |
| iCloud Drive is implemented on FileProvider on modern macOS | **Not substantiated.** WWDC21-10182 covers third-party providers only. |
| "Unsandboxed apps can read the whole Mobile Documents tree" | **No doc page.** Established by implication from DTS quotes + the `EPERM` test. |
| How a free Personal Team actually *creates* an App Group | **Undocumented workflow.** The capability table says supported; the help page routes through a portal free accounts can't reach (§2.5). |
| "An ad-hoc-signed unsandboxed Mac app can't use iCloud" | **No single Apple sentence.** Chain of TN3125 + the macOS capability table (§2.7). |
| Xcode's "Sign to Run Locally" == ad-hoc signing | **Forum-level only**, no Apple doc page. |
| Any numeric sync latency, debounce, or coalescing window | **Undocumented.** Only "usually immediately", "quickly", "at appropriate times". |
| That closing a document or finishing a coordinated write forces an upload | **No such statement.** `forUploading` is unrelated. |
| What Files.app shows for an unresolved version conflict on iOS | **Not substantiated.** macOS Finder/`NSDocument` behaviour only. |
| Apple guidance for a file-per-device or append-only-log pattern | **Does not exist.** Do not attribute one to Apple. |

---

## Implications for the iPhone decision (#146)

Not decisions — the shape of the choice, each consequence traceable above.

1. **A genuinely shared three-device library needs the paid membership on the iOS side** (§2.2, §2.3) — iCloud is ADP-only on every platform table, and TestFlight is paid regardless. The Mac has a documented free path (§1.5a); iOS does not. This converts "Distribution mechanics" in the wayfinder map from conditional to required, and the 7-day profile expiry (§2.4) makes free-team the wrong answer for a device you actually read on.
2. **All three apps must name the *same literal* container ID**, and stop passing `nil` (§1.3). `iCloud.$(PRODUCT_BUNDLE_IDENTIFIER)` is the wrong expansion given the bundle IDs already diverge. The team already matches, and per DTS the container ID no longer has to match any app's bundle ID (§1.2).
3. **The Mac app would have to move its library** out of `com~apple~CloudDocs/Vellum/` into the container's `Documents/` (§1.1, §1.5). That is a user-data migration, not a config change — and it is the leg that currently works, so sequence it carefully.
4. **`NSUbiquitousContainers` + a `CFBundleVersion` bump + at least one file in `Documents/`** are all required for the folder to appear, with `SupportedFolderLevels = Any` for Vellum's depth (§1.4). Get it wrong once and it stays wrong until the next bump.
5. **The materialization guard needs rebuilding on documented primitives** — `SF_DATALESS` or `setiopolicy_np`, not `fileExists` and `.icloud` sibling paths (§3.3, §3.4). As written the guard triggers what it guards against. And note that coordinated reads *also* materialize unless you pass `immediatelyAvailableMetadataOnly` (§3.5).
6. **Conflict handling is absent, not merely simple** (§4.5). TN2336's sanctioned minimum is observe-and-clean-up rather than full merge (§4.3) — still new machinery: an `NSFilePresenter` on the records directory, using the folder-level `presentedSubitemAtURL:didGainVersion:` callbacks (§4.2).
7. **Strongest structural lever: stop writing volatile per-device state into the shared sidecar** (§4.4). Apple names last-opened timestamps and scroll position as causes of "needless conflict", and Vellum touches `openedAt` on every open. This bears directly on #146's open question about whether reading position syncs in v1 — the cheapest answer, per-device and out of the shared file, is also the one Apple's guidance points at.
8. **One thing worth a DTS incident.** If the Mac's entitlement-free direct-write approach is load-bearing for the product, an incident is the only way to get an authoritative answer on direct-path writes and coordination-vs-sync (§1.5) — there is no existing Apple-staff answer on the forums, and code-level support is itself a paid-membership benefit (§2.1), so it comes free with the decision in item 1.

---

## Source index

**Apple documentation and archived guides**
- [iCloud File Management — File System Programming Guide](https://developer.apple.com/library/archive/documentation/FileManagement/Conceptual/FileSystemProgrammingGuide/iCloud/iCloud.html)
- [The Role of File Coordinators and Presenters](https://developer.apple.com/library/archive/documentation/FileManagement/Conceptual/FileSystemProgrammingGuide/FileCoordinators/FileCoordinators.html)
- [File System Basics](https://developer.apple.com/library/archive/documentation/FileManagement/Conceptual/FileSystemProgrammingGuide/FileSystemOverview/FileSystemOverview.html)
- iCloud Design Guide: [iCloud Fundamentals](https://developer.apple.com/library/archive/documentation/General/Conceptual/iCloudDesignGuide/Chapters/iCloudFundametals.html) · [Designing for Documents in iCloud](https://developer.apple.com/library/archive/documentation/General/Conceptual/iCloudDesignGuide/Chapters/DesigningForDocumentsIniCloud.html) · [Designing for Key-Value Data in iCloud](https://developer.apple.com/library/archive/documentation/General/Conceptual/iCloudDesignGuide/Chapters/DesigningForKey-ValueDataIniCloud.html) · [Testing and Debugging](https://developer.apple.com/library/archive/documentation/General/Conceptual/iCloudDesignGuide/Chapters/TestingandDebuggingforiCloud.html)
- [Resolving Document Version Conflicts (iOS)](https://developer.apple.com/library/archive/documentation/DataManagement/Conceptual/DocumentBasedAppPGiOS/ResolveVersionConflicts/ResolveVersionConflicts.html) · [Managing the Document Life Cycle (Mac)](https://developer.apple.com/library/archive/documentation/DataManagement/Conceptual/DocBasedAppProgrammingGuideForOSX/ManagingLifecycle/ManagingLifecycle.html)
- [Cocoa Keys — Information Property List Key Reference](https://developer.apple.com/library/archive/documentation/General/Reference/InfoPlistKeyReference/Articles/CocoaKeys.html)
- [Entitlement Key Reference: Enabling iCloud Storage (archived)](https://developer.apple.com/library/archive/documentation/Miscellaneous/Reference/EntitlementKeyReference/Chapters/EnablingiCloud.html)
- [Configuring iCloud services (Xcode)](https://developer.apple.com/documentation/xcode/configuring-icloud-services/) · [Synchronizing documents in the iCloud environment](https://developer.apple.com/documentation/uikit/synchronizing-documents-in-the-icloud-environment)
- [FileManager.url(forUbiquityContainerIdentifier:)](https://developer.apple.com/documentation/foundation/nsfilemanager/1411653-urlforubiquitycontaineridentifie)
- [NSFileCoordinator](https://developer.apple.com/documentation/foundation/nsfilecoordinator) · [ReadingOptions.forUploading](https://developer.apple.com/documentation/foundation/nsfilecoordinator/readingoptions/foruploading) · [NSFilePresenter](https://developer.apple.com/documentation/foundation/nsfilepresenter)
- [NSFileVersion](https://developer.apple.com/documentation/foundation/nsfileversion) · [isConflict](https://developer.apple.com/documentation/foundation/nsfileversion/isconflict) · [isResolved](https://developer.apple.com/documentation/foundation/nsfileversion/isresolved) · [removeOtherVersionsOfItem(at:)](https://developer.apple.com/documentation/foundation/nsfileversion/removeotherversionsofitem(at:))
- [UIDocument](https://developer.apple.com/documentation/uikit/uidocument) · [UIDocument.State](https://developer.apple.com/documentation/uikit/uidocument/state-swift.struct)
- [NSUbiquitousKeyValueStore](https://developer.apple.com/documentation/foundation/nsubiquitouskeyvaluestore)
- [NSURLUbiquitousItemDownloadingStatusKey](https://developer.apple.com/documentation/foundation/nsurlubiquitousitemdownloadingstatuskey) · [NSMetadataUbiquitousItemDownloadingStatusKey](https://developer.apple.com/documentation/foundation/nsmetadataubiquitousitemdownloadingstatuskey)
- [Protecting user data with App Sandbox](https://developer.apple.com/documentation/security/protecting-user-data-with-app-sandbox) · [Accessing files from the macOS App Sandbox](https://developer.apple.com/documentation/security/accessing-files-from-the-macos-app-sandbox)
- Entitlements: [icloud-container-identifiers](https://developer.apple.com/documentation/bundleresources/entitlements/com.apple.developer.icloud-container-identifiers) · [icloud-services](https://developer.apple.com/documentation/bundleresources/entitlements/com.apple.developer.icloud-services)

**Technical Notes and Q&As**
- [TN3150: Getting ready for dataless files](https://developer.apple.com/documentation/technotes/tn3150-getting-ready-for-data-less-files)
- [TN2336: Handling version conflicts in the iCloud environment](https://developer.apple.com/library/archive/technotes/tn2336/_index.html)
- [TN2415: Entitlements Troubleshooting](https://developer.apple.com/library/archive/technotes/tn2415/_index.html)
- [TN3162: Understanding CloudKit throttles](https://developer.apple.com/documentation/technotes/tn3162-understanding-cloudkit-throttles)
- [QA1893: Updating the metadata of iCloud containers for iCloud Drive](https://developer.apple.com/library/archive/qa/qa1893/_index.html)

**Account, membership and signing**
- [Choosing a Membership](https://developer.apple.com/support/compare-memberships/) · [About your developer account](https://developer.apple.com/help/account/basics/about-your-developer-account) · [Apple Developer Program](https://developer.apple.com/programs/)
- [Supported capabilities (iOS)](https://developer.apple.com/help/account/reference/supported-capabilities-ios/) / [(macOS)](https://developer.apple.com/help/account/reference/supported-capabilities-macos/) — read the raw HTML, not a text conversion (§2.2)
- [Create an iCloud container](https://developer.apple.com/help/account/identifiers/create-an-icloud-container/) · [Register an app group](https://developer.apple.com/help/account/identifiers/register-an-app-group/) · [Capabilities overview](https://developer.apple.com/help/account/capabilities/capabilities-overview/)
- [TN3125: Inside code signing — provisioning profiles](https://developer.apple.com/documentation/technotes/tn3125-inside-code-signing-provisioning-profiles) · [QA1915: Your (Personal Team) cannot be used to Code Sign](https://developer.apple.com/library/archive/qa/qa1915/_index.html)
- [Adding capabilities to your app](https://developer.apple.com/documentation/xcode/adding-capabilities-to-your-app) · [Configuring app groups](https://developer.apple.com/documentation/xcode/configuring-app-groups) · [App Groups Entitlement](https://developer.apple.com/documentation/bundleresources/entitlements/com.apple.security.application-groups) · [Distributing your app for beta testing and releases](https://developer.apple.com/documentation/xcode/distributing-your-app-for-beta-testing-and-releases)

**Apple Support (end-user)**
- [If document versions conflict in iCloud Drive on Mac](https://support.apple.com/guide/mac-help/document-versions-conflict-icloud-drive-mac-mh40780/mac)

**Apple Developer Forums — DTS replies only, secondary**
- [Thread 727902](https://developer.apple.com/forums/thread/727902) — Quinn: sandboxed apps see iCloud Drive as an external volume; `EPERM` test
- [Thread 663889](https://developer.apple.com/forums/thread/663889) — Quinn: unsandboxed ≠ unlimited
- [Thread 765461](https://developer.apple.com/forums/thread/765461) — container ID no longer must match the bundle ID
- [Thread 772632](https://developer.apple.com/forums/thread/772632) — publishing a container to iCloud Drive
- [Thread 771643](https://developer.apple.com/forums/thread/771643) — no API to force iCloud Drive sync
- [Thread 756129](https://developer.apple.com/forums/thread/756129) — opting out of dataless materialization when enumerating
- [Thread 804253](https://developer.apple.com/forums/thread/804253) — current version inconsistent across devices; DTS routed to Feedback
- [Thread 128767](https://developer.apple.com/forums/thread/128767) — Quinn: the "Apple Developer" column *is* the Personal Team
- [Thread 721701](https://developer.apple.com/forums/thread/721701) — Quinn: App Groups macOS vs iOS; App Group Container Protection on macOS 15+
- [Thread 669516](https://developer.apple.com/forums/thread/669516) — pointer to the Personal Team capability column

**Vellum code surveyed (2026-08-01)**
- `main/Vellum/Services/Web/WebStorage.swift`, `main/project.yml`
- `ipad-app/Vellum/Services/Web/WebStorage.swift`, `.../WebLibrary.swift`, `.../WebSessionBackend.swift`, `.../Pdf/PdfAtomicWriter.swift`, `Vellum/Vellum-iOS.entitlements`, `project.yml`
