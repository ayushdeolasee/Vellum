import Foundation
import Testing

@testable import Vellum

private let validWidgetItemID = String(repeating: "a", count: 64)

@Suite("Widget and system routes")
struct VellumSystemRouteTests {
    @Test("Development profiles reject production-only services")
    func developmentRejectsProductionServices() {
        let development = RuntimeProfile(bundleIdentifier: "com.ayushdeolasee.vellum.dev")
        let production = RuntimeProfile(bundleIdentifier: "com.ayushdeolasee.vellum")

        #expect(development.allowsProductionServices == false)
        #expect(production.allowsProductionServices)
    }

    @Test("A widget route round-trips through the narrow URL grammar", .bug(id: 158))
    func deepLinkRoundTrip() throws {
        let route = VellumSystemRoute(shelf: .readLater, itemID: validWidgetItemID)
        let url = try #require(VellumDeepLink.url(for: route))

        #expect(url.absoluteString == "vellum-dev://open/read-later?id=\(validWidgetItemID)")
        #expect(VellumDeepLink.parse(url) == route)
    }

    @Test(
        "Malformed or over-broad deep links fail closed",
        .bug(id: 158),
        arguments: [
            "https://open/recent?id=\(validWidgetItemID)",
            "vellum-dev://other/recent?id=\(validWidgetItemID)",
            "vellum-dev://open/unknown?id=\(validWidgetItemID)",
            "vellum-dev://open/recent?id=short",
            "vellum-dev://open/recent?id=\(validWidgetItemID)&extra=value",
            "vellum-dev://open/recent?id=\(validWidgetItemID)#fragment",
            "vellum-dev://user@open/recent?id=\(validWidgetItemID)",
            "vellum-dev://open:42/recent?id=\(validWidgetItemID)",
        ])
    func rejectsMalformed(_ value: String) throws {
        let url = try #require(URL(string: value))
        #expect(VellumDeepLink.parse(url) == nil)
    }

    @Test("The App Group snapshot round-trips through one known file", .bug(id: 158))
    func snapshotRoundTrip() throws {
        let fileURL = FileManager.default.temporaryDirectory
            .appending(path: "vellum-widget-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: fileURL) }
        let store = VellumWidgetSnapshotStore(fileURL: fileURL)
        let item = VellumWidgetItem(
            shelf: .recent,
            title: "A useful paper",
            subtitle: "12 pages",
            systemImage: "doc.text",
            date: Date(timeIntervalSince1970: 1_234),
            target: .file(path: "/library/paper.pdf", recordedPath: "/library/paper.pdf"))
        let snapshot = VellumWidgetSnapshot(
            generatedAt: Date(timeIntervalSince1970: 1_234),
            recentDocuments: [item],
            readLaterItems: [])

        #expect(try store.save(snapshot))
        #expect(store.load() == snapshot)
        let sameItemsLater = VellumWidgetSnapshot(
            generatedAt: snapshot.generatedAt.addingTimeInterval(60),
            recentDocuments: snapshot.recentDocuments,
            readLaterItems: snapshot.readLaterItems)
        #expect(try store.save(sameItemsLater) == false)
        #expect(store.load()?.generatedAt == snapshot.generatedAt)
    }

    @Test("Invalid snapshot targets are never persisted", .bug(id: 158))
    func invalidSnapshotIsRejected() {
        let store = VellumWidgetSnapshotStore(
            fileURL: FileManager.default.temporaryDirectory
                .appending(path: "vellum-widget-invalid-\(UUID().uuidString).json"))
        let invalid = VellumWidgetItem(
            shelf: .recent,
            title: "Paper",
            subtitle: "",
            systemImage: "doc.text",
            date: nil,
            target: .file(path: "relative.pdf", recordedPath: "relative.pdf"))
        let snapshot = VellumWidgetSnapshot(
            generatedAt: .now,
            recentDocuments: [invalid],
            readLaterItems: [])

        #expect(throws: VellumWidgetSnapshotStoreError.invalidSnapshot) {
            try store.save(snapshot)
        }
    }
}
