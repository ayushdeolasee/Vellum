import Foundation
import VellumCore

struct AppleStreamingTransport: StreamingTransport {
    let session: URLSession
    init(session: URLSession = .shared) { self.session = session }

    enum Failure: Error { case nonHTTPResponse }

    func execute(
        _ request: URLRequest,
        onHead: @escaping @Sendable (StreamingHead) async throws -> Void,
        onChunk: @escaping @Sendable (Data) async throws -> Void
    ) async throws {
        let delegate = Delegate()
        let task = session.dataTask(with: request)
        task.delegate = delegate
        defer { task.cancel() }
        try await withTaskCancellationHandler {
            try Task.checkCancellation()
            task.resume()
            for try await event in delegate.events.stream {
                try Task.checkCancellation()
                switch event {
                case .head(let response):
                    guard let http = response as? HTTPURLResponse else { throw Failure.nonHTTPResponse }
                    var headers: [String: [String]] = [:]
                    for (key, value) in http.allHeaderFields {
                        if let name = key as? String, let value = value as? String {
                            headers[name.lowercased(), default: []].append(value)
                        }
                    }
                    try await onHead(.init(status: http.statusCode, headers: headers, url: http.url))
                    task.resume()
                case .data(let data):
                    try await onChunk(data)
                    task.resume()
                }
            }
            try Task.checkCancellation()
        } onCancel: {
            task.cancel()
        }
    }

    private final class Delegate: NSObject, URLSessionDataDelegate {
        enum Event: Sendable {
            case head(URLResponse)
            case data(Data)
        }

        let events = AsyncThrowingStream<Event, Error>.makeStream()

        func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                        completionHandler: @escaping @Sendable (URLSession.ResponseDisposition) -> Void) {
            dataTask.suspend()
            events.continuation.yield(.head(response))
            completionHandler(.allow)
        }

        func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
            // One resume per delivery, after the consumer has finished with the bytes.
            dataTask.suspend()
            events.continuation.yield(.data(data))
        }

        func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
            events.continuation.finish(throwing: error)
        }
    }
}
