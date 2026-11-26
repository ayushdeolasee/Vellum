import Foundation

public protocol PositionClock: Sendable {
    func now() -> Date
}

public struct SystemPositionClock: PositionClock {
    public init() {}
    public func now() -> Date { .now }
}

/// The coalescing POLICY lives in `PositionStore`; only the timer is injected,
/// so a test can drive the schedule without sleeping.
public protocol PositionTimer: Sendable {
    /// Cancels any pending fire, then schedules one `delay` from now.
    func schedule(after delay: TimeInterval, _ body: @escaping @Sendable () async -> Void)
    func cancel()
}

public struct TaskPositionTimer: PositionTimer {
    private let box = Box()

    public init() {}

    public func schedule(after delay: TimeInterval, _ body: @escaping @Sendable () async -> Void) {
        box.replace(
            with: Task {
                if delay > 0 {
                    try? await Task.sleep(for: .seconds(delay))
                }
                guard !Task.isCancelled else { return }
                await body()
            })
    }

    public func cancel() {
        box.replace(with: nil)
    }

    private final class Box: @unchecked Sendable {
        private let lock = NSLock()
        private var task: Task<Void, Never>?

        func replace(with next: Task<Void, Never>?) {
            lock.lock()
            let previous = task
            task = next
            lock.unlock()
            previous?.cancel()
        }
    }
}
