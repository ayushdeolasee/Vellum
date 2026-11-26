import Foundation
import LinuxReader
import VellumCore

/// Owned by one displayed document in one open library. Coalesce scroll events
/// while a previous save runs and let navigation force the latest sample to disk.
@MainActor
final class ReaderPositionSession {
    private let context: SharedLibraryWriteContext
    private let key: DocumentKey
    private var saved: ReadingPosition?
    private var latest: ReadingPosition?
    private var timer: Task<Void, Never>?
    private var write: Task<Void, Error>?

    init?(context: SharedLibraryWriteContext?, key: DocumentKey?, restored: ReadingPosition?) {
        guard let context, let key else { return nil }
        self.context = context
        self.key = key
        saved = restored
    }

    func moved(_ position: ReadingPosition) {
        guard latest != position else { return }
        latest = position
        guard timer == nil else { return }
        timer = Task {
            try? await Task.sleep(for: .milliseconds(350))
            guard !Task.isCancelled else { return }
            timer = nil
            try? await flush()
        }
    }

    func flush() async throws {
        timer?.cancel()
        timer = nil
        while true {
            if let write {
                try await write.value
                continue
            }
            guard let value = latest, value != saved else { return }
            let next = Task {
                defer { self.write = nil }
                try await context.savePosition(value, for: key)
                saved = value
            }
            write = next
            try await next.value
        }
    }
}
