import Foundation

// The Help centre's reference content, kept as data next to the walkthrough's
// for the same reason: the copy is the feature, so it gets unit tests rather
// than being buried in a view body.
//
// The division of labour between the two is deliberate. The walkthrough is a
// narrative — six pages, read once, in order, answering "what is this app".
// This is a lookup table — answering "what was that shortcut" six weeks later.
// Neither repeats the other's job: the walkthrough never lists shortcuts
// exhaustively, and no topic here tries to teach a workflow.
//
// Every claim below was checked against the command that implements it. When a
// shortcut moves, this file moves with it.

/// One entry in the searchable Help centre.
struct HelpTopic: Identifiable, Sendable, Equatable {
    /// Stable slug; also the suffix of the row's accessibility identifier.
    let id: String
    let title: String
    /// SF Symbol for the row. Validated by `HelpCenterTests` — an unresolvable
    /// name renders as an invisible gap rather than failing loudly.
    let symbol: String
    /// One or two sentences. Long enough to answer the question, short enough
    /// that a filtered list stays skimmable.
    let summary: String
    /// Written exactly as the menu shows it, or nil when the feature has no key
    /// equivalent. Rendered as a `Keycap`, the same component the walkthrough
    /// and the welcome screen use.
    var shortcut: String?
    /// Extra search terms that are not in the title or summary — the words
    /// someone would actually type. "sidebar" for the inspector, "url" for a
    /// webpage. Without these, search only finds text the user can already see.
    var keywords: [String] = []

    /// Everything a query is matched against, lowercased once at the call site
    /// of `search` rather than per term.
    fileprivate var searchableText: String {
        ([title, summary, shortcut ?? ""] + keywords).joined(separator: " ").lowercased()
    }

    /// Filters the catalogue. All terms must match (AND, not OR) so adding a
    /// word narrows the list the way every other search field on the Mac does;
    /// an empty query returns everything rather than nothing.
    static func search(_ query: String) -> [HelpTopic] {
        let terms = query.lowercased().split(whereSeparator: \.isWhitespace).map(String.init)
        guard !terms.isEmpty else { return all }
        return all.filter { topic in
            let haystack = topic.searchableText
            return terms.allSatisfy(haystack.contains)
        }
    }

    static let all: [HelpTopic] = [
        HelpTopic(
            id: "open-pdf",
            title: "Open a PDF",
            symbol: "doc",
            summary: "Open one or several PDFs at once. Vellum bundles and saved web pages open the same way.",
            shortcut: "⌘O",
            keywords: ["file", "import", "document"]),
        HelpTopic(
            id: "open-web",
            title: "Add a web page",
            symbol: "globe",
            summary: "Opens the Add Webpage sheet. Paste an article URL and Vellum reads it here rather than in a browser.",
            shortcut: "⌘L",
            keywords: ["url", "article", "link", "browser", "internet"]),
        HelpTopic(
            id: "phone-home",
            title: "Use Home on iPhone",
            symbol: "house",
            summary: "Search titles, filenames, and web addresses from Home. Open a result, add a webpage, or use Continue Reading to resume from its last saved position.",
            shortcut: nil,
            keywords: ["phone", "library", "search", "recent", "resume", "handoff"]),
        HelpTopic(
            id: "phone-reader",
            title: "Use the iPhone reader",
            symbol: "iphone",
            summary: "Tap the page indicator to jump in a PDF. The bottom bar also holds bookmarks, the sticky-note tool, the inspector, open documents, and More actions.",
            shortcut: nil,
            keywords: ["phone", "chrome", "page", "toolbar", "controls", "jump"]),
        HelpTopic(
            id: "new-tab",
            title: "New tab",
            symbol: "plus.rectangle.on.rectangle",
            summary: "Opens a fresh start page in a new tab, leaving what you are reading where it is.",
            shortcut: "⌘T",
            keywords: ["start page", "welcome", "library"]),
        HelpTopic(
            id: "switch-tabs",
            title: "Switch between tabs",
            symbol: "rectangle.on.rectangle",
            summary: "On iPhone, open the card switcher to choose or close a document; its + returns to Home to open another. With a keyboard, jump with ⌘1 through ⌘9 or cycle with ⌘⇧[ and ⌘⇧]. Cycling wraps around.",
            shortcut: "⌘1–⌘9",
            keywords: ["cycle", "next", "previous", "navigate", "phone", "cards", "close"]),
        HelpTopic(
            id: "split-right",
            title: "Split the pane right",
            symbol: "rectangle.split.2x1",
            summary: "Puts a second document beside the focused pane. Tabs can be dragged between panes.",
            shortcut: "⌘\\",
            keywords: ["compare", "side by side", "pane", "two documents"]),
        HelpTopic(
            id: "split-down",
            title: "Split the pane down",
            symbol: "rectangle.split.1x2",
            summary: "Puts a second document below the focused pane.",
            shortcut: "⌘⌥\\",
            keywords: ["compare", "stacked", "pane"]),
        HelpTopic(
            id: "find",
            title: "Find in the document",
            symbol: "magnifyingglass",
            summary: "Searches the current PDF or web page. Step forward with ⌘G and back with ⌘⇧G.",
            shortcut: "⌘F",
            keywords: ["search", "text", "next", "previous"]),
        HelpTopic(
            id: "note-mode",
            title: "Drop a sticky note",
            symbol: "note.text",
            // Bare N, not ⌘N: `.toggleNoteMode` is registered in the iPad
            // shortcut catalogue with an empty modifier set, and it is
            // suppressed while a text field has focus.
            summary: "Press N to enter note mode, then tap anywhere on the page. Press N again to go back to reading.",
            shortcut: "N",
            keywords: ["annotation", "comment", "sticky", "margin"]),
        HelpTopic(
            id: "highlight",
            title: "Highlight a passage",
            symbol: "highlighter",
            summary: "Select text and choose a highlight from the popover, or turn the selection into a note. Everything you mark is listed in the Annotations tab.",
            shortcut: nil,
            keywords: ["annotation", "mark", "select", "selection"]),
        HelpTopic(
            id: "bookmark",
            title: "Bookmark where you are",
            symbol: "bookmark",
            summary: "Remembers the current PDF page or web page position. Bookmarks list alongside your highlights and notes, and carry no page content of their own.",
            shortcut: "⌘D",
            keywords: ["save position", "place", "resume"]),
        HelpTopic(
            id: "inspector",
            title: "Show or hide the inspector",
            symbol: "sidebar.right",
            summary: "Annotations, AI, and Scratchpad share one inspector. It is a draggable pull-up sheet on iPhone and a side panel on iPad and Mac.",
            shortcut: "⌘⌥S",
            keywords: ["sidebar", "panel", "sheet", "phone", "annotations", "ai", "scratchpad"]),
        HelpTopic(
            id: "scratchpad",
            title: "Scratchpad",
            symbol: "square.and.pencil",
            summary: "A Markdown notebook per document, in the inspector. It renders as you type, handles inline LaTeX, and saves itself.",
            shortcut: nil,
            keywords: ["notes", "markdown", "latex", "writing", "notebook"]),
        HelpTopic(
            id: "ai-setup",
            title: "Connect an AI model",
            symbol: "sparkles",
            // The five key-based providers plus the one OAuth provider, named
            // exactly as AiProviderOption.all labels them.
            summary: "Everything else in Vellum works without this. In Settings ▸ AI, paste a key for Gemini, the OpenAI API, OpenRouter, OpenCode Zen or OpenCode Go, or sign in to \"ChatGPT (Codex)\" through your browser to use an existing ChatGPT subscription.",
            shortcut: nil,
            keywords: ["provider", "api key", "gemini", "openai", "openrouter", "opencode", "chatgpt", "codex", "model", "llm"]),
        HelpTopic(
            id: "ai-context",
            title: "What the AI is sent",
            symbol: "lock.shield",
            // Verified against AiPrompts.buildContextBlock (title, total pages,
            // current page, current-page text and annotations, visible pages),
            // buildConversationBlock (last 10 messages), and
            // AiStore.shouldAutoAttachPageImage (page text under 200
            // characters). Tool-assisted turns can additionally pull other
            // pages via searchDocument / getPageText / getAnnotations.
            summary: "A request carries your prompt, the recent conversation, and context from the page you are on: the document title, which pages are visible, and that page's text and annotations. When a page has almost no extractable text, an image of it is included instead. If you ask the assistant to search, it can pull excerpts and annotations from other pages too. Reference chips show only what you attached yourself.",
            shortcut: nil,
            keywords: ["privacy", "sent", "data", "context", "transmitted", "provider", "chips"]),
        HelpTopic(
            id: "ai-actions",
            title: "What the AI can change",
            symbol: "hand.tap",
            summary: "The assistant can jump to a page, add a note, and highlight text it finds. It cannot delete or edit anything you wrote.",
            shortcut: nil,
            keywords: ["tools", "agent", "edit", "actions", "write"]),
        HelpTopic(
            id: "ask-ai",
            title: "Ask AI about a selection",
            symbol: "quote.opening",
            summary: "Select a passage and pick \"Ask AI about this\" from the popover to quote it into the composer. The assistant's replies can be quoted back the same way.",
            shortcut: nil,
            keywords: ["quote", "selection", "reference", "chip", "cite"]),
        HelpTopic(
            id: "offline",
            title: "Saved and offline web pages",
            symbol: "externaldrive",
            summary: "Saving a web page keeps an offline snapshot of it. Bookmarking one only records your position — the page itself is fetched again next time.",
            shortcut: nil,
            keywords: ["snapshot", "archive", "library", "cache", "storage"]),
        HelpTopic(
            id: "safari-share",
            title: "Save from Safari",
            symbol: "safari",
            summary: "Share a webpage to Vellum. The extension hands it to the app, which creates the offline archive; pages over the conservative 1 MiB DOM limit fall back to fetching the shared URL.",
            shortcut: nil,
            keywords: ["capture", "share extension", "app group", "webpage", "offline", "xpc"]),
        HelpTopic(
            id: "retention",
            title: "What Vellum deletes",
            symbol: "clock.arrow.circlepath",
            // Kept in step with StorageHousekeeping by
            // testRetentionTopicMatchesTheShippedPolicy.
            summary: "Only things it can rebuild: offline copies of web pages and cached extracted text, for pages you have not opened in six months and never saved or annotated. Your highlights, notes, bookmarks and reading positions are never swept. Settings ▸ Storage changes the window to 1, 3, 6 or 12 months, or Never.",
            shortcut: nil,
            keywords: ["retention", "cleanup", "eviction", "housekeeping", "six months", "purge"]),
        HelpTopic(
            id: "storage-location",
            title: "Where your library lives",
            symbol: "icloud",
            // Three modes, matching WebStorageMode: .icloud / .custom / .local.
            summary: "Choose local storage, iCloud Drive, or a folder you control. Scratchpad notes, AI conversations, and reading positions sync in iCloud mode; builds without the iCloud entitlement stay local. Settings ▸ Storage shows the active location.",
            shortcut: nil,
            keywords: ["icloud", "folder", "sync", "location", "move", "disk", "entitlement", "scratchpad"]),
        HelpTopic(
            id: "export",
            title: "Export a document",
            symbol: "square.and.arrow.up",
            // Real menu titles from ToolbarView's overflow menu — not
            // paraphrases. "Export a Copy…" is web-only.
            summary: "\"Export with Notes…\" packs the document, your Scratchpad and its attachments into one .vellum file; sharing the AI conversation with it is a separate checkbox, off by default. For a web page, \"Export a Copy…\" writes a self-contained .vellumweb archive.",
            shortcut: nil,
            keywords: ["share", "backup", "vellum bundle", "vellumweb", "archive", "portable"]),
        HelpTopic(
            id: "settings",
            title: "Settings",
            symbol: "gearshape",
            summary: "Appearance, reading, annotation, AI, and storage defaults.",
            shortcut: "⌘,",
            keywords: ["preferences", "options", "configure"]),
        HelpTopic(
            id: "walkthrough",
            title: "Replay the walkthrough",
            symbol: "book.pages",
            summary: "The six-page tour Vellum shows on first launch. Help ▸ Vellum Walkthrough reopens it at any time.",
            shortcut: nil,
            keywords: ["tour", "onboarding", "first run", "intro", "getting started"]),
    ]
}
