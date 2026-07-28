import Foundation

// Retention policy for derived, re-creatable data (class C in
// plans/storage-design.html §2): the extracted-text cache and web-snapshot
// artifacts for pages the user never saved or annotated. One user-adjustable
// TTL, stored in UserDefaults, applied identically by the launch-time eviction
// pass (VellumApp) and the Storage pane's "Run Cleanup Now" button — both
// exclude currently-open documents so an in-use cache is never swept.
enum StorageHousekeeping {
    static let retentionMonthsKey = "storage.retentionMonths"
    static let defaultMonths = 6
    /// Selectable retention lengths, in months. `nil` in the picker is "Never".
    static let monthOptions = [1, 3, 6, 12]

    /// Selected retention in months, or nil for "Never" (skip eviction).
    /// Defaults to six months when the user has never chosen (design §8 default).
    static var retentionMonths: Int? {
        let defaults = UserDefaults.standard
        guard defaults.object(forKey: retentionMonthsKey) != nil else { return defaultMonths }
        let value = defaults.integer(forKey: retentionMonthsKey)
        return value <= 0 ? nil : value
    }

    /// Persist the retention choice. `nil` stores the "Never" sentinel (0).
    static func setRetentionMonths(_ months: Int?) {
        UserDefaults.standard.set(months ?? 0, forKey: retentionMonthsKey)
    }

    /// The eviction cutoff for the current policy, or nil when retention is
    /// "Never" (callers skip eviction entirely). `now` is injectable for tests.
    static func evictionCutoff(now: Date = .now) -> Date? {
        guard let months = retentionMonths else { return nil }
        return Calendar.current.date(byAdding: .month, value: -months, to: now)
    }

    /// Run the TTL eviction immediately with the current policy — the shared
    /// body of the launch sweep and the "Run Cleanup Now" button. Open documents
    /// are excluded exactly as at launch: the text cache by storage key, the web
    /// store by URL. A "Never" policy is a no-op.
    ///
    /// `measuringReclaimedBytes` is opt-in because measuring is not free: it
    /// walks the whole cache index and every web record twice (and
    /// `listSnapshotStorage` asks iCloud to re-download evicted records as a
    /// side effect). Only "Run Cleanup Now" shows the number, so the launch
    /// sweep leaves it off and gets 0.
    @discardableResult
    static func runCleanup(
        openPdfKeys: Set<String>,
        openWebUrls: Set<String>,
        measuringReclaimedBytes: Bool = false
    ) async -> Int64 {
        guard let cutoff = evictionCutoff() else { return 0 }
        let before = measuringReclaimedBytes ? await derivedByteTotal() : 0
        await PageTextCache.shared.evictStale(olderThan: cutoff, excludingKeys: openPdfKeys)
        WebLibrary.evictStaleUnsavedSnapshots(olderThan: cutoff, excludingUrls: openWebUrls)
        guard measuringReclaimedBytes else { return 0 }
        return max(0, before - await derivedByteTotal())
    }

    /// Total on-disk size of the two evictable stores (class C data).
    private static func derivedByteTotal() async -> Int64 {
        let cache = await PageTextCache.shared.listEntries().reduce(Int64(0)) { $0 + $1.byteSize }
        let web = WebLibrary.listSnapshotStorage().reduce(Int64(0)) { $0 + $1.byteSize }
        return cache + web
    }
}
