import CShell
import Foundation
import LinuxReader
import VellumCore

@MainActor
final class ReaderController {
    private let root: URL
    private var store: ReadOnlyLibraryFileStore?
    private var entries: [LibraryFileEntry] = []
    private var selection: URL?
    private var bytes: Data?
    private var pageIndex = 0
    private var pageCount = 0
    private var generation = 0
    private var work: Task<Void, Never>?

    init(root: URL) { self.root = root }

    func run() -> Int32 {
        guard shell_install_pump(SHELL_AUTO, serviceSwiftMainQueue) >= 0 else { return 1 }
        defer { shell_remove_pump() }
        return withExtendedLifetime(self) {
            reader_run({ window, event, row, context in
                precondition(shell_on_gtk_thread())
                MainActor.assumeIsolated {
                    let owner = Unmanaged<ReaderController>.fromOpaque(context!).takeUnretainedValue()
                    owner.handle(event, row: Int(row), window: window!)
                }
            }, Unmanaged.passUnretained(self).toOpaque())
        }
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

    private func handle(_ event: ReaderEvent, row: Int, window: OpaquePointer) {
        switch event {
        case READER_OPEN:
            replaceWork { token in
                do {
                    let root = try await RootDirectory.open(self.root)
                    let store = ReadOnlyLibraryFileStore(root: root)
                    let entries = try await LibraryCatalog.pdfs(in: store)
                    guard self.isCurrent(token) else { return }
                    self.store = store
                    self.entries = entries
                    for entry in entries { reader_add_row(window, entry.name) }
                    if entries.isEmpty {
                        reader_set_message(window, "Vellum", "No PDFs in this library.")
                    } else {
                        reader_select_row(window, 0)
                    }
                } catch {
                    guard self.isCurrent(token) else { return }
                    reader_set_message(window, "Vellum", "Could not open the library: \(error)")
                }
            }
        case READER_SELECT:
            guard entries.indices.contains(row) else { return }
            selection = entries[row].url
            bytes = nil
            pageCount = 0
            showPage(0, window: window)
        case READER_PREVIOUS:
            if pageIndex > 0 { showPage(pageIndex - 1, window: window) }
        case READER_NEXT:
            if pageIndex + 1 < pageCount { showPage(pageIndex + 1, window: window) }
        case READER_CLOSE:
            replaceWork { _ in
                await PdfiumActor.shared.shutdown()
                reader_finish_close(window)
            }
        default:
            preconditionFailure("Unknown reader event")
        }
    }

    private func showPage(_ index: Int, window: OpaquePointer) {
        guard let file = selection, let store else { return }
        let title = file.lastPathComponent
        pageIndex = index
        reader_set_message(window, title, "Loading page \(index + 1)…")
        if pageCount > 0 { reader_set_position(window, Int32(index + 1), Int32(pageCount)) }
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
                case PdfiumError.invalidDocument: message = "This file could not be read as a PDF."
                case ReaderFileError.fileTooLarge, PdfiumError.limitExceeded:
                    message = "This PDF exceeds the reader’s size limit."
                default: message = "Could not open page \(index + 1): \(error.localizedDescription)"
                }
                reader_set_message(window, title, message)
                if self.pageCount > 0 {
                    reader_set_position(window, Int32(index + 1), Int32(self.pageCount))
                }
            }
        }
    }
}
