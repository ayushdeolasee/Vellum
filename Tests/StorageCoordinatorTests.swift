import Foundation
import Testing

@testable import Vellum

@Suite("StorageCoordinator orchestration", .serialized)
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
        effectiveMode: @escaping @Sendable () -> WebStorageMode
    ) -> StorageCoordinator {
        StorageCoordinator(
            storeDir: storeDir,
            modeProvider: { chosenMode },
            effectiveModeProvider: effectiveMode,
            rootResolver: {
                WebStorageSettings.resolveICloudRoot(environment: [:])
                return WebStorageSettings.icloudVellumRoot
            },
            containerFactory: factory)
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
        #expect(await coordinator.currentStatus().pendingConflicts == 1)

        await coordinator.foreground()
        await resolver.waitForCount(2)
        #expect(await coordinator.currentStatus().pendingConflicts == 1)

        await coordinator.foreground()
        await resolver.waitForCount(3)
        let status = await coordinator.currentStatus()
        #expect(status.pendingConflicts == 0)
        #expect(status.lastError == nil)
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
@Suite("iOS background flush controller", .serialized)
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

    func release() {
        didRelease = true
        let waiters = releaseWaiters
        releaseWaiters.removeAll()
        for waiter in waiters { waiter.resume() }
    }
}
