import CShell
import Foundation
import LinuxReader
import VellumCore

@MainActor
final class ReaderController {
    private let rootOverride: URL?
    private let preferences = ReaderPreferences()
    let settings = ReaderSettingsController()
    private var libraryRoot: URL?
    private var store: ReadOnlyLibraryFileStore?
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
            openLibrary(URL(fileURLWithPath: path, isDirectory: true), remember: true, window: window)
        case READER_REOPEN_LIBRARY:
            if let libraryRoot { openLibrary(libraryRoot, window: window) }
        case READER_CHANGE_PROVIDER, READER_CHECK_KEY, READER_SAVE_KEY, READER_REMOVE_KEY:
            settings.handle(event, index: entry, text: text, panel: reader_settings(window))
        case READER_SELECT:
            guard entries.indices.contains(entry), entry != selectedEntry else { return }
            resetDocument()
            selectedEntry = entry
            selection = entries[entry].file.url
            if let file = selection, file.pathExtension.lowercased() == "vellumweb" {
                showArchive(file, window: window)
            } else {
                showPage(0, window: window)
            }
        case READER_PREVIOUS:
            if pageIndex > 0 { showPage(pageIndex - 1, window: window) }
        case READER_NEXT:
            if pageIndex + 1 < pageCount { showPage(pageIndex + 1, window: window) }
        case READER_SEARCH:
            guard !entries.isEmpty else { return }
            updateSearch(String(cString: reader_search_query(window)), window: window)
        case READER_CLOSE:
            webPage = nil
            let search = searchWork
            search?.cancel()
            let pendingSettings = settings.beginClose()
            replaceWork { _ in
                await search?.value
                await pendingSettings?.value
                await PdfiumActor.shared.shutdown()
                reader_finish_close(window)
            }
        default:
            preconditionFailure("Unknown reader event")
        }
    }

    private func openLibrary(_ path: URL, remember: Bool = false, window: OpaquePointer) {
        let search = searchWork
        search?.cancel()
        searchWork = nil
        resetDocument()
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
        selectedEntry = nil
        selection = nil
        bytes = nil
        pdfTitle = nil
        pageCount = 0
        pageIndex = 0
        webPage = nil
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
        replaceWork { token in
            do {
                let metadataCatalog = try await self.catalog(in: store, token: token)
                let (resources, metadata) = try await ArchiveResourceMap.load(from: store, file: file, catalog: metadataCatalog)
                guard self.isCurrent(token) else { return }
                self.webPage = WebPageHost(stack: reader_content_stack(window), resources: resources,
                                           probe: self.webProbe) {
                    let position = metadata.position.map { position in
                        "Saved page \(position.page)" + (position.pageCount.map { " of \($0)" } ?? "")
                    }
                    reader_web_ready(window, metadata.displayTitle, position ?? "")
                }
            } catch {
                guard self.isCurrent(token) else { return }
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
                    if let catalog = try? await self.catalog(in: store, token: token),
                       let saved = try? await catalog.sharedPDF(bytes: loaded, file: file,
                                                               stamp: opening.stableIdentifier, fallbackTitle: title) {
                        title = saved.displayTitle
                        if let page = saved.lastPage, (1...opening.pageCount).contains(page) {
                            index = page - 1
                        }
                    }
                    guard self.isCurrent(token) else { return }
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
                bitmap.pixels.withUnsafeBytes { buffer in
                    reader_set_page(window, title, Int32(index + 1), Int32(info.pageCount),
                                    buffer.bindMemory(to: UInt8.self).baseAddress,
                                    Int32(bitmap.width), Int32(bitmap.height), bitmap.bytesPerRow)
                }
            } catch {
                guard self.isCurrent(token) else { return }
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
