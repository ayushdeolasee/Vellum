import CPdfiumJob
import Dispatch
import Foundation

/// The only entry to PDFium. Admission runs on the actor, so callers can queue
/// or cancel while a synchronous page job occupies the dedicated worker.
public actor PdfiumActor {
    public static let shared = PdfiumActor()
    public enum Priority: Sendable { case onDemand, background }

    private let worker = DispatchQueue(label: "vellum.pdfium")
    private struct Job: Sendable {
        let id: UUID
        let priority: Priority
        let byteCount: Int
        let execute: @Sendable () -> Void
        let cancel: @Sendable () -> Void
    }
    private var pending: [Job] = []
    private var running = false
    private var admittedBytes = 0
    private var stopping = false
    private var stopped = false
    private var shutdownWaiters: [CheckedContinuation<Void, Never>] = []
    private init() {}

    var pendingCount: Int { pending.count }

    func run<T: Sendable>(priority: Priority, byteCount: Int,
                          _ work: @escaping @Sendable () throws -> T) async throws -> T {
        let id = UUID()
        let result: Result<T, Error> = await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                if Task.isCancelled {
                    continuation.resume(returning: .failure(CancellationError()))
                    return
                }
                guard !stopping else {
                    continuation.resume(returning: .failure(PdfiumError.closed))
                    return
                }
                // Keep a waiting slot and one maximum-sized document available
                // to an interactive caller even when background work is saturated.
                let slotLimit = priority == .background ? 63 : 64
                let byteLimit = priority == .background ? PdfiumDocument.maxInputBytes : 2 * PdfiumDocument.maxInputBytes
                guard pending.count < slotLimit, byteCount <= byteLimit - admittedBytes else {
                    continuation.resume(returning: .failure(PdfiumError.queueFull))
                    return
                }
                admittedBytes += byteCount
                pending.append(Job(id: id, priority: priority, byteCount: byteCount, execute: {
                    let result = Result { try work() }
                    Task {
                        await self.finished(byteCount: byteCount) {
                            continuation.resume(returning: result)
                        }
                    }
                }, cancel: {
                    continuation.resume(returning: .failure(CancellationError()))
                }))
                startNext()
            }
        } onCancel: {
            Task { await self.cancelPending(id) }
        }
        try Task.checkCancellation()
        return try result.get()
    }

    private func cancelPending(_ id: UUID) {
        guard let index = pending.firstIndex(where: { $0.id == id }) else { return }
        let job = pending.remove(at: index)
        admittedBytes -= job.byteCount
        job.cancel()
    }

    private func startNext() {
        guard !running else { return }
        guard !pending.isEmpty else {
            if stopping && !stopped {
                // The last worker job has returned. Serialize destruction with
                // initialization and page work even if several callers shut down.
                worker.sync { pdf_worker_shutdown() }
                stopped = true
                for waiter in shutdownWaiters { waiter.resume() }
                shutdownWaiters.removeAll()
            }
            return
        }
        let index = pending.firstIndex { $0.priority == .onDemand } ?? 0
        let job = pending.remove(at: index)
        running = true
        worker.async(execute: job.execute)
    }

    private func finished(byteCount: Int, resume: @Sendable () -> Void) {
        admittedBytes -= byteCount
        running = false
        resume()
        startNext()
    }

    /// For process shutdown. Drain admitted jobs and close the library on its worker.
    public func shutdown() async {
        guard !stopped else { return }
        stopping = true
        await withCheckedContinuation { waiter in
            shutdownWaiters.append(waiter)
            startNext()
        }
    }
}
