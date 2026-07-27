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
            summary:
                "Highlights and notes work the same way on a PDF and on a web page. In a PDF they "
                + "are written into the file itself when you save; on a web page they are kept with "
                + "the page in your library.",
            points: [
                WalkthroughPoint(
                    symbol: "highlighter",
                    text: "Select text and pick a colour — yellow, green, blue, pink, or purple."),
                WalkthroughPoint(
                    symbol: "note.text",
                    text: "Press N for note mode, then click anywhere on the page to drop a sticky note.",
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
                    text: "Snapshot a region of the page into your notes, or drop in an image from Finder."),
                WalkthroughPoint(
                    symbol: "arrow.up.doc",
                    text:
                        "\"Export with Notes…\" packs the document, your notes and attachments into one "
                        + ".vellum file. Sharing the AI conversation is a separate checkbox, off by default."),
            ]
        ),

        WalkthroughPage(
            id: "connect",
            symbol: "sparkles",
            title: "Connect an AI model",
            summary:
                "Vellum ships no model of its own — you bring your own account, and nothing is sent "
                + "anywhere until you do. Set it up in the inspector's AI tab, or in Settings ▸ AI.",
            points: [
                WalkthroughPoint(
                    symbol: "key",
                    text:
                        "Paste an API key for Gemini, the OpenAI API, OpenRouter, OpenCode Zen, "
                        + "or OpenCode Go."),
                WalkthroughPoint(
                    symbol: "person.crop.circle.badge.checkmark",
                    text:
                        "Or choose \"ChatGPT (Codex)\" and sign in through your browser — nothing to paste."),
                WalkthroughPoint(
                    symbol: "lock.shield",
                    text: "Credentials go into the macOS Keychain, never into a settings file."),
                WalkthroughPoint(
                    symbol: "slider.horizontal.3",
                    text:
                        "Pick a model from the selector and star the ones you use. OpenRouter's catalogue "
                        + "loads live, with pricing and context length."),
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
                WalkthroughPoint(
                    symbol: "hand.tap",
                    text:
                        "It can jump to a page, add a note, and highlight text it finds — capped at five "
                        + "changes per reply, so it can't run away with your document."),
                WalkthroughPoint(
                    symbol: "quote.opening",
                    text:
                        "Select a passage and choose \"Ask AI about this\" to quote it into the composer. "
                        + "Its replies can be quoted back the same way."),
                WalkthroughPoint(
                    symbol: "photo",
                    text:
                        "Attach the current page, a cropped region, or an image file. Images only — "
                        + "anything else is named back to you instead of vanishing."),
            ]
        ),

        WalkthroughPage(
            id: "storage",
            symbol: "externaldrive",
            title: "Where your work lives",
            summary:
                "Vellum splits your data in two: the things you made, which it never deletes on its "
                + "own, and the things it can rebuild, which it tidies up.",
            points: [
                WalkthroughPoint(
                    symbol: "checkmark.seal",
                    text:
                        "Kept indefinitely: highlights, notes, bookmarks, reading positions, saved pages, "
                        + "and AI conversations. Only you delete these."),
                WalkthroughPoint(
                    symbol: "clock.arrow.circlepath",
                    text:
                        "Tidied up: offline copies of web pages and extracted text. By default Vellum "
                        + "clears these for pages you haven't opened in six months — and only for pages "
                        + "you never saved or annotated."),
                WalkthroughPoint(
                    symbol: "slider.horizontal.3",
                    text:
                        "Settings ▸ Storage sets that window to 1, 3, 6 or 12 months, or Never, and can "
                        + "run a cleanup on demand."),
                WalkthroughPoint(
                    symbol: "icloud",
                    text:
                        "Your library can live in iCloud Drive, in a folder you choose, or only on this Mac."),
            ],
            footnote: "You can reopen this any time from Help ▸ Vellum Walkthrough."
        ),
    ]
}
