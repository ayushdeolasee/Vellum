import Foundation
import Testing

@testable import Vellum

// The `AppDefaults` guard (#102), the app-state counterpart to the keychain
// guard covered by `UITestLaunchConfigurationTests` (#97).
//
// Every assertion here only ever READS `UserDefaults.standard`. The claim under
// test is that a test cannot reach the real domain, so proving it must not
// begin by writing to it.
//
// The two write tests go further and REFUSE to run unless the floor is already
// in place: their writes go wherever `AppDefaults` points, so if the floor ever
// regressed, a test that wrote first and checked afterwards would report the
// damage only after doing it — deleting the developer's real window layout via
// its own cleanup. Checking first also makes the obvious mutation (point the
// floor at `.standard`) safe to run: all three fail without a single write.

@Suite("App state cannot reach the real defaults")
struct AppDefaultsGuardTests {
    /// Fail fast, before writing anything, if the floor is not holding.
    private func requireFloor() throws {
        try #require(
            AppDefaults.current !== UserDefaults.standard,
            "refusing to write: the guard under test is not in place")
    }

    /// The floor: with nothing installed, a hosted test bundle still must not
    /// be handed the domain it shares with the app.
    @Test("The ambient domain under test is never UserDefaults.standard")
    func ambientDomainIsNotStandard() {
        #expect(AppDefaults.current !== UserDefaults.standard)
    }

    /// `WorkspaceService.save` had no seam at all; a test reached it only if it
    /// got past `WorkspaceStore.scheduleSave`'s `guard didRestore`. Calling it
    /// directly here is the case that guard never covered.
    @Test("A workspace save cannot land in the real domain")
    func workspaceSaveStaysOutOfStandard() throws {
        try requireFloor()
        let key = "vellum.workspace"
        let before = UserDefaults.standard.string(forKey: key)
        defer { WorkspaceService.clear() }

        WorkspaceService.save(
            WorkspaceState(root: .leaf(tabs: [], activeTabIndex: nil), focusedLeafIndex: 0))

        #expect(WorkspaceService.load() != nil, "the save still has to land somewhere readable")
        #expect(
            UserDefaults.standard.string(forKey: key) == before,
            "a test's workspace save must not touch the real window layout")
    }

    @Test("A recents write cannot land in the real domain")
    func recentsWriteStaysOutOfStandard() throws {
        try requireFloor()
        // Match on the file name, not the whole path: the JSON writer escapes
        // forward slashes, so the stored text holds `\/tmp\/…`.
        let fileName = "guard-\(UUID().uuidString).pdf"
        let path = "/tmp/\(fileName)"
        let before = UserDefaults.standard.string(forKey: RecentFilesService.storageKey)
        defer { _ = RecentFilesService.remove(path: path) }

        RecentFilesService.record(
            DocumentInfo(kind: .pdf, pdfPath: path, title: "Guard", pageCount: 1))

        // Assert on the domain the write went to, not on membership of the list
        // it returns: the ambient domain is shared with the unseamed XCTest
        // classes, and recents is a capped read-modify-write, so membership can
        // be evicted by an unrelated write for reasons that are not this bug.
        #expect(
            AppDefaults.current.string(forKey: RecentFilesService.storageKey)?
                .contains(fileName) == true)
        #expect(
            UserDefaults.standard.string(forKey: RecentFilesService.storageKey) == before,
            "a test's recents write must not touch the real recent-documents list")
    }

    /// The legacy scratchpad blob is the third key that reaches real state, and
    /// the one with observed damage: two suites SEED and DELETE it to drive
    /// migration coverage, so on `.standard` they were editing the user's
    /// pre-folder notes — and racing any other test process doing the same.
    @Test("The legacy note blob cannot land in the real domain")
    func legacyBlobStaysOutOfStandard() throws {
        try requireFloor()
        let key = ScratchpadPersistence.notesKey
        let before = UserDefaults.standard.data(forKey: key)
        defer { AppDefaults.current.removeObject(forKey: key) }

        ScratchpadPersistence.removeLegacyEntry(key: "/tmp/nothing-\(UUID().uuidString).pdf")

        #expect(
            UserDefaults.standard.data(forKey: key) == before,
            "a test's legacy-blob write must not touch the real notes")
    }

    /// The isolation property the task-local buys over the process-global it
    /// replaces: the redirect unwinds with the task that bound it, so there is
    /// no window in which another suite could observe — or reset — it.
    @Test("A scoped redirect is invisible outside its scope")
    func scopedRedirectDoesNotLeak() async throws {
        let name = "vellum.scoped.\(UUID().uuidString)"
        let scratch = try #require(UserDefaults(suiteName: name))
        defer { removeSuite(scratch, named: name) }
        let path = "/tmp/scoped-\(UUID().uuidString).pdf"

        await AppDefaults.withDefaults(scratch) {
            RecentFilesService.record(
                DocumentInfo(kind: .pdf, pdfPath: path, title: "Scoped", pageCount: 1))
            #expect(RecentFilesService.getRecent().contains { $0.pdfPath == path })
        }

        #expect(
            !RecentFilesService.getRecent().contains { $0.pdfPath == path },
            "the scoped domain must not be visible once its binding has unwound")
    }
}
