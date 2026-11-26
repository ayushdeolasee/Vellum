import CShell
import Foundation
import LinuxReader
import VellumCore

@MainActor
final class ReaderController {
    private let rootOverride: URL?
    private let preferences = ReaderPreferences()
    private let chat = ReaderChatController()
    let settings = ReaderSettingsController()
    private var libraryRoot: URL?
    private var store: ReadOnlyLibraryFileStore?
    private(set) var writeContext: SharedLibraryWriteContext?
    private var positionSession: ReaderPositionSession?
    private var documentKey: DocumentKey?
    private var displayedPosition: ReadingPosition?
    private var transition: Task<Void, Never>?
    private var closing = false
    private var closeRequested = false
    private var chatCloseHandled = false
    private var entries: [LibrarySearchEntry] = []
    private var selectedEntry: Int?
    private var searchWork: Task<Void, Never>?
    private var selection: URL?
    private var bytes: Data?
    private var pdfTitle: String?
    private var pageIndex = 0
    private var pageCount = 0
    private var generation = 0
    private var work: Task<Void, Never>?

    private var scratchpad: ScratchpadPane?
    private var metadataCatalog: ReaderMetadataCatalog?
    private var webPage: WebPageHost?
    private let webProbe: WebProbe?

    init(rootOverride: URL?, webProbe: WebProbe? = nil) {
        self.rootOverride = rootOverride
        self.webProbe = webProbe
    }

    func run() -> Int32 {
        guard shell_install_pump(SHELL_AUTO, serviceSwiftMainQueue) >= 0 else { return 1 }
        defer { shell_remove_pump() }
        let status = withExtendedLifetime(self) {
            reader_run({ window, event, entry, text, context in
                precondition(shell_on_gtk_thread())
                MainActor.assumeIsolated {
                    let owner = Unmanaged<ReaderController>.fromOpaque(context!).takeUnretainedValue()
                    owner.handle(event, entry: Int(entry), text: text, window: window!)
                }
            }, Unmanaged.passUnretained(self).toOpaque())
        }
        return status == 0 ? (webProbe?.result() ?? 0) : status
    }

    // Superseded reads/renders can still be unwinding on their worker. Joining
    // the predecessor also gives normal close a single handle to drain them all.
    private func replaceWork(_ operation: @escaping @MainActor (Int) async -> Void) {
        generation += 1
        let token = generation
        let prior = work
        prior?.cancel()
        work = Task {
            await prior?.value
            guard isCurrent(token) else { return }
            await operation(token)
        }
    }

    private func isCurrent(_ token: Int) -> Bool {
        generation == token && !Task.isCancelled
    }

    private func handle(_ event: ReaderEvent, entry: Int, text: UnsafePointer<CChar>?, window: OpaquePointer) {
        switch event {
        case READER_OPEN:
            replaceWork { token in
                let provider = await self.preferences.loadProvider()
                let root: URL
                if let explicit = self.rootOverride { root = explicit }
                else { root = await self.preferences.loadLibrary() }
                guard self.isCurrent(token) else { return }
                self.settings.configure(provider: provider, panel: reader_settings(window))
                self.openLibrary(root, window: window)
            }
        case READER_CHOOSE_LIBRARY:
            guard let text, let path = String(validatingCString: text), path.hasPrefix("/") else { return }
            leaveDocument(window, flushDrafts: true) {
                self.openLibrary(URL(fileURLWithPath: path, isDirectory: true), remember: true, window: window)
            }
        case READER_REOPEN_LIBRARY:
            if let libraryRoot {
                leaveDocument(window, flushDrafts: true) { self.openLibrary(libraryRoot, window: window) }
            }
        case READER_TOGGLE_EDITING:
            guard let store else { return }
            leaveDocument(window, flushDrafts: true) {
                self.changeEditing(in: store, window: window)
            }
        case READER_CHANGE_PROVIDER, READER_CHECK_KEY, READER_SAVE_KEY, READER_REMOVE_KEY:
            settings.handle(event, index: entry, text: text, panel: reader_settings(window))
        case READER_SETTINGS_DONE:
            chat.refreshProvider(settings.provider, panel: reader_chat_panel(window))
        case READER_CHAT_TOGGLE:
            chat.show(provider: settings.provider, panel: reader_chat_panel(window))
        case READER_CHAT_SEND:
            chat.send(provider: settings.provider, panel: reader_chat_panel(window))
        case READER_CHAT_DRAFT:
            chat.draftChanged(reader_chat_panel(window))
        case READER_CHAT_RETRY:
            chat.save(panel: reader_chat_panel(window))
        case READER_CHAT_STOP:
            chat.stop(panel: reader_chat_panel(window))
        case READER_SELECT:
            guard entries.indices.contains(entry), entry != selectedEntry else { return }
            leaveDocument(window, flushDrafts: false) {
                self.chat.reset(reader_chat_panel(window))
                self.resetDocument()
                self.selectedEntry = entry
                let file = self.entries[entry].file.url
                self.selection = file
                if file.pathExtension.lowercased() == "vellumweb" {
                    self.showArchive(file, window: window)
                } else {
                    self.showPage(0, window: window)
                }
            }
        case READER_PREVIOUS:
            if pageIndex > 0 { showPage(pageIndex - 1, window: window) }
        case READER_NEXT:
            if pageIndex + 1 < pageCount { showPage(pageIndex + 1, window: window) }
        case READER_SEARCH:
            guard !entries.isEmpty else { return }
            updateSearch(String(cString: reader_search_query(window)), window: window)
        case READER_CLOSE_REQUEST:
            if transition != nil { closeRequested = true; return }
            leaveDocument(window, flushDrafts: true, quitting: true) {
                self.chatCloseHandled = true
                self.webPage?.session = nil
                self.positionSession = nil
                reader_commit_close(window)
            }
        case READER_CLOSE:
            closing = true
            let changing = transition
            let search = searchWork
            search?.cancel()
            let pendingChat = chatCloseHandled ? nil : chat.drain(reader_chat_panel(window), closing: true)
            let pendingSettings = settings.beginClose()
            replaceWork { _ in
                await changing?.value
                await pendingChat?.value
                if !self.chatCloseHandled {
                    do { try await self.chat.keepForNextLaunch() }
                    catch { FileHandle.standardError.write(Data("Could not preserve chat recovery during reader shutdown.\n".utf8)) }
                }
                try? await self.flushPosition()
                _ = await self.scratchpad?.flush()
                self.webPage = nil
                await self.writeContext?.retire()
                await search?.value
                await pendingSettings?.value
                await self.scratchpad?.shutdown()
                await PdfiumActor.shared.shutdown()
                reader_finish_close(window)
            }
        default:
            preconditionFailure("Unknown reader event")
        }
    }

    private func flushPosition() async throws {
        guard let session = positionSession else { return }
        if let point = await webPage?.location() { session.moved(point) }
        try await session.flush()
    }

    private func confirmLeaving(_ window: OpaquePointer, _ kind: ReaderLeaveKind) async -> Bool {
        // The dialog always replies once, including when GTK shuts down.
        final class Reply {
            let continuation: CheckedContinuation<Bool, Never>
            init(_ continuation: CheckedContinuation<Bool, Never>) { self.continuation = continuation }
        }
        return await withCheckedContinuation { continuation in
            reader_confirm_leave(window, kind, { owner, discard in
                Unmanaged<Reply>.fromOpaque(owner!).takeRetainedValue().continuation.resume(returning: discard)
            }, Unmanaged.passRetained(Reply(continuation)).toOpaque())
        }
    }

    private func leaveDocument(_ window: OpaquePointer, flushDrafts: Bool, quitting: Bool = false, then proceed: @escaping () -> Void) {
        guard !closing, transition == nil else { return }
        let pendingChat = chat.drain(reader_chat_panel(window))
        if pendingChat == nil && positionSession == nil && scratchpad?.pendingSave == nil && (!flushDrafts || scratchpad == nil) {
            proceed()
            return
        }
        reader_set_close_pending(window, true)
        let rendering = work
        transition = Task {
            await rendering?.value
            do {
                await scratchpad?.pendingSave?.value
                await pendingChat?.value
                guard !closing else { return }
                do { try await flushPosition() }
                catch {
                    guard await confirmLeaving(window, LEAVE_POSITION) else { throw error }
                }
                if flushDrafts, await scratchpad?.flush() == false {
                    guard await confirmLeaving(window, LEAVE_SCRATCHPAD) else { throw LibraryFileError.retryable }
                    scratchpad?.discardUnsavedDrafts()
                }
                if quitting, !closing {
                    do { try await chat.keepForNextLaunch() }
                    catch {
                        guard await confirmLeaving(window, LEAVE_CHAT) else { throw error }
                    }
                }
                guard !closing else { return }
                transition = nil
                reader_set_close_pending(window, false)
                if closeRequested && !quitting {
                    closeRequested = false
                    handle(READER_CLOSE_REQUEST, entry: -1, text: nil, window: window)
                } else {
                    proceed()
                }
            } catch {
                guard !closing else { return }
                transition = nil
                closeRequested = false
                reader_set_close_pending(window, false)
                if reader_chat_visible(reader_chat_panel(window)) {
                    chat.show(provider: settings.provider, panel: reader_chat_panel(window))
                }
                let message = "Could not save changes. This document is still open."
                reader_show_status(window, message)
                reader_settings_set_library(reader_settings(window), libraryRoot?.path ?? "", message, false)
                if let selectedEntry { reader_reselect_entry(window, Int32(selectedEntry)) }
            }
        }
    }

    private func changeEditing(in store: ReadOnlyLibraryFileStore, window: OpaquePointer) {
        let panel = reader_settings(window)!
        reader_set_close_pending(window, true)
        let enabling = writeContext == nil
        transition = Task {
            defer {
                transition = nil
                if !closing {
                    reader_set_close_pending(window, false)
                    if closeRequested {
                        closeRequested = false
                        handle(READER_CLOSE_REQUEST, entry: -1, text: nil, window: window)
                    }
                }
            }
            do {
                let next = enabling ? try await SharedLibraryWriteContext.activate(root: store.root) : nil
                var message = enabling ? "Shared editing enabled for this folder." : "This folder is read only."
                do { try await preferences.saveEditing(enabling, for: store.root) }
                catch {
                    if enabling { throw error }
                    message = "Read only for this session. Could not save the setting for next launch."
                }
                await scratchpad?.shutdown()
                await writeContext?.retire()
                guard !closing else { await next?.retire(); return }
                writeContext = next
                chat.setContext(next, provider: settings.provider, panel: reader_chat_panel(window))
                let storage = await scratchpadStorage(files: store, context: next)
                guard !closing else { return }
                scratchpad = ScratchpadPane(panel: reader_scratchpad_panel(window), storage: storage)
                scratchpad?.select(documentStorageKey)
                positionSession = ReaderPositionSession(context: next, key: documentKey, restored: nil)
                webPage?.session = positionSession
                if let point = await webPage?.location() ?? displayedPosition { positionSession?.moved(point) }
                reader_set_editing(window, enabling, true)
                reader_settings_set_library(panel, store.root.url.path, message, false)
                reader_show_status(window, message)
            } catch {
                reader_settings_set_library(panel, store.root.url.path, "Could not change editing mode: \(error)", false)
            }
        }
    }

    private var documentStorageKey: String?

    private func bindPosition(key: DocumentKey?, storageKey: String?, restored: ReadingPosition?) {
        documentKey = key
        documentStorageKey = storageKey
        positionSession = ReaderPositionSession(context: writeContext, key: key, restored: restored)
        scratchpad?.select(storageKey)
    }

    private func openLibrary(_ path: URL, remember: Bool = false, window: OpaquePointer) {
        let search = searchWork
        search?.cancel()
        searchWork = nil
        chat.reset(reader_chat_panel(window))
        resetDocument()
        let oldContext = writeContext
        writeContext = nil
        reader_set_editing(window, false, false)
        store = nil
        metadataCatalog = nil
        entries = []
        libraryRoot = path
        reader_reset_search(window)
        reader_set_message(window, "Vellum", "Opening library…")
        let panel = reader_settings(window)!
        reader_settings_set_library(panel, path.path, "Opening library…", true)

        replaceWork { token in
            await search?.value
            await self.scratchpad?.shutdown()
            self.scratchpad = nil
            await oldContext?.retire()
            guard self.isCurrent(token) else { return }
            do {
                let root = try await RootDirectory.open(path)
                let store = ReadOnlyLibraryFileStore(root: root)
                let (entries, catalog) = try await LibraryCatalog.searchEntries(in: store)
                guard self.isCurrent(token) else { return }
                var message = ""
                if remember {
                    do { try await self.preferences.saveLibrary(path) }
                    catch { message = "Could not remember this folder." }
                }
                guard self.isCurrent(token) else { return }
                var context: SharedLibraryWriteContext?
                if await self.preferences.editingEnabled(for: root) {
                    do { context = try await SharedLibraryWriteContext.activate(root: root) }
                    catch { message = "Could not enable shared editing. This folder is read only." }
                }
                let storage = await self.scratchpadStorage(files: store, context: context)
                guard self.isCurrent(token) else { await context?.retire(); return }
                self.writeContext = context
                reader_set_editing(window, context != nil, true)
                self.scratchpad = ScratchpadPane(panel: reader_scratchpad_panel(window), storage: storage)
                self.store = store
                self.metadataCatalog = catalog
                self.entries = entries
                reader_settings_set_library(panel, path.path, message, false)
                self.showRows(entries.indices, window: window)
                if entries.isEmpty {
                    reader_set_message(window, "Vellum", "No documents in this library.")
                } else {
                    reader_enable_search(window)
                    reader_select_row(window, 0)
                }
            } catch {
                guard self.isCurrent(token) else { return }
                let message = "Could not open this library folder."
                reader_settings_set_library(panel, path.path, message, false)
                reader_set_message(window, "Vellum", message)
            }
        }
    }

    private func resetDocument() {
        documentKey = nil
        documentStorageKey = nil
        displayedPosition = nil
        positionSession = nil
        if writeContext != nil { metadataCatalog = nil }
        scratchpad?.beginSelection()
        selectedEntry = nil
        selection = nil
        bytes = nil
        pdfTitle = nil
        pageCount = 0
        pageIndex = 0
        webPage = nil
    }

    private func scratchpadStorage(files: ReadOnlyLibraryFileStore, context: SharedLibraryWriteContext?) async -> ScratchpadStorage {
        if let writeContext = context {
            return ScratchpadStorage(files: files, importDirectory: files.root.url) { url, data, expected in
                try await writeContext.replace(url, with: data, ifCurrent: expected)
            }
        }
        #if DEBUG && SCRATCHPAD_QUALIFICATION
        if let storage = await ScratchpadQualification.storage(files: files) { return storage }
        #endif
        return ScratchpadStorage(files: files)
    }

    private func updateSearch(_ query: String, window: OpaquePointer) {
        let prior = searchWork
        prior?.cancel()
        reader_clear_rows(window)
        if query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            showRows(entries.indices, window: window)
            return
        }

        let entries = self.entries
        searchWork = Task {
            // Join cancelled requests so rapid edits leave only one ranking pass running.
            await prior?.value
            guard !Task.isCancelled,
                  let matches = try? await LibraryCatalog.matches(in: entries, query: query),
                  !Task.isCancelled else { return }
            showRows(matches, window: window)
            if matches.isEmpty { reader_show_no_matches(window) }
        }
    }

    private func showRows(_ indexes: some Sequence<Int>, window: OpaquePointer) {
        for (row, index) in indexes.enumerated() {
            let entry = entries[index]
            reader_add_row(window, Int32(index), entry.title, entry.file.name)
            if index == selectedEntry { reader_select_row(window, Int32(row)) }
        }
    }

    private func catalog(in store: ReadOnlyLibraryFileStore, token: Int) async throws -> ReaderMetadataCatalog {
        if let metadataCatalog { return metadataCatalog }
        let loaded = try await ReaderMetadataCatalog.load(in: store)
        guard isCurrent(token) else { throw CancellationError() }
        metadataCatalog = loaded
        return loaded
    }

    private func showArchive(_ file: URL, window: OpaquePointer) {
        guard let store else { return }
        let title = file.lastPathComponent
        reader_set_message(window, title, "Opening offline archive…")
        replaceWork { [self] token in
            do {
                let metadataCatalog = try await self.catalog(in: store, token: token)
                let (resources, metadata) = try await ArchiveResourceMap.load(from: store, file: file, catalog: metadataCatalog)
                guard self.isCurrent(token) else { return }
                self.bindPosition(key: metadata.storageKey.flatMap { DocumentKey(rawValue: "web:" + $0) },
                                  storageKey: metadata.storageKey, restored: metadata.position)
                self.webPage = WebPageHost(stack: reader_content_stack(window), resources: resources,
                                           probe: self.webProbe, restoring: metadata.position, session: self.positionSession) { [weak self] visibleText in
                    guard let self, self.isCurrent(token) else { return }
                    self.chat.bind(.article(resources.hashes, key: metadata.storageKey, title: metadata.displayTitle,
                                            file: file, store: store, visibleText: visibleText),
                                   store: store, context: self.writeContext, provider: self.settings.provider,
                                   panel: reader_chat_panel(window))
                    let position = metadata.position.map { position in
                        "Saved page \(position.page)" + (position.pageCount.map { " of \($0)" } ?? "")
                    }
                    reader_web_ready(window, metadata.displayTitle, position ?? "")
                }
            } catch {
                guard self.isCurrent(token) else { return }
                self.scratchpad?.select(nil)
                reader_set_message(window, title, "Could not open archive: \(error.localizedDescription)")
            }
        }
    }

    private func showPage(_ requestedIndex: Int, window: OpaquePointer) {
        guard let file = selection, let store else { return }
        let loadingTitle = pdfTitle ?? file.lastPathComponent
        pageIndex = requestedIndex
        let message = bytes == nil ? "Opening PDF…" : "Loading page \(requestedIndex + 1)…"
        reader_page_message(window, loadingTitle, message, Int32(requestedIndex + 1), Int32(pageCount))
        replaceWork { token in
            var index = requestedIndex
            var title = loadingTitle
            do {
                let data: Data
                if let cached = self.bytes {
                    data = cached
                } else {
                    guard let loaded = try await store.read(file) else {
                        throw CocoaError(.fileNoSuchFile)
                    }
                    guard self.isCurrent(token) else { return }
                    let opening = try await PdfiumDocument.openingInfo(in: loaded)
                    guard self.isCurrent(token) else { return }
                    var restored: ReadingPosition?
                    var storageKey: String?
                    if let catalog = try? await self.catalog(in: store, token: token),
                       let saved = try? await catalog.sharedPDF(bytes: loaded, file: file,
                                                               stamp: opening.stableIdentifier, fallbackTitle: title) {
                        restored = saved.position
                        storageKey = saved.storageKey
                        title = saved.displayTitle
                        if let page = saved.lastPage, (1...opening.pageCount).contains(page) {
                            index = page - 1
                        }
                    }
                    guard self.isCurrent(token) else { return }
                    self.bindPosition(key: storageKey.map { .pdf(stableIdentifier: $0) },
                                      storageKey: storageKey, restored: restored)
                    self.pageCount = opening.pageCount
                    self.pdfTitle = title
                    self.pageIndex = index
                    self.bytes = loaded
                    data = loaded
                }
                let info = try await PdfiumDocument.pageInfo(in: data, at: index)
                guard self.isCurrent(token) else { return }
                self.pageCount = info.pageCount
                // Fit large-format pages within a bounded preview raster.
                let scale = min(2, 1600 / max(info.widthPt, info.heightPt))
                let bitmap = try await PdfiumDocument.render(in: data, at: index, scale: scale)
                guard self.isCurrent(token) else { return }
                MainActor.preconditionIsolated()
                precondition(shell_on_gtk_thread())
                let point = ReadingPosition(page: index + 1, pageCount: info.pageCount)
                self.displayedPosition = point
                self.positionSession?.moved(point)
                self.chat.bind(.pdf(data, key: self.documentStorageKey, file: file, title: title, page: index),
                               store: store, context: self.writeContext, provider: self.settings.provider,
                               panel: reader_chat_panel(window))
                bitmap.pixels.withUnsafeBytes { buffer in
                    reader_set_page(window, title, Int32(index + 1), Int32(info.pageCount),
                                    buffer.bindMemory(to: UInt8.self).baseAddress,
                                    Int32(bitmap.width), Int32(bitmap.height), bitmap.bytesPerRow)
                }
            } catch {
                guard self.isCurrent(token) else { return }
                if self.bytes == nil { self.scratchpad?.select(nil) }
                let message: String
                switch error {
                case PdfiumError.passwordRequired: message = "This PDF requires a password."
                case PdfiumError.invalidPage, PdfiumError.invalidDimensions:
                    message = "Page \(index + 1) could not be displayed."
                case PdfiumError.queueFull: message = "The PDF reader is busy. Open another file, then reopen this PDF."
                case PdfiumError.unsupportedSecurity: message = "This PDF uses an unsupported security method."
                case PdfiumError.engineFailure: message = "PDFium could not render this page."
                case LibraryFileError.io(let reason): message = "Could not read this PDF: \(reason)"
                case LibraryFileError.symbolicLink, LibraryFileError.outsideAllowedRoot:
                    message = "Open a regular PDF inside the library’s PDFs folder."
                case PdfiumError.invalidDocument: message = "This file could not be read as a PDF."
                case ReaderFileError.fileTooLarge, PdfiumError.limitExceeded:
                    message = "This PDF exceeds the reader’s size limit."
                default: message = "Could not open page \(index + 1): \(error.localizedDescription)"
                }
                reader_page_message(window, title, message, Int32(index + 1), Int32(self.pageCount))
            }
        }
    }
}
