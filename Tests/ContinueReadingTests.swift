import Foundation
import Testing

@testable import Vellum

@Suite("Home — continue reading")
struct ContinueReadingTests {
    @Test("Cross-device recents resolve to local open targets in merged order")
    func resolvesStablePathAndWebKeys() {
        let now = Date(timeIntervalSince1970: 10_000)
        let mac = DeviceIdentityStub(
            id: DeviceID("00000000-0000-0000-0000-000000000001"),
            name: "Ayush's Mac",
            platform: "macos")
        let pdfID = "6f1b2a44-8c3e-4d10-9f77-1a2b3c4d5e6f"
        let pdf = item(
            id: "pdf", kind: .pdf, locator: "/local/Book.pdf", storageKey: pdfID)
        let webURL = "https://example.com/article"
        let web = item(
            id: "web", kind: .web, locator: webURL,
            storageKey: WebLibrary.pageKey(webURL))
        let missing = ResumeEntry(
            key: .pdf(stableIdentifier: "not-on-this-device"), title: "Missing",
            openedAt: now.addingTimeInterval(10), position: nil,
            lastOpenedOn: mac, openElsewhere: [])
        let pdfResume = ResumeEntry(
            key: .pdf(stableIdentifier: pdfID), title: "Book",
            openedAt: now, position: ReadingPosition(page: 42, pageCount: 300),
            lastOpenedOn: mac, openElsewhere: [])
        let webResume = ResumeEntry(
            key: .web(normalizedURL: webURL), title: "Article",
            openedAt: now.addingTimeInterval(-10),
            position: ReadingPosition(page: 1, scrollFraction: 0.376),
            lastOpenedOn: mac, openElsewhere: [])

        let rows = ContinueReadingResolver.resolve(
            [missing, pdfResume, webResume], in: [pdf, web])

        #expect(rows.map(\.document.id) == ["pdf", "web"])
        #expect(rows.map(\.progressLabel) == ["Page 42 of 300", "38% read"])
        #expect(rows.map(\.deviceLabel) == ["From Ayush's Mac", "From Ayush's Mac"])
    }

    @Test("The three-row limit is applied after unavailable recents are skipped")
    func resolvesPastAnUnavailableRecentPrefix() {
        let now = Date(timeIntervalSince1970: 20_000)
        let device = DeviceIdentityStub(
            id: DeviceID("00000000-0000-0000-0000-000000000002"),
            name: "Other iPhone",
            platform: "ios")
        let unavailable = (0..<12).map { index in
            ResumeEntry(
                key: .pdf(stableIdentifier: "missing-\(index)"),
                title: "Missing \(index)",
                openedAt: now.addingTimeInterval(Double(-index)),
                position: nil,
                lastOpenedOn: device,
                openElsewhere: [])
        }
        let available = (0..<3).map { index in
            item(
                id: "available-\(index)",
                kind: .pdf,
                locator: "/local/Available-\(index).pdf",
                storageKey: "00000000-0000-0000-0000-0000000000\(10 + index)")
        }
        let availableRecents = available.enumerated().map { index, document in
            ResumeEntry(
                key: .pdf(stableIdentifier: document.storageKey!),
                title: document.title,
                openedAt: now.addingTimeInterval(Double(-20 - index)),
                position: ReadingPosition(page: index + 2),
                lastOpenedOn: device,
                openElsewhere: [])
        }

        let rows = ContinueReadingResolver.resolve(
            unavailable + availableRecents,
            in: available,
            limit: 3)

        #expect(rows.map(\.document.id) == [
            "available-0", "available-1", "available-2",
        ])
    }

    private func item(
        id: String,
        kind: DocumentKind,
        locator: String,
        storageKey: String
    ) -> HomeSearchItem {
        HomeSearchItem(
            id: id,
            identity: HomeSearchItemBuilder.identity(locator, kind: kind),
            section: .recents,
            kind: kind,
            target: kind == .web
                ? .url(locator)
                : .file(path: locator, recordedPath: locator),
            title: id.capitalized,
            subtitle: locator,
            detail: "",
            tooltip: locator,
            date: nil,
            badges: [],
            canRevealInFinder: kind == .pdf,
            haystack: HomeSearchHaystack(title: id, name: id, location: locator),
            storageKey: storageKey)
    }
}
