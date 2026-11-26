import Foundation
import LinuxReader
import VellumCore

@MainActor
final class ReaderPositionSession {
    private let context: SharedLibraryWriteContext
    private let key: DocumentKey
    private let failed: () -> Void
    private var saved: ReadingPosition?
    private var latest: (point: ReadingPosition, time: Date)?
    private var timer: Task<Void, Never>?
    private var draining = false
    private var write: Task<Void, Error>?

    init?(context: SharedLibraryWriteContext?, key: DocumentKey?, restored: ReadingPosition?,
          failed: @escaping () -> Void) {
        guard let context, let key else { return nil }
        self.context = context
        self.key = key
        self.failed = failed
        saved = restored
    }

    func moved(_ position: ReadingPosition) {
        guard latest?.point != position else { return }
        latest = (position, .now)
        guard timer == nil, !draining else { return }
        timer = Task {
            try? await Task.sleep(for: .milliseconds(350))
            guard !Task.isCancelled else { return }
            do { try await commitLatest() } catch { failed() }
            timer = nil
        }
    }

    func flush() async {
        draining = true
        defer { draining = false }
        let pending = timer
        pending?.cancel()
        await pending?.value
        timer = nil
        do { try await commitLatest() } catch { failed() }
    }

    private func commitLatest() async throws {
        while true {
            if let write { try await write.value; continue }
            guard let value = latest, value.point != saved else { return }
            let next = Task {
                defer { self.write = nil }
                try await context.savePosition(value.point, for: key, at: value.time)
                saved = value.point
            }
            write = next
            try await next.value
        }
    }
}
