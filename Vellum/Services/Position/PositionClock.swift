import Foundation

protocol PositionClock: Sendable {
    func now() -> Date
}

struct SystemPositionClock: PositionClock {
    init() {}
    func now() -> Date { .now }
}

final class ManualPositionClock: PositionClock, @unchecked Sendable {
    private let lock = NSLock()
    private var current: Date

    init(_ start: Date) {
        current = start
    }

    func now() -> Date {
        lock.lock()
        defer { lock.unlock() }
        return current
    }

    func advance(by interval: TimeInterval) {
        lock.lock()
        defer { lock.unlock() }
        current = current.addingTimeInterval(interval)
    }

    func set(_ date: Date) {
        lock.lock()
        defer { lock.unlock() }
        current = date
    }
}

/// The coalescing POLICY lives in `PositionStore`; only the timer is injected,
/// so a test can drive the schedule without sleeping.
protocol PositionTimer: Sendable {
    /// Cancels any pending fire, then schedules one `delay` from now.
    func schedule(after delay: TimeInterval, _ body: @escaping @Sendable () async -> Void)
    func cancel()
}

struct TaskPositionTimer: PositionTimer {
    private let box = Box()

    init() {}

    func schedule(after delay: TimeInterval, _ body: @escaping @Sendable () async -> Void) {
        box.replace(
            with: Task {
                if delay > 0 {
                    try? await Task.sleep(for: .seconds(delay))
                }
                guard !Task.isCancelled else { return }
                await body()
            })
    }

    func cancel() {
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

final class ManualPositionTimer: PositionTimer, @unchecked Sendable {
    private let lock = NSLock()
    private var delay: TimeInterval?
    private var body: (@Sendable () async -> Void)?
    private var fires = 0

    init() {}

    var pendingDelay: TimeInterval? {
        lock.lock()
        defer { lock.unlock() }
        return delay
    }

    var fireCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return fires
    }

    func schedule(after delay: TimeInterval, _ body: @escaping @Sendable () async -> Void) {
        lock.lock()
        defer { lock.unlock() }
        self.delay = delay
        self.body = body
    }

    func cancel() {
        lock.lock()
        defer { lock.unlock() }
        delay = nil
        body = nil
    }

    /// Deterministic, no sleeping.
    func fire() async {
        let pending = lock.withLock { () -> (@Sendable () async -> Void)? in
            let pending = body
            delay = nil
            body = nil
            if pending != nil { fires += 1 }
            return pending
        }
        await pending?()
    }
}
