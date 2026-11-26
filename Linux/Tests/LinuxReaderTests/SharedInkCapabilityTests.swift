import Foundation
import Testing
import VellumCore
@testable import LinuxReader

struct SharedInkCapabilityTests {
    @Test func knownPeersMustHaveCurrentMatchingAdvertisements() async throws {
        let fm = FileManager.default
        let workspace = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let library = workspace.appendingPathComponent("shared", isDirectory: true)
        try fm.createDirectory(at: library, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: workspace) }

        let root = try await RootDirectory.open(library)
        let readOnly = ReadOnlyLibraryFileStore(root: root)
        let capabilities = InkCapabilityStore.directory(in: library)
        #expect(try await readOnly.list(capabilities, suffix: nil).isEmpty)
        #expect(try fm.contentsOfDirectory(atPath: library.path).isEmpty)

        let identity: DeviceIdentityProvider<LinuxDeviceIDDefaults> = .linux(
            environment: ["XDG_STATE_HOME": workspace.appendingPathComponent("state").path])
        let context = try await SharedLibraryWriteContext.activate(
            root: root, inkCapabilityBuild: "linux/test-build", identity: identity)
        await context.advertiseInkCapability()
        let ownID = try identity.current().id
        let ownURL = capabilities.appendingPathComponent(ownID.rawValue + ".json")
        let ownRecord = try JSONDecoder().decode([String: JSONValue].self, from: Data(contentsOf: ownURL))
        #expect(ownRecord["device_id"] == .string(ownID.rawValue))
        #expect(ownRecord["app_build"] == .string("linux/test-build"))
        #expect(await !context.permitsInkEditing())

        // The I4-only peer has participated in managed reading positions, but
        // has no capabilities directory to enroll itself with.
        let positionStorage = FilePositionStorage(root: library.appendingPathComponent(".vellum/positions"))
        let peerID = DeviceID("ipad-i4")
        var position = PositionDeviceRecord(deviceID: peerID, deviceName: "iPad",
                                            devicePlatform: "ipados", writtenAt: .now)
        try await positionStorage.write(position)
        #expect(await !context.permitsInkEditing())

        let files = LocalFolderFileStore(root: library)
        let peerURL = capabilities.appendingPathComponent(peerID.rawValue + ".json")
        func advertisePeer(build: String, at date: Date = .now) async throws {
            try await InkCapabilityStore.advertise(in: library, device: peerID, appBuild: build, now: date,
                read: { url, _ in try await files.read(url) },
                replace: { url, data, previous in try await files.replace(url, with: data, ifCurrent: previous) })
        }
        try await advertisePeer(build: "iOS/0.1.1 (4)")
        #expect(await context.permitsInkEditing())

        var displacedBuild = ownRecord
        displacedBuild["app_build"] = .string("linux/other-build")
        try JSONEncoder().encode(displacedBuild).write(to: ownURL)
        #expect(await !context.permitsInkEditing())
        await context.advertiseInkCapability()
        #expect(await context.permitsInkEditing())

        // A replace by a downgraded position writer can preserve the clock and
        // unknown fields. Different bytes still invalidate its old ad.
        position.deviceName = "iPad after downgrade"
        try await positionStorage.write(position)
        #expect(await !context.permitsInkEditing())
        try await advertisePeer(build: "iOS/0.1.1 (5)")
        #expect(await context.permitsInkEditing())

        var fields = try JSONDecoder().decode([String: JSONValue].self, from: Data(contentsOf: peerURL))
        let futureValue: JSONValue = .object(["number": .int(99), "null": .null])
        fields["future"] = futureValue
        try JSONEncoder().encode(fields).write(to: peerURL)
        try await advertisePeer(build: "iOS/0.1.1 (6)")
        let valid = try Data(contentsOf: peerURL)
        fields = try JSONDecoder().decode([String: JSONValue].self, from: valid)
        #expect(fields["future"] == futureValue)
        #expect(fields["app_build"] == .string("iOS/0.1.1 (6)"))
        #expect(await context.permitsInkEditing())

        for (key, replacement) in [
            ("schema_version", JSONValue.int(2)),
            ("features", .array([])),
            ("advertised_at", .string("2020-01-01T00:00:00.000Z")),
            ("advertised_at", .string("2099-01-01T00:00:00.000Z")),
            ("device_id", .string("different-device")),
        ] {
            var bad = fields
            bad[key] = replacement
            let bytes = try JSONEncoder().encode(bad)
            try bytes.write(to: peerURL)
            #expect(await !context.permitsInkEditing(), "Unexpected grant for \(key)")
            #expect(try Data(contentsOf: peerURL) == bytes)
        }
        try Data("{".utf8).write(to: peerURL)
        #expect(await !context.permitsInkEditing())
        try valid.write(to: peerURL)

        let newerPosition = try PositionLayout.fileURL(in: positionStorage.root, for: peerID, version: 2)
        let conflict = capabilities.appendingPathComponent("ipad-i4.sync-conflict-20261126-120000-PEER.json")
        try fm.removeItem(at: peerURL)
        try fm.createSymbolicLink(at: peerURL, withDestinationURL: workspace.appendingPathComponent("missing"))
        #expect(await !context.permitsInkEditing())
        try fm.removeItem(at: peerURL)
        try valid.write(to: peerURL)
        for url in [newerPosition, conflict] {
            try valid.write(to: url)
            #expect(await !context.permitsInkEditing())
            try fm.removeItem(at: url)
        }
        #expect(await context.permitsInkEditing())

        let other = capabilities.appendingPathComponent("another-peer.json")
        try valid.write(to: other)
        #expect(await !context.permitsInkEditing())
        try fm.removeItem(at: other)
        // A vanished record does not erase the fact that the active library
        // already showed evidence of an additional participant.
        #expect(await !context.permitsInkEditing())
        await context.retire()
    }

    @Test func capabilityConflictsBlockPublicationAndInkEdits() async throws {
        let fm = FileManager.default
        let workspace = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let library = workspace.appendingPathComponent("shared", isDirectory: true)
        try fm.createDirectory(at: library, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: workspace) }

        let identity: DeviceIdentityProvider<LinuxDeviceIDDefaults> = .linux(
            environment: ["XDG_STATE_HOME": workspace.appendingPathComponent("state").path])
        let context = try await SharedLibraryWriteContext.activate(
            root: RootDirectory.open(library), inkCapabilityBuild: "linux/build", identity: identity)
        let files = LocalFolderFileStore(root: library)
        let directory = InkCapabilityStore.directory(in: library)
        let id = try identity.current().id
        let canonical = directory.appendingPathComponent(id.rawValue + ".json")
        let sibling = directory.appendingPathComponent(id.rawValue + ".sync-conflict-20261126-120000-PEER.json")
        let occupied = Data("preserve this conflict".utf8)
        try await files.replace(sibling, with: occupied)
        await context.advertiseInkCapability()
        #expect(try await files.read(canonical) == nil)
        #expect(try await files.read(sibling) == occupied)

        try await files.remove(sibling)
        await context.advertiseInkCapability()
        let original = try #require(try await files.read(canonical))
        try await InkCapabilityStore.advertise(in: library, device: DeviceID("mac"), appBuild: "macOS/4",
            read: { url, _ in try await files.read(url) },
            replace: { url, data, previous in try await files.replace(url, with: data, ifCurrent: previous) })
        #expect(await context.permitsInkEditing())

        let key = DocumentKey.pdf(stableIdentifier: "fixture")
        try await files.replace(sibling, with: occupied)
        try await context.savePosition(ReadingPosition(page: 2), for: key)
        #expect(try await files.read(canonical) == original)
        #expect(try await files.read(sibling) == occupied)
        #expect(await !context.permitsInkEditing())

        try await files.remove(sibling)
        let uuidArchive = directory.appendingPathComponent("conflicts", isDirectory: true)
            .appendingPathComponent(UUID().uuidString + ".json")
        let fallbackArchive = PreserveLosersConflictResolver.archiveURL(
            for: canonical, version: ConflictVersion(id: String(repeating: "x", count: 256)))
        #expect(!fallbackArchive.lastPathComponent.hasPrefix(id.rawValue + "."))
        for (index, archive) in [uuidArchive, fallbackArchive].enumerated() {
            await context.advertiseInkCapability()
            let clean = try #require(try await files.read(canonical))
            #expect(await context.permitsInkEditing())
            try await files.replace(archive, with: occupied)
            #expect(await !context.permitsInkEditing())
            try await context.savePosition(ReadingPosition(page: index + 3), for: key)
            #expect(try await files.read(canonical) == clean)
            try await files.remove(canonical)
            await context.advertiseInkCapability()
            #expect(try await files.read(canonical) == nil)
            #expect(try await files.read(archive) == occupied)
            #expect(await !context.permitsInkEditing())
            try await files.remove(archive)
        }
        await context.advertiseInkCapability()
        #expect(try await files.read(canonical) != original)
        #expect(await context.permitsInkEditing())
        await context.retire()
    }

    @Test func changingOrReplacingTheSelectedFolderDiscardsAGrant() async throws {
        let fm = FileManager.default
        let workspace = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let library = workspace.appendingPathComponent("shared", isDirectory: true)
        try fm.createDirectory(at: library, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: workspace) }
        let identity: DeviceIdentityProvider<LinuxDeviceIDDefaults> = .linux(
            environment: ["XDG_STATE_HOME": workspace.appendingPathComponent("state").path])
        let context = try await SharedLibraryWriteContext.activate(
            root: RootDirectory.open(library), inkCapabilityBuild: "linux/build", identity: identity)
        try await context.savePosition(ReadingPosition(page: 2), for: .pdf(stableIdentifier: "fixture"))
        let files = LocalFolderFileStore(root: library)
        try await InkCapabilityStore.advertise(in: library, device: DeviceID("ipad"), appBuild: "iOS/4",
            read: { url, _ in try await files.read(url) },
            replace: { url, data, previous in try await files.replace(url, with: data, ifCurrent: previous) })
        #expect(await context.permitsInkEditing())

        let displaced = workspace.appendingPathComponent("displaced", isDirectory: true)
        try fm.moveItem(at: library, to: displaced)
        try fm.createDirectory(at: library, withIntermediateDirectories: false)
        // Although existing document reads still use the pinned directory,
        // its grant cannot authorize ink in the replacement at this path.
        #expect(await !context.permitsInkEditing())
        await context.retire()
        let replacement = try await SharedLibraryWriteContext.activate(
            root: RootDirectory.open(library), inkCapabilityBuild: "linux/build", identity: identity)
        await replacement.advertiseInkCapability()
        #expect(await !replacement.permitsInkEditing())
        #expect(await !context.permitsInkEditing())
        await replacement.retire()
    }
}
