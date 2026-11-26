import Foundation
import Synchronization

/// Blocking filesystem calls share two worker slots across all open libraries.
enum LibraryIO {
    static let queue: OperationQueue = {
        let queue = OperationQueue()
        queue.name = "vellum.library.io"
        queue.maxConcurrentOperationCount = 2
        return queue
    }()

    typealias Work<T> = @Sendable (_ checkCancellation: () throws -> Void) throws -> T

    private struct Admission<T: Sendable> {
        typealias Pending = (work: Work<T>, continuation: CheckedContinuation<T, Error>)

        var cancelled = false
        var waiting: Pending?

        mutating func takeWaiting() -> Pending? {
            defer { waiting = nil }
            return waiting
        }
    }

    static func run<T: Sendable>(_ work: @escaping Work<T>) async throws -> T {
        let admission = Mutex(Admission<T>())
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let admitted = admission.withLock { state in
                    guard !state.cancelled else { return false }
                    state.waiting = (work, continuation)
                    return true
                }
                guard admitted else {
                    continuation.resume(throwing: CancellationError())
                    return
                }
                queue.addOperation {
                    // Taking the continuation transfers completion to the worker.
                    // From here, cancellation unwinds the worker's own descriptors.
                    guard let job = admission.withLock({ $0.takeWaiting() }) else { return }
                    let checkCancellation = {
                        if admission.withLock({ $0.cancelled }) { throw CancellationError() }
                    }
                    job.continuation.resume(with: Result {
                        try checkCancellation()
                        let value = try job.work(checkCancellation)
                        try checkCancellation()
                        return value
                    })
                }
            }
        } onCancel: {
            let pending = admission.withLock { state in
                state.cancelled = true
                return state.takeWaiting()
            }
            pending?.continuation.resume(throwing: CancellationError())
        }
    }
}
