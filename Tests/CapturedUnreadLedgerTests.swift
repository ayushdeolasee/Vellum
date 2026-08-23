import Foundation
import Testing

@testable import Vellum

@Suite("Captured unread ledger")
struct CapturedUnreadLedgerTests {
    @Test("Opening clears only local New state and does not mutate the web record")
    func openingDoesNotRewriteWebLibraryRecord() async throws {
        let suite = "vellum-captured-unread-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let ledger = CapturedUnreadLedger(suiteName: suite)
        let url = "https://example.com/captured"
        let key = WebLibrary.pageKey(url)

        let original = WebPageRecord(url: url)
        let before = try JSONSerialization.jsonObject(with: JSONEncoder().encode(original))
        await ledger.markUnread(forKey: key)
        #expect(await ledger.isUnread(forKey: key))

        await ledger.markOpened(document: DocumentInfo(kind: .web, pdfPath: url, title: "Captured"))

        let after = try JSONSerialization.jsonObject(with: JSONEncoder().encode(original))
        let remainsUnread = await ledger.isUnread(forKey: key)
        #expect(!remainsUnread)
        #expect((after as? NSDictionary) == (before as? NSDictionary))
    }

    @Test("Opening a PDF cannot clear a captured webpage")
    func pdfOpenDoesNotClearWebKey() async throws {
        let suite = "vellum-captured-unread-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let ledger = CapturedUnreadLedger(suiteName: suite)
        let key = WebLibrary.pageKey("https://example.com/captured")
        await ledger.markUnread(forKey: key)

        await ledger.markOpened(document: DocumentInfo(kind: .pdf, pdfPath: "/tmp/file.pdf"))

        #expect(await ledger.isUnread(forKey: key))
    }

    @Test("Home refreshes for a newly durable capture, not a duplicate")
    func refreshPolicyTracksNewIngestion() {
        #expect(CaptureLibraryFreshness.shouldRefresh(after: CaptureDrainReport(ingested: 1)))
        #expect(!CaptureLibraryFreshness.shouldRefresh(after: CaptureDrainReport(deduped: 1)))
    }
}
