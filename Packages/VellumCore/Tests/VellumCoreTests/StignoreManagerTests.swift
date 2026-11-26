import Foundation
import VellumCore
import XCTest

final class StignoreManagerTests: XCTestCase {
    private let fm = FileManager.default
    private let begin = "// BEGIN VELLUM MANAGED - DO NOT EDIT THIS BLOCK"
    private let end = "// END VELLUM MANAGED"

    func testCreatesOnceWithoutTouchingBytesOrMtimeOnSecondActivation() throws {
        try withRoot { root, file in
            XCTAssertTrue(try StignoreManager.ensure(at: root))
            let bytes = try Data(contentsOf: file)
            XCTAssertTrue(bytes.starts(with: begin.utf8))
            let mtime = Date(timeIntervalSince1970: 1_700_000_000)
            try fm.setAttributes([.modificationDate: mtime], ofItemAtPath: file.path)

            XCTAssertFalse(try StignoreManager.ensure(at: root) { _, _ in
                XCTFail("Unchanged rules should not invoke the writer")
            })
            XCTAssertEqual(try Data(contentsOf: file), bytes)
            XCTAssertEqual(try fm.attributesOfItem(atPath: file.path)[.modificationDate] as? Date, mtime)
            XCTAssertEqual(try fm.contentsOfDirectory(atPath: root.path), [".stignore"])
        }
    }

    func testAppendsToUserOnlyFileAndReplacesAnExistingBlockByteForByteAroundIt() throws {
        try withRoot { root, file in
            let userRules = Data([0xef, 0xbb, 0xbf, 0xff]) + Data("// user\r\n!*.tmp".utf8)
            try userRules.write(to: file)
            XCTAssertTrue(try StignoreManager.ensure(at: root))
            XCTAssertTrue(try Data(contentsOf: file).starts(with: userRules + Data("\r\n\r\n".utf8)))

            let before = userRules + Data("\r\n".utf8)
            let after = Data("\n// after\r\nlast-rule".utf8) + Data([0x80])
            let oldBlock = Data("\(begin)\r\nstale-rule\r\n\(end)".utf8)
            try (before + oldBlock + after).write(to: file)
            try fm.setAttributes([.posixPermissions: 0o640], ofItemAtPath: file.path)
            XCTAssertTrue(try StignoreManager.ensure(at: root))
            let updated = try Data(contentsOf: file)
            XCTAssertTrue(updated.starts(with: before + Data("\(begin)\r\n".utf8)))
            XCTAssertEqual(Data(updated.suffix(after.count)), after)
            XCTAssertNil(updated.range(of: Data("stale-rule".utf8)))
            XCTAssertEqual(try fm.attributesOfItem(atPath: file.path)[.posixPermissions] as? NSNumber, 0o640)
            XCTAssertFalse(try StignoreManager.ensure(at: root))
        }
    }

    func testMalformedMarkersLeaveTheFileUntouched() throws {
        try withRoot { root, file in
            for malformed in [
                begin, end, "\(end)\n\(begin)", "\(begin)\n\(begin)\n\(end)",
                "\(begin)\n\(end)\n\(begin)\n\(end)",
            ] {
                let bytes = Data("!user-rule\n\(malformed)\n".utf8)
                try bytes.write(to: file)
                XCTAssertThrowsError(try StignoreManager.ensure(at: root)) {
                    XCTAssertEqual($0 as? StignoreManager.UpdateError, .malformedMarkers)
                }
                XCTAssertEqual(try Data(contentsOf: file), bytes)
            }
        }
    }

    func testWriteFailureAndConcurrentEditsPreserveTheLatestUserBytes() throws {
        struct WriteFailure: Error {}

        try withRoot { root, file in
            let original = Data("original\n".utf8)
            let edit = Data("user edit\n".utf8)
            try original.write(to: file)
            XCTAssertThrowsError(try StignoreManager.ensure(at: root) { _, staging in
                try staging.write(contentsOf: Data("partial".utf8))
                throw WriteFailure()
            }) { XCTAssertTrue($0 is WriteFailure) }
            XCTAssertEqual(try Data(contentsOf: file), original)

            for existing in [true, false] {
                if !existing { try fm.removeItem(at: file) }
                XCTAssertThrowsError(try StignoreManager.ensure(at: root) { bytes, staging in
                    try staging.write(contentsOf: bytes)
                    try edit.write(to: file, options: .atomic)
                }) { XCTAssertEqual($0 as? StignoreManager.UpdateError, .changedDuringUpdate) }
                XCTAssertEqual(try Data(contentsOf: file), edit)
                XCTAssertEqual(try fm.contentsOfDirectory(atPath: root.path), [".stignore"])
            }
        }
    }

    func testDoesNotFollowAnIgnoreFileSymlink() throws {
        try withRoot { root, file in
            let target = root.appendingPathComponent("user-rules")
            let bytes = Data("keep\n".utf8)
            try bytes.write(to: target)
            try fm.createSymbolicLink(at: file, withDestinationURL: target)
            XCTAssertThrowsError(try StignoreManager.ensure(at: root))
            XCTAssertEqual(try Data(contentsOf: target), bytes)
            XCTAssertEqual(try fm.destinationOfSymbolicLink(atPath: file.path), target.path)
        }
    }

    private func withRoot(_ body: (URL, URL) throws -> Void) throws {
        let root = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try fm.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? fm.removeItem(at: root) }
        try body(root, root.appendingPathComponent(".stignore"))
    }
}
