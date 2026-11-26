import Foundation
import VellumCore

/// Owns one private copy. The library root and GTK reader have no entry point
/// here. Admission and close are ordered, including while a save is in flight.
/// Supply the creation ID so the caller can address the result. After a stale
/// save, retain the newer bytes and open a fresh disposable copy to edit them.
actor PdfEditSession {
    enum Failure: Error { case stale, closed }
    private let writer: Writer
    private let directory: URL
    nonisolated let file: URL
    private var tail: Task<Data, Error>?
    private var closing: Task<Void, Error>?

    init(disposableCopyOf original: Data) async throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        file = directory.appendingPathComponent("document.pdf")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false,
                                               attributes: [.posixPermissions: 0o700])
        do {
            try original.write(to: file, options: .withoutOverwriting)
        } catch {
            try? FileManager.default.removeItem(at: directory)
            throw error
        }
        writer = Writer(file: file, original: original)
    }

    func enqueue(_ edit: PdfAnnotationEdit, now: String) throws -> Task<Data, Error> {
        guard closing == nil else { throw Failure.closed }
        let task = Task { [tail, writer, edit] in
            _ = await tail?.result
            return try await writer.apply(edit, now: now)
        }
        tail = task
        return task
    }

    func close() async throws {
        if let closing { return try await closing.value }
        let task = Task { [tail, directory] in
            _ = await tail?.result // each admitted edit reports its own result
            try FileManager.default.removeItem(at: directory)
        }
        closing = task
        try await task.value
    }

    private actor Writer {
        let file: URL
        var original: Data
        init(file: URL, original: Data) {
            self.file = file
            self.original = original
        }

        func apply(_ edit: PdfAnnotationEdit, now: String) throws -> Data {
            let next = try PdfAnnotationIncrement.applying(edit, to: original, now: now)
            // This detects a change up to the final comparison. The private
            // copy has one writer. Shared libraries need FolderFileStore's
            // conditional exchange and displaced-file recovery (#472).
            try PdfAtomicFile.save(next, toPath: file.path) {
                guard try Data(contentsOf: file) == original else { throw Failure.stale }
            }
            original = next
            return next
        }
    }
}
