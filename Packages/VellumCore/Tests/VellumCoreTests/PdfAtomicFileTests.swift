import Foundation
import XCTest
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif
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
            XCTAssertEqual(try? manager.attributesOfItem(atPath: temporary)[.posixPermissions] as? NSNumber, 0o640)
            // A real rename(2) refuses to replace this directory with a file.
            let result = rename(temporary, directory.path)
            return result == 0 ? 0 : errno
        }) {
            guard case .io(let message) = $0 as? PdfCoreError else { return XCTFail("Expected PDF IO error") }
            XCTAssertTrue(message.hasPrefix("Failed to replace PDF with annotated copy:"))
        }
        XCTAssertEqual(try Data(contentsOf: path), beforeFailure)
        XCTAssertEqual(try manager.contentsOfDirectory(atPath: directory.path), ["reader.pdf"])
    }

    func testSymlinkAndMissingDestinationLeaveLibraryEntriesAlone() throws {
        let manager = FileManager.default
        let directory = manager.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try manager.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? manager.removeItem(at: directory) }

        let target = directory.appendingPathComponent("private.pdf")
        let link = directory.appendingPathComponent("alias.pdf")
        let missing = directory.appendingPathComponent("missing.pdf")
        let original = try Data(contentsOf: PdfFixtureBuilder.fixtureURL("classic-two-column"))
        try original.write(to: target)
        try manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: target.path)
        try manager.createSymbolicLink(at: link, withDestinationURL: target)
        for path in [link, missing] {
            XCTAssertThrowsError(try PdfAtomicFile.save(Data("new".utf8), toPath: path.path)) {
                guard case .io(let message) = $0 as? PdfCoreError else { return XCTFail("Expected PDF IO error") }
                XCTAssertTrue(message.hasPrefix("Failed to read PDF permissions:"))
            }
        }
        XCTAssertEqual(try manager.destinationOfSymbolicLink(atPath: link.path), target.path)
        XCTAssertEqual(try Data(contentsOf: target), original)
        XCTAssertEqual(try manager.attributesOfItem(atPath: target.path)[.posixPermissions] as? NSNumber, 0o600)
        XCTAssertEqual(try manager.contentsOfDirectory(atPath: directory.path).sorted(), ["alias.pdf", "private.pdf"])
    }
}
