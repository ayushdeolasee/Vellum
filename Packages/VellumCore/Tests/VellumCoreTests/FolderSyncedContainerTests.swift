import Foundation
import Testing
@testable import VellumCore

@Suite("Shared folder conflict recovery")
struct FolderSyncedContainerTests {
    private let winner = Data("current".utf8)
    private let loser = Data("losing version".utf8)

    private struct SilentWatcher: FolderDirectoryWatching {
        func update(directories: Set<URL>, notify: @escaping @Sendable () -> Void) {}
        func stop() {}
    }

    private struct Deadline: Error {}

    private func next(_ container: FolderSyncedContainer) async throws -> ConflictEvent {
        try await withThrowingTaskGroup(of: ConflictEvent.self) { group in
            group.addTask {
                for await event in container.conflicts { return event }
                throw Deadline()
            }
            group.addTask {
                try await Task.sleep(for: .seconds(5))
                throw Deadline()
            }
            defer { group.cancelAll() }
            return try await group.next()!
        }
    }

    private func fixture(_ body: (URL, LocalFolderFileStore) async throws -> Void) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        try await body(root.standardizedFileURL, LocalFolderFileStore(root: root))
    }

    private func sibling(_ url: URL) -> URL {
        url.deletingPathExtension().appendingPathExtension("sync-conflict-20260122-151234-ALPHA")
            .appendingPathExtension(url.pathExtension)
    }

    @Test("A native event discovers live siblings in all three trees, grouped by canonical path")
    func nativeDelivery() async throws {
        try await fixture { root, store in
            let container = FolderSyncedContainer(root: root, store: store, watcher: FolderDirectoryWatcher(),
                                                   rescanInterval: .seconds(120))
            let files = [".vellum/documents/a/note.md", "PDFs/nested/paper.pdf", "Web Pages/doc.vellumweb"]
                .map { root.appendingPathComponent($0) }
            let outside = root.appendingPathComponent("unrelated/ignore.pdf")
            for file in files + [outside] { try await store.replace(file, with: winner) }
            await container.resume()
            do {
                try await store.replace(sibling(outside), with: loser)
                for (index, file) in files.enumerated() {
                    let payload = Data("loser \(index)".utf8)
                    try await store.replace(sibling(file), with: payload)
                    let event = try await next(container)
                    #expect(event.url == file)
                    #expect(event.losingVersions.map(\.originatingDeviceName) == ["ALPHA"])
                    let visible = try await container.list(file.deletingLastPathComponent())
                    #expect(visible.map(\.name) == [file.lastPathComponent])
                    let outcome = try await container.resolveConflict(event)
                    guard case .keptCurrent(let archives) = outcome else {
                        Issue.record("Expected a preserved sibling"); continue
                    }
                    #expect(archives.count == 1)
                    #expect(try Data(contentsOf: archives[0]) == payload)
                    #expect(try Data(contentsOf: file) == winner)
                    #expect(try await store.read(sibling(file)) == nil)
                }
            } catch { await container.suspend(); throw error }
            await container.suspend()
        }
    }

    @Test("Periodic/resume discovery recovers missed events; an old snapshot cannot retire a new sibling")
    func missedAndLateChanges() async throws {
        try await fixture { root, store in
            let file = root.appendingPathComponent(".vellum/records/a.json")
            let copy = sibling(file)
            let late = Data("rewritten by peer".utf8)
            let container = FolderSyncedContainer(root: root, store: store, watcher: SilentWatcher(),
                                                   rescanInterval: .milliseconds(80))
            try await store.replace(file, with: winner)
            await container.resume()
            do {
                try await store.replace(copy, with: loser)
                let first = try await next(container)
                try await store.replace(copy, with: late)
                #expect(try await container.resolveConflict(first) == .deferred)
                #expect(try await store.read(copy) == late)
                await container.suspend()
                await container.resume()
                let latest = try await next(container)
                #expect(latest.losingVersions != first.losingVersions)
                guard case .keptCurrent(let archives) = try await container.resolveConflict(latest) else {
                    throw Deadline()
                }
                #expect(try Data(contentsOf: archives[0]) == late)
            } catch { await container.suspend(); throw error }
            await container.suspend()
        }
    }

    @Test("A completed merge keeps both inputs; a canonical edit during policy evaluation wins")
    func mergeAndLateWinner() async throws {
        try await fixture { root, store in
            for race in [false, true] {
                let file = root.appendingPathComponent(".vellum/documents/\(race)/meta.json")
                let copy = sibling(file)
                let merged = Data("merged".utf8)
                try await store.replace(file, with: winner)
                try await store.replace(copy, with: loser)
                let container = FolderSyncedContainer(root: root, store: store, watcher: SilentWatcher()) { _, _ in
                    if race { try await store.replace(file, with: Data("late".utf8)) }
                    return .merged(merged)
                }
                await container.resume()
                do {
                    let event = try await next(container)
                    let outcome = try await container.resolveConflict(event)
                    if race {
                        #expect(outcome == .deferred)
                        #expect(try await store.read(copy) == loser)
                        #expect(try await store.read(file) == Data("late".utf8))
                    } else {
                        #expect(outcome == .merged(file))
                        #expect(try await store.read(file) == merged)
                        let archives = try store.contents(of: file.deletingLastPathComponent().appendingPathComponent("conflicts"))
                        #expect(try Set(archives.map { try Data(contentsOf: $0.url) }) == [winner, loser])
                    }
                } catch { await container.suspend(); throw error }
                await container.suspend()
            }
        }
    }

    @Test("Only one competing compare-and-replace succeeds across backend instances")
    func competingWrites() async throws {
        try await fixture { root, first in
            let second = LocalFolderFileStore(root: root)
            let url = root.appendingPathComponent("PDFs/paper.pdf")
            #expect(try await first.replace(url, with: winner, ifCurrent: nil))
            #expect(try await !second.replace(url, with: loser, ifCurrent: nil))
            async let a = first.replace(url, with: Data([1]), ifCurrent: winner)
            async let b = second.replace(url, with: Data([2]), ifCurrent: winner)
            let result = try await [a, b]
            #expect(result.filter { $0 }.count == 1)
            #expect(try await first.read(url) == Data([result[0] ? 1 : 2]))
            let link = root.appendingPathComponent("PDFs/link")
            try FileManager.default.createSymbolicLink(at: link, withDestinationURL: root.deletingLastPathComponent())
            await #expect(throws: LibraryFileError.self) {
                try await second.replace(link.appendingPathComponent("escaped"), with: loser)
            }
        }
    }
}
