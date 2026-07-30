import Foundation

final class StubURLProtocol: URLProtocol {
    nonisolated(unsafe) static var handler: ((URLRequest) throws -> (HTTPURLResponse, Data))?
    private static let lock = NSLock()

    static func install(_ value: @escaping (URLRequest) throws -> (HTTPURLResponse, Data)) {
        lock.lock(); handler = value; lock.unlock()
    }

    static func reset() {
        lock.lock(); handler = nil; lock.unlock()
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.lock.lock(); let value = Self.handler; Self.lock.unlock()
        do {
            guard let value else { throw URLError(.badServerResponse) }
            let (response, data) = try value(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() {}

    static func session() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]
        return URLSession(configuration: configuration)
    }
}
