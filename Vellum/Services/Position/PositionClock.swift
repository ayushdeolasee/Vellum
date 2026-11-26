import Foundation
import VellumCore

typealias PositionClock = VellumCore.PositionClock
typealias PositionTimer = VellumCore.PositionTimer
typealias SystemPositionClock = VellumCore.SystemPositionClock
typealias TaskPositionTimer = VellumCore.TaskPositionTimer

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
