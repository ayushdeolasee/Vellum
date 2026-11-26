import Foundation
import XCTest
@testable import VellumCore

final class PdfAtomicFileTests: XCTestCase {
    func testSuccessiveReplacementsPreservePermissionsAndOriginalOnRenameFailure() throws {
        let manager = FileManager.default
        let directory = manager.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try manager.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? manager.removeItem(at: directory) }
        let path = directory.appendingPathComponent("reader.pdf")
        try manager.copyItem(at: PdfFixtureBuilder.fixtureURL("classic-two-column"), to: path)
        try manager.setAttributes([.posixPermissions: 0o640], ofItemAtPath: path.path)
        for title in ["First", "第二"] {
            let original = try Data(contentsOf: path)
            let next = try PdfInfoIncrement.setMetadataIncrement(normalizedData: original, key: "title", value: title)
            try PdfAtomicFile.save(next, toPath: path.path)
            let file = try ClassicPdfFile(data: Data(contentsOf: path))
            XCTAssertEqual(file.infoNumber.flatMap(file.objectSource)?.textString(forKey: "Title"), title)
            XCTAssertEqual(try manager.attributesOfItem(atPath: path.path)[.posixPermissions] as? NSNumber, 0o640)
        }

        let beforeFailure = try Data(contentsOf: path)
        let replacement = Data("uncommitted".utf8)
        XCTAssertThrowsError(try PdfAtomicFile.save(replacement, toPath: path.path) { temporary, destination in
            XCTAssertEqual(destination, path.path)
            let staged = URL(fileURLWithPath: temporary)
            XCTAssertEqual(staged.deletingLastPathComponent().path, directory.path)
            XCTAssertTrue(staged.lastPathComponent.hasPrefix(".reader.pdf.vellum-"))
            XCTAssertEqual(try? Data(contentsOf: staged), replacement)
            return EACCES
        }) {
            XCTAssertEqual($0 as? PdfCoreError, .io("Failed to replace PDF with annotated copy: \(String(cString: strerror(EACCES)))"))
        }
        XCTAssertEqual(try Data(contentsOf: path), beforeFailure)
        XCTAssertEqual(try manager.contentsOfDirectory(atPath: directory.path), ["reader.pdf"])
    }
}
