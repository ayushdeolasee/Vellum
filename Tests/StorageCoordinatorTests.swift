import Foundation
import Testing

@testable import Vellum

@Suite("StorageCoordinator orchestration", .serialized, .isolatedStorage)
struct StorageCoordinatorTests {
    private let records = URL(fileURLWithPath: "/vellum/records", isDirectory: true)

    private static let current = ConflictVersion(id: "v-current", isCurrent: true)
    private static let loser = ConflictVersion(id: "v-loser", isCurrent: false)

    private func url(_ name: String) -> URL {
        records.appendingPathComponent(name)
    }

    private func scratch(_ name: String = "storage-coordinator") -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(name)-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func installRoot(_ root: URL?) {
        VellumUbiquityContainerRoot.resetCacheForTests()
        VellumUbiquityContainerRoot.rootLookupOverride = { _ in root }
        WebStorageSettings.resolveICloudRoot(environment: [:])
    }

    private func coordinator(
        chosenMode: WebStorageMode?,
        storeDir: URL,
        factory: @escaping @Sendable () async -> (any SyncedContainer)?,
        effectiveMode: @escaping @Sendable () -> WebStorageMode,
        conflictArchiveRegistry: StorageCoordinator.ConflictArchiveRegistry =
            ConflictArchiveRegistryState().registry
    ) -> StorageCoordinator {
        StorageCoordinator(
            storeDir: storeDir,
            modeProvider: { chosenMode },
            effectiveModeProvider: effectiveMode,
            rootResolver: {
                WebStorageSettings.resolveICloudRoot(environment: [:])
                return WebStorageSettings.icloudVellumRoot
            },
            containerFactory: factory,
            conflictArchiveRegistry: conflictArchiveRegistry)
    }

    @Test("Local and custom modes never construct a synced container")
    func localAndCustomNeverConstructContainer() async {
        let storeDir = scratch("storage-direct")
        let customRoot = scratch("storage-custom")
        let probe = FactoryProbe()
        WebStorageSettings.customRootOverride = customRoot
        defer {
            WebStorageSettings.customRootOverride = nil
            try? FileManager.default.removeItem(at: storeDir)
            try? FileManager.default.removeItem(at: customRoot)
        }

        let local = coordinator(
            chosenMode: .local,
            storeDir: storeDir,
            factory: { probe.note(); return FakeSyncedContainer() },
            effectiveMode: { .local })
        let custom = coordinator(
            chosenMode: .custom,
            storeDir: storeDir,
            factory: { probe.note(); return FakeSyncedContainer() },
            effectiveMode: { .custom })

        await local.start()
        await custom.start()

        #expect(probe.callCount == 0)
        #expect(await local.currentStatus().availability == .direct)
        #expect(await custom.currentStatus().availability == .direct)
    }

    @Test("iCloud unavailable reports local fallback and leaves WebStorage local")
    func unavailableICloudIsExplicitLocalFallback() async {
        let storeDir = scratch("storage-unavailable")
        let probe = FactoryProbe()
        WebStorageSettings.modeOverride = .icloud
        installRoot(nil)
        defer {
            WebStorageSettings.modeOverride = nil
            VellumUbiquityContainerRoot.resetCacheForTests()
            try? FileManager.default.removeItem(at: storeDir)
        }

        let coordinator = coordinator(
            chosenMode: .icloud,
            storeDir: storeDir,
            factory: { probe.note(); return FakeSyncedContainer() },
            effectiveMode: { WebStorageSettings.effectiveMode })

        await coordinator.start()
        let status = await coordinator.currentStatus()
        let layout = WebStorageLayout.resolve(mode: WebStorageSettings.effectiveMode, storeDir: storeDir)

        #expect(probe.callCount == 0)
        #expect(status.chosenMode == .icloud)
        #expect(status.effectiveMode == .local)
        #expect(status.availability == .degradedToLocal(.iCloudUnavailable))
        #expect(WebStorageSettings.effectiveMode == .local)
        #expect(layout == .local(storeDir: storeDir))
    }

    @Test("Concurrent start is single-flight and installs one conflict consumer")
    func concurrentStartIsSingleFlight() async {
        let storeDir = scratch("storage-start")
        let root = scratch("storage-root")
        let resolver = CountingResolver(outcomes: [.success(.keptCurrent(archivedLosers: []))])
        let container = FakeSyncedContainer(resolver: resolver)
        let probe = FactoryProbe()
        installRoot(root)
        defer {
            VellumUbiquityContainerRoot.resetCacheForTests()
            try? FileManager.default.removeItem(at: storeDir)
            try? FileManager.default.removeItem(at: root)
        }
        let coordinator = coordinator(
            chosenMode: .icloud,
            storeDir: storeDir,
            factory: { probe.note(); return container },
            effectiveMode: { .icloud })

        async let first: Void = coordinator.start()
        async let second: Void = coordinator.start()
        async let third: Void = coordinator.start()
        _ = await (first, second, third)

        container.seed(url("a.json"), data: Data("current".utf8))
        container.injectConflict(at: url("a.json"), versions: [Self.current, Self.loser])
        await resolver.waitForCount(1)

        #expect(probe.callCount == 1)
        #expect(resolver.seenCount == 1)
        #expect(await coordinator.currentStatus().acceptsCoordinatedOperations)
    }

    @Test("Duplicate conflict notifications are deduped by URL and version set")
    func duplicateConflictEventsAreDeduped() async {
        let storeDir = scratch("storage-duplicates")
        let root = scratch("storage-root")
        let resolver = CountingResolver(outcomes: [.success(.keptCurrent(archivedLosers: []))])
        let container = FakeSyncedContainer(resolver: resolver)
        installRoot(root)
        defer {
            VellumUbiquityContainerRoot.resetCacheForTests()
            try? FileManager.default.removeItem(at: storeDir)
            try? FileManager.default.removeItem(at: root)
        }
        let coordinator = coordinator(
            chosenMode: .icloud,
            storeDir: storeDir,
            factory: { container },
            effectiveMode: { .icloud })
        await coordinator.start()

        let target = url("a.json")
        container.seed(target, data: Data("current".utf8))
        container.injectConflict(at: target, versions: [Self.current, Self.loser])
        container.injectConflict(at: target, versions: [Self.loser, Self.current])
        await resolver.waitForCount(1)

        #expect(resolver.seenCount == 1)
        #expect(await coordinator.currentStatus().pendingConflicts == 0)
    }

    @Test("Preserved conflict archives remain coordinated for export and delete")
    func preservedConflictArchivesCanBeRecoveredAndDeleted() async throws {
        let storeDir = scratch("storage-conflict-archive")
        let root = scratch("storage-root")
        let target = url("scratchpad.md")
        let archive = target.deletingLastPathComponent()
            .appendingPathComponent("conflicts/scratchpad.v-loser.md")
        let loserBytes = Data("losing notes".utf8)
        let resolver = CountingResolver(outcomes: [
            .success(.keptCurrent(archivedLosers: [archive]))
        ])
        let container = FakeSyncedContainer(resolver: resolver)
        installRoot(root)
        defer {
            VellumUbiquityContainerRoot.resetCacheForTests()
            try? FileManager.default.removeItem(at: storeDir)
            try? FileManager.default.removeItem(at: root)
        }
        let coordinator = coordinator(
            chosenMode: .icloud,
            storeDir: storeDir,
            factory: { container },
            effectiveMode: { .icloud })
        await coordinator.start()

        container.seed(target, data: Data("current notes".utf8))
        container.seed(archive, data: loserBytes, readiness: .notDownloaded)
        container.injectConflict(at: target, versions: [Self.current, Self.loser])
        await resolver.waitForCount(1)
        await coordinator.awaitQuiescence()

        let descriptor = try #require(await coordinator.archivedConflicts().first)
        let exported = try await coordinator.exportArchivedConflict(descriptor)
        #expect(try Data(contentsOf: exported) == loserBytes)
        #expect(container.coordinatedReadCount == 1)
        #expect(container.materializationCount == 1)
        #expect(container.directoryEnumerationCount == 0)
        #expect(container.existenceCheckCount == 0)

        try await coordinator.deleteArchivedConflict(descriptor)
        #expect(container.peek(archive) == nil)
        #expect(container.coordinatedRemoveCount == 1)
        #expect(await coordinator.archivedConflicts().isEmpty)
    }

    @Test("Archive export participates in background drain")
    func archiveExportDrainsBeforeSuspend() async throws {
        let storeDir = scratch("storage-conflict-export-drain")
        let root = scratch("storage-root")
        let target = url("scratchpad.md")
        let archive = target.deletingLastPathComponent()
            .appendingPathComponent("conflicts/scratchpad.v-loser.md")
        let resolver = CountingResolver(outcomes: [
            .success(.keptCurrent(archivedLosers: [archive]))
        ])
        let base = FakeSyncedContainer(resolver: resolver)
        let container = BlockingRecoveryContainer(base: base)
        installRoot(root)
        defer {
            VellumUbiquityContainerRoot.resetCacheForTests()
            try? FileManager.default.removeItem(at: storeDir)
            try? FileManager.default.removeItem(at: root)
        }
        let coordinator = coordinator(
            chosenMode: .icloud,
            storeDir: storeDir,
            factory: { container },
            effectiveMode: { .icloud })
        await coordinator.start()

        base.seed(target, data: Data("current".utf8))
        base.seed(archive, data: Data("loser".utf8))
        base.injectConflict(at: target, versions: [Self.current, Self.loser])
        await resolver.waitForCount(1)
        await coordinator.awaitQuiescence()
        let descriptor = try #require(await coordinator.archivedConflicts().first)

        let export = Task { try await coordinator.exportArchivedConflict(descriptor) }
        await container.readGate.waitUntilEntered()
        let background = Task { await coordinator.background() }
        await waitUntil {
            let status = await coordinator.currentStatus()
            return status.lifecycle == .backgrounding && status.inFlightOperations == 1
        }

        #expect(base.isSuspended == false)
        await container.readGate.release()
        _ = try await export.value
        let outcome = await background.value
        #expect(outcome.drained)
        #expect(base.isSuspended)
    }

    @Test("Archive deletion participates in background drain")
    func archiveDeletionDrainsBeforeSuspend() async throws {
        let storeDir = scratch("storage-conflict-delete-drain")
        let root = scratch("storage-root")
        let target = url("scratchpad.md")
        let archive = target.deletingLastPathComponent()
            .appendingPathComponent("conflicts/scratchpad.v-loser.md")
        let resolver = CountingResolver(outcomes: [
            .success(.keptCurrent(archivedLosers: [archive]))
        ])
        let base = FakeSyncedContainer(resolver: resolver)
        let container = BlockingRecoveryContainer(base: base)
        installRoot(root)
        defer {
            VellumUbiquityContainerRoot.resetCacheForTests()
            try? FileManager.default.removeItem(at: storeDir)
            try? FileManager.default.removeItem(at: root)
        }
        let coordinator = coordinator(
            chosenMode: .icloud,
            storeDir: storeDir,
            factory: { container },
            effectiveMode: { .icloud })
        await coordinator.start()

        base.seed(target, data: Data("current".utf8))
        base.seed(archive, data: Data("loser".utf8))
        base.injectConflict(at: target, versions: [Self.current, Self.loser])
        await resolver.waitForCount(1)
        await coordinator.awaitQuiescence()
        let descriptor = try #require(await coordinator.archivedConflicts().first)

        let deletion = Task { try await coordinator.deleteArchivedConflict(descriptor) }
        await container.removeGate.waitUntilEntered()
        let background = Task { await coordinator.background() }
        await waitUntil {
            let status = await coordinator.currentStatus()
            return status.lifecycle == .backgrounding && status.inFlightOperations == 1
        }

        #expect(base.isSuspended == false)
        await container.removeGate.release()
        try await deletion.value
        let outcome = await background.value
        #expect(outcome.drained)
        #expect(base.isSuspended)
    }

    @Test("Preserved conflict archives are rediscovered after coordinator restart")
    func archivedConflictsSurviveRestart() async throws {
        let storeDir = scratch("storage-conflict-restart")
        let root = scratch("storage-root")
        let syncedRoot = root.appendingPathComponent("Documents/Vellum", isDirectory: true)
        let target = syncedRoot.appendingPathComponent(
            ".vellum/documents/key/scratchpad.md")
        let archive = target.deletingLastPathComponent()
            .appendingPathComponent("conflicts/scratchpad.v-loser.md")
        let registryState = ConflictArchiveRegistryState()
        let resolver = CountingResolver(outcomes: [
            .success(.keptCurrent(archivedLosers: [archive]))
        ])
        let firstContainer = FakeSyncedContainer(resolver: resolver)
        installRoot(root)
        defer {
            VellumUbiquityContainerRoot.resetCacheForTests()
            try? FileManager.default.removeItem(at: storeDir)
            try? FileManager.default.removeItem(at: root)
        }

        let firstCoordinator = coordinator(
            chosenMode: .icloud,
            storeDir: storeDir,
            factory: { firstContainer },
            effectiveMode: { .icloud },
            conflictArchiveRegistry: registryState.registry)
        await firstCoordinator.start()
        firstContainer.seed(target, data: Data("current".utf8))
        firstContainer.seed(archive, data: Data("loser".utf8))
        firstContainer.injectConflict(at: target, versions: [Self.current, Self.loser])
        await resolver.waitForCount(1)
        await firstCoordinator.awaitQuiescence()
        #expect(await firstCoordinator.archivedConflicts().count == 1)
        await firstCoordinator.stop()

        let secondContainer = FakeSyncedContainer()
        secondContainer.seed(archive, data: Data("loser".utf8))
        let secondCoordinator = coordinator(
            chosenMode: .icloud,
            storeDir: storeDir,
            factory: { secondContainer },
            effectiveMode: { .icloud },
            conflictArchiveRegistry: registryState.registry)
        await secondCoordinator.start()

        let restored = try #require(await secondCoordinator.archivedConflicts().first)
        #expect(restored.archiveURL == archive)
        #expect(secondContainer.metadataQueryCount == 1)
        #expect(secondContainer.directoryEnumerationCount == 0)
        #expect(secondContainer.existenceCheckCount == 0)
    }

    @Test("Incomplete iCloud discovery keeps the launch relocation marker")
    func incompleteDiscoveryKeepsLaunchRelocationPending() async {
        let storeDir = scratch("storage-incomplete-relocation")
        let root = scratch("storage-root")
        let localLayout = WebStorageLayout.local(storeDir: storeDir)
        let source = WebStorageLayout.pretty(
            root: root.appendingPathComponent("Documents/Vellum", isDirectory: true),
            recordsInRoot: true,
            localStoreDir: storeDir)
        let container = FakeSyncedContainer()
        container.failNextList(with: .timedOut(source.recordsDir))
        installRoot(root)
        WebLibrary.layoutOverride = localLayout
        WebStorageMigrator.recordPendingRelocation(mode: .icloud, customPath: nil)
        defer {
            WebStorageMigrator.clearPendingRelocation()
            WebLibrary.layoutOverride = nil
            VellumUbiquityContainerRoot.resetCacheForTests()
            try? FileManager.default.removeItem(at: storeDir)
            try? FileManager.default.removeItem(at: root)
        }
        let coordinator = coordinator(
            chosenMode: .local,
            storeDir: storeDir,
            factory: { container },
            effectiveMode: { .local })
        await coordinator.start()

        await WebStorageMigrator.sweepAtLaunch(coordinator: coordinator)

        #expect(AppDefaults.current.string(
            forKey: WebStorageSettings.pendingRelocationKey) != nil)
        #expect(container.metadataQueryCount > 0)
        #expect(container.coordinatedRemoveCount == 0)
    }

    @Test("Managed web archive conflicts are rediscovered without trusting arbitrary URLs")
    func managedWebArchiveConflictsSurviveRestart() async throws {
        let storeDir = scratch("storage-web-conflict-restart")
        let root = scratch("storage-root")
        let syncedRoot = root.appendingPathComponent("Documents/Vellum", isDirectory: true)
        let layout = WebStorageLayout.pretty(
            root: syncedRoot, recordsInRoot: true, localStoreDir: storeDir)
        let original = layout.archivesDir.appendingPathComponent("Article.vellumweb")
        let archive = layout.archivesDir.appendingPathComponent(
            "conflicts/Article.v-loser.vellumweb")
        let wrongShape = layout.archivesDir.appendingPathComponent("Untrusted.vellumweb")
        let unmanagedOriginal = syncedRoot.appendingPathComponent("Other/notes.md")
        let unmanagedArchive = syncedRoot.appendingPathComponent(
            "Other/conflicts/notes.v-loser.md")
        let registryState = ConflictArchiveRegistryState()
        let descriptors = [
            StorageCoordinator.ArchivedConflict(
                archiveURL: archive, originalURL: original, detectedAt: .now),
            StorageCoordinator.ArchivedConflict(
                archiveURL: wrongShape, originalURL: original, detectedAt: .now),
            StorageCoordinator.ArchivedConflict(
                archiveURL: unmanagedArchive, originalURL: unmanagedOriginal, detectedAt: .now),
        ]
        registryState.registry.save(descriptors)
        let container = FakeSyncedContainer()
        for descriptor in descriptors {
            container.seed(descriptor.archiveURL, data: Data("preserved".utf8))
        }
        installRoot(root)
        defer {
            VellumUbiquityContainerRoot.resetCacheForTests()
            try? FileManager.default.removeItem(at: storeDir)
            try? FileManager.default.removeItem(at: root)
        }
        let coordinator = coordinator(
            chosenMode: .icloud,
            storeDir: storeDir,
            factory: { container },
            effectiveMode: { .icloud },
            conflictArchiveRegistry: registryState.registry)

        await coordinator.start()

        let restored = await coordinator.archivedConflicts()
        #expect(restored.map(\.archiveURL) == [archive])
        #expect(container.metadataQueryCount == 1)
        #expect(container.directoryEnumerationCount == 0)
        #expect(container.existenceCheckCount == 0)
    }

    @Test("Review keeps bytes and Restore archives the current copy before replacement")
    func reviewedConflictRestorationIsRecoverable() async throws {
        let storeDir = scratch("conflict-restore")
        let root = scratch("conflict-root")
        let layout = WebStorageLayout.pretty(root: root.appendingPathComponent("Documents/Vellum"),
                                             recordsInRoot: true, localStoreDir: storeDir)
        let original = layout.documentsDir.appendingPathComponent("abc123/conversations.json")
        let archive = original.deletingLastPathComponent().appendingPathComponent("conflicts/conversations.loser.json")
        let descriptor = StorageCoordinator.ArchivedConflict(archiveURL: archive,
            originalURL: original, detectedAt: .now)
        let registryState = ConflictArchiveRegistryState()
        registryState.registry.save([descriptor])
        let container = FakeSyncedContainer()
        container.seed(original, data: Data("current".utf8))
        container.seed(archive, data: Data("preserved".utf8))
        installRoot(root)
        defer {
            VellumUbiquityContainerRoot.resetCacheForTests()
            try? FileManager.default.removeItem(at: storeDir)
            try? FileManager.default.removeItem(at: root)
        }
        let coordinator = coordinator(chosenMode: .icloud, storeDir: storeDir,
            factory: { container }, effectiveMode: { .icloud }, conflictArchiveRegistry: registryState.registry)
        await coordinator.start()
        #expect(await coordinator.archivedConflicts().first?.needsReview == true)
        do {
            try await coordinator.restoreArchivedConflict(descriptor, admissionAllowed: { false })
            Issue.record("an open document must reject restoration")
        } catch { }
        #expect(container.peek(original) == Data("current".utf8))
        container.failNextWrite(with: .io("backup denied"))
        do {
            try await coordinator.restoreArchivedConflict(descriptor)
            Issue.record("backup failure must reject restoration")
        } catch { }
        #expect(container.peek(original) == Data("current".utf8))
        #expect(container.peek(archive) == Data("preserved".utf8))
        #expect(await coordinator.archivedConflicts().first?.needsReview == true)
        try await coordinator.restoreArchivedConflict(descriptor)
        #expect(container.peek(original) == Data("preserved".utf8))
        let restored = await coordinator.archivedConflicts()
        let backup = try #require(restored.first { $0.archiveURL != archive })
        #expect(container.peek(backup.archiveURL) == Data("current".utf8))
        #expect(restored.allSatisfy { !$0.needsReview })
        #expect(registryState.registry.load().allSatisfy { !$0.needsReview })
        try await coordinator.keepCurrentForArchivedConflict(backup)
        #expect(container.peek(backup.archiveURL) == Data("current".utf8))
        // Older registry descriptors decode as needing review without migration.
        let decoded = try JSONDecoder().decode(StorageCoordinator.ArchivedConflict.self,
                                               from: JSONEncoder().encode(descriptor))
        #expect(decoded.needsReview)
    }

    @Test("A provider failure after replacement retains both copies and needs review", arguments: [false, true])
    func committedRestoreFailureRemainsReviewable(onReadBack: Bool) async throws {
        let storeDir = scratch("restore-postcommit")
        let root = scratch("restore-root")
        let layout = WebStorageLayout.pretty(root: root.appendingPathComponent("Documents/Vellum"),
                                             recordsInRoot: true, localStoreDir: storeDir)
        let original = layout.documentsDir.appendingPathComponent("abc12345/conversations.json")
        let archive = original.deletingLastPathComponent().appendingPathComponent("conflicts/conversations.loser.json")
        var descriptor = StorageCoordinator.ArchivedConflict(archiveURL: archive,
            originalURL: original, detectedAt: .now)
        descriptor.reviewedAt = .now
        let registryState = ConflictArchiveRegistryState()
        registryState.registry.save([descriptor])
        let container = FakeSyncedContainer()
        container.seed(original, data: Data("current".utf8))
        container.seed(archive, data: Data("preserved".utf8))
        container.failAfterNextReplacement(at: original, onReadBack: onReadBack)
        installRoot(root)
        defer {
            VellumUbiquityContainerRoot.resetCacheForTests()
            try? FileManager.default.removeItem(at: storeDir)
            try? FileManager.default.removeItem(at: root)
        }
        let coordinator = coordinator(chosenMode: .icloud, storeDir: storeDir,
            factory: { container }, effectiveMode: { .icloud }, conflictArchiveRegistry: registryState.registry)
        await coordinator.start()
        do {
            try await coordinator.restoreArchivedConflict(descriptor)
            Issue.record("an unverified replacement must report uncertainty")
        } catch let error as StorageCoordinator.ArchivedConflictError {
            #expect(error == .replacementUnverified)
        }
        #expect(container.peek(original) == Data("preserved".utf8))
        let copies = await coordinator.archivedConflicts()
        let backup = try #require(copies.first { $0.archiveURL != archive })
        #expect(container.peek(backup.archiveURL) == Data("current".utf8))
        #expect(container.peek(archive) == Data("preserved".utf8))
        #expect(copies.allSatisfy { $0.needsReview })
        #expect(registryState.registry.load().allSatisfy { $0.needsReview })
    }

    @MainActor
    @Test("Chat remains pending while its dirty snapshot is in flight")
    func chatPendingIncludesInFlightSnapshot() async throws {
        let storeDir = scratch("pending-chat")
        let root = scratch("pending-chat-root")
        let key = UUID().uuidString.lowercased()
        let layout = WebStorageLayout.pretty(root: root.appendingPathComponent("Documents/Vellum"),
                                             recordsInRoot: true, localStoreDir: storeDir)
        let original = layout.documentsDir.appendingPathComponent("\(key)/conversations.json")
        let gate = AsyncGate()
        let container = FakeSyncedContainer(beforeReplace: { url in
            if url == original { await gate.enterAndWait() }
        })
        container.seed(original, data: try JSONEncoder().encode([AiMessage]()))
        installRoot(root)
        let previousOverride = DocumentDataStore.rootDirectoryOverride
        DocumentDataStore.rootDirectoryOverride = nil
        defer {
            DocumentDataStore.rootDirectoryOverride = previousOverride
            AiPersistence.invalidateCachedConversation(forKey: key)
            VellumUbiquityContainerRoot.resetCacheForTests()
            try? FileManager.default.removeItem(at: storeDir)
            try? FileManager.default.removeItem(at: root)
        }
        let coordinator = coordinator(chosenMode: .icloud, storeDir: storeDir,
            factory: { container }, effectiveMode: { .icloud })
        await coordinator.start()
        let document = DocumentInfo(kind: .pdf, pdfPath: root.appendingPathComponent("closed.pdf").path,
            title: nil, pageCount: nil, lastPage: nil, docId: key)
        _ = await AiPersistence.loadConversation(for: document, coordinator: coordinator)
        AiPersistence.saveConversation(for: document,
            messages: [AiPersistence.makeMessage(role: .user, content: "draft")], coordinator: coordinator)
        let flush = Task { @MainActor in await AiPersistence.awaitPendingFlush() }
        do { try await gate.waitUntilEntered(timeout: .seconds(3)) }
        catch {
            await gate.release()
            _ = await flush.value
            throw error
        }
        #expect(AiPersistence.hasPendingChanges(forKey: key))
        #expect(AiPersistence.hasPendingChanges)
        await gate.release()
        #expect(await flush.value)
        #expect(!AiPersistence.hasPendingChanges(forKey: key))
    }

    @MainActor
    @Test("Workspace recovery joins resource work and reloads a committed but unverified copy")
    func workspaceRestoreDrainsAndInvalidatesCleanCache() async throws {
        let storeDir = scratch("workspace-restore")
        let root = scratch("workspace-restore-root")
        let key = UUID().uuidString.lowercased()
        let layout = WebStorageLayout.pretty(root: root.appendingPathComponent("Documents/Vellum"),
                                             recordsInRoot: true, localStoreDir: storeDir)
        let original = layout.documentsDir.appendingPathComponent("\(key)/conversations.json")
        let archive = original.deletingLastPathComponent().appendingPathComponent("conflicts/conversations.loser.json")
        let descriptor = StorageCoordinator.ArchivedConflict(archiveURL: archive,
            originalURL: original, detectedAt: .now)
        let registryState = ConflictArchiveRegistryState()
        registryState.registry.save([descriptor])
        let old = try JSONEncoder().encode([AiPersistence.makeMessage(role: .user, content: "current")])
        let restored = try JSONEncoder().encode([AiPersistence.makeMessage(role: .user, content: "preserved")])
        let container = FakeSyncedContainer()
        container.seed(original, data: old)
        container.seed(archive, data: restored)
        container.failAfterNextReplacement(at: original, onReadBack: true)
        installRoot(root)
        let previousOverride = DocumentDataStore.rootDirectoryOverride
        DocumentDataStore.rootDirectoryOverride = nil
        defer {
            DocumentDataStore.rootDirectoryOverride = previousOverride
            AiPersistence.invalidateCachedConversation(forKey: key)
            VellumUbiquityContainerRoot.resetCacheForTests()
            try? FileManager.default.removeItem(at: storeDir)
            try? FileManager.default.removeItem(at: root)
        }
        let coordinator = coordinator(chosenMode: .icloud, storeDir: storeDir,
            factory: { container }, effectiveMode: { .icloud }, conflictArchiveRegistry: registryState.registry)
        await coordinator.start()
        let workspace = WorkspaceStore(sessions: DocumentSessionManager(), storageCoordinator: coordinator)
        let document = DocumentInfo(kind: .pdf, pdfPath: root.appendingPathComponent("closed.pdf").path,
            title: nil, pageCount: nil, lastPage: nil, docId: key)
        #expect(await AiPersistence.loadConversation(for: document, coordinator: coordinator).first?.content == "current")
        let gate = AsyncGate()
        let earlier = Task { @MainActor in
            await gate.enterAndWait()
            workspace.tabTeardowns.finish(tabId: "earlier")
        }
        workspace.tabTeardowns.register(tabId: "earlier", document: document, task: earlier)
        do { try await gate.waitUntilEntered(timeout: .seconds(3)) }
        catch {
            await gate.release()
            await earlier.value
            throw error
        }
        let recovery = Task { @MainActor in try await workspace.restoreArchivedConflict(descriptor) }
        for _ in 0..<50 { await Task.yield() }
        #expect(container.peek(original) == old)
        #expect(!workspace.tabTeardowns.isEmpty)
        await gate.release()
        await earlier.value
        do {
            try await recovery.value
            Issue.record("an unverified replacement must report uncertainty")
        } catch let error as StorageCoordinator.ArchivedConflictError {
            #expect(error == .replacementUnverified)
        }
        await workspace.tabTeardowns.awaitAll()
        #expect(workspace.tabTeardowns.isEmpty)
        #expect(!AiPersistence.hasPendingChanges(forKey: key))
        #expect(await AiPersistence.loadConversation(for: document, coordinator: coordinator).first?.content == "preserved")
    }

    @Test("Restore comparison rejects a peer write arriving at the replacement accessor")
    func restoreRejectsPeerWriteAtReplacement() async throws {
        let storeDir = scratch("restore-peer-race")
        let root = scratch("restore-peer-root")
        let layout = WebStorageLayout.pretty(root: root.appendingPathComponent("Documents/Vellum"),
                                             recordsInRoot: true, localStoreDir: storeDir)
        let original = layout.documentsDir.appendingPathComponent("abc12345/conversations.json")
        let archive = original.deletingLastPathComponent().appendingPathComponent("conflicts/conversations.loser.json")
        let descriptor = StorageCoordinator.ArchivedConflict(archiveURL: archive,
            originalURL: original, detectedAt: .now)
        let registry = ConflictArchiveRegistryState()
        registry.registry.save([descriptor])
        let gate = AsyncGate()
        let container = FakeSyncedContainer(beforeReplace: { url in
            if url == original { await gate.enterAndWait() }
        })
        container.seed(original, data: Data("current".utf8))
        container.seed(archive, data: Data("preserved".utf8))
        installRoot(root)
        defer {
            VellumUbiquityContainerRoot.resetCacheForTests()
            try? FileManager.default.removeItem(at: storeDir)
            try? FileManager.default.removeItem(at: root)
        }
        let coordinator = coordinator(chosenMode: .icloud, storeDir: storeDir,
            factory: { container }, effectiveMode: { .icloud }, conflictArchiveRegistry: registry.registry)
        await coordinator.start()
        let available = await coordinator.archivedConflicts()
        try #require(available.contains { $0.id == descriptor.id })
        let restore = Task { try await coordinator.restoreArchivedConflict(descriptor) }
        do { try await gate.waitUntilEntered(timeout: .seconds(3)) }
        catch {
            await gate.release()
            restore.cancel()
            _ = try? await restore.value
            throw error
        }
        // This arrives after the backup and final admission check.
        container.seed(original, data: Data("peer latest".utf8))
        await gate.release()
        do {
            try await restore.value
            Issue.record("a peer write must reject the replacement")
        } catch let error as StorageCoordinator.ArchivedConflictError {
            #expect(error == .currentChanged)
        }
        #expect(container.peek(original) == Data("peer latest".utf8))
        #expect(container.peek(archive) == Data("preserved".utf8))
        let copies = await coordinator.archivedConflicts()
        let backup = try #require(copies.first { $0.archiveURL != archive })
        #expect(container.peek(backup.archiveURL) == Data("current".utf8))
        let allNeedReview = copies.allSatisfy { $0.needsReview }
        #expect(allNeedReview)
        // An adapter which has not implemented atomic comparison fails closed.
        let unsupported = BlockingRecoveryContainer(base: container)
        #expect(try await !unsupported.replace(original, with: Data("unsafe".utf8), ifCurrent: Data("peer latest".utf8)))
        #expect(container.peek(original) == Data("peer latest".utf8))
    }

    @MainActor
    @Test("Attachment recovery uses its document owner and unknown layouts reject open drafts")
    func attachmentRestoreRejectsOpenDraft() async throws {
        let storeDir = scratch("restore-attachment")
        let root = scratch("restore-attachment-root")
        let key = UUID().uuidString.lowercased()
        let attachmentId = UUID().uuidString.lowercased()
        let layout = WebStorageLayout.pretty(root: root.appendingPathComponent("Documents/Vellum"),
                                             recordsInRoot: true, localStoreDir: storeDir)
        let original = layout.documentsDir.appendingPathComponent("\(key)/attachments/\(attachmentId).png")
        let archive = original.deletingLastPathComponent().appendingPathComponent("conflicts/\(attachmentId).loser.png")
        let attachment = StorageCoordinator.ArchivedConflict(archiveURL: archive,
            originalURL: original, detectedAt: .now)
        let unknown = StorageCoordinator.ArchivedConflict(archiveURL: archive,
            originalURL: layout.documentsDir.appendingPathComponent("\(key)/unknown/\(attachmentId).png"), detectedAt: .now)
        #expect(attachment.storageKey == key)
        #expect(unknown.storageKey == nil)
        let container = FakeSyncedContainer()
        container.seed(original, data: Data("current image".utf8))
        container.seed(archive, data: Data("preserved image".utf8))
        installRoot(root)
        let previousOverride = DocumentDataStore.rootDirectoryOverride
        DocumentDataStore.rootDirectoryOverride = nil
        defer {
            DocumentDataStore.rootDirectoryOverride = previousOverride
            VellumUbiquityContainerRoot.resetCacheForTests()
            try? FileManager.default.removeItem(at: storeDir)
            try? FileManager.default.removeItem(at: root)
        }
        let coordinator = coordinator(chosenMode: .icloud, storeDir: storeDir,
            factory: { container }, effectiveMode: { .icloud })
        await coordinator.start()
        let workspace = WorkspaceStore(sessions: DocumentSessionManager(), storageCoordinator: coordinator)
        let pane = workspace.focusedPane
        let document = DocumentInfo(kind: .pdf, pdfPath: root.appendingPathComponent("open.pdf").path,
            title: nil, pageCount: 1, lastPage: 1, docId: key)
        pane.app.attachTab(PdfTab(id: "open", document: document, currentPage: 1, numPages: 1,
            zoom: 1, visiblePages: [], webVisibleRange: nil, webVisibleBookmarks: [], mode: .view))
        await pane.scratchpad.loadForDocument(document).value
        pane.scratchpad.text = "open draft"
        #expect(pane.scratchpad.hasPendingChanges(forKey: key))
        for descriptor in [attachment, unknown] {
            do {
                try await workspace.restoreArchivedConflict(descriptor)
                Issue.record("an open affected document must reject recovery")
            } catch WorkspaceStore.ConflictRecoveryError.documentOpen { }
        }
        #expect(pane.scratchpad.text == "open draft")
        #expect(container.peek(original) == Data("current image".utf8))
        await pane.scratchpad.flush().value
        await ScratchpadPersistence.awaitPendingFlush()
        await workspace.tabTeardowns.awaitAll()
    }

    @Test("Preserved conflict archives return when iCloud storage is reselected")
    func archivedConflictsSurviveReconfigureAwayAndBack() async throws {
        let storeDir = scratch("storage-conflict-reconfigure")
        let root = scratch("storage-root")
        let target = root.appendingPathComponent(
            ".vellum/documents/key/scratchpad.md")
        let archive = target.deletingLastPathComponent()
            .appendingPathComponent("conflicts/scratchpad.v-loser.md")
        let state = StorageModeState(mode: .icloud, root: root)
        let registryState = ConflictArchiveRegistryState()
        let resolver = CountingResolver(outcomes: [
            .success(.keptCurrent(archivedLosers: [archive]))
        ])
        let firstContainer = FakeSyncedContainer(resolver: resolver)
        let secondContainer = FakeSyncedContainer()
        secondContainer.seed(archive, data: Data("loser".utf8))
        let factory = ContainerSequence([firstContainer, secondContainer])
        defer {
            try? FileManager.default.removeItem(at: storeDir)
            try? FileManager.default.removeItem(at: root)
        }
        let coordinator = StorageCoordinator(
            storeDir: storeDir,
            modeProvider: { state.mode },
            effectiveModeProvider: { state.mode ?? .local },
            rootResolver: { state.root },
            containerFactory: { factory.next() },
            conflictArchiveRegistry: registryState.registry)
        await coordinator.start()

        firstContainer.seed(target, data: Data("current".utf8))
        firstContainer.seed(archive, data: Data("loser".utf8))
        firstContainer.injectConflict(at: target, versions: [Self.current, Self.loser])
        await resolver.waitForCount(1)
        await coordinator.awaitQuiescence()
        #expect(await coordinator.archivedConflicts().count == 1)

        state.set(mode: .local)
        await coordinator.reconfigure()
        #expect(await coordinator.archivedConflicts().isEmpty)

        state.set(mode: .icloud)
        await coordinator.reconfigure()
        let restored = try #require(await coordinator.archivedConflicts().first)
        #expect(restored.archiveURL == archive)
        #expect(factory.callCount == 2)
        #expect(secondContainer.metadataQueryCount == 1)
    }

    @Test("Throwing and deferred resolutions stay pending and retry on foreground")
    func retryableConflictFailuresWaitForForeground() async {
        let storeDir = scratch("storage-retry")
        let root = scratch("storage-root")
        let resolver = CountingResolver(outcomes: [
            .failure(RetryMarker()),
            .success(.deferred),
            .success(.keptCurrent(archivedLosers: [])),
        ])
        let container = FakeSyncedContainer(resolver: resolver)
        installRoot(root)
        defer {
            VellumUbiquityContainerRoot.resetCacheForTests()
            try? FileManager.default.removeItem(at: storeDir)
            try? FileManager.default.removeItem(at: root)
        }
        let coordinator = coordinator(
            chosenMode: .icloud,
            storeDir: storeDir,
            factory: { container },
            effectiveMode: { .icloud })
        await coordinator.start()

        let target = url("a.json")
        container.seed(target, data: Data("current".utf8))
        container.injectConflict(at: target, versions: [Self.current, Self.loser])
        await resolver.waitForCount(1)
        // The resolver signals before the coordinator parks the retryable result.
        await coordinator.awaitQuiescence()
        #expect(await coordinator.currentStatus().pendingConflicts == 1)

        await coordinator.foreground()
        await resolver.waitForCount(2)
        await coordinator.awaitQuiescence()
        #expect(await coordinator.currentStatus().pendingConflicts == 1)

        await coordinator.foreground()
        await resolver.waitForCount(3)
        await coordinator.awaitQuiescence()
        let status = await coordinator.currentStatus()
        #expect(status.pendingConflicts == 0)
        #expect(status.lastError == nil)
        await coordinator.stop()
    }

    @Test("Conflict emitted while suspended is rescanned and drained on foreground")
    func conflictDuringSuspendResolvesOnForeground() async {
        let storeDir = scratch("storage-resume")
        let root = scratch("storage-root")
        let resolver = CountingResolver(outcomes: [.success(.keptCurrent(archivedLosers: []))])
        let container = FakeSyncedContainer(resolver: resolver)
        installRoot(root)
        defer {
            VellumUbiquityContainerRoot.resetCacheForTests()
            try? FileManager.default.removeItem(at: storeDir)
            try? FileManager.default.removeItem(at: root)
        }
        let coordinator = coordinator(
            chosenMode: .icloud,
            storeDir: storeDir,
            factory: { container },
            effectiveMode: { .icloud })
        await coordinator.start()
        await coordinator.background()

        let target = url("a.json")
        container.seed(target, data: Data("current".utf8))
        container.injectConflict(at: target, versions: [Self.current, Self.loser])
        #expect(container.deliveredConflictCount == 0)

        await coordinator.foreground()
        await resolver.waitForCount(1)

        #expect(resolver.seenCount == 1)
        #expect(container.presenterRemovals == 1)
        #expect(container.presenterRegistrations == 2)
    }

    @Test("Bounded background drain reports timeout and leaves the active container unsuspended")
    func boundedBackgroundDrainTimesOut() async {
        let storeDir = scratch("storage-timeout")
        let root = scratch("storage-root")
        let container = FakeSyncedContainer()
        let gate = AsyncGate()
        installRoot(root)
        defer {
            VellumUbiquityContainerRoot.resetCacheForTests()
            try? FileManager.default.removeItem(at: storeDir)
            try? FileManager.default.removeItem(at: root)
        }
        let coordinator = coordinator(
            chosenMode: .icloud,
            storeDir: storeDir,
            factory: { container },
            effectiveMode: { .icloud })
        await coordinator.start()

        let operation = Task {
            try? await coordinator.runCoordinatedOperation {
                await gate.enterAndWait()
            }
        }
        await gate.waitUntilEntered()

        let outcome = await coordinator.background(timeout: 0)

        #expect(outcome.drained == false)
        #expect(outcome.timedOut)
        #expect(outcome.inFlightOperations == 1)
        #expect(!container.isSuspended)
        #expect(await coordinator.currentStatus().lifecycle == .backgrounding)

        await gate.release()
        await operation.value
        await coordinator.foreground()
        #expect(container.presenterRegistrations == 1)
    }

    @Test("Foreground invalidates an in-progress background drain without releasing a blocked operation", .timeLimit(.minutes(1)))
    func foregroundInvalidatesInProgressBackgroundDrain() async {
        let storeDir = scratch("storage-foreground-invalidates")
        let root = scratch("storage-root")
        let container = FakeSyncedContainer()
        let gate = AsyncGate()
        installRoot(root)
        defer {
            VellumUbiquityContainerRoot.resetCacheForTests()
            try? FileManager.default.removeItem(at: storeDir)
            try? FileManager.default.removeItem(at: root)
        }
        let coordinator = coordinator(
            chosenMode: .icloud,
            storeDir: storeDir,
            factory: { container },
            effectiveMode: { .icloud })
        await coordinator.start()

        let operation = Task {
            try? await coordinator.runCoordinatedOperation {
                await gate.enterAndWait()
            }
        }
        await gate.waitUntilEntered()

        let background = Task { await coordinator.background(timeout: 20) }
        await waitUntil {
            let status = await coordinator.currentStatus()
            return status.lifecycle == .backgrounding
                && !status.acceptsCoordinatedOperations
                && status.inFlightOperations == 1
        }

        await coordinator.foreground()
        let reopened = try? await coordinator.runCoordinatedOperation { true }
        let foregroundStatus = await coordinator.currentStatus()
        let outcome = await background.value

        #expect(reopened == true)
        #expect(foregroundStatus.lifecycle == .active)
        #expect(foregroundStatus.acceptsCoordinatedOperations)
        #expect(foregroundStatus.inFlightOperations == 1)
        #expect(outcome.drained == false)
        #expect(outcome.timedOut == false)
        #expect(outcome.inFlightOperations == 1)
        #expect(!container.isSuspended)
        #expect(container.presenterRemovals == 0)

        await gate.release()
        await operation.value
    }

    @Test("Invalidated background drain does not suspend after final generation check")
    func invalidatedBackgroundDrainDoesNotSuspend() async {
        let storeDir = scratch("storage-stale-background")
        let root = scratch("storage-root")
        let container = FakeSyncedContainer()
        installRoot(root)
        defer {
            VellumUbiquityContainerRoot.resetCacheForTests()
            try? FileManager.default.removeItem(at: storeDir)
            try? FileManager.default.removeItem(at: root)
        }
        let coordinator = coordinator(
            chosenMode: .icloud,
            storeDir: storeDir,
            factory: { container },
            effectiveMode: { .icloud })
        await coordinator.start()

        let outcome = await coordinator.background(timeout: nil) { false }

        #expect(outcome.drained == false)
        #expect(outcome.timedOut == false)
        #expect(!container.isSuspended)
        #expect(await coordinator.currentStatus().lifecycle == .backgrounding)

        await coordinator.foreground()
        #expect(container.presenterRegistrations == 1)
    }

    @Test("Background joins app-requested operations before suspend")
    func backgroundDrainsOperationsBeforeSuspend() async {
        let storeDir = scratch("storage-drain")
        let root = scratch("storage-root")
        let container = FakeSyncedContainer()
        let gate = AsyncGate()
        installRoot(root)
        defer {
            VellumUbiquityContainerRoot.resetCacheForTests()
            try? FileManager.default.removeItem(at: storeDir)
            try? FileManager.default.removeItem(at: root)
        }
        let coordinator = coordinator(
            chosenMode: .icloud,
            storeDir: storeDir,
            factory: { container },
            effectiveMode: { .icloud })
        await coordinator.start()

        let operation = Task {
            try? await coordinator.runCoordinatedOperation {
                await gate.enterAndWait()
            }
        }
        await gate.waitUntilEntered()

        let background = Task { await coordinator.background() }
        #expect(!container.isSuspended)
        await gate.release()
        let outcome = await background.value
        await operation.value

        #expect(outcome.drained)
        #expect(container.isSuspended)
        #expect(container.presenterRemovals == 1)
    }

    @Test("Background joins an active storage-context lease before suspend")
    func backgroundDrainsStorageContextBeforeSuspend() async {
        let storeDir = scratch("storage-context-drain")
        let root = scratch("storage-context-root")
        let container = FakeSyncedContainer()
        let gate = AsyncGate()
        installRoot(root)
        defer {
            VellumUbiquityContainerRoot.resetCacheForTests()
            try? FileManager.default.removeItem(at: storeDir)
            try? FileManager.default.removeItem(at: root)
        }
        let coordinator = coordinator(
            chosenMode: .icloud,
            storeDir: storeDir,
            factory: { container },
            effectiveMode: { .icloud })
        await coordinator.start()

        let operation = Task {
            try? await coordinator.withStorageContext { _ in
                await gate.enterAndWait()
            }
        }
        await gate.waitUntilEntered()

        let background = Task { await coordinator.background() }
        #expect(container.isSuspended == false)
        await gate.release()
        let outcome = await background.value
        await operation.value

        #expect(outcome.drained)
        #expect(container.isSuspended)
    }

    @Test("Conflict event between quiescence and suspend is parked until foreground")
    func conflictBetweenQuiescenceAndSuspendIsParked() async {
        let storeDir = scratch("storage-transition-event")
        let root = scratch("storage-root")
        let resolver = CountingResolver(outcomes: [.success(.keptCurrent(archivedLosers: []))])
        let container = FakeSyncedContainer(resolver: resolver)
        installRoot(root)
        defer {
            VellumUbiquityContainerRoot.resetCacheForTests()
            try? FileManager.default.removeItem(at: storeDir)
            try? FileManager.default.removeItem(at: root)
        }
        let coordinator = coordinator(
            chosenMode: .icloud,
            storeDir: storeDir,
            factory: { container },
            effectiveMode: { .icloud })
        await coordinator.start()

        let target = url("transition.json")
        let outcome = await coordinator.background(timeout: nil) {
            container.seed(target, data: Data("current".utf8))
            container.injectConflict(at: target, versions: [Self.current, Self.loser])
            return true
        }

        #expect(outcome.drained)
        #expect(container.isSuspended)
        #expect(resolver.seenCount == 0)
        await waitUntil {
            await coordinator.currentStatus().pendingConflicts == 1
        }
        #expect(await coordinator.currentStatus().pendingConflicts == 1)

        await coordinator.foreground()
        await resolver.waitForCount(1)
        #expect(await coordinator.currentStatus().pendingConflicts == 0)
    }

    @Test("Reconfigure drains old work, retires old container, and installs one new consumer")
    func reconfigureRetiresOldRuntimeAfterDrain() async {
        let storeDir = scratch("storage-reconfigure")
        let rootOne = scratch("storage-root-one")
        let rootTwo = scratch("storage-root-two")
        let state = StorageModeState(mode: .icloud, root: rootOne)
        let resolverOne = BlockingResolver()
        let resolverTwo = CountingResolver(outcomes: [.success(.keptCurrent(archivedLosers: []))])
        let first = FakeSyncedContainer(resolver: resolverOne)
        let second = FakeSyncedContainer(resolver: resolverTwo)
        let factory = ContainerSequence([first, second])
        defer {
            try? FileManager.default.removeItem(at: storeDir)
            try? FileManager.default.removeItem(at: rootOne)
            try? FileManager.default.removeItem(at: rootTwo)
        }
        let coordinator = StorageCoordinator(
            storeDir: storeDir,
            modeProvider: { state.mode },
            effectiveModeProvider: { state.mode ?? .local },
            rootResolver: { state.root },
            containerFactory: { factory.next() })
        await coordinator.start()

        let firstTarget = url("first.json")
        first.seed(firstTarget, data: Data("current".utf8))
        first.injectConflict(at: firstTarget, versions: [Self.current, Self.loser])
        await resolverOne.waitForCount(1)

        state.set(root: rootTwo)
        let reconfigure = Task { await coordinator.reconfigure() }
        await waitUntil {
            let status = await coordinator.currentStatus()
            return status.lifecycle == .starting && status.inFlightConflicts == 1
        }
        #expect(!first.isSuspended)

        await resolverOne.release()
        await reconfigure.value

        let status = await coordinator.currentStatus()
        #expect(status.availability == .coordinated)
        #expect(factory.callCount == 2)
        #expect(first.isSuspended)
        #expect(second.presenterRegistrations == 1)

        let secondTarget = url("second.json")
        second.seed(secondTarget, data: Data("current".utf8))
        second.injectConflict(at: secondTarget, versions: [Self.current, Self.loser])
        await resolverTwo.waitForCount(1)
        #expect(resolverTwo.seenCount == 1)
    }

    @Test("Exclusive relocation keeps admission closed until the new layout is installed")
    func exclusiveRelocationAtomicallyInstallsNewLayout() async {
        let storeDir = scratch("storage-exclusive")
        let root = scratch("storage-exclusive-root")
        let state = StorageModeState(mode: .icloud, root: root)
        let container = FakeSyncedContainer()
        let relocation = AsyncGate()
        defer {
            try? FileManager.default.removeItem(at: storeDir)
            try? FileManager.default.removeItem(at: root)
        }
        let coordinator = StorageCoordinator(
            storeDir: storeDir,
            modeProvider: { state.mode },
            effectiveModeProvider: { state.mode ?? .local },
            rootResolver: { state.root },
            containerFactory: { container })
        await coordinator.start()

        state.set(mode: .local)
        let transition = Task {
            await coordinator.performExclusiveStorageOperation(reconfigureAfter: true) {
                await relocation.enterAndWait()
                return true
            }
        }
        await relocation.waitUntilEntered()

        let during = await coordinator.currentStatus()
        let admittedDuringMove = try? await coordinator.withStorageContext { _ in true }
        #expect(during.lifecycle == .starting)
        #expect(!during.acceptsCoordinatedOperations)
        #expect(admittedDuringMove == nil)
        #expect(!container.isSuspended)

        await relocation.release()
        #expect(await transition.value)

        let after = await coordinator.currentStatus()
        let layout = try? await coordinator.withStorageContext { $0.layout }
        #expect(after.lifecycle == .active)
        #expect(after.effectiveMode == .local)
        #expect(after.availability == .direct)
        #expect(container.isSuspended)
        #expect(layout == .local(storeDir: storeDir))
    }

    @Test("Reconfigure keeps a storage-context lease on one root and container")
    func reconfigureKeepsStorageContextLeaseStable() async throws {
        let storeDir = scratch("storage-context-reconfigure")
        let rootOne = scratch("storage-context-root-one")
        let rootTwo = scratch("storage-context-root-two")
        let state = StorageModeState(mode: .icloud, root: rootOne)
        let first = FakeSyncedContainer()
        let second = FakeSyncedContainer()
        let factory = ContainerSequence([first, second])
        let gate = AsyncGate()
        defer {
            try? FileManager.default.removeItem(at: storeDir)
            try? FileManager.default.removeItem(at: rootOne)
            try? FileManager.default.removeItem(at: rootTwo)
        }
        let coordinator = StorageCoordinator(
            storeDir: storeDir,
            modeProvider: { state.mode },
            effectiveModeProvider: { state.mode ?? .local },
            rootResolver: { state.root },
            containerFactory: { factory.next() })
        await coordinator.start()

        let leased = Task {
            try await coordinator.withStorageContext { context in
                await gate.enterAndWait()
                switch context {
                case .direct:
                    return (false, context.layout)
                case .coordinated(let container, let layout):
                    return ((container as? FakeSyncedContainer) === first, layout)
                }
            }
        }
        await gate.waitUntilEntered()
        state.set(root: rootTwo)
        let reconfigure = Task { await coordinator.reconfigure() }
        await waitUntil { await coordinator.currentStatus().inFlightOperations == 1 }
        #expect(first.isSuspended == false)

        await gate.release()
        let leasedResult = try await leased.value
        await reconfigure.value
        let currentResult = try await coordinator.withStorageContext { context in
            switch context {
            case .direct:
                return (false, context.layout)
            case .coordinated(let container, let layout):
                return ((container as? FakeSyncedContainer) === second, layout)
            }
        }

        #expect(leasedResult.0)
        #expect(leasedResult.1.recordsDir == rootOne
            .appendingPathComponent(".vellum", isDirectory: true)
            .appendingPathComponent("records", isDirectory: true))
        #expect(first.isSuspended)
        #expect(currentResult.0)
        #expect(currentResult.1.recordsDir == rootTwo
            .appendingPathComponent(".vellum", isDirectory: true)
            .appendingPathComponent("records", isDirectory: true))
    }

    @Test("Reconfigure is a no-op for the same effective iCloud access")
    func reconfigureNoopsForSameEffectiveAccess() async {
        let storeDir = scratch("storage-reconfigure-noop")
        let root = scratch("storage-root")
        let state = StorageModeState(mode: .icloud, root: root)
        let container = FakeSyncedContainer()
        let factory = ContainerSequence([container, FakeSyncedContainer()])
        defer {
            try? FileManager.default.removeItem(at: storeDir)
            try? FileManager.default.removeItem(at: root)
        }
        let coordinator = StorageCoordinator(
            storeDir: storeDir,
            modeProvider: { state.mode },
            effectiveModeProvider: { state.mode ?? .local },
            rootResolver: { state.root },
            containerFactory: { factory.next() })

        await coordinator.start()
        await coordinator.reconfigure()

        #expect(factory.callCount == 1)
        #expect(!container.isSuspended)
        #expect(await coordinator.currentStatus().availability == .coordinated)
    }

    @Test("Reconfigure follows a changed custom archive root")
    func reconfigureTracksCustomFolderChanges() async throws {
        let storeDir = scratch("storage-custom-reconfigure")
        let firstRoot = scratch("storage-custom-one")
        let secondRoot = scratch("storage-custom-two")
        WebStorageSettings.customRootOverride = firstRoot
        defer {
            WebStorageSettings.customRootOverride = nil
            try? FileManager.default.removeItem(at: storeDir)
            try? FileManager.default.removeItem(at: firstRoot)
            try? FileManager.default.removeItem(at: secondRoot)
        }
        let coordinator = StorageCoordinator(
            storeDir: storeDir,
            modeProvider: { .custom },
            effectiveModeProvider: { .custom },
            containerFactory: { nil })
        await coordinator.start()
        let first = try await coordinator.withStorageContext { $0.layout.archivesDir }

        WebStorageSettings.customRootOverride = secondRoot
        await coordinator.reconfigure()
        let second = try await coordinator.withStorageContext { $0.layout.archivesDir }

        #expect(first == firstRoot.appendingPathComponent("Web Pages", isDirectory: true))
        #expect(second == secondRoot.appendingPathComponent("Web Pages", isDirectory: true))
    }

    @Test("WorkspaceStore owns and forwards coordinator lifecycle")
    @MainActor
    func workspaceLifecycleIntegration() async {
        let storeDir = scratch("storage-workspace")
        let root = scratch("storage-root")
        let container = FakeSyncedContainer()
        installRoot(root)
        defer {
            VellumUbiquityContainerRoot.resetCacheForTests()
            try? FileManager.default.removeItem(at: storeDir)
            try? FileManager.default.removeItem(at: root)
        }
        let coordinator = coordinator(
            chosenMode: .icloud,
            storeDir: storeDir,
            factory: { container },
            effectiveMode: { .icloud })
        let workspace = WorkspaceStore(
            sessions: DocumentSessionManager(),
            storageCoordinator: coordinator)

        await workspace.startStorageCoordinator()
        #expect(await coordinator.currentStatus().availability == .coordinated)

        _ = await workspace.backgroundStorageCoordinator(timeout: 0)
        #expect(container.isSuspended)

        await workspace.foregroundStorageCoordinator()
        #expect(!container.isSuspended)

        await workspace.stopStorageCoordinator(timeout: 0)
        #expect(await coordinator.currentStatus().lifecycle == .stopped)
    }

    private func waitUntil(
        _ predicate: @escaping @Sendable () async -> Bool,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        for _ in 0..<1_000 {
            if await predicate() { return }
            await Task.yield()
        }
        Issue.record("Condition was not met before timeout at \(file):\(line)")
    }
}

#if os(iOS)
@Suite("iOS background flush controller", .serialized, .isolatedStorage)
@MainActor
struct BackgroundFlushControllerTests {
    @Test("Foreground invalidation cancels stale flush and ends token once")
    func foregroundInvalidationCancelsStaleFlush() async {
        let controller = BackgroundFlushController()
        let handle = TestBackgroundFlushHandle()
        let gate = AsyncGate()
        let generation = controller.begin()
        let task = Task { @MainActor in
            await gate.enterAndWait()
        }
        controller.install(task: task, token: handle, generation: generation)

        #expect(controller.isCurrent(generation))
        controller.invalidate()

        #expect(!controller.isCurrent(generation))
        #expect(handle.endCount == 1)
        #expect(task.isCancelled)

        await gate.release()
        await task.value
        controller.finish(generation: generation)
        #expect(handle.endCount == 1)
    }

    @Test("Pre-install expiration is ordered behind install on the main actor")
    func preInstallExpirationIsMainActorOrdered() async {
        let controller = BackgroundFlushController()
        let handle = TestBackgroundFlushHandle()
        let gate = AsyncGate()
        let generation = controller.begin()
        let task = Task { @MainActor in
            await gate.enterAndWait()
        }

        Task { @MainActor in
            controller.expire(generation: generation)
        }
        controller.install(task: task, token: handle, generation: generation)
        await Task.yield()

        #expect(!controller.isCurrent(generation))
        #expect(handle.endCount == 1)
        #expect(task.isCancelled)

        await gate.release()
        await task.value
        controller.finish(generation: generation)
        #expect(handle.endCount == 1)
    }
}

@MainActor
private final class TestBackgroundFlushHandle: BackgroundFlushHandle {
    private(set) var endCount = 0

    func end() {
        endCount += 1
    }
}
#endif

private final class FactoryProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var calls = 0

    var callCount: Int { lock.withLock { calls } }

    func note() {
        lock.withLock { calls += 1 }
    }
}

private final class StorageModeState: @unchecked Sendable {
    private let lock = NSLock()
    private var currentMode: WebStorageMode?
    private var currentRoot: URL?

    init(mode: WebStorageMode?, root: URL?) {
        currentMode = mode
        currentRoot = root
    }

    var mode: WebStorageMode? { lock.withLock { currentMode } }
    var root: URL? { lock.withLock { currentRoot } }

    func set(mode: WebStorageMode? = nil, root: URL? = nil) {
        lock.withLock {
            if let mode { currentMode = mode }
            if let root { currentRoot = root }
        }
    }
}

private final class ConflictArchiveRegistryState: @unchecked Sendable {
    private let lock = NSLock()
    private var conflicts: [StorageCoordinator.ArchivedConflict] = []

    var registry: StorageCoordinator.ConflictArchiveRegistry {
        StorageCoordinator.ConflictArchiveRegistry(
            load: { [self] in lock.withLock { conflicts } },
            save: { [self] next in lock.withLock { conflicts = next } })
    }
}

private final class ContainerSequence: @unchecked Sendable {
    private let lock = NSLock()
    private var containers: [FakeSyncedContainer]
    private var calls = 0

    init(_ containers: [FakeSyncedContainer]) {
        self.containers = containers
    }

    var callCount: Int { lock.withLock { calls } }

    func next() -> FakeSyncedContainer? {
        lock.withLock {
            calls += 1
            return containers.isEmpty ? nil : containers.removeFirst()
        }
    }
}

private struct RetryMarker: Error {}

private final class BlockingResolver: ConflictResolver, @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    private var waiters: [(Int, CheckedContinuation<Void, Never>)] = []
    private let gate = AsyncGate()

    var seenCount: Int { lock.withLock { count } }

    func waitForCount(_ expected: Int) async {
        if lock.withLock({ count >= expected }) { return }
        await withCheckedContinuation { continuation in
            lock.withLock {
                if count >= expected {
                    continuation.resume()
                } else {
                    waiters.append((expected, continuation))
                }
            }
        }
    }

    func release() async {
        await gate.release()
    }

    func resolve(
        _ event: ConflictEvent,
        reading: @Sendable (ConflictVersion) async throws -> Data
    ) async throws -> ConflictResolution {
        lock.withLock {
            count += 1
            let ready = waiters.filter { count >= $0.0 }
            waiters.removeAll { count >= $0.0 }
            for waiter in ready { waiter.1.resume() }
        }
        await gate.enterAndWait()
        return .keptCurrent(archivedLosers: [])
    }
}

private final class CountingResolver: ConflictResolver, @unchecked Sendable {
    enum Outcome: Sendable {
        case success(ConflictResolution)
        case failure(any Error)
    }

    private let lock = NSLock()
    private var outcomes: [Outcome]
    private var events: [ConflictEvent] = []
    private var waiters: [(Int, CheckedContinuation<Void, Never>)] = []

    init(outcomes: [Outcome]) {
        self.outcomes = outcomes
    }

    var seenCount: Int { lock.withLock { events.count } }

    func waitForCount(_ count: Int) async {
        if lock.withLock({ events.count >= count }) { return }
        await withCheckedContinuation { continuation in
            lock.withLock {
                if events.count >= count {
                    continuation.resume()
                } else {
                    waiters.append((count, continuation))
                }
            }
        }
    }

    func resolve(
        _ event: ConflictEvent,
        reading: @Sendable (ConflictVersion) async throws -> Data
    ) async throws -> ConflictResolution {
        let outcome: Outcome = lock.withLock {
            outcomes.isEmpty ? .success(.keptCurrent(archivedLosers: [])) : outcomes.removeFirst()
        }
        defer {
            lock.withLock {
                events.append(event)
                let ready = waiters.filter { events.count >= $0.0 }
                waiters.removeAll { events.count >= $0.0 }
                for waiter in ready { waiter.1.resume() }
            }
        }
        switch outcome {
        case .success(let resolution):
            return resolution
        case .failure(let error):
            throw error
        }
    }
}

private final class BlockingRecoveryContainer: SyncedContainer, @unchecked Sendable {
    let base: FakeSyncedContainer
    let readGate = AsyncGate()
    let removeGate = AsyncGate()

    init(base: FakeSyncedContainer) {
        self.base = base
    }

    var conflicts: AsyncStream<ConflictEvent> { base.conflicts }

    func read<T: Sendable>(
        _ url: URL,
        materializing: Materialization,
        _ body: @Sendable (Data) throws -> T
    ) async throws -> T {
        await readGate.enterAndWait()
        return try await base.read(url, materializing: materializing, body)
    }

    func replace(_ url: URL, with data: Data) async throws {
        try await base.replace(url, with: data)
    }

    func remove(_ url: URL) async throws {
        await removeGate.enterAndWait()
        try await base.remove(url)
    }

    func list(_ directory: URL, matching filter: SyncedItemFilter) async throws -> [SyncedItem] {
        try await base.list(directory, matching: filter)
    }

    func resolveConflict(_ event: ConflictEvent) async throws -> ConflictResolution {
        try await base.resolveConflict(event)
    }

    func suspend() async { await base.suspend() }
    func resume() async { await base.resume() }
}

private actor AsyncGate {
    private var didEnter = false
    private var didRelease = false
    private var enteredWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseWaiters: [CheckedContinuation<Void, Never>] = []

    func enterAndWait() async {
        didEnter = true
        let waiters = enteredWaiters
        enteredWaiters.removeAll()
        for waiter in waiters { waiter.resume() }
        if didRelease { return }
        await withCheckedContinuation { continuation in
            releaseWaiters.append(continuation)
        }
    }

    func waitUntilEntered() async {
        if didEnter { return }
        await withCheckedContinuation { continuation in
            enteredWaiters.append(continuation)
        }
    }

    enum WaitError: Error { case neverEntered }

    /// A failed operation may return before reaching its injected suspension.
    /// Polling bounds that failure without leaving a continuation parked.
    func waitUntilEntered(timeout: Duration) async throws {
        let deadline = ContinuousClock.now.advanced(by: timeout)
        while !didEnter {
            guard ContinuousClock.now < deadline else { throw WaitError.neverEntered }
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    func release() {
        didRelease = true
        let waiters = releaseWaiters
        releaseWaiters.removeAll()
        for waiter in waiters { waiter.resume() }
    }
}
