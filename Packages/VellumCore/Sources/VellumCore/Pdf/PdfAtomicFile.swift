import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

public enum PdfAtomicFile {
    /// Write `data` over the PDF at `path` atomically: temp file
    /// `.{name}.vellum-{uuid}.tmp` in the same directory, original permissions
    /// preserved, POSIX rename. Error strings mirror save_document/replace_file.
    public static func save(_ data: Data, toPath path: String) throws {
        try save(data, toPath: path) { source, destination in
            rename(source, destination) == 0 ? 0 : errno
        }
    }

    // The replacement returns the captured POSIX error (zero on success).
    static func save(_ data: Data, toPath path: String, replace: (String, String) -> Int32) throws {
        let url = URL(fileURLWithPath: path)
        let parent = url.deletingLastPathComponent()
        let fileName = url.lastPathComponent.isEmpty ? "document.pdf" : url.lastPathComponent
        let nonce = UUID().uuidString.lowercased()
        let temporaryURL = parent.appendingPathComponent(".\(fileName).vellum-\(nonce).tmp")

        let permissions: Any?
        do {
            permissions = try FileManager.default.attributesOfItem(atPath: path)[.posixPermissions]
        } catch {
            throw PdfCoreError.io("Failed to read PDF permissions: \(error.localizedDescription)")
        }

        do {
            try data.write(to: temporaryURL)
        } catch {
            try? FileManager.default.removeItem(at: temporaryURL)
            throw PdfCoreError.io("Failed to write annotated PDF: \(error.localizedDescription)")
        }

        if let permissions {
            do {
                try FileManager.default.setAttributes(
                    [.posixPermissions: permissions], ofItemAtPath: temporaryURL.path)
            } catch {
                try? FileManager.default.removeItem(at: temporaryURL)
                throw PdfCoreError.io("Failed to preserve PDF permissions: \(error.localizedDescription)")
            }
        }

        // rename(2) is atomic on the same volume and replaces the destination.
        let failure = replace(temporaryURL.path, path)
        if failure != 0 {
            let message = String(cString: strerror(failure))
            try? FileManager.default.removeItem(at: temporaryURL)
            throw PdfCoreError.io("Failed to replace PDF with annotated copy: \(message)")
        }
    }
}
