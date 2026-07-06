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

    /// Content types the picker accepts (PDF + `.vellumweb` archive). Cached — a
    /// computed rebuild ran on every welcome-screen body pass.
    static let openableTypes: [UTType] = {
        var types: [UTType] = [.pdf]
        if let archive = UTType(filenameExtension: "vellumweb") { types.append(archive) }
        return types
    }()

    /// Resolve a stored recent-document path to a file that exists *now*.
    ///
    /// Recents persist an absolute path rooted in the app's data container
    /// (`.../Application/<UUID>/Documents/Documents/<name>`), but that container
    /// UUID changes across reinstalls/updates — so the stored path can stop
    /// resolving even though the imported copy is still present under the current
    /// library directory. Every opened PDF was copied into `libraryDirectory`
    /// (flat, by filename), so if the stored path is gone we fall back to a
    /// same-named file in the current library. Returns `nil` if neither exists.
    static func resolveExistingPath(_ path: String) -> String? {
        if FileManager.default.fileExists(atPath: path) { return path }
        let candidate = libraryDirectory.appendingPathComponent((path as NSString).lastPathComponent)
        if FileManager.default.fileExists(atPath: candidate.path) { return candidate.path }
        return nil
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
