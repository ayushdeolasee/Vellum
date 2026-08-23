import Foundation
import Testing

@testable import Vellum

// The prefetch decision rules, tested where they are pure. Nothing here touches
// a network, a disk or a clock — the planner takes the facts as arguments,
// exactly as `RetentionEngine` takes `now`.

@Suite("Read-later autopull — what a run decides to download")
struct ReadLaterPrefetchPlannerTests {
    private let base = RetentionFixtures.date("2026-08-02T09:00:00.000000+00:00")

    private func item(
        _ id: String, kind: ReadLaterKind = .article, savedOffset: TimeInterval = 0
    ) throws -> ReadLaterItem {
        try makeIntegrationItem(
            provider: .readwise, id: id, updatedAt: base.addingTimeInterval(savedOffset),
            kind: kind)
    }

    private func plan(
        _ items: [ReadLaterItem],
        isEnabled: Bool = true,
        policy: ReadLaterPrefetchPolicy = .foreground,
        backedOff: Set<IntegrationProvider> = [],
        facts: [String: ReadLaterPrefetchFacts] = [:]
    ) -> ReadLaterPrefetchPlan {
        ReadLaterPrefetchPlanner.plan(
            items: items, isEnabled: isEnabled, policy: policy, backedOffProviders: backedOff,
            facts: { facts[$0.id] ?? ReadLaterPrefetchFacts() })
    }

    @Test("An untouched article is downloaded")
    func fetchesFreshArticle() throws {
        let article = try item("a")
        let result = plan([article])
        #expect(result.fetch.map(\.id) == [article.id])
        #expect(result.decision(for: article.id)?.isFetch == true)
    }

    @Test("Nothing is downloaded while the setting is off")
    func disabledDownloadsNothing() throws {
        let result = plan([try item("a"), try item("b", kind: .pdf)], isEnabled: false)
        #expect(result.fetch.isEmpty)
        #expect(result.skipCount(.disabled) == 2)
    }

    @Test("Kinds Vellum cannot open offline are never downloaded")
    func unsupportedKindsAreSkipped() throws {
        let result = plan([
            try item("video", kind: .video),
            try item("epub", kind: .epub),
            try item("other", kind: .other),
            try item("pdf", kind: .pdf),
        ])
        #expect(result.fetch.map(\.id) == ["readwise:pdf"])
        #expect(result.skipCount(.unsupportedKind) == 3)
    }

    @Test("An item whose copy is already on disk is left alone")
    func alreadyOfflineIsSkipped() throws {
        let article = try item("a")
        let result = plan(
            [article], facts: [article.id: ReadLaterPrefetchFacts(hasOfflineCopy: true)])
        #expect(result.fetch.isEmpty)
        #expect(result.decision(for: article.id)?.skip == .alreadyOffline)
    }

    /// The rule that keeps retention from becoming a re-download loop.
    @Test("An item retention already expired is not silently downloaded again")
    func evictedItemIsNotRefetched() throws {
        let article = try item("a")
        let result = plan([article], facts: [article.id: ReadLaterPrefetchFacts(wasEvicted: true)])
        #expect(result.fetch.isEmpty)
        #expect(result.decision(for: article.id)?.skip == .expiredOnce)
    }

    @Test("Already-offline outranks expired-once, so a copy that is here is never called evicted")
    func presenceOutranksEviction() throws {
        let article = try item("a")
        let result = plan(
            [article],
            facts: [article.id: ReadLaterPrefetchFacts(hasOfflineCopy: true, wasEvicted: true)])
        #expect(result.decision(for: article.id)?.skip == .alreadyOffline)
    }

    @Test("The item cap bounds one run, and the newest saves win the slots")
    func itemCapKeepsNewest() throws {
        let items = try (0..<6).map { try item("i\($0)", savedOffset: Double($0) * 3600) }
        let result = plan(items, policy: ReadLaterPrefetchPolicy(maximumItems: 2))
        #expect(result.fetch.map(\.id) == ["readwise:i5", "readwise:i4"])
        #expect(result.skipCount(.itemBudget) == 4)
    }

    @Test("The byte budget stops planning once the estimate is spent")
    func byteBudgetStopsPlanning() throws {
        let items = try (0..<4).map {
            try item("p\($0)", kind: .pdf, savedOffset: Double($0) * 3600)
        }
        // Two 6 MB estimates fit in 13 MB; the third does not.
        let result = plan(
            items,
            policy: ReadLaterPrefetchPolicy(maximumItems: 10, maximumBytes: 13 * 1024 * 1024))
        #expect(result.fetch.count == 2)
        #expect(result.skipCount(.byteBudget) == 2)
    }

    /// Otherwise a single item larger than the budget could never be fetched.
    @Test("An item bigger than the whole budget still runs when it is first")
    func oversizedFirstItemStillRuns() throws {
        let pdf = try item("big", kind: .pdf)
        let result = plan(
            [pdf], policy: ReadLaterPrefetchPolicy(maximumItems: 3, maximumBytes: 1_000))
        #expect(result.fetch.map(\.id) == [pdf.id])
    }

    @Test("A known previous size is preferred over the per-kind estimate")
    func recordedSizeBeatsEstimate() throws {
        let article = try item("a")
        let result = plan(
            [article],
            policy: ReadLaterPrefetchPolicy(maximumItems: 5, maximumBytes: 200_000),
            facts: [article.id: ReadLaterPrefetchFacts(estimatedBytes: 120_000)])
        #expect(result.estimatedBytes == 120_000)
        #expect(result.fetch.count == 1)
    }

    @Test("A rate-limited provider is skipped without touching the other one")
    func backedOffProviderIsSkipped() throws {
        let readwise = try item("a")
        let raindrop = try makeIntegrationItem(provider: .raindrop, id: "b", updatedAt: base)
        let result = plan([readwise, raindrop], backedOff: [.readwise])
        #expect(result.fetch.map(\.id) == [raindrop.id])
        #expect(result.decision(for: readwise.id)?.skip == .providerBackedOff)
    }

    @Test("The background policy is strictly smaller than the foreground one")
    func backgroundPolicyIsSmaller() {
        #expect(ReadLaterPrefetchPolicy.background.maximumItems
            < ReadLaterPrefetchPolicy.foreground.maximumItems)
        #expect(ReadLaterPrefetchPolicy.background.maximumBytes
            < ReadLaterPrefetchPolicy.foreground.maximumBytes)
    }

    @Test("Every item gets exactly one decision, whatever it is")
    func everyItemIsAccountedFor() throws {
        let items = try [
            item("a"), item("b", kind: .video), item("c", kind: .pdf), item("d"),
        ]
        let result = plan(items, policy: ReadLaterPrefetchPolicy(maximumItems: 1))
        #expect(result.decisions.count == items.count)
        #expect(Set(result.decisions.keys) == Set(items.map(\.id)))
        #expect(result.fetch.count == 1)
    }
}
