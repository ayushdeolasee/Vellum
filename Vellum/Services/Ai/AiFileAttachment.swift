import Foundation
import UniformTypeIdentifiers

/// A dropped or picked file, classified for AI attachment. Vellum's AI chat
/// accepts images only — for both drag-and-drop and the "+" ▸ Attach image…
/// picker — so an image is decoded into the same `AiPageImageSnapshot` every
/// other image path produces, and every other file is reported by name rather
/// than attached, so no drop ever silently vanishes.
enum AiFileAttachment {
    /// An image file, decoded into the shared snapshot type.
    case image(AiPageImageSnapshot, name: String)
    /// A readable file we won't attach: it isn't an image, or it carries an
    /// image type but its bytes wouldn't decode (corrupt). Only the name is
    /// kept — the caller names it in the images-only notice.
    case rejected(name: String)
}

/// Classify one file. Blocking file I/O and image decode — call it off the main
/// actor (a drag must never stall on a 60MB file or an iCloud Drive download).
/// Returns nil only when the path can't be reached at all (missing, no
/// permission, or a directory); a readable non-image comes back as `.rejected`.
func aiFileAttachment(from url: URL) -> AiFileAttachment? {
    let name = url.lastPathComponent
    let values = try? url.resourceValues(forKeys: [.contentTypeKey, .isDirectoryKey])
    guard values?.isDirectory != true else { return nil }
    // Resource values know the real type even for extensionless files; the
    // extension is only a fallback for paths the file system won't describe.
    let type = values?.contentType ?? UTType(filenameExtension: url.pathExtension)

    guard type?.conforms(to: .image) == true else {
        // A non-image file: reject it by name — but only if it's actually a
        // readable file, so a missing/unreadable path still returns nil and
        // gets the distinct "folder or unreadable" notice.
        guard (try? url.checkResourceIsReachable()) == true else { return nil }
        return .rejected(name: name)
    }

    // An image by type: decode it, or reject by name if the bytes are corrupt.
    guard let data = try? Data(contentsOf: url),
          let snapshot = aiImageSnapshot(from: data) else {
        return .rejected(name: name)
    }
    return .image(snapshot, name: name)
}
