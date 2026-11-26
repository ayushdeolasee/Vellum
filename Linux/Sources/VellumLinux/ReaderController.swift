import CShell
import Foundation
import LinuxReader
import VellumCore

@MainActor
final class ReaderController {
    private let root: URL
    private var store: ReadOnlyLibraryFileStore?
    private var entries: [LibrarySearchEntry] = []
    private var selectedEntry: Int?
    private var searchWork: Task<Void, Never>?
    private var selection: URL?
    private var bytes: Data?
    private var pageIndex = 0
    private var pageCount = 0
    private var generation = 0
    private var work: Task<Void, Never>?

    private var metadataCatalog: ReaderMetadataCatalog?
    private var webPage: WebPageHost?
    private let webProbe: WebProbe?

    init(root: URL, webProbe: WebProbe? = nil) {
        self.root = root
        self.webProbe = webProbe
    }

    func run() -> Int32 {
        guard shell_install_pump(SHELL_AUTO, serviceSwiftMainQueue) >= 0 else { return 1 }
        defer { shell_remove_pump() }
        let status = withExtendedLifetime(self) {
            reader_run({ window, event, entry, context in
                precondition(shell_on_gtk_thread())
                MainActor.assumeIsolated {
                    let owner = Unmanaged<ReaderController>.fromOpaque(context!).takeUnretainedValue()
                    owner.handle(event, entry: Int(entry), window: window!)
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

    private func handle(_ event: ReaderEvent, entry: Int, window: OpaquePointer) {
        switch event {
        case READER_OPEN:
            replaceWork { token in
                do {
                    let root = try await RootDirectory.open(self.root)
                    let store = ReadOnlyLibraryFileStore(root: root)
                    let catalog = try await ReaderMetadataCatalog.load(in: store)
                    let entries = try await LibraryCatalog.searchEntries(in: store, metadata: catalog)
                    guard self.isCurrent(token) else { return }
                    self.store = store
                    self.metadataCatalog = catalog
                    self.entries = entries
                    self.showRows(entries.indices, window: window)
                    if entries.isEmpty {
                        reader_set_message(window, "Vellum", "No documents in this library.")
                    } else {
                        reader_enable_search(window)
                        reader_select_row(window, 0)
                    }
                } catch {
                    guard self.isCurrent(token) else { return }
                    reader_set_message(window, "Vellum", "Could not open the library: \(error)")
                }
            }
        case READER_SELECT:
            guard entries.indices.contains(entry), entry != selectedEntry else { return }
            selectedEntry = entry
            selection = entries[entry].file.url
            bytes = nil
            pageCount = 0
            pageIndex = 0
            webPage = nil
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
            updateSearch(String(cString: reader_search_query(window)), window: window)
        case READER_CLOSE:
            webPage = nil
            let search = searchWork
            search?.cancel()
            replaceWork { _ in
                await search?.value
                await PdfiumActor.shared.shutdown()
                reader_finish_close(window)
            }
        default:
            preconditionFailure("Unknown reader event")
        }
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

    private func showArchive(_ file: URL, window: OpaquePointer) {
        guard let store, let metadataCatalog else { return }
        let title = file.lastPathComponent
        reader_set_message(window, title, "Opening offline archive…")
        replaceWork { token in
            do {
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

    private func showPage(_ index: Int, window: OpaquePointer) {
        guard let file = selection, let store else { return }
        let title = file.lastPathComponent
        pageIndex = index
        reader_page_message(window, title, "Loading page \(index + 1)…", Int32(index + 1), Int32(pageCount))
        replaceWork { token in
            do {
                let data: Data
                if let cached = self.bytes {
                    data = cached
                } else {
                    guard let loaded = try await store.read(file) else {
                        throw CocoaError(.fileNoSuchFile)
                    }
                    guard self.isCurrent(token) else { return }
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
