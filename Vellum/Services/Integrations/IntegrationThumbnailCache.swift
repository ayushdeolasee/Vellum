#if os(iOS)
import CryptoKit
import Foundation
import ImageIO
#if os(macOS)
import AppKit
#else
import UIKit
#endif

actor IntegrationThumbnailCache {
    private let root: URL
    private let downloader: IntegrationDownloading
    private let fileManager: FileManager
    private let maximumBytes: Int
    private let maximumPixelCount: Int

    init(root: URL = WebLibrary.appDataDir.appendingPathComponent("integrations", isDirectory: true).appendingPathComponent("thumbnails", isDirectory: true), session: URLSession = .shared, fileManager: FileManager = .default, maximumBytes: Int = 8 * 1024 * 1024, maximumPixelCount: Int = 40_000_000) {
        self.root = root; self.downloader = IntegrationDownloadClient(session: session); self.fileManager = fileManager; self.maximumBytes = maximumBytes; self.maximumPixelCount = maximumPixelCount
    }

    func imageURL(for candidate: URL?) async -> URL? {
        guard let source = candidate.flatMap(ReadLaterItem.validHTTPURL) else { return nil }
        let destination = root.appendingPathComponent(Self.key(source) + ".image")
        if validImage(at: destination) { return destination }
        let staging = root.appendingPathComponent(Self.key(source) + ".partial")
        do {
            try Task.checkCancellation()
            try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
            // Streamed to disk in the chunks the loading system delivers, with
            // the byte cap enforced mid-flight — the same client the PDF path
            // uses. Buffering the whole response (`session.data(for:)`) would
            // materialize the body in memory BEFORE any check ran, so a
            // chunked response with no Content-Length could grow unbounded.
            _ = try await downloader.download(URLRequest(url: source), to: staging, maximumBytes: maximumBytes) { _ in }
            defer { try? fileManager.removeItem(at: staging) }
            try Task.checkCancellation()
            guard let data = try? Data(contentsOf: staging, options: .mappedIfSafe), !data.isEmpty, validImageData(data) else { return nil }
            try data.write(to: destination, options: .atomic)
            return destination
        } catch { try? fileManager.removeItem(at: staging); return nil }
    }

    /// A decoded, row-sized image. Callers on the main actor must use this
    /// rather than `imageURL` + `UIImage(contentsOfFile:)`: the file read and
    /// the ImageIO decode both happen here, inside the actor, and the result is
    /// downsampled to `maximumThumbnailPixelSize` so a 4000px hero image doesn't
    /// sit in memory to fill a 34pt well.
    ///
    /// `sending` because `UIImage` isn't Sendable — this instance is created
    /// here, never stored, and never touched again once handed back.
    func image(for candidate: URL?) async -> sending UIImage? {
        guard let url = await imageURL(for: candidate) else { return nil }
        guard let data = try? Data(contentsOf: url, options: .mappedIfSafe),
              let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: Self.maximumThumbnailPixelSize,
        ]
        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        // Scale 1 is correct: the CGImage is already downsampled to
        // `maximumThumbnailPixelSize` and the row applies
        // `.resizable().scaledToFill()` inside a fixed frame. `UIScreen.main.scale`
        // would be wrong here anyway — it is main-actor-bound and deprecated.
        return UIImage(cgImage: cgImage)
    }

    /// Enough for the library well at 3x, with headroom. The iPad rows are
    /// taller than the Mac's 34pt well, but 256px still covers a 44–52pt well
    /// at 3x and raising it costs memory per row.
    private static let maximumThumbnailPixelSize = 256

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
        return UIImage(data: data) != nil
    }
    static func key(_ url: URL) -> String { SHA256.hash(data: Data(url.absoluteString.utf8)).map { String(format: "%02x", $0) }.joined() }
}
#endif
