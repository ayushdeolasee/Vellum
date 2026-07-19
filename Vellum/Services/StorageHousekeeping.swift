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
    static func runCleanup(openPdfKeys: Set<String>, openWebUrls: Set<String>) async {
        guard let cutoff = evictionCutoff() else { return }
        await PageTextCache.shared.evictStale(olderThan: cutoff, excludingKeys: openPdfKeys)
        WebLibrary.evictStaleUnsavedSnapshots(olderThan: cutoff, excludingUrls: openWebUrls)
    }
}
