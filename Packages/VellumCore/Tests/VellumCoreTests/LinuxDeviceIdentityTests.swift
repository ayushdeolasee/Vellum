#if os(Linux)
import Foundation
import XCTest
import VellumCore

final class LinuxDeviceIdentityTests: XCTestCase {
    func testConcurrentFirstLaunches() throws {
        // Re-exec only this test. Every child gets its own process and the same empty settings root.
        if let output = ProcessInfo.processInfo.environment["VELLUM_TEST_ID_OUTPUT"] {
            let device = try DeviceIdentityProvider.linux().current()
            XCTAssertEqual(device.name, "Linux")
            XCTAssertEqual(device.platform, "linux")
            try Data(device.id.rawValue.utf8).write(to: URL(fileURLWithPath: output))
            return
        }

        let root = PositionFixtures.scratchDirectory("device-id")
        defer { PositionFixtures.remove(root) }
        let state = root.appendingPathComponent("state")
        let environment = ["XDG_STATE_HOME": state.path, "HOME": root.path]
        var children: [Process] = []
        defer { for child in children { child.waitUntilExit() } }
        for index in 0..<4 {
            let child = Process()
            child.executableURL = URL(fileURLWithPath: "/proc/self/exe")
            child.arguments = ["VellumCoreTests.LinuxDeviceIdentityTests/testConcurrentFirstLaunches"]
            child.environment = ProcessInfo.processInfo.environment.merging(environment) { _, new in new }
            child.environment?["VELLUM_TEST_ID_OUTPUT"] = root.appendingPathComponent("result-\(index)").path
            try child.run()
            children.append(child)
        }
        let ids = try children.enumerated().map { index, child in
            child.waitUntilExit()
            XCTAssertEqual(child.terminationStatus, 0)
            return try String(contentsOf: root.appendingPathComponent("result-\(index)"), encoding: .utf8)
        }
        let idFile = state.appendingPathComponent("vellum/device-id")
        let stored = try String(contentsOf: idFile, encoding: .utf8)
        let fm = FileManager.default
        XCTAssertEqual(try fm.attributesOfItem(atPath: idFile.path)[.posixPermissions] as? NSNumber, 0o600)
        XCTAssertEqual(Set(ids), [stored])
        XCTAssertNotNil(UUID(uuidString: stored))
        let relaunched = try DeviceIdentityProvider.linux(name: "Desktop", environment: environment).current()
        XCTAssertEqual(relaunched.id.rawValue, stored)
        XCTAssertEqual(relaunched.name, "Desktop")

        let existing = "B06FF418-FB3D-4D83-A58A-1F318EAEF833"
        try Data((existing + "\n").utf8).write(to: idFile)
        try fm.setAttributes([.posixPermissions: 0o644], ofItemAtPath: idFile.path)
        let normalized = try DeviceIdentityProvider.linux(environment: environment).current()
        XCTAssertEqual(normalized.id.rawValue, existing.lowercased())
        XCTAssertEqual(try String(contentsOf: idFile, encoding: .utf8), normalized.id.rawValue)
        XCTAssertEqual(try fm.attributesOfItem(atPath: idFile.path)[.posixPermissions] as? NSNumber, 0o600)

        let fallback = DeviceIdentityProvider.linux(environment: ["XDG_STATE_HOME": "relative", "HOME": root.path])
        let other = try fallback.current()
        XCTAssertNotEqual(other.id, relaunched.id)
        let localFile = root.appendingPathComponent(".local/state/vellum/device-id")
        XCTAssertEqual(try String(contentsOf: localFile, encoding: .utf8), other.id.rawValue)
        try Data("broken".utf8).write(to: localFile)
        XCTAssertThrowsError(try fallback.current())
        XCTAssertEqual(try String(contentsOf: localFile, encoding: .utf8), "broken")
    }
}
#endif
