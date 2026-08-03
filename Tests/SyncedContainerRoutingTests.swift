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

    private final class IdentifierProbe: @unchecked Sendable {
        private let lock = NSLock()
        private var seen: [SyncedContainerIdentifier] = []
        var identifiers: [SyncedContainerIdentifier] { lock.withLock { seen } }
        func note(_ identifier: SyncedContainerIdentifier) {
            lock.withLock { seen.append(identifier) }
        }
    }

    private final class BlockingRootLookup: @unchecked Sendable {
        private let lock = NSLock()
        private let lookupStarted: DispatchSemaphore
        private let releaseLookup: DispatchSemaphore
        private let result: URL?
        private var calls = 0

        init(result: URL?, lookupStarted: DispatchSemaphore, releaseLookup: DispatchSemaphore) {
            self.result = result
            self.lookupStarted = lookupStarted
            self.releaseLookup = releaseLookup
        }

        var callCount: Int { lock.withLock { calls } }

        func lookup(_ identifier: SyncedContainerIdentifier) -> URL? {
            lock.withLock { calls += 1 }
            lookupStarted.signal()
            _ = releaseLookup.wait(timeout: .now() + 5)
            return result
        }
    }

    private final class RootResults: @unchecked Sendable {
        private let lock = NSLock()
        private var roots: [URL?] = []

        var values: [URL?] { lock.withLock { roots } }

        func append(_ root: URL?) {
            lock.withLock { roots.append(root) }
        }
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

    @Test("The shared resolver passes the fixed identifier explicitly")
    func sharedResolverPassesTheFixedIdentifier() {
        let containerRoot = scratch()
        let probe = IdentifierProbe()
        VellumUbiquityContainerRoot.resetCacheForTests()
        VellumUbiquityContainerRoot.rootLookupOverride = { identifier in
            probe.note(identifier)
            return containerRoot
        }
        defer {
            VellumUbiquityContainerRoot.resetCacheForTests()
            try? FileManager.default.removeItem(at: containerRoot)
        }

        let root = VellumUbiquityContainerRoot.root(for: .vellum, environment: [:])

        #expect(root == containerRoot)
        #expect(probe.identifiers == [.vellum])
    }

    @Test("Concurrent first root callers share one blocking lookup", .timeLimit(.minutes(1)))
    func concurrentFirstCallSharesOneLookupAndOneRoot() {
        let containerRoot = scratch()
        let lookupStarted = DispatchSemaphore(value: 0)
        let releaseLookup = DispatchSemaphore(value: 0)
        let followerWaited = DispatchSemaphore(value: 0)
        let results = RootResults()
        let lookup = BlockingRootLookup(
            result: containerRoot,
            lookupStarted: lookupStarted,
            releaseLookup: releaseLookup)
        VellumUbiquityContainerRoot.resetCacheForTests()
        VellumUbiquityContainerRoot.rootLookupOverride = lookup.lookup
        VellumUbiquityContainerRoot.observeWaitForResolvingRootForTests { identifier in
            if identifier == .vellum {
                followerWaited.signal()
            }
        }
        defer {
            releaseLookup.signal()
            releaseLookup.signal()
            VellumUbiquityContainerRoot.resetCacheForTests()
            try? FileManager.default.removeItem(at: containerRoot)
        }

        let group = DispatchGroup()
        group.enter()
        DispatchQueue.global(qos: .userInitiated).async {
            let root = VellumUbiquityContainerRoot.root(for: .vellum, environment: [:])
            results.append(root)
            group.leave()
        }
        guard lookupStarted.wait(timeout: .now() + 2) == .success else {
            Issue.record("The first caller never entered the blocking ubiquity lookup")
            return
        }

        group.enter()
        DispatchQueue.global(qos: .userInitiated).async {
            let root = VellumUbiquityContainerRoot.root(for: .vellum, environment: [:])
            results.append(root)
            group.leave()
        }
        guard followerWaited.wait(timeout: .now() + 2) == .success else {
            Issue.record("The concurrent caller did not wait on the in-flight lookup")
            releaseLookup.signal()
            _ = group.wait(timeout: .now() + 2)
            return
        }

        #expect(lookup.callCount == 1)
        releaseLookup.signal()
        #expect(group.wait(timeout: .now() + 2) == .success)

        let roots = results.values
        #expect(roots.count == 2)
        #expect(roots.allSatisfy { $0 == containerRoot })
        #expect(lookup.callCount == 1)
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
        #expect(access.isCoordinated == false)
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

        #expect(access.isCoordinated == false)
        #expect(probe.callCount == 0)
    }

    @Test("Only the iCloud mode resolves to a coordinated access")
    func onlyICloudIsCoordinated() {
        let storeDir = scratch()
        let containerRoot = scratch()
        VellumUbiquityContainerRoot.resetCacheForTests()
        VellumUbiquityContainerRoot.rootLookupOverride = { _ in containerRoot }
        WebStorageSettings.resolveICloudRoot()
        defer {
            VellumUbiquityContainerRoot.resetCacheForTests()
            try? FileManager.default.removeItem(at: storeDir)
            try? FileManager.default.removeItem(at: containerRoot)
        }

        let access = StorageAccess.resolve(mode: .icloud, storeDir: storeDir) { FakeSyncedContainer() }

        #expect(access.isCoordinated)
        #expect(
            access.root == containerRoot
                .appendingPathComponent("Documents/Vellum/.vellum/records", isDirectory: true))
    }

    @Test("DEBUG fake ubiquity root drives the byte-compatible WebStorage layout")
    func debugFakeRootDrivesTheWebStorageLayout() {
        let storeDir = scratch()
        let fakeContainerRoot = scratch()
        let probe = FactoryProbe()
        WebStorageSettings.modeOverride = .icloud
        VellumUbiquityContainerRoot.resetCacheForTests()
        VellumUbiquityContainerRoot.rootLookupOverride = { _ in
            probe.note()
            return nil
        }
        WebStorageSettings.resolveICloudRoot(environment: [
            VellumUbiquityContainerRoot.fakeRootEnvironmentKey: fakeContainerRoot.path
        ])
        defer {
            WebStorageSettings.modeOverride = nil
            VellumUbiquityContainerRoot.resetCacheForTests()
            try? FileManager.default.removeItem(at: storeDir)
            try? FileManager.default.removeItem(at: fakeContainerRoot)
        }

        let layout = WebStorageLayout.resolve(mode: WebStorageSettings.effectiveMode, storeDir: storeDir)

        #expect(WebStorageSettings.effectiveMode == .icloud)
        #expect(probe.callCount == 0)
        #expect(
            layout.recordsDir == fakeContainerRoot
                .appendingPathComponent("Documents/Vellum/.vellum/records", isDirectory: true))
        #expect(
            layout.archivesDir == fakeContainerRoot
                .appendingPathComponent("Documents/Vellum/Web Pages", isDirectory: true))
        #expect(
            layout.documentsDir == fakeContainerRoot
                .appendingPathComponent("Documents/Vellum/.vellum/documents", isDirectory: true))
    }

    @Test("An unavailable container degrades to unavailable rather than to a nil-identifier container")
    func unavailableIsItsOwnAnswer() {
        let storeDir = scratch()
        WebStorageSettings.modeOverride = .icloud
        VellumUbiquityContainerRoot.resetCacheForTests()
        let probe = FactoryProbe()
        VellumUbiquityContainerRoot.rootLookupOverride = { _ in
            probe.note()
            return nil
        }
        WebStorageSettings.resolveICloudRoot(environment: [:])
        defer {
            WebStorageSettings.modeOverride = nil
            VellumUbiquityContainerRoot.resetCacheForTests()
            try? FileManager.default.removeItem(at: storeDir)
        }
        _ = VellumUbiquityContainerRoot.root(for: .vellum, environment: [:])

        let access = StorageAccess.resolve(mode: .icloud, storeDir: storeDir) { nil }

        guard case .unavailable = access else {
            Issue.record("iCloud with no container must resolve to .unavailable, got \(access)")
            return
        }
        #expect(WebStorageSettings.effectiveMode == .local)
        #expect(WebStorageSettings.modeIsDegraded)
        #expect(access.container == nil)
        #expect(access.root == nil)
        #expect(probe.callCount == 1)
    }
}
