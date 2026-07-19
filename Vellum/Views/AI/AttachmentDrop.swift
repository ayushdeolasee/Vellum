import AppKit
import UniformTypeIdentifiers

/// A payload handed from an AppKit drop inside the AI panel up to SwiftUI. The
/// file case is deliberately unread: the bytes are loaded off the main actor.
enum AttachmentDropPayload {
    case files([URL])
    case imageData(Data, name: String)
}

/// `NSItemProvider.loadItem` for a file URL hands back whichever of these the
/// drag source happened to register — a `URL`, an `NSURL`, or the URL's bytes.
/// Nonisolated: it runs on the provider's completion queue, off the main actor.
func fileURL(fromDropItem item: NSSecureCoding?) -> URL? {
    switch item {
    case let url as URL: url
    case let url as NSURL: url as URL
    case let data as Data: URL(dataRepresentation: data, relativeTo: nil)
    default: nil
    }
}

/// Drag-destination plumbing shared by the AI panel's AppKit text views.
///
/// AppKit gives a drag to the registered destination under the cursor, and the
/// panel's SwiftUI `.onDrop` never sees a drop that lands on AppKit content
/// inside it — so the composer field and each transcript bubble take attachment
/// drops themselves and forward the payload to the panel.
///
/// Main-actor because every caller is an AppKit dragging callback, which is.
@MainActor
enum AttachmentDrop {
    /// What a view must register to be offered attachment drags: Finder hands
    /// over a file URL, Preview / a browser hand over raw image bytes.
    static let draggedTypes: [NSPasteboard.PasteboardType] = [.fileURL, .png, .tiff, .URL]

    /// Cheap test used by the per-mouse-move dragging callbacks: does this drag
    /// carry anything attachable — a file of any type, or raw image bytes?
    /// (Deliberately does not touch the file — reading bytes on every
    /// `draggingUpdated` would stall the drag.)
    static func carriesAttachment(_ sender: NSDraggingInfo) -> Bool {
        let pasteboard = sender.draggingPasteboard
        return pasteboard.canReadObject(forClasses: [NSURL.self], options: fileURLOptions)
            || NSImage.canInit(with: pasteboard)
    }

    /// What the drag carries — files (Finder) or raw image bytes (Preview, a
    /// browser). `performDragOperation` runs on the main thread, so this only
    /// *names* the payload: files are never read here (a 60MB TIFF, or anything
    /// on iCloud Drive, would stall the drag while it materializes), and raw
    /// bytes are taken straight off the pasteboard rather than round-tripped
    /// through `NSImage.tiffRepresentation`, which would allocate the full
    /// uncompressed bitmap on the main actor. Reading, classifying and decoding
    /// all happen off the main actor in the handler.
    static func payload(_ sender: NSDraggingInfo) -> AttachmentDropPayload? {
        let pasteboard = sender.draggingPasteboard
        if let urls = pasteboard.readObjects(
            forClasses: [NSURL.self], options: fileURLOptions) as? [URL],
           !urls.isEmpty {
            return .files(urls)
        }
        if let type = pasteboard.types?.first(where: {
            UTType($0.rawValue)?.conforms(to: .image) == true
        }), let data = pasteboard.data(forType: type) {
            return .imageData(data, name: "Dropped image")
        }
        return nil
    }

    static let fileURLOptions: [NSPasteboard.ReadingOptionKey: Any] = [
        .urlReadingFileURLsOnly: true,
    ]
}
