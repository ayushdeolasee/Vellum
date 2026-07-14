import XCTest
@testable import Vellum

// Storage-location feature: layout resolution, pretty-name index, relocation
// between layouts, and the legacy-fallback record read. Uses the same
// scratch-dir seams as WebLibraryStorageTests plus `WebLibrary.layoutOverride`
// to simulate a pretty (iCloud/custom-style) layout without touching real
// UserDefaults or iCloud Drive.

@MainActor
final class WebStorageLocationTests: XCTestCase {
    private var tempDir: URL!
    private var storeDir: URL!
    private var prettyRoot: URL!

    override func setUp() async throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("vellum-webstorage-tests-\(UUID().uuidString)")
        storeDir = tempDir.appendingPathComponent("appsupport-web", isDirectory: true)
        prettyRoot = tempDir.appendingPathComponent("cloud/Vellum", isDirectory: true)
        try FileManager.default.createDirectory(at: storeDir, withIntermediateDirectories: true)
        WebLibrary.storeDirOverride = storeDir
    }

    override func tearDown() async throws {
        WebLibrary.storeDirOverride = nil
        WebLibrary.layoutOverride = nil
        WebStorageSettings.modeOverride = nil
        WebStorageSettings.customRootOverride = nil
        WebStorageSettings.icloudDriveRootOverride = nil
        WebStorageSettings.autoSavePagesOverride = nil
        if let tempDir { try? FileManager.default.removeItem(at: tempDir) }
    }

    private var localLayout: WebStorageLayout {
        .local(storeDir: storeDir)
    }

    private var prettyLayout: WebStorageLayout {
        .pretty(root: prettyRoot, recordsInRoot: true, localStoreDir: storeDir)
    }

    @discardableResult
    private func makeLocalRecord(url: String, title: String?, saved: Bool = true) throws -> String {
        let key = WebLibrary.pageKey(url)
        var record = WebPageRecord(url: url)
        record.title = title
        record.saved = saved
        record.savedAt = saved ? WebLibrary.rfc3339Now() : nil
        try WebLibrary.saveRecord(record, at: storeDir.appendingPathComponent("\(key).json"))
        return key
    }

    // MARK: - Layout resolution

    func testEffectiveModeDegradesToLocalWhenRootsMissing() {
        WebStorageSettings.modeOverride = .icloud
        WebStorageSettings.icloudDriveRootOverride = tempDir.appendingPathComponent("nonexistent")
        XCTAssertEqual(WebStorageSettings.effectiveMode, .local)
        XCTAssertTrue(WebStorageSettings.modeIsDegraded)

        WebStorageSettings.modeOverride = .custom
        WebStorageSettings.customRootOverride = nil
        XCTAssertEqual(WebStorageSettings.effectiveMode, .local)
    }

    func testPrettyLayoutDirectories() {
        let layout = prettyLayout
        XCTAssertEqual(layout.archivesDir.lastPathComponent, "Web Pages")
        XCTAssertEqual(layout.recordsDir.lastPathComponent, "records")
        XCTAssertEqual(layout.indexPath?.lastPathComponent, "index.json")
        XCTAssertTrue(layout.recordsDir.path.contains("/.vellum/"))

        // Custom-style: records stay in the local store.
        let custom = WebStorageLayout.pretty(
            root: prettyRoot, recordsInRoot: false, localStoreDir: storeDir)
        XCTAssertEqual(custom.recordsDir, storeDir)
    }

    // MARK: - Pretty names

    func testSanitizedBaseName() {
        XCTAssertEqual(
            WebArchiveIndex.sanitizedBaseName(title: "The Rust Book", url: "https://x.com"),
            "The Rust Book")
        XCTAssertEqual(
            WebArchiveIndex.sanitizedBaseName(title: "a/b: c\\d", url: "https://x.com"),
            "a-b- c-d")
        XCTAssertEqual(
            WebArchiveIndex.sanitizedBaseName(title: ".hidden", url: "https://x.com"),
            "hidden")
        XCTAssertEqual(
            WebArchiveIndex.sanitizedBaseName(title: nil, url: "https://example.org/docs/intro"),
            "example.org — intro")
        // Foundation's lenient URL parser reads this as a host-less path; the
        // path tail is used alone, with no dangling "—" separator.
        XCTAssertEqual(
            WebArchiveIndex.sanitizedBaseName(title: "  ", url: "not a url"),
            "not a url")
        XCTAssertEqual(
            WebArchiveIndex.sanitizedBaseName(title: nil, url: ""),
            "Web Page")
        let long = String(repeating: "x", count: 200)
        XCTAssertLessThanOrEqual(
            WebArchiveIndex.sanitizedBaseName(title: long, url: "https://x.com").count, 80)
    }

    func testIndexAssignsStableUniqueNames() throws {
        let layout = prettyLayout
        let indexPath = try XCTUnwrap(layout.indexPath)
        try FileManager.default.createDirectory(
            at: layout.archivesDir, withIntermediateDirectories: true)

        let nameA = WebArchiveIndex.assignFileName(
            forKey: "key-a", title: "Same Title", url: "https://a.com",
            at: indexPath, archivesDir: layout.archivesDir)
        XCTAssertEqual(nameA, "Same Title.vellumweb")

        // Same key again → same name, no churn.
        XCTAssertEqual(
            WebArchiveIndex.assignFileName(
                forKey: "key-a", title: "Renamed Later", url: "https://a.com",
                at: indexPath, archivesDir: layout.archivesDir),
            nameA)

        // Different key, same title → suffixed.
        let nameB = WebArchiveIndex.assignFileName(
            forKey: "key-b", title: "Same Title", url: "https://b.com",
            at: indexPath, archivesDir: layout.archivesDir)
        XCTAssertEqual(nameB, "Same Title 2.vellumweb")

        // A file squatting on disk without an index entry is also avoided.
        try Data("x".utf8).write(
            to: layout.archivesDir.appendingPathComponent("Squatter.vellumweb"))
        let nameC = WebArchiveIndex.assignFileName(
            forKey: "key-c", title: "Squatter", url: "https://c.com",
            at: indexPath, archivesDir: layout.archivesDir)
        XCTAssertEqual(nameC, "Squatter 2.vellumweb")

        WebArchiveIndex.removeEntry(forKey: "key-a", at: indexPath)
        XCTAssertNil(WebArchiveIndex.fileName(forKey: "key-a", at: indexPath))
        XCTAssertEqual(WebArchiveIndex.fileName(forKey: "key-b", at: indexPath), nameB)
    }

    func testManagedArchiveDestinationUsesRecordTitleInPrettyLayout() throws {
        WebLibrary.layoutOverride = prettyLayout
        let key = try makeLocalRecord(url: "https://example.com/guide", title: "A Fine Guide")
        // Record still sits in the legacy store — destination resolution must
        // find it through the fallback read.
        let dest = WebLibrary.managedArchiveDestination(forKey: key)
        XCTAssertEqual(dest.lastPathComponent, "A Fine Guide.vellumweb")
        XCTAssertEqual(dest.deletingLastPathComponent(), prettyLayout.archivesDir)

        WebLibrary.layoutOverride = localLayout
        XCTAssertEqual(
            WebLibrary.managedArchiveDestination(forKey: key),
            storeDir.appendingPathComponent("\(key).vellumweb"))
    }

    // MARK: - Fallback record read

    func testWithRecordFallsBackToLegacyLocalRecord() throws {
        WebLibrary.layoutOverride = prettyLayout
        let url = "https://example.com/annotated"
        let key = try makeLocalRecord(url: url, title: "Kept", saved: true)

        // Mutate through the pretty-layout primary path; the legacy record's
        // contents (saved flag, title) must carry over, not be reset.
        let primary = WebLibrary.recordPath(forKey: key)
        XCTAssertNotEqual(primary, storeDir.appendingPathComponent("\(key).json"))
        try WebLibrary.withRecord(url: url, recordPath: primary) { record in
            record.lastPage = 4
        }

        let migrated = WebLibrary.loadRecord(at: primary)
        XCTAssertEqual(migrated?.title, "Kept")
        XCTAssertEqual(migrated?.saved, true)
        XCTAssertEqual(migrated?.lastPage, 4)
    }

    // MARK: - Relocation

    func testRelocateLocalToPrettyMovesRecordsAndRenamesArchives() throws {
        let keyA = try makeLocalRecord(url: "https://example.com/a", title: "Alpha Article")
        let keyB = try makeLocalRecord(url: "https://example.com/b", title: "Beta Piece", saved: false)
        try Data(repeating: 1, count: 64)
            .write(to: storeDir.appendingPathComponent("\(keyA).vellumweb"))
        try Data(repeating: 2, count: 64)
            .write(to: storeDir.appendingPathComponent("\(keyB).vellumweb"))
        // Derived caches must NOT move.
        try Data("html".utf8).write(to: storeDir.appendingPathComponent("\(keyA).snapshot.html"))

        WebLibrary.layoutOverride = prettyLayout
        XCTAssertTrue(WebStorageMigrator.relocate(from: localLayout, to: prettyLayout))

        let fm = FileManager.default
        XCTAssertTrue(fm.fileExists(
            atPath: prettyLayout.recordsDir.appendingPathComponent("\(keyA).json").path))
        XCTAssertFalse(fm.fileExists(
            atPath: storeDir.appendingPathComponent("\(keyA).json").path))
        XCTAssertTrue(fm.fileExists(
            atPath: prettyLayout.archivesDir.appendingPathComponent("Alpha Article.vellumweb").path))
        XCTAssertTrue(fm.fileExists(
            atPath: prettyLayout.archivesDir.appendingPathComponent("Beta Piece.vellumweb").path))
        XCTAssertFalse(fm.fileExists(
            atPath: storeDir.appendingPathComponent("\(keyA).vellumweb").path))
        XCTAssertTrue(fm.fileExists(
            atPath: storeDir.appendingPathComponent("\(keyA).snapshot.html").path),
            "derived caches stay local")

        // Library reads resolve to the new home.
        XCTAssertEqual(
            WebLibrary.existingManagedArchiveURL(forKey: keyA)?.lastPathComponent,
            "Alpha Article.vellumweb")
        XCTAssertTrue(WebLibrary.hasLocalSnapshot(forKey: keyB))
        XCTAssertEqual(WebLibrary.listSaved().count, 1)

        // Idempotent: running again with nothing to move is a clean no-op.
        XCTAssertTrue(WebStorageMigrator.relocate(from: localLayout, to: prettyLayout))
    }

    func testRelocatePrettyBackToLocalRestoresHashedNames() throws {
        let keyA = try makeLocalRecord(url: "https://example.com/a", title: "Alpha Article")
        try Data(repeating: 1, count: 64)
            .write(to: storeDir.appendingPathComponent("\(keyA).vellumweb"))
        WebLibrary.layoutOverride = prettyLayout
        XCTAssertTrue(WebStorageMigrator.relocate(from: localLayout, to: prettyLayout))

        WebLibrary.layoutOverride = localLayout
        XCTAssertTrue(WebStorageMigrator.relocate(from: prettyLayout, to: localLayout))

        let fm = FileManager.default
        XCTAssertTrue(fm.fileExists(atPath: storeDir.appendingPathComponent("\(keyA).json").path))
        XCTAssertTrue(fm.fileExists(atPath: storeDir.appendingPathComponent("\(keyA).vellumweb").path))
        // The pretty structure we created is cleaned up once empty.
        XCTAssertFalse(fm.fileExists(atPath: prettyLayout.archivesDir.path))
        XCTAssertFalse(fm.fileExists(atPath: prettyLayout.recordsDir.path))
    }

    func testRelocateMergesWhenBothCopiesExist() throws {
        // Both locations hold a record: the destination (a session fallback-
        // read wrote it there) and the legacy source, which an already-open
        // session annotated AFTER the destination copy was created. Migration
        // must merge — the late annotation survives — never just delete the
        // source.
        let url = "https://example.com/live"
        let key = try makeLocalRecord(url: url, title: "Stale", saved: false)
        let lateNote = Annotation(
            id: "late-note", type: .note, pageNumber: 1, color: "#fde68a",
            content: "written after the switch", positionData: nil,
            createdAt: WebLibrary.rfc3339Now(), updatedAt: WebLibrary.rfc3339Now())
        var source = try XCTUnwrap(
            WebLibrary.loadRecord(at: storeDir.appendingPathComponent("\(key).json")))
        source.annotations = [lateNote]
        try WebLibrary.saveRecord(source, at: storeDir.appendingPathComponent("\(key).json"))

        WebLibrary.layoutOverride = prettyLayout
        var live = WebPageRecord(url: url)
        live.title = "Live"
        live.saved = true
        try WebLibrary.saveRecord(live, at: WebLibrary.recordPath(forKey: key))

        XCTAssertTrue(WebStorageMigrator.relocate(from: localLayout, to: prettyLayout))
        let kept = WebLibrary.loadRecord(at: WebLibrary.recordPath(forKey: key))
        XCTAssertEqual(kept?.title, "Live", "destination fields win on conflict")
        XCTAssertEqual(kept?.saved, true)
        XCTAssertEqual(
            kept?.annotations.map(\.id), ["late-note"],
            "annotations written to the source after the switch are merged in")
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: storeDir.appendingPathComponent("\(key).json").path),
            "merged legacy copy is removed")
    }

    // MARK: - Removal in pretty layouts

    func testRemoveLocalSnapshotsClearsPrettyArchiveAndIndexEntry() throws {
        let key = try makeLocalRecord(url: "https://example.com/gone", title: "Going Away")
        try Data(repeating: 1, count: 64)
            .write(to: storeDir.appendingPathComponent("\(key).vellumweb"))
        WebLibrary.layoutOverride = prettyLayout
        XCTAssertTrue(WebStorageMigrator.relocate(from: localLayout, to: prettyLayout))
        let indexPath = try XCTUnwrap(prettyLayout.indexPath)
        XCTAssertNotNil(WebArchiveIndex.fileName(forKey: key, at: indexPath))

        WebLibrary.removeLocalSnapshots(forKey: key)

        XCTAssertFalse(WebLibrary.hasLocalSnapshot(forKey: key))
        XCTAssertNil(WebArchiveIndex.fileName(forKey: key, at: indexPath))
        XCTAssertNotNil(
            WebLibrary.loadRecord(at: WebLibrary.recordPath(forKey: key)),
            "record always survives removal")
    }
}
