import Foundation

// The walkthrough's copy, kept as data rather than inlined in the view so the
// page sequence can be unit-tested and so adding a page is an edit to one array
// instead of a change to the sheet's layout.
//
// Every line here is a claim about behavior that exists today. When a feature
// changes, this file changes with it — onboarding that lies is worse than no
// onboarding, so prefer deleting a bullet to letting it drift.

/// One bullet on a walkthrough page.
struct WalkthroughPoint: Identifiable, Sendable {
    /// SF Symbol shown in the gutter. Validated by `WalkthroughContentTests`,
    /// which fails on a name macOS can't resolve — a typo would otherwise just
    /// render an invisible gap.
    let symbol: String
    let text: String
    /// Optional shortcut rendered as a keycap at the end of the line. Written
    /// exactly as the menus show it (e.g. "⌘⌥S"), not as prose.
    var shortcut: String?

    var id: String { text }
}

/// One page of the walkthrough.
struct WalkthroughPage: Identifiable, Sendable {
    /// Stable slug, also the suffix of the page's accessibility identifiers, so
    /// UI automation can name a page without depending on its position.
    let id: String
    let symbol: String
    let title: String
    /// One or two sentences setting up the bullets. Deliberately short: this is
    /// the only part most people read.
    let summary: String
    let points: [WalkthroughPoint]
    /// Closing line, used on the last page to say how to get back here.
    var footnote: String?
}

extension WalkthroughPage {
    /// The walkthrough, in order.
    ///
    /// Sequenced document-first: what Vellum is, how to mark a document up,
    /// where notes live, then the AI (which is opt-in and needs an account),
    /// then storage. The issue that asked for this listed the AI first, but a
    /// reader who has not yet opened a document has no context for tool calls.
    static let all: [WalkthroughPage] = [
        WalkthroughPage(
            id: "welcome",
            symbol: "doc.text",
            title: "A quiet place to read",
            summary:
                "Vellum opens PDFs and web articles side by side, keeps your markings with them, "
                + "and puts an optional AI assistant in the margin rather than in the way.",
            points: [
                WalkthroughPoint(
                    symbol: "folder",
                    text: "Open a PDF from disk, or paste an article URL to read it here.",
                    shortcut: "⌘O"),
                WalkthroughPoint(
                    symbol: "rectangle.split.2x1",
                    text: "Split the window to read two documents at once. Tabs drag between panes.",
                    shortcut: "⌘\\"),
                WalkthroughPoint(
                    symbol: "sidebar.right",
                    text: "The inspector on the right has three tabs: Annotations, AI, and Scratchpad.",
                    shortcut: "⌘⌥S"),
                WalkthroughPoint(
                    symbol: "clock",
                    text: "The start page keeps what you've read recently next to the pages you've saved."),
            ]
        ),

        WalkthroughPage(
            id: "annotate",
            symbol: "highlighter",
            title: "Mark up the page",
            // "as you make them", not "when you save": PdfSessionBackend.save()
            // is a documented no-op because createAnnotation/updateAnnotation
            // already write the PDF back to disk. Telling a new reader their
            // markings are unsaved until ⌘S would be actively misleading.
            summary:
                "Highlights and notes work the same way on a PDF and on a web page. In a PDF they "
                + "are written into the file itself as you make them; on a web page they are kept "
                + "with the page in your library.",
            points: [
                WalkthroughPoint(
                    symbol: "highlighter",
                    // The palette used to be spelled out here. It was cut on
                    // review: naming five colors teaches nothing a reader won't
                    // see the instant the popover opens, and it dates the copy
                    // the moment the palette changes.
                    text: "Select text to highlight it, or turn the selection into a note."),
                WalkthroughPoint(
                    symbol: "note.text",
                    text: "Press N for note mode, then tap anywhere on the page to drop a sticky note.",
                    shortcut: "N"),
                WalkthroughPoint(
                    symbol: "bookmark",
                    text: "Bookmark the page you're on; bookmarks list alongside your other annotations.",
                    shortcut: "⌘D"),
                WalkthroughPoint(
                    symbol: "magnifyingglass",
                    text: "Search the whole document and step through the matches.",
                    shortcut: "⌘F"),
            ]
        ),

        WalkthroughPage(
            id: "notes",
            symbol: "square.and.pencil",
            title: "Keep your thinking next to it",
            summary:
                "Every document gets its own Scratchpad in the inspector — a Markdown notebook that "
                + "renders as you type and autosaves on its own.",
            points: [
                WalkthroughPoint(
                    symbol: "text.alignleft",
                    text: "Markdown renders live; the line under your cursor shows its raw source."),
                WalkthroughPoint(
                    symbol: "function",
                    text: "LaTeX renders inline, in your notes and in AI replies alike."),
                WalkthroughPoint(
                    symbol: "camera.viewfinder",
                    text: "Snapshot a region of the page into your notes, or drop in an image from Files."),
                // The "sharing the AI conversation is a separate checkbox, off
                // by default" sentence was cut here. It is still true and still
                // documented in the Help centre's export topic, where someone
                // about to share a file will look for it — but on a first read
                // it is a caveat about a dialog the reader has not opened.
                WalkthroughPoint(
                    symbol: "arrow.up.doc",
                    text:
                        "\"Export with Notes…\" packs the document, your notes and attachments "
                        + "into one .vellum file."),
            ]
        ),

        WalkthroughPage(
            id: "connect",
            symbol: "sparkles",
            title: "Connect an AI model",
            // "nothing from your documents leaves this Mac", not a blanket
            // "nothing is sent anywhere": selecting OpenRouter and opening the
            // model picker fires a keyless GET to its public model catalog
            // (OpenRouterCatalog.refresh) before any account exists. No user
            // content is in that request, so the scoped claim is the true one.
            // One location, not two. The in-inspector settings panel was
            // removed when global settings moved to the Settings window
            // (AiSettingsPanel is gone); the inspector's AI tab now shows a
            // "Configure AI in Settings" banner that opens this same place, so
            // naming Settings ▸ AI is both true and where the banner lands.
            summary:
                "Vellum ships no model of its own — you bring your own account, and nothing from "
                + "your documents leaves this iPad until you do. Set it up in Settings ▸ AI.",
            points: [
                // Leads with "optional" on purpose. This is the page most
                // likely to make a new reader think they have hit a paywall or
                // a required signup, and everything in the three pages before
                // it works with no account at all.
                WalkthroughPoint(
                    symbol: "checkmark.circle",
                    text:
                        "Reading, highlighting, notes and the Scratchpad all work with no AI "
                        + "account at all. This page is optional."),
                WalkthroughPoint(
                    symbol: "key",
                    text:
                        "Paste an API key for Gemini, the OpenAI API, OpenRouter, OpenCode Zen, "
                        + "or OpenCode Go."),
                // Not "the OpenAI API": ChatGPTAuth replicates the Codex CLI
                // login against OpenAI's own auth server and talks to the
                // ChatGPT Codex backend, so this bills against a ChatGPT
                // subscription rather than against API credit. Reviewed and
                // reworded to say so.
                WalkthroughPoint(
                    symbol: "person.crop.circle.badge.checkmark",
                    text:
                        "Or choose \"ChatGPT (Codex)\" and sign in through your browser to use an "
                        + "existing ChatGPT subscription instead of an API key."),
            ]
        ),

        WalkthroughPage(
            id: "assistant",
            symbol: "text.bubble",
            title: "Working with the assistant",
            summary:
                "The assistant is pointed at the document you're reading and can act on it, so ask it "
                + "to do things rather than only to explain them.",
            points: [
                WalkthroughPoint(
                    symbol: "doc.text.magnifyingglass",
                    text:
                        "It can read any page, search the whole document, and list the highlights and "
                        + "notes you've already made."),
                // The "capped at five changes per reply" clause was cut on
                // review. AiToolEngine.maxWrites is still 5 and still enforced;
                // the cap is simply an implementation guardrail, not something
                // a first-time reader needs on screen.
                WalkthroughPoint(
                    symbol: "hand.tap",
                    text: "It can jump to a page, add a note, and highlight text it finds."),
                WalkthroughPoint(
                    symbol: "quote.opening",
                    text:
                        "Select a passage and choose \"Ask AI about this\" to quote it into the composer. "
                        + "Its replies can be quoted back the same way."),
                // The "anything else is named back to you" clause was cut on
                // review. AiFileAttachment still reports a non-image drop by
                // name rather than swallowing it, but describing the failure
                // mode of a drop the reader has not made yet is noise.
                WalkthroughPoint(
                    symbol: "photo",
                    text: "Attach the current page, a cropped region, or an image file. Images only."),
            ]
        ),

        WalkthroughPage(
            id: "storage",
            symbol: "externaldrive",
            title: "Where your work lives",
            // Not "never deletes on its own" — see the AI-conversation note on
            // the first bullet. "Keeps" is the claim the code actually backs.
            summary:
                "Vellum splits your data in two: the things you made, which it keeps, and the "
                + "things it can rebuild, which it tidies up.",
            points: [
                // AI conversations are deliberately NOT inside the "only you
                // delete these" list: AiPersistence.saveConversation runs every
                // save through `limit`, which keeps only the last
                // `maxMessagesPerDocument` messages and hard-truncates any
                // single message past `maxMessageCharacters`. That trim is
                // written straight to conversations.json, so the older messages
                // are genuinely gone — claiming otherwise would be the one lie
                // on the page the whole feature was filed for.
                // AI conversations are deliberately absent from this list.
                // AiPersistence.saveConversation runs every save through
                // `limit`, which keeps only the last `maxMessagesPerDocument`
                // messages and writes that trimmed list to conversations.json —
                // so listing them as "kept indefinitely" would be false. The
                // earlier draft said "trimmed to the last 120 messages", which
                // was true but is exactly the kind of internal number a first
                // read does not need. Omitting them is honest; claiming they
                // are permanent would not be.
                WalkthroughPoint(
                    symbol: "checkmark.seal",
                    text:
                        "Kept indefinitely: your highlights, notes, bookmarks, reading positions, "
                        + "and the pages you save."),
                WalkthroughPoint(
                    symbol: "clock.arrow.circlepath",
                    text:
                        "Tidied up: offline copies of web pages and extracted text. By default Vellum "
                        + "clears these for pages you haven't opened in six months and only for pages "
                        + "you never saved or annotated."),
                // The exact option list (1, 3, 6, 12, Never) lives in the Help
                // centre's retention topic. Here it is enough to know the
                // setting exists and can be switched off.
                WalkthroughPoint(
                    symbol: "slider.horizontal.3",
                    text: "Settings ▸ Storage changes that window, or turns the cleanup off."),
                WalkthroughPoint(
                    symbol: "icloud",
                    text:
                        "Your library can live in iCloud Drive, in a folder you choose, or only on this iPad."),
            ],
            footnote:
                "Reopen this any time from the Help menu, or the ? button on the Home screen. "
                + "For a searchable list of every feature and shortcut, open Help ▸ Vellum Help (⌘?)."
        ),
    ]
}
