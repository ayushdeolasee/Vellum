#if os(iOS)
import SwiftUI
import Testing
import UIKit

@testable import Vellum

// Layout safety net for the phone reader's chrome (#153 P5).
//
// Same method as `WalkthroughLayoutTests`, and for the same reason: a
// `UIHostingController` that is never added to a window is never visible and
// never takes focus, so SwiftUI can be asked to lay the real bars out headless.
// `sizeThatFits(in:)` is the UIKit analogue of `NSHostingView.fittingSize`.
//
// The rule this file obeys is the one that file's header earns the hard way:
// NOTHING here re-derives a number. Every constant comes from
// `PhoneChromeLayout`, which is why that enum exists at all — a test that
// mirrored the paddings would go out of date silently and then fail pointing at
// the wrong file.
//
// What is actually being protected:
//
//   * the bars fit the phones this shell ships on. They are floating capsules
//     with no wrapping and no truncation of their own, so a bar that needs more
//     width than the screen does not reflow — it clips, and the control that
//     falls off the edge is the one furthest right (More);
//   * every interactive slot is still a 44pt target after all that;
//   * the scrim stays a legibility aid rather than a vignette.
/// The widths this shell claims: iPhone SE/13 mini (375), the 6.1" class (390),
/// the 6.3" class (402), and the Max/Plus class (430).
///
/// File-scope rather than a member of the suite below: `@Test(arguments:)`
/// evaluates its argument list outside the suite's isolation, so a
/// `@MainActor`-inherited static would not be reachable from it.
private let supportedWidths: [CGFloat] = [375, 390, 402, 430]

@MainActor
@Suite(.serialized, .scratchDefaults)
struct PhoneChromeLayoutTests {

    // MARK: - Fitting

    @Test("The top bar fits every supported screen width", arguments: supportedWidths)
    func topBarFitsWithoutClipping(width: CGFloat) async throws {
        let fixture = try await ChromeFixture()
        let needed = intrinsicWidth(of: fixture.host(PhoneReaderTopBar(shell: fixture.shell)))
        #expect(
            needed <= width,
            """
            The reader's top bar needs \(Int(needed))pt but a \(Int(width))pt screen has \
            \(Int(width))pt. Floating capsules do not reflow — the overflow is clipped at the \
            trailing edge. Shorten the title capsule's max width in PhoneChromeLayout rather \
            than trimming the bar's controls.
            """)
    }

    @Test("The bottom bar fits every supported screen width", arguments: supportedWidths)
    func bottomBarFitsWithoutClipping(width: CGFloat) async throws {
        let fixture = try await ChromeFixture()
        let bar = PhoneReaderBottomBar(shell: fixture.shell, onOpenFile: {}, onAddWebpage: {})
        let needed = intrinsicWidth(of: fixture.host(bar))
        #expect(
            needed <= width,
            """
            The reader's bottom bar needs \(Int(needed))pt but a \(Int(width))pt screen has \
            \(Int(width))pt, so its trailing pod (inspector / tabs / more — the three ways out \
            of the document) is clipped. Fold a control into the More menu instead of shrinking \
            PhoneChromeLayout.buttonSide below the 44pt floor.
            """)
    }

    /// Web tabs swap the page indicator for in-page history, which is two 44pt
    /// slots instead of one label-width one — the wider of the two shapes.
    @Test("The bottom bar fits at the narrowest width with a web document open")
    func bottomBarFitsForWebDocuments() async throws {
        let fixture = try await ChromeFixture(kind: .web)
        let bar = PhoneReaderBottomBar(shell: fixture.shell, onOpenFile: {}, onAddWebpage: {})
        let needed = intrinsicWidth(of: fixture.host(bar))
        #expect(needed <= PhoneChromeLayout.narrowestSupportedWidth)
    }

    // MARK: - Touch targets

    @Test("Every interactive slot in the chrome is at least 44pt on both axes")
    func slotsMeetTheTouchFloor() {
        #expect(PhoneChromeLayout.buttonSide >= 44)
        // The capsule has to be at least as tall as the slot it contains, or the
        // top and bottom of every target are outside their own glass.
        #expect(PhoneChromeLayout.capsuleHeight >= PhoneChromeLayout.buttonSide)
    }

    /// The bars are hosted at their real heights rather than trusted to be
    /// them: a stray `.padding()` inside a pod would inflate the bar and push
    /// the bottom one under the home indicator.
    @Test("Each bar is exactly one capsule plus its edge gap tall")
    func barsMeasureTheirDeclaredHeight() async throws {
        let fixture = try await ChromeFixture()
        let width = PhoneChromeLayout.narrowestSupportedWidth

        let top = intrinsicHeight(
            of: fixture.host(PhoneReaderTopBar(shell: fixture.shell)), width: width)
        #expect(abs(top - PhoneChromeLayout.barHeight) <= 1)

        let bottom = intrinsicHeight(
            of: fixture.host(
                PhoneReaderBottomBar(shell: fixture.shell, onOpenFile: {}, onAddWebpage: {})),
            width: width)
        #expect(abs(bottom - PhoneChromeLayout.barHeight) <= 1)
    }

    // MARK: - Scrim budget

    @Test("The scrim stays a legibility aid on the shortest supported screen")
    func scrimCoverageStaysUnderBudget() {
        let coverage = PhoneChromeLayout.scrimCoverage(
            screenHeight: PhoneChromeLayout.shortestSupportedScreenHeight)
        #expect(
            coverage < PhoneChromeLayout.maxScrimCoverage,
            """
            The two scrims cover \(Int(coverage * 100))% of a \
            \(Int(PhoneChromeLayout.shortestSupportedScreenHeight))pt screen, past the \
            \(Int(PhoneChromeLayout.maxScrimCoverage * 100))% budget. Past that they stop \
            reading as a gradient behind the chrome and start reading as a vignette over the \
            page.
            """)
    }

    /// The scrim exists to be *behind* the bars. A gradient that ended before
    /// the capsule did would leave its trailing edge sitting on bare paper.
    @Test("Each scrim reaches past the bar it sits behind")
    func scrimsCoverTheirBars() {
        #expect(PhoneChromeLayout.topScrimHeight > PhoneChromeLayout.barHeight)
        #expect(PhoneChromeLayout.bottomScrimHeight > PhoneChromeLayout.barHeight)
    }

    // MARK: - Measurement

    /// Intrinsic width: what the view asks for when nothing constrains it.
    private func intrinsicWidth(of view: some View) -> CGFloat {
        let host = UIHostingController(rootView: view)
        return host.sizeThatFits(
            in: CGSize(
                width: UIView.layoutFittingCompressedSize.width,
                height: UIView.layoutFittingCompressedSize.height)
        ).width
    }

    private func intrinsicHeight(of view: some View, width: CGFloat) -> CGFloat {
        let host = UIHostingController(rootView: view)
        host.view.frame = CGRect(x: 0, y: 0, width: width, height: .greatestFiniteMagnitude)
        return host.sizeThatFits(
            in: CGSize(width: width, height: UIView.layoutFittingCompressedSize.height)
        ).height
    }
}

// MARK: - Fixture

/// A single-pane workspace with one document open, plus the environment the
/// bars read. Built from the real stores over a fake `SessionService` — the
/// bars are measured as they ship, not as a stripped-down stand-in.
@MainActor
private struct ChromeFixture {
    let workspace: WorkspaceStore
    let shell: PhoneShellStore

    init(kind: DocumentKind = .pdf) async throws {
        workspace = WorkspaceStore(sessions: ChromeSessionService(), layout: .singlePane)
        shell = PhoneShellStore(workspace: workspace)
        let app = workspace.focusedPane.app
        switch kind {
        case .pdf: await app.openFile(path: "/tmp/phone-chrome.pdf")
        case .web: await app.openUrl("https://example.com/article")
        }
        shell.didOpenDocument()
    }

    /// The bars read four stores and the palette out of the environment; a
    /// missing one is a crash at hosting time, not a compile error, so they are
    /// injected in one place.
    func host(_ view: some View) -> some View {
        let pane = workspace.focusedPane
        return view
            .environment(pane.app)
            .environment(pane.annotations)
            .environment(pane.ai)
            .environment(pane.scratchpad)
            .environment(workspace)
            .environment(\.palette, .light)
            .tint(ThemePalette.light.primary)
    }
}

/// Opens documents without touching the backend. Same shape as the fake in
/// `PhoneShellStateTests`, kept local for the same reason: a shared test double
/// becomes a second implementation to keep honest.
@MainActor
private final class ChromeSessionService: SessionService {
    func openFile(path: String, sessionId: String) async throws -> DocumentInfo {
        DocumentInfo(kind: .pdf, pdfPath: path, title: "Chrome PDF", pageCount: 12, lastPage: 1)
    }

    func openWebDocument(url: String, sessionId: String) async throws -> DocumentInfo {
        DocumentInfo(
            kind: .web, pdfPath: url, title: "Chrome Webpage", pageCount: 1, lastPage: 1,
            docId: "chrome-web")
    }

    func openVellumwebFile(path: String, sessionId: String) async throws -> DocumentInfo {
        try await openWebDocument(url: path, sessionId: sessionId)
    }

    func saveFile(sessionId: String) async throws {}
    func closeFile(sessionId: String) async throws {}
    func readPdfBytes(sessionId: String) async throws -> Data { Data() }
    func setWebpageSaved(sessionId: String, saved: Bool) async throws {}
    func getWebpageSaved(sessionId: String) async throws -> Bool { false }
    func listSavedWebpages() async throws -> [WebLibraryEntry] { [] }
    func removeSavedWebpage(url: String) async throws {}

    func exportVellumweb(
        sessionId: String, destPath: String, pages: [WebPageText]
    ) async throws -> VellumwebExportSummary {
        VellumwebExportSummary(path: destPath, bytes: 0, assetCount: 0, assetsSkipped: 0)
    }

    func archiveWebpageDefault(
        sessionId: String, pages: [WebPageText], expectedUrl: String
    ) async throws -> Bool {
        false
    }

    func getAnnotations(sessionId: String, pageNumber: Int?) async throws -> [Annotation] { [] }

    func createAnnotation(
        sessionId: String, input: CreateAnnotationInput
    ) async throws -> Annotation {
        throw SessionServiceError.invalidDocument("Unused in phone chrome tests")
    }

    func updateAnnotation(sessionId: String, input: UpdateAnnotationInput) async throws -> Bool {
        false
    }

    func deleteAnnotation(sessionId: String, id: String) async throws -> Bool { false }
    func setDocumentMetadata(sessionId: String, key: String, value: String) async throws {}
    func ensureDocumentId(sessionId: String) async throws -> String { sessionId }
}
#endif
