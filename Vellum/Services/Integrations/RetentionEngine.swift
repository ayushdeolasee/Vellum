import Foundation

// Read-later retention, as a pure function. An item Vellum downloaded for
// offline reading keeps its bytes for a fixed window; reading it restarts the
// window; annotating it exempts it forever. The value here is not the four
// lines of arithmetic — it is that the four lines exist in exactly one place
// with a name, take `now` as a parameter, and touch nothing.
//
// This file has no I/O, no global state, and no `Date()` inside, so the
// exhaustive clock tests never go near a filesystem.

struct RetentionPolicy: Sendable, Equatable {
    var window: TimeInterval

    init(window: TimeInterval = 14 * 86_400) {
        self.window = window
    }

    static let readLater = RetentionPolicy()
}

enum RetentionVerdict: Sendable, Equatable {
    /// Annotated — permanent. No date math ran.
    case exempt
    case retained(until: Date)
    case expired(since: Date)
}

enum RetentionEngine {
    static func verdict(
        addedAt: Date,
        lastReadAt: Date?,
        annotatedAt: Date?,
        now: Date,
        policy: RetentionPolicy = .readLater
    ) -> RetentionVerdict {
        // Hard short-circuit, before any date math: an annotated item is
        // permanent regardless of how long ago it was added or read.
        if annotatedAt != nil { return .exempt }
        let expiresAt = expiry(addedAt: addedAt, lastReadAt: lastReadAt, policy: policy)
        // `>=` fixes the boundary: an item added exactly one window ago is
        // expired, not retained.
        return now >= expiresAt ? .expired(since: expiresAt) : .retained(until: expiresAt)
    }

    static func expiry(
        addedAt: Date,
        lastReadAt: Date?,
        policy: RetentionPolicy = .readLater
    ) -> Date {
        // `max` is load-bearing: reading can only ever extend the window, never
        // shorten it, even when a `last_read_at` arrives older than `added_at`
        // (clock skew, or a provider backfilling an old read).
        let base = max(addedAt, lastReadAt ?? addedAt)
        return base.addingTimeInterval(policy.window)
    }
}
