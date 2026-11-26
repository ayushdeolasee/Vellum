import AsyncHTTPClient
import Foundation
import FoundationNetworking
import VellumCore

public struct AHCTransport: StreamingTransport {
    public init() {}

    public func execute(
        _ request: URLRequest,
        onHead: @escaping @Sendable (StreamingHead) async throws -> Void,
        onChunk: @escaping @Sendable (Data) async throws -> Void
    ) async throws {
        guard let url = request.url else { throw URLError(.badURL) }
        // A streamed upload cannot be silently replaced with an empty body.
        guard request.httpBodyStream == nil else { throw URLError(.requestBodyStreamExhausted) }
        var outbound = HTTPClientRequest(url: url.absoluteString)
        outbound.method = .RAW(value: request.httpMethod ?? "GET")
        for (name, value) in request.allHTTPHeaderFields ?? [:] {
            outbound.headers.add(name: name, value: value)
        }
        if let data = request.httpBody { outbound.body = .bytes(data) }

        try Task.checkCancellation()
        guard let milliseconds = Int64(exactly: (request.timeoutInterval * 1000).rounded(.up)),
              milliseconds >= 0 else { throw URLError(.timedOut) }
        let response = try await HTTPClient.shared.execute(outbound, timeout: .milliseconds(milliseconds))
        var headers: [String: [String]] = [:]
        for (name, value) in response.headers { headers[name.lowercased(), default: []].append(value) }
        try await onHead(StreamingHead(status: Int(response.status.code), headers: headers, url: response.url))
        for try await buffer in response.body {
            try Task.checkCancellation()
            try await onChunk(Data(buffer.readableBytesView))
        }
        try Task.checkCancellation()
    }
}
