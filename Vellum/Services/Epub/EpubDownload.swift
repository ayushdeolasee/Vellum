import Foundation

// Opening an http(s) link first asks whether it is a book. The response
// headers decide most links (an EPUB MIME type or `.epub` filename means a
// book, HTML means a webpage); ambiguous binary responses are sniffed for the
// EPUB `mimetype` entry. A book streams to disk with progress and a size cap
// from the same request; anything else is cancelled and opens as a webpage.
enum EpubDownload {
    static let maxBytes: Int64 = 512 * 1024 * 1024
    static let mediaType = "application/epub+zip"

    enum Outcome: Sendable, Equatable {
        case notEpub
        case downloaded(file: URL, filename: String)
    }

    enum Verdict: Equatable {
        case epub, maybe, notEpub
    }

    static func verdict(contentType: String?, filename: String?, url: URL) -> Verdict {
        let mime = contentType?.split(separator: ";").first?
            .trimmingCharacters(in: .whitespaces).lowercased() ?? ""
        if mime == mediaType { return .epub }
        if let filename, (filename as NSString).pathExtension.lowercased() == "epub" { return .epub }
        if mime.hasPrefix("text/") || mime.contains("html") || mime.contains("json")
            || mime.hasPrefix("image/") || mime.hasPrefix("video/") || mime.hasPrefix("audio/")
            || mime == "application/pdf" {
            return .notEpub
        }
        if url.pathExtension.lowercased() == "epub" { return .epub }
        let binary: Set<String> = [
            "", "application/octet-stream", "binary/octet-stream", "application/zip",
            "application/x-zip-compressed", "application/download", "application/force-download",
        ]
        return binary.contains(mime) ? .maybe : .notEpub
    }

    /// OCF requires an uncompressed first entry named `mimetype` holding the
    /// media type, so a valid book starts with this local file header.
    static func hasEpubSignature(_ prefix: Data) -> Bool {
        let bytes = [UInt8](prefix.prefix(58))
        guard bytes.count >= 58, bytes[0...3] == [0x50, 0x4B, 0x03, 0x04] else { return false }
        return Data(bytes[30..<58]) == Data(("mimetype" + mediaType).utf8)
    }

    static func filename(contentDisposition: String?) -> String? {
        guard let header = contentDisposition else { return nil }
        for part in header.split(separator: ";") {
            let pair = part.split(separator: "=", maxSplits: 1).map {
                $0.trimmingCharacters(in: .whitespaces)
            }
            guard pair.count == 2 else { continue }
            let key = pair[0].lowercased()
            var value = pair[1].trimmingCharacters(in: CharacterSet(charactersIn: "\""))
            if key == "filename*" {
                if let range = value.range(of: "''") { value = String(value[range.upperBound...]) }
                value = value.removingPercentEncoding ?? value
                return value
            }
            if key == "filename" { return value }
        }
        return nil
    }

    static let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.httpAdditionalHeaders = ["User-Agent": WebFetch.userAgent]
        config.timeoutIntervalForRequest = 20
        config.httpCookieAcceptPolicy = .never
        config.httpShouldSetCookies = false
        config.urlCache = nil
        return URLSession(configuration: config)
    }()

    /// Probe failures before the response is known to be a book return
    /// `.notEpub`, so the link still opens as a webpage.
    static func fetch(
        _ url: URL,
        into directory: URL = FileManager.default.temporaryDirectory,
        session: URLSession = session,
        maxBytes: Int64 = maxBytes,
        progress: @escaping @Sendable (Double?) async -> Void = { _ in }
    ) async throws -> Outcome {
        let delegate = StreamDelegate()
        let task = session.dataTask(with: URLRequest(url: url))
        task.delegate = delegate
        defer { task.cancel() }
        var file: URL?
        var handle: FileHandle?
        func discard() {
            try? handle?.close()
            if let file { try? FileManager.default.removeItem(at: file) }
        }
        do {
            return try await withTaskCancellationHandler {
                task.resume()
                var response: HTTPURLResponse?
                var name = url.lastPathComponent
                var kind = Verdict.notEpub
                var pending = Data()
                var expected: Int64?
                var received: Int64 = 0
                var reported: Int64 = 0

                func commit() async throws {
                    let target = directory.appendingPathComponent("vellum-download-\(UUID().uuidString).epub")
                    guard FileManager.default.createFile(atPath: target.path, contents: nil) else {
                        throw SessionServiceError.io("Could not save the downloaded book")
                    }
                    file = target
                    handle = try FileHandle(forWritingTo: target)
                    try handle?.write(contentsOf: pending)
                    pending = Data()
                    await progress(expected.map { min(1, Double(received) / Double($0)) })
                }

                for try await event in delegate.events {
                    try Task.checkCancellation()
                    switch event {
                    case .response(let value):
                        guard (200..<300).contains(value.statusCode) else { return .notEpub }
                        response = value
                        let disposition = filename(contentDisposition: value.value(forHTTPHeaderField: "Content-Disposition"))
                        let finalURL = value.url ?? url
                        kind = verdict(contentType: value.value(forHTTPHeaderField: "Content-Type"),
                                          filename: disposition ?? finalURL.lastPathComponent, url: finalURL)
                        guard kind != .notEpub else { return .notEpub }
                        name = disposition ?? finalURL.lastPathComponent
                        expected = value.expectedContentLength > 0 ? value.expectedContentLength : nil
                        if let expected, expected > maxBytes {
                            throw SessionServiceError.io("This book is too large to download")
                        }
                        if kind == .epub { try await commit() }
                    case .data(let chunk):
                        received += Int64(chunk.count)
                        if received > maxBytes { throw SessionServiceError.io("This book is too large to download") }
                        if let handle {
                            try handle.write(contentsOf: chunk)
                        } else {
                            pending.append(chunk)
                            guard pending.count >= 58 else { continue }
                            guard hasEpubSignature(pending) else { return .notEpub }
                            kind = .epub
                            try await commit()
                        }
                        if received - reported >= 256 * 1024 {
                            reported = received
                            await progress(expected.map { min(1, Double(received) / Double($0)) })
                        }
                    }
                }
                try Task.checkCancellation()
                guard response != nil else { return .notEpub }
                if handle == nil {
                    guard hasEpubSignature(pending) else { return .notEpub }
                    try await commit()
                }
                try handle?.close()
                handle = nil
                guard let file else { return .notEpub }
                await progress(1)
                return .downloaded(file: file, filename: name)
            } onCancel: {
                task.cancel()
            }
        } catch {
            discard()
            if error is CancellationError || (error as? URLError)?.code == .cancelled {
                throw CancellationError()
            }
            // Before any book bytes were committed, let the webpage flow
            // report its own error.
            if file == nil, !(error is SessionServiceError) { return .notEpub }
            if let error = error as? SessionServiceError { throw error }
            throw SessionServiceError.io("The book download failed: \(error.localizedDescription)")
        }
    }

    private enum Event: Sendable {
        case response(HTTPURLResponse)
        case data(Data)
    }

    private final class StreamDelegate: NSObject, URLSessionDataDelegate, @unchecked Sendable {
        let events: AsyncThrowingStream<Event, Error>
        private let continuation: AsyncThrowingStream<Event, Error>.Continuation

        override init() {
            let (stream, continuation) = AsyncThrowingStream<Event, Error>.makeStream()
            events = stream
            self.continuation = continuation
            super.init()
        }

        func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
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
}
