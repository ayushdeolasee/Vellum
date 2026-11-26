import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public struct StreamingHead: Sendable {
    public let status: Int
    public let headers: [String: [String]]
    public let url: URL?

    public init(status: Int, headers: [String: [String]], url: URL? = nil) {
        self.status = status
        self.headers = headers
        self.url = url
    }

    public func header(_ name: String) -> String? {
        headers.first { $0.key.caseInsensitiveCompare(name) == .orderedSame }?.value.first
    }
}

/// Callbacks run in order. Throwing from either callback stops the request.
/// Implementations must await the consumer before delivering the next chunk.
public protocol StreamingTransport: Sendable {
    func execute(
        _ request: URLRequest,
        onHead: @escaping @Sendable (StreamingHead) async throws -> Void,
        onChunk: @escaping @Sendable (Data) async throws -> Void
    ) async throws
}
