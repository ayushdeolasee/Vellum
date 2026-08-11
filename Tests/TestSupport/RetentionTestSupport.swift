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

    /// The offline half of autopull, scripted. Records what the prefetcher
    /// asked for so the wiring can be asserted without a network, a WKWebView
    /// or a provider account.
    actor OfflineStoreDouble: ReadLaterOfflineStoring {
        private(set) var storeCalls: [String] = []
        private(set) var removeCalls: [String] = []
        private var present: Set<String>
        private var exempt: Set<String>
        private var failing: [String: any Error]
        private var refusingRemoval: Set<String>
        private let bytes: Int
        private let storeStarted: IntegrationTestGate?
        private let storeRelease: IntegrationTestGate?

        init(
            present: Set<String> = [],
            exempt: Set<String> = [],
            failing: [String: any Error] = [:],
            refusingRemoval: Set<String> = [],
            bytes: Int = 4_096,
            storeStarted: IntegrationTestGate? = nil,
            storeRelease: IntegrationTestGate? = nil
        ) {
            self.present = present
            self.exempt = exempt
            self.failing = failing
            self.refusingRemoval = refusingRemoval
            self.bytes = bytes
            self.storeStarted = storeStarted
            self.storeRelease = storeRelease
        }

        func setExempt(_ ids: Set<String>) { exempt = ids }

        func hasOfflineCopy(for item: ReadLaterItem) async -> Bool { present.contains(item.id) }

        func storeOfflineCopy(for item: ReadLaterItem) async throws -> Int {
            storeCalls.append(item.id)
            await storeStarted?.open()
            await storeRelease?.wait()
            if let error = failing[item.id] { throw error }
            present.insert(item.id)
            return bytes
        }

        func isExempt(_ item: ReadLaterItem) async -> Bool { exempt.contains(item.id) }

        func removeOfflineCopy(
            for item: ReadLaterItem, openDocumentPaths: Set<String>
        ) async -> Bool {
            removeCalls.append(item.id)
            guard !refusingRemoval.contains(item.id) else { return false }
            present.remove(item.id)
            return true
        }

        func removeOfflineCopy(
            forItemID itemID: String,
            sourceURL: String?,
            openDocumentPaths: Set<String>
        ) async -> Bool {
            removeCalls.append(itemID)
            guard !refusingRemoval.contains(itemID) else { return false }
            present.remove(itemID)
            return true
        }
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
