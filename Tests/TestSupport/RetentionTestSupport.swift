import Foundation

@testable import Vellum

/// Shared fixtures for the read-later retention suites. Item ids are real
/// `"<provider>:<vendor id>"` shapes so the ledger's key handling is exercised
/// against ids that contain a colon.
enum RetentionFixtures {
    static let day: TimeInterval = 86_400

    static let raindrop = "raindrop:884213771"
    static let readwise = "readwise:01j9x7kqvv3"

    static func date(_ rfc3339: String) -> Date {
        guard let date = PositionTimestamp.parse(rfc3339) else {
            fatalError("fixture timestamp is not RFC3339: \(rfc3339)")
        }
        return date
    }

    static func days(_ count: Double) -> TimeInterval { count * day }

    static func scratchDirectory(_ suite: String) -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("vellum-\(suite)-tests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    static func remove(_ url: URL) {
        try? FileManager.default.removeItem(at: url)
    }

    /// Records which item ids a sweep asked to delete, across actor hops, and
    /// can be scripted to report failure for a given id.
    final class DeleterLog: @unchecked Sendable {
        private let lock = NSLock()
        private var ids: [String] = []
        private var failing: Set<String> = []

        init(failingFor failing: Set<String> = []) {
            self.failing = failing
        }

        var deletedIDs: [String] {
            lock.lock()
            defer { lock.unlock() }
            return ids
        }

        /// Synchronous, because `lock`/`unlock` are unavailable from an async
        /// context — the async closure below only ever calls this.
        private func record(_ itemID: String) -> Bool {
            lock.lock()
            defer { lock.unlock() }
            ids.append(itemID)
            return !failing.contains(itemID)
        }

        var deleter: @Sendable (String) async -> Bool {
            { [self] itemID in record(itemID) }
        }
    }
}
