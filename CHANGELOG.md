# Changelog

## Unreleased — iPhone release slice (#150)

### Included

- One universal iPhone and iPad app with phone-specific Home, reader, inspector, and tab switcher layouts.
- Continue Reading position handoff through the coordinated storage layer.
- Safari share capture through an App Group, with a 1 MiB DOM limit, URL fallback, and app-side archive creation.
- Background read-later prefetch and retention that protects opened, saved, and annotated items.
- Recent and Read Later Home Screen widgets, Lock Screen accessories, and validated App Intent/deep-link entry points.
- Local, custom-folder, and iCloud Drive coordinated storage. Live Scratchpad data follows the same coordinated storage location (#165).

### Manual verification still required

- Reader chrome taps and PDF gestures on a touch device.
- A real Safari share, including the extension-to-app payload threshold.
- A suspended-app background wake that drains the Safari capture inbox and creates the archive.
- Widget gallery and Lock Screen placement on a physical iPhone; simulator deep-link routing is covered separately.
- Real iCloud conflicts, metadata discovery, evicted downloads, and a third-party custom folder provider after iCloud cutover.

## 0.1.0 - 2026-08-24

Vellum's first macOS release.

### Reading and workspace

- Open PDFs and web articles in a native reader with scrolling, zoom, page navigation, printing, and in-document search.
- Keep several documents open in tabs, switch with keyboard shortcuts, and arrange tabs in side-by-side or stacked panes.
- Search the library by title, filename, or web address, then return to recent documents from Home.
- Choose reading and appearance defaults, follow the first-run walkthrough, and search the built-in help guide.

### Annotations and Scratchpad

- Highlight passages in multiple colors, resize highlights, add sticky notes, and bookmark PDF pages or positions in web articles.
- Browse every annotation in the inspector, pin important items, and edit bookmark titles.
- Keep an autosaving Markdown Scratchpad for each document with live formatting, inline LaTeX, images, and captured page regions.
- Store PDF annotations inside the PDF itself, keep web annotations with the saved page, and export Scratchpad notes as Markdown.

### AI assistant

- Connect your own Gemini, OpenAI API, OpenRouter, OpenCode Zen, or OpenCode Go account. AI is optional and the reading tools work without it.
- Ask questions using the current page and conversation as context, or let the assistant search other pages and existing annotations when needed.
- Let the assistant jump to a page, add a note, or highlight matching text without giving it permission to edit or delete your work.
- Reference selected text and attach the current page, a cropped region, or an image. Replies support streaming Markdown and LaTeX.

### Web and read-later libraries

- Paste an article URL to read it inside Vellum, annotate it, and save a self-contained offline `.vellumweb` copy.
- Connect Readwise Reader and Raindrop.io, browse their collections, search their items from Home, and move items between supported collections.
- Download supported articles and PDFs for offline reading, with retention that protects items you opened, saved, or annotated.
- Navigate web history, find text within a page, and preserve web notes, bookmarks, and reading positions.

### Storage, sharing, and reliability

- Choose Vellum's private app folder, iCloud Drive, or a custom folder for library data, Scratchpads, AI conversations, and reading positions.
- Export a document, its Scratchpad, and its attachments as one `.vellum` file. AI conversations are included only when you choose to share them.
- Import `.vellum` bundles without silently replacing different local notes, and export saved web pages as portable `.vellumweb` files.
- Relink moved PDFs, inspect storage use, recover destructive library removals with Undo, and check for app updates from inside Vellum.
