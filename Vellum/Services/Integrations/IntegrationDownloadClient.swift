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
        do {
            let (bytes, response) = try await session.bytes(for: request)
            guard let response = response as? HTTPURLResponse, (200...299).contains(response.statusCode) else { throw IntegrationError.invalidResponse }
            let expected = response.expectedContentLength > 0 ? response.expectedContentLength : nil
            if let expected, expected > maximumBytes { throw IntegrationError.downloadTooLarge }
            let handle = try FileHandle(forWritingTo: temporaryURL); defer { try? handle.close() }
            var buffer = Data(); var received: Int64 = 0; await progress(expected == nil ? nil : 0)
            for try await byte in bytes {
                try Task.checkCancellation(); buffer.append(byte); received += 1
                if received > maximumBytes { throw IntegrationError.downloadTooLarge }
                if buffer.count >= 64 * 1024 { try handle.write(contentsOf: buffer); buffer.removeAll(keepingCapacity: true) }
                if received % (128 * 1024) == 0 { await progress(expected.map { min(1, Double(received) / Double($0)) }) }
            }
            if !buffer.isEmpty { try handle.write(contentsOf: buffer) }
            await progress(expected.map { _ in 1 })
            return .init(temporaryURL: temporaryURL, response: response)
        } catch { try? FileManager.default.removeItem(at: temporaryURL); throw error }
    }
}
