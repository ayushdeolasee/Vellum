import AppKit
import UniformTypeIdentifiers

/// An image handed from an AppKit drop inside the AI panel up to SwiftUI. The
/// file case is deliberately unread: the bytes are loaded off the main actor.
enum ImageDropPayload {
    case file(URL)
    case data(Data, name: String)
}

/// Drag-destination plumbing shared by the AI panel's AppKit text views.
///
/// AppKit gives a drag to the registered destination under the cursor, and the
/// panel's SwiftUI `.onDrop` never sees a drop that lands on AppKit content
/// inside it — so the composer field and each transcript bubble take image drops
/// themselves and forward the payload to the panel.
///
/// Main-actor because every caller is an AppKit dragging callback, which is.
@MainActor
enum ImageDrop {
    /// What a view must register to be offered image drags: Finder hands over a
    /// file URL, Preview / a browser hand over raw bytes.
    static let draggedTypes: [NSPasteboard.PasteboardType] = [.fileURL, .png, .tiff, .URL]

    /// Cheap test used by the per-mouse-move dragging callbacks: does this drag
    /// carry an image at all? (Deliberately does not touch the file — reading
    /// bytes on every `draggingUpdated` would stall the drag.)
    static func carriesImage(_ sender: NSDraggingInfo) -> Bool {
        let pasteboard = sender.draggingPasteboard
        return pasteboard.canReadObject(forClasses: [NSURL.self], options: urlOptions)
            || NSImage.canInit(with: pasteboard)
    }

    /// What the drag carries — a file (Finder) or raw image bytes (Preview, a
    /// browser). `performDragOperation` runs on the main thread, so this only
    /// *names* the payload: the file is never read here (a 60MB TIFF, or anything
    /// on iCloud Drive, would stall the drag while it materializes), and raw bytes
    /// are taken straight off the pasteboard rather than round-tripped through
    /// `NSImage.tiffRepresentation`, which would allocate the full uncompressed
    /// bitmap on the main actor. Reading, decoding and resizing all happen off the
    /// main actor in the handler.
    static func payload(_ sender: NSDraggingInfo) -> ImageDropPayload? {
        let pasteboard = sender.draggingPasteboard
        if let urls = pasteboard.readObjects(
            forClasses: [NSURL.self], options: urlOptions) as? [URL],
           let url = urls.first {
            return .file(url)
        }
        if let type = pasteboard.types?.first(where: {
            UTType($0.rawValue)?.conforms(to: .image) == true
        }), let data = pasteboard.data(forType: type) {
            return .data(data, name: "Dropped image")
        }
        return nil
    }

    static let urlOptions: [NSPasteboard.ReadingOptionKey: Any] = [
        .urlReadingFileURLsOnly: true,
        .urlReadingContentsConformToTypes: [UTType.image.identifier],
    ]
}
