import Testing

/// One process-wide lock for tests installing storage/Keychain overrides.
/// `.serialized` alone only serializes tests within the annotated suite.
struct StorageIsolationTrait: TestTrait, SuiteTrait, TestScoping {
    var isRecursive: Bool { true }

    func provideScope(for test: Test, testCase: Test.Case?,
                      performing function: @Sendable () async throws -> Void) async throws {
        await StorageTestLock.shared.acquire()
        do {
            try await function()
            await StorageTestLock.shared.release()
        } catch {
            await StorageTestLock.shared.release()
            throw error
        }
    }
}

private actor StorageTestLock {
    static let shared = StorageTestLock()
    private var busy = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func acquire() async {
        if !busy { busy = true; return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func release() {
        if waiters.isEmpty { busy = false }
        else { waiters.removeFirst().resume() }
    }
}

extension Trait where Self == StorageIsolationTrait {
    static var isolatedStorage: Self { Self() }
}
