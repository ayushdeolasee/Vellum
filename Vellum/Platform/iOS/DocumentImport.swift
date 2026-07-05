#if os(iOS)
import Foundation
import UniformTypeIdentifiers

/// iOS document intake. Files chosen from the Files app / iCloud are external and
/// security-scoped; Vellum writes annotations back into the PDF, so we copy each
/// picked file into the app's Documents directory and operate on that writable
/// copy. This keeps the whole path-based service layer (sessions, recent files,
/// atomic writer) unchanged from macOS.
enum DocumentImport {
    static var libraryDirectory: URL {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let dir = docs.appendingPathComponent("Documents", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Content types the picker accepts (PDF + `.vellumweb` archive).
    static var openableTypes: [UTType] {
        var types: [UTType] = [.pdf]
        if let archive = UTType(filenameExtension: "vellumweb") { types.append(archive) }
        return types
    }

    /// Copy security-scoped picked URLs into the writable library, returning the
    /// local paths to hand to `AppStore.openFiles`. A file already inside the
    /// container is opened in place. Name collisions get a numeric suffix so two
    /// different source files never clobber each other.
    static func importPicked(_ urls: [URL]) -> [String] {
        var paths: [String] = []
        for url in urls {
            if url.path.hasPrefix(libraryDirectory.path) {
                paths.append(url.path)
                continue
            }
            let accessed = url.startAccessingSecurityScopedResource()
            defer { if accessed { url.stopAccessingSecurityScopedResource() } }
            let dest = uniqueDestination(for: url.lastPathComponent)
            do {
                if FileManager.default.fileExists(atPath: dest.path) {
                    try FileManager.default.removeItem(at: dest)
                }
                try FileManager.default.copyItem(at: url, to: dest)
                paths.append(dest.path)
            } catch {
                NSLog("[document-import] Failed to import \(url.lastPathComponent): \(error)")
            }
        }
        return paths
    }

    private static func uniqueDestination(for filename: String) -> URL {
        let dir = libraryDirectory
        var candidate = dir.appendingPathComponent(filename)
        guard FileManager.default.fileExists(atPath: candidate.path) else { return candidate }
        let base = (filename as NSString).deletingPathExtension
        let ext = (filename as NSString).pathExtension
        var index = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            let name = ext.isEmpty ? "\(base) \(index)" : "\(base) \(index).\(ext)"
            candidate = dir.appendingPathComponent(name)
            index += 1
        }
        return candidate
    }
}
#endif
