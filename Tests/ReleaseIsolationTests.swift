import Foundation
import XCTest
@testable import Vellum

final class ReleaseIsolationTests: XCTestCase {
    func testHostedStorageDefaultsStayInsideScratchRoot() throws {
        let root = try XCTUnwrap(TestEnvironment.storageRoot).standardizedFileURL.path + "/"
        for url in [WebLibrary.appDataDir, WebLibrary.storeDir, DocumentDataStore.rootDirectory,
                    ScratchpadAttachmentStore.directory, PositionLayout.root,
                    PageTextCache.defaultDirectory, DocumentAccessBookmarkStore.shared.directory] {
            XCTAssertTrue(url.standardizedFileURL.path == String(root.dropLast())
                          || url.standardizedFileURL.path.hasPrefix(root), url.path)
        }
        XCTAssertFalse(AppDefaults.current === UserDefaults.standard)
#if os(iOS)
        let imported = DocumentImport.libraryDirectory
        XCTAssertTrue(imported.path.hasPrefix(root))
        XCTAssertNotEqual(imported.standardizedFileURL.path.lowercased(),
                          DocumentDataStore.rootDirectory.standardizedFileURL.path.lowercased())
        let probe = imported.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: probe) }
        try Data("isolated import".utf8).write(to: probe)
#endif
    }

    func testUIRootValidationRejectsFallbackAndLeavesSentinelUntouched() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let sentinel = directory.appendingPathComponent("sentinel")
        let bytes = Data("existing library".utf8)
        try bytes.write(to: sentinel)
        for arguments in [[], ["--ui-test-storage-root"], ["--ui-test-storage-root", ""],
                          ["--ui-test-storage-root", "relative"], ["--ui-test-storage-root", "/"],
                          ["--ui-test-storage-root", NSHomeDirectory()],
                          ["--ui-test-storage-root", sentinel.path]] {
            XCTAssertThrowsError(try UITestLaunchConfiguration.validatedStorageRoot(arguments: arguments))
            XCTAssertEqual(try Data(contentsOf: sentinel), bytes)
        }
        let resolved = try UITestLaunchConfiguration.validatedStorageRoot(
            arguments: ["--ui-test-storage-root", directory.path])
        XCTAssertEqual(resolved, directory.standardizedFileURL.resolvingSymlinksInPath())
    }

    func testUIRootRejectsLiveStorageDirectoriesAndTheirChildren() {
        for kind in [FileManager.SearchPathDirectory.documentDirectory,
                     .applicationSupportDirectory, .cachesDirectory] {
            guard let directory = FileManager.default.urls(for: kind, in: .userDomainMask).first else {
                XCTFail("Missing standard directory: \(kind)")
                continue
            }
            for root in [directory, directory.appendingPathComponent("Documents")] {
                XCTAssertThrowsError(try UITestLaunchConfiguration.validatedStorageRoot(
                    arguments: ["--ui-test-storage-root", root.path]), root.path)
            }
        }
        XCTAssertThrowsError(try UITestLaunchConfiguration.validatedStorageRoot(
            arguments: ["--ui-test-storage-root", FileManager.default.temporaryDirectory.path]))
    }

    func testDefaultBookmarkWriteDoesNotChangeExplicitLibrary() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let sentinel = DocumentAccessBookmarkStore(directory: directory)
        try sentinel.upsert(key: "sentinel", lastKnownPath: "/sentinel.pdf", bookmarkData: Data([1]))
        let before = try Data(contentsOf: sentinel.fileURL)
        let key = UUID().uuidString
        defer { try? DocumentAccessBookmarkStore.shared.remove(key: key) }
        try DocumentAccessBookmarkStore.shared.upsert(
            key: key, lastKnownPath: "/scratch.pdf", bookmarkData: Data([2]))
        XCTAssertEqual(try Data(contentsOf: sentinel.fileURL), before)
    }
}
