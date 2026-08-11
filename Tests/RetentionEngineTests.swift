import Foundation
import Testing

@testable import Vellum

// The retention rule decides whether a downloaded article's bytes survive, so
// every boundary in it is worth pinning: the exact instant of expiry, what a
// read does to it, and the fact that an annotation short-circuits the whole
// calculation. Pure function, no filesystem, no `Date()`.

@Suite("Read-later retention — the 14-day clock")
struct RetentionClockTests {
    private let added = RetentionFixtures.date("2026-07-20T09:00:00.000000+00:00")

    private func verdict(daysLater: Double, policy: RetentionPolicy = .readLater)
        -> RetentionVerdict
    {
        RetentionEngine.verdict(
            addedAt: added,
            lastReadAt: nil,
            annotatedAt: nil,
            now: added.addingTimeInterval(RetentionFixtures.days(daysLater)),
            policy: policy)
    }

    @Test("An item added thirteen days ago is retained")
    func thirteenDaysRetained() {
        #expect(
            verdict(daysLater: 13)
                == .retained(until: added.addingTimeInterval(RetentionFixtures.days(14))))
    }

    /// The boundary the brief fixes as "eligible once N >= 14": fourteen days
    /// exactly is expired, not the last retained moment.
    @Test("An item added exactly fourteen days ago is expired")
    func fourteenDaysExpired() {
        #expect(
            verdict(daysLater: 14)
                == .expired(since: added.addingTimeInterval(RetentionFixtures.days(14))))
    }

    @Test("An item added a second short of fourteen days is retained")
    func oneSecondShortRetained() {
        let expiresAt = added.addingTimeInterval(RetentionFixtures.days(14))
        let now = expiresAt.addingTimeInterval(-1)
        let result = RetentionEngine.verdict(
            addedAt: added, lastReadAt: nil, annotatedAt: nil, now: now)
        #expect(result == .retained(until: expiresAt))
    }

    @Test("An item added twenty days ago is expired")
    func twentyDaysExpired() {
        #expect(
            verdict(daysLater: 20)
                == .expired(since: added.addingTimeInterval(RetentionFixtures.days(14))))
    }

    @Test("The retained verdict reports the exact instant it expires")
    func retainedCarriesExpiry() {
        guard case .retained(let until) = verdict(daysLater: 3) else {
            Issue.record("expected a retained verdict")
            return
        }
        #expect(until == RetentionEngine.expiry(addedAt: added, lastReadAt: nil))
        #expect(until == added.addingTimeInterval(14 * 86_400))
    }

    @Test("A custom policy window replaces fourteen days everywhere")
    func customWindow() {
        let policy = RetentionPolicy(window: RetentionFixtures.days(3))
        #expect(
            verdict(daysLater: 2, policy: policy)
                == .retained(until: added.addingTimeInterval(RetentionFixtures.days(3))))
        #expect(
            verdict(daysLater: 3, policy: policy)
                == .expired(since: added.addingTimeInterval(RetentionFixtures.days(3))))
        #expect(
            RetentionEngine.expiry(addedAt: added, lastReadAt: nil, policy: policy)
                == added.addingTimeInterval(RetentionFixtures.days(3)))
    }
}

@Suite("Read-later retention — reading resets the clock")
struct RetentionReadResetTests {
    private let added = RetentionFixtures.date("2026-07-20T09:00:00.000000+00:00")

    private func read(onDay day: Double) -> Date {
        added.addingTimeInterval(RetentionFixtures.days(day))
    }

    @Test("A read on day thirteen pushes expiry out to day twenty-seven")
    func readSlidesWindow() {
        let result = RetentionEngine.verdict(
            addedAt: added,
            lastReadAt: read(onDay: 13),
            annotatedAt: nil,
            now: read(onDay: 14))
        #expect(result == .retained(until: read(onDay: 27)))
    }

    /// Guards the arithmetic that would look right on day 13 and be wrong every
    /// other day: the window is measured FROM the read, not added to the
    /// original add.
    @Test("The new expiry is computed from the read, not added to the original add")
    func expiryMeasuredFromRead() {
        let expiry = RetentionEngine.expiry(addedAt: added, lastReadAt: read(onDay: 5))
        #expect(expiry == read(onDay: 19))
        #expect(expiry != added.addingTimeInterval(RetentionFixtures.days(28)))
    }

    @Test("A read after expiry restores the item for another fourteen days")
    func readAfterExpiryRestores() {
        let lateRead = read(onDay: 40)
        let result = RetentionEngine.verdict(
            addedAt: added,
            lastReadAt: lateRead,
            annotatedAt: nil,
            now: read(onDay: 41))
        #expect(result == .retained(until: read(onDay: 54)))
    }

    @Test("Repeated reads keep sliding the window from the most recent read")
    func repeatedReadsSlide() {
        for day in [2.0, 9.0, 20.0, 31.0] {
            #expect(
                RetentionEngine.expiry(addedAt: added, lastReadAt: read(onDay: day))
                    == read(onDay: day + 14))
        }
    }

    /// A `last_read_at` older than `added_at` is possible via clock skew or a
    /// provider backfill; `max` is what stops it from shortening the window.
    @Test("A read timestamped before the add date never shortens the window")
    func staleReadNeverShortens() {
        let staleRead = added.addingTimeInterval(-RetentionFixtures.days(30))
        #expect(
            RetentionEngine.expiry(addedAt: added, lastReadAt: staleRead)
                == added.addingTimeInterval(RetentionFixtures.days(14)))
        #expect(
            RetentionEngine.verdict(
                addedAt: added, lastReadAt: staleRead, annotatedAt: nil, now: read(onDay: 13))
                == .retained(until: read(onDay: 14)))
    }

    @Test("Reading never produces an expiry earlier than the add-only baseline")
    func readingIsMonotonic() {
        let baseline = RetentionEngine.expiry(addedAt: added, lastReadAt: nil)
        for offset in stride(from: -60.0, through: 60.0, by: 0.5) {
            let expiry = RetentionEngine.expiry(
                addedAt: added, lastReadAt: added.addingTimeInterval(RetentionFixtures.days(offset)))
            #expect(expiry >= baseline)
        }
    }
}

@Suite("Read-later retention — annotation exempts permanently")
struct RetentionExemptionTests {
    private let added = RetentionFixtures.date("2026-07-20T09:00:00.000000+00:00")
    private let year2200 = RetentionFixtures.date("2200-01-01T00:00:00.000000+00:00")

    @Test("An annotated item is retained with the clock set to the year 2200")
    func annotatedSurvivesTheFarFuture() {
        let result = RetentionEngine.verdict(
            addedAt: added,
            lastReadAt: nil,
            annotatedAt: added.addingTimeInterval(RetentionFixtures.days(1)),
            now: year2200)
        #expect(result == .exempt)
    }

    /// Exemption is a short-circuit, not a special case of "retained": no
    /// expiry instant is computed at all, so there is nothing to be wrong.
    @Test("Exemption short-circuits before any date math")
    func exemptionShortCircuits() {
        let epoch = Date(timeIntervalSince1970: 0)
        let result = RetentionEngine.verdict(
            addedAt: epoch,
            lastReadAt: nil,
            annotatedAt: epoch,
            now: year2200)
        #expect(result == .exempt)
        if case .expired = result { Issue.record("an annotated item must never expire") }
    }

    @Test("An annotation after several read-reset cycles still exempts permanently")
    func annotationAfterReads() {
        let result = RetentionEngine.verdict(
            addedAt: added,
            lastReadAt: added.addingTimeInterval(RetentionFixtures.days(40)),
            annotatedAt: added.addingTimeInterval(RetentionFixtures.days(41)),
            now: year2200)
        #expect(result == .exempt)
    }

    @Test("Exemption survives a policy with a zero-length window")
    func exemptionSurvivesZeroWindow() {
        let result = RetentionEngine.verdict(
            addedAt: added,
            lastReadAt: nil,
            annotatedAt: added,
            now: added,
            policy: RetentionPolicy(window: 0))
        #expect(result == .exempt)
        // ...and the same item without the annotation is expired immediately,
        // so the zero window really is in force.
        #expect(
            RetentionEngine.verdict(
                addedAt: added, lastReadAt: nil, annotatedAt: nil, now: added,
                policy: RetentionPolicy(window: 0)) == .expired(since: added))
    }

    @Test("An item annotated after it already expired becomes exempt")
    func annotationRevivesExpiredItem() {
        let now = added.addingTimeInterval(RetentionFixtures.days(30))
        #expect(
            RetentionEngine.verdict(addedAt: added, lastReadAt: nil, annotatedAt: nil, now: now)
                == .expired(since: added.addingTimeInterval(RetentionFixtures.days(14))))
        #expect(
            RetentionEngine.verdict(addedAt: added, lastReadAt: nil, annotatedAt: now, now: now)
                == .exempt)
    }
}
