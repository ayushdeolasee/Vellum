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

        let attributes: [FileAttributeKey: Any]
        do {
            attributes = try FileManager.default.attributesOfItem(atPath: path)
        } catch {
            throw PdfCoreError.io("Failed to read PDF permissions: \(error.localizedDescription)")
        }
        guard attributes[.type] as? FileAttributeType == .typeRegular,
              let permissions = attributes[.posixPermissions] as? NSNumber else {
            throw PdfCoreError.io("Failed to read PDF permissions: expected a regular file")
        }

        // Create the stage exclusively, with no access for group or others
        // until its complete contents and source permissions are ready.
        let mode = mode_t(permissions.uint16Value)
        let fd = open(temporaryURL.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, mode & 0o600)
        guard fd >= 0 else { throw ioError("Failed to write annotated PDF", errno) }
        var committed = false
        defer { if !committed { unlink(temporaryURL.path) } }

        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        do {
            try handle.write(contentsOf: data)
            guard fchmod(fd, mode) == 0 else { throw ioError("Failed to preserve PDF permissions", errno) }
            try handle.synchronize()
            try handle.close()
        } catch let error as PdfCoreError {
            throw error
        } catch {
            throw PdfCoreError.io("Failed to write annotated PDF: \(error.localizedDescription)")
        }

        let failure = replace(temporaryURL.path, path)
        guard failure == 0 else { throw ioError("Failed to replace PDF with annotated copy", failure) }
        committed = true

        // The rename is already visible. Flush its directory entry where the
        // filesystem permits this; reporting failure here would invite retries
        // of a mutation which has already committed.
        let directory = open(parent.path, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        if directory >= 0 {
            _ = fsync(directory)
            _ = close(directory)
        }
    }

    private static func ioError(_ operation: String, _ code: Int32) -> PdfCoreError {
        var buffer = [CChar](repeating: 0, count: 256)
        let result = strerror_r(code, &buffer, buffer.count)
        let message = result == 0 ? String(cString: buffer) : "POSIX error \(code)"
        return .io("\(operation): \(message)")
    }
}
