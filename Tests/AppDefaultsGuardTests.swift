import Foundation
import Testing

@testable import Vellum

// The `AppDefaults` guard (#102), the app-state counterpart to the keychain
// guard covered by `UITestLaunchConfigurationTests` (#97).
//
// Every assertion here only ever READS `UserDefaults.standard`. The claim under
// test is that a test cannot reach the real domain, so proving it must not
// begin by writing to it.

@Suite("App state cannot reach the real defaults")
struct AppDefaultsGuardTests {
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
    func workspaceSaveStaysOutOfStandard() {
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
    func recentsWriteStaysOutOfStandard() {
        let path = "/tmp/guard-\(UUID().uuidString).pdf"
        let before = UserDefaults.standard.string(forKey: RecentFilesService.storageKey)
        defer { _ = RecentFilesService.remove(path: path) }

        RecentFilesService.record(
            DocumentInfo(kind: .pdf, pdfPath: path, title: "Guard", pageCount: 1))

        #expect(RecentFilesService.getRecent().contains { $0.pdfPath == path })
        #expect(
            UserDefaults.standard.string(forKey: RecentFilesService.storageKey) == before,
            "a test's recents write must not touch the real recent-documents list")
    }

    /// The isolation property the task-local buys over the process-global it
    /// replaces: the redirect unwinds with the task that bound it, so there is
    /// no window in which another suite could observe — or reset — it.
    @Test("A scoped redirect is invisible outside its scope")
    func scopedRedirectDoesNotLeak() async throws {
        let name = "vellum.scoped.\(UUID().uuidString)"
        let scratch = try #require(UserDefaults(suiteName: name))
        defer { scratch.removePersistentDomain(forName: name) }
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
