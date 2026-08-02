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

    /// Content types the picker accepts (PDF, `.vellumweb` archive, `.vellum`
    /// bundle). Cached — a computed rebuild ran on every welcome-screen body
    /// pass. `exportedAs` rather than `filenameExtension:` because the app
    /// declares both custom types itself (Info-iOS.plist): the lookup is
    /// deterministic instead of returning nil until LaunchServices catches up.
    static let openableTypes: [UTType] = [
        .pdf,
        UTType(exportedAs: "com.vellum.webarchive"),
        UTType(exportedAs: "com.vellum.bundle"),
    ]

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
    /// container is opened in place (except a `.vellum`, which is a container to
    /// unpack, not a document to keep open). Name collisions get a numeric
    /// suffix so two different source files never clobber each other.
    static func importPicked(_ urls: [URL]) -> [String] {
        var paths: [String] = []
        for url in urls {
            if url.path.hasPrefix(libraryDirectory.path), !isBundle(url) {
                paths.append(url.path)
                continue
            }
            let accessed = url.startAccessingSecurityScopedResource()
            defer { if accessed { url.stopAccessingSecurityScopedResource() } }
            // A `.vellum` is unpacked into a document + sidecar and then thrown
            // away, so it is staged in tmp/ rather than added to the library the
            // user browses in Files.
            let dest = isBundle(url)
                ? stagingDestination(for: url.lastPathComponent)
                : uniqueDestination(for: url.lastPathComponent)
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

    private static func isBundle(_ url: URL) -> Bool {
        url.pathExtension.lowercased() == "vellum"
    }

    /// A private per-import directory under `tmp/`. Own directory rather than a
    /// unique filename so the import can delete the whole thing afterwards
    /// (`AppStore.openOneFile`) without guessing at siblings.
    private static func stagingDestination(for filename: String) -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("vellum-import-\(UUID().uuidString.lowercased())", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent(filename)
    }

    /// Where a `.vellum` bundle's document file lands. Re-importing an updated
    /// bundle for a document already in the library must overwrite that copy, not
    /// pile up "paper 2.pdf" — so an existing same-named file whose embedded
    /// /VellumDocId matches the manifest is reused. Anything else gets a unique
    /// name. `documentFile` has already passed `VellumBundle.safeName`, so it is
    /// a bare filename with no separators.
    ///
    /// This parses a PDF synchronously; call it off the hot path (the import
    /// flow already is).
    static func bundleDestination(documentFile: String, docId: String) -> URL {
        let candidate = libraryDirectory.appendingPathComponent(documentFile)
        guard FileManager.default.fileExists(atPath: candidate.path) else { return candidate }
        if PdfMetadata.documentId(atPath: candidate.path) == docId { return candidate }
        return uniqueDestination(for: documentFile)
    }

    static func uniqueDestination(for filename: String) -> URL {
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
