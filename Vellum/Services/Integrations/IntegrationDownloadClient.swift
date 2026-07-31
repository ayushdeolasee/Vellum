import Foundation

struct IntegrationDownloadResult: Sendable { let temporaryURL: URL; let response: HTTPURLResponse }
protocol IntegrationDownloading: Sendable {
    func download(_ request: URLRequest, to temporaryURL: URL, maximumBytes: Int, progress: @escaping @Sendable (Double?) async -> Void) async throws -> IntegrationDownloadResult
}

actor IntegrationDownloadClient: IntegrationDownloading {
    private let session: URLSession
    init(session: URLSession = .shared) { self.session = session }

    func download(_ request: URLRequest, to temporaryURL: URL, maximumBytes: Int, progress: @escaping @Sendable (Double?) async -> Void) async throws -> IntegrationDownloadResult {
        try? FileManager.default.removeItem(at: temporaryURL)
        FileManager.default.createFile(atPath: temporaryURL.path, contents: nil)
        let delegate = IntegrationDownloadStreamDelegate()
        let task = session.dataTask(with: request)
        task.delegate = delegate
        defer { task.cancel() }
        do {
            let handle = try FileHandle(forWritingTo: temporaryURL); defer { try? handle.close() }
            var response: HTTPURLResponse?
            var expected: Int64?
            var received: Int64 = 0
            var reportedThroughByte: Int64 = 0
            try await withTaskCancellationHandler {
                task.resume()
                for try await event in delegate.events {
                    try Task.checkCancellation()
                    switch event {
                    case .response(let value):
                        guard (200...299).contains(value.statusCode) else { throw IntegrationError.invalidResponse }
                        response = value
                        expected = value.expectedContentLength > 0 ? value.expectedContentLength : nil
                        if let expected, expected > maximumBytes { throw IntegrationError.downloadTooLarge }
                        await progress(expected == nil ? nil : 0)
                    case .data(let chunk):
                        received += Int64(chunk.count)
                        if received > maximumBytes { throw IntegrationError.downloadTooLarge }
                        try handle.write(contentsOf: chunk)
                        if received - reportedThroughByte >= 128 * 1024 {
                            reportedThroughByte = received
                            await progress(expected.map { min(1, Double(received) / Double($0)) })
                        }
                    }
                }
            } onCancel: {
                task.cancel()
            }
            // Cancellation while suspended on the stream ENDS it (AsyncThrowingStream's
            // next() returns nil under cancellation instead of throwing), so the loop
            // above can exit cleanly with a response already in hand — re-check here or
            // a cancelled download would return success with a partial file.
            try Task.checkCancellation()
            guard let response else { throw IntegrationError.invalidResponse }
            await progress(expected.map { _ in 1 })
            return .init(temporaryURL: temporaryURL, response: response)
        } catch {
            try? FileManager.default.removeItem(at: temporaryURL)
            if let urlError = error as? URLError, urlError.code == .cancelled { throw CancellationError() }
            throw error
        }
    }
}

/// Bridges a URLSessionDataTask's delegate callbacks into an AsyncThrowingStream so the
/// response body can be consumed in multi-kilobyte chunks (as delivered by the URL Loading
/// System) instead of iterating `URLSession.bytes(for:)` one byte at a time, which saturates
/// a cooperative-pool thread for large (up to 250 MB) downloads.
private enum IntegrationDownloadEvent: Sendable { case response(HTTPURLResponse); case data(Data) }

private final class IntegrationDownloadStreamDelegate: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    let events: AsyncThrowingStream<IntegrationDownloadEvent, Error>
    private let continuation: AsyncThrowingStream<IntegrationDownloadEvent, Error>.Continuation

    override init() {
        var continuation: AsyncThrowingStream<IntegrationDownloadEvent, Error>.Continuation!
        events = AsyncThrowingStream { continuation = $0 }
        self.continuation = continuation
        super.init()
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse, completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        if let http = response as? HTTPURLResponse { continuation.yield(.response(http)) }
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        continuation.yield(.data(data))
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error { continuation.finish(throwing: error) } else { continuation.finish() }
    }
}
