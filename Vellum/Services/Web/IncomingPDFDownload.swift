#if os(macOS)
import Foundation
import PDFKit

enum IncomingPDFDownload {
    private enum NotPDF: Error { case response }

    static func download(
        _ url: URL,
        session: URLSession = .shared,
        maximumBytes: Int = 250 * 1024 * 1024
    ) async throws -> URL? {
        guard let scheme = url.scheme?.lowercased(),
            ["http", "https"].contains(scheme), url.host != nil
        else {
            throw SessionServiceError.invalidDocument("Only HTTP and HTTPS links can be opened.")
        }
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("vellum-incoming-\(UUID().uuidString)", isDirectory: true)
        let temporary = directory.appendingPathComponent("download.pdf")
        try await Task.detached(priority: .userInitiated) {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }.value
        let client = IntegrationDownloadClient(session: session) { response in
            let mime = response.mimeType?.lowercased()
            let isPDF =
                mime == "application/pdf"
                || (mime != "text/html"
                    && (response.url?.pathExtension.lowercased() == "pdf"
                        || response.suggestedFilename?.lowercased().hasSuffix(".pdf") == true))
            guard isPDF else { throw NotPDF.response }
        }
        do {
            let result = try await client.download(
                URLRequest(url: url), to: temporary, maximumBytes: maximumBytes
            ) { _ in }
            try Task.checkCancellation()
            let destination = try await Task.detached(priority: .userInitiated) {
                guard let document = PDFDocument(url: temporary), document.pageCount > 0 else {
                    throw SessionServiceError.invalidDocument("The downloaded file is not a readable PDF.")
                }
                let suggested = result.response.suggestedFilename ?? "Downloaded document.pdf"
                let base = URL(fileURLWithPath: suggested).deletingPathExtension().lastPathComponent
                let name = base.isEmpty || base == "." || base == ".." ? "Downloaded document" : base
                let destination = directory.appendingPathComponent(name + ".pdf")
                if destination != temporary {
                    try FileManager.default.moveItem(at: temporary, to: destination)
                }
                return destination
            }.value
            try Task.checkCancellation()
            return destination
        } catch {
            await remove(directory)
            if error is NotPDF { return nil }
            if let networkError = error as? URLError,
                networkError.code != .cancelled, url.pathExtension.lowercased() != "pdf"
            {
                return nil
            }
            throw error
        }
    }

    static func remove(_ url: URL) async {
        await Task.detached(priority: .utility) {
            try? FileManager.default.removeItem(at: url)
        }.value
    }
}
#endif
