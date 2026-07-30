import AppKit
import CryptoKit
import Foundation
import ImageIO

actor IntegrationThumbnailCache {
    private let root: URL
    private let session: URLSession
    private let fileManager: FileManager
    private let maximumBytes: Int
    private let maximumPixelCount: Int

    init(root: URL = WebLibrary.appDataDir.appendingPathComponent("integrations", isDirectory: true).appendingPathComponent("thumbnails", isDirectory: true), session: URLSession = .shared, fileManager: FileManager = .default, maximumBytes: Int = 8 * 1024 * 1024, maximumPixelCount: Int = 40_000_000) {
        self.root = root; self.session = session; self.fileManager = fileManager; self.maximumBytes = maximumBytes; self.maximumPixelCount = maximumPixelCount
    }

    func imageURL(for candidate: URL?) async -> URL? {
        guard let source = candidate.flatMap(ReadLaterItem.validHTTPURL) else { return nil }
        let destination = root.appendingPathComponent(Self.key(source) + ".image")
        if validImage(at: destination) { return destination }
        do {
            try Task.checkCancellation()
            let (bytes, response) = try await session.bytes(for: URLRequest(url: source))
            guard let response = response as? HTTPURLResponse, (200...299).contains(response.statusCode) else { return nil }
            guard response.expectedContentLength <= 0 || response.expectedContentLength <= Int64(maximumBytes) else { return nil }
            var data = Data()
            data.reserveCapacity(min(maximumBytes, max(0, Int(response.expectedContentLength))))
            for try await byte in bytes {
                try Task.checkCancellation()
                guard data.count < maximumBytes else { return nil }
                data.append(byte)
            }
            guard !data.isEmpty, validImageData(data) else { return nil }
            try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
            try data.write(to: destination, options: .atomic)
            return destination
        } catch { return nil }
    }

    func removeUnreferenced(keeping urls: Set<URL>) {
        let keys = Set(urls.map(Self.key))
        guard let contents = try? fileManager.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) else { return }
        for file in contents where !keys.contains(file.deletingPathExtension().lastPathComponent) { try? fileManager.removeItem(at: file) }
    }

    private func validImage(at url: URL) -> Bool {
        guard fileManager.fileExists(atPath: url.path), let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize, size <= maximumBytes, let data = try? Data(contentsOf: url, options: .mappedIfSafe) else { return false }
        return validImageData(data)
    }
    private func validImageData(_ data: Data) -> Bool {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil), let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any], let width = properties[kCGImagePropertyPixelWidth] as? NSNumber, let height = properties[kCGImagePropertyPixelHeight] as? NSNumber else { return false }
        let (pixels, overflow) = width.int64Value.multipliedReportingOverflow(by: height.int64Value)
        guard !overflow, width.intValue > 0, height.intValue > 0, pixels > 0, pixels <= Int64(maximumPixelCount) else { return false }
        return NSImage(data: data) != nil
    }
    static func key(_ url: URL) -> String { SHA256.hash(data: Data(url.absoluteString.utf8)).map { String(format: "%02x", $0) }.joined() }
}
