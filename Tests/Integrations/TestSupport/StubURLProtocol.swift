import Foundation

/// A chunk of a streamed stub response body. `delay` (if present) is awaited
/// before the chunk is delivered to the client, letting tests exercise
/// mid-download cancellation and slow/absent Content-Length scenarios.
struct StubStreamingChunk: Sendable {
    let data: Data
    let delay: Duration?
    init(_ data: Data, delay: Duration? = nil) { self.data = data; self.delay = delay }
}

struct StubStreamingResponse: Sendable {
    let response: HTTPURLResponse
    let chunks: [StubStreamingChunk]
}

final class StubURLProtocol: URLProtocol {
    nonisolated(unsafe) static var handler: (@Sendable (URLRequest) throws -> (HTTPURLResponse, Data))?
    nonisolated(unsafe) static var streamingHandler: (@Sendable (URLRequest) throws -> StubStreamingResponse)?
    private static let lock = NSLock()
    private var streamTask: Task<Void, Never>?

    static func install(_ value: @escaping @Sendable (URLRequest) throws -> (HTTPURLResponse, Data)) {
        lock.lock(); handler = value; lock.unlock()
    }

    /// Installs a handler that delivers its response body as a sequence of
    /// chunks (each optionally delayed) instead of a single `didLoad` call —
    /// use this to exercise clients that consume the body incrementally.
    static func installStreaming(_ value: @escaping @Sendable (URLRequest) throws -> StubStreamingResponse) {
        lock.lock(); streamingHandler = value; lock.unlock()
    }

    static func reset() {
        lock.lock(); handler = nil; streamingHandler = nil; lock.unlock()
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.lock.lock(); let value = Self.handler; let streaming = Self.streamingHandler; Self.lock.unlock()
        if let streaming { startStreaming(streaming); return }
        do {
            guard let value else { throw URLError(.badServerResponse) }
            let (response, data) = try value(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() { streamTask?.cancel() }

    private func startStreaming(_ streaming: @escaping @Sendable (URLRequest) throws -> StubStreamingResponse) {
        // `URLProtocol` marks its `Sendable` conformance unavailable, so the
        // stub can't be declared `@unchecked Sendable` and `self` can't cross
        // into the task unaided. The escape hatch is sound here: the loading
        // system expects client callbacks from arbitrary threads, and after
        // `startLoading` this instance is touched only by this one task (plus
        // `stopLoading`'s cancel, which is why the task checks cancellation).
        nonisolated(unsafe) let stub = self
        streamTask = Task { [request] in
            do {
                let value = try streaming(request)
                stub.client?.urlProtocol(stub, didReceive: value.response, cacheStoragePolicy: .notAllowed)
                for chunk in value.chunks {
                    if let delay = chunk.delay { try await Task.sleep(for: delay) }
                    try Task.checkCancellation()
                    stub.client?.urlProtocol(stub, didLoad: chunk.data)
                }
                stub.client?.urlProtocolDidFinishLoading(stub)
            } catch is CancellationError {
                // stopLoading() already cancelled us; the URL Loading System doesn't expect
                // a client callback in that case.
            } catch {
                stub.client?.urlProtocol(stub, didFailWithError: error)
            }
        }
    }

    static func session() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]
        return URLSession(configuration: configuration)
    }
}
