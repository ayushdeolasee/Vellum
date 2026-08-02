import Foundation
import Testing

@testable import Vellum

// Clause 7: only iCloud is coordinated. The local and custom-folder layouts
// keep the pre-existing uncoordinated tmp+rename path exactly as it is, and
// they must not so much as construct a container — coordination has a real cost
// and a real failure mode, and neither belongs on a folder that never syncs.
//
// Serialized: it drives `WebStorageSettings`' process-global overrides.

@Suite("Coordination seam — routing and identity", .serialized)
struct SyncedContainerRoutingTests {
    /// Proof the factory was never reached, not just that the result looks right.
    private final class FactoryProbe: @unchecked Sendable {
        private let lock = NSLock()
        private var calls = 0
        var callCount: Int { lock.withLock { calls } }
        func note() { lock.withLock { calls += 1 } }
    }

    private func scratch() -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("vellum-sync-routing-tests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// Anchors `Bundle(for:)` on the test bundle, which is the bundle a derived
    /// identifier would actually get wrong.
    private final class TestBundleAnchor {}

    /// Deriving the identifier from whichever bundle happens to be asking names
    /// `iCloud.com.ayushdeolasee.vellum.tests` from inside the test bundle — a
    /// container that does not exist. A literal is immune to who asks.
    @Test("The container identifier is explicit and never nil")
    func identifierIsALiteral() {
        let derivedFromTestBundle = "iCloud.\(Bundle(for: TestBundleAnchor.self).bundleIdentifier ?? "")"

        #expect(SyncedContainerIdentifier.vellum.rawValue == "iCloud.com.ayushdeolasee.vellum")
        #expect(SyncedContainerIdentifier.vellum.rawValue.hasPrefix("iCloud."))
        #expect(SyncedContainerIdentifier.vellum.rawValue != derivedFromTestBundle)
    }

    @Test("Local storage resolves to the direct path and constructs no container")
    func localIsDirect() {
        let storeDir = scratch()
        defer { try? FileManager.default.removeItem(at: storeDir) }
        let probe = FactoryProbe()

        let access = StorageAccess.resolve(mode: .local, storeDir: storeDir) {
            probe.note()
            return FakeSyncedContainer()
        }

        #expect(access.root == storeDir)
        #expect(!access.isCoordinated)
        #expect(probe.callCount == 0)
    }

    @Test("A custom folder resolves to the direct path and constructs no container")
    func customFolderIsDirect() {
        let storeDir = scratch()
        let customRoot = scratch()
        WebStorageSettings.customRootOverride = customRoot
        defer {
            WebStorageSettings.customRootOverride = nil
            try? FileManager.default.removeItem(at: storeDir)
            try? FileManager.default.removeItem(at: customRoot)
        }
        let probe = FactoryProbe()

        let access = StorageAccess.resolve(mode: .custom, storeDir: storeDir) {
            probe.note()
            return FakeSyncedContainer()
        }

        #expect(!access.isCoordinated)
        #expect(probe.callCount == 0)
    }

    @Test("Only the iCloud mode resolves to a coordinated access")
    func onlyICloudIsCoordinated() {
        let storeDir = scratch()
        let driveRoot = scratch()
        WebStorageSettings.icloudDriveRootOverride = driveRoot
        defer {
            WebStorageSettings.icloudDriveRootOverride = nil
            try? FileManager.default.removeItem(at: storeDir)
            try? FileManager.default.removeItem(at: driveRoot)
        }

        let access = StorageAccess.resolve(mode: .icloud, storeDir: storeDir) { FakeSyncedContainer() }

        #expect(access.isCoordinated)
        #expect(access.root == driveRoot.appendingPathComponent("Vellum/.vellum/records", isDirectory: true))
    }

    @Test("An unavailable container degrades to unavailable rather than to a nil-identifier container")
    func unavailableIsItsOwnAnswer() {
        let storeDir = scratch()
        defer { try? FileManager.default.removeItem(at: storeDir) }

        let access = StorageAccess.resolve(mode: .icloud, storeDir: storeDir) { nil }

        guard case .unavailable = access else {
            Issue.record("iCloud with no container must resolve to .unavailable, got \(access)")
            return
        }
        #expect(access.container == nil)
        #expect(access.root == nil)
    }
}
