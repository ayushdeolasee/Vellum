import Foundation
import UniformTypeIdentifiers

/// A payload handed from a drop inside the AI panel up to the store. The file
/// case is deliberately unread: the bytes are loaded off the main actor.
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
    case let data as Data: fileURL(fromDropData: data)
    default: nil
    }
}

/// The `Data` shape is not one format but two, and telling them apart matters.
///
/// UIKit registers `public.file-url` as a **binary property list** holding the
/// URL string alongside its security-scoped bookmark — that is what a drag out
/// of Files, or an `NSItemProvider(contentsOf:)`, actually carries. Handing
/// those bytes to `URL(dataRepresentation:)` does not fail; it returns a URL
/// whose last path component is the filename with the bookmark bytes
/// percent-escaped onto the end (`notes.txtP%C3%00%08…`). Every such path is
/// unreachable, so `aiFileAttachment` returns nil and the user is told their
/// PNG is "a folder or unreadable" — packet 5 §5 risk 8's symptom, arriving
/// through URL decoding rather than through security scoping.
///
/// Other sources really do register `url.dataRepresentation`, so that branch
/// stays — it is just no longer the *first* thing tried.
private func fileURL(fromDropData data: Data) -> URL? {
    if let plist = try? PropertyListSerialization.propertyList(
        from: data, options: [], format: nil) {
        let strings = (plist as? [Any])?.compactMap { $0 as? String } ?? [plist as? String].compactMap { $0 }
        if let url = strings.lazy.compactMap({ URL(string: $0) }).first(where: \.isFileURL) {
            return url
        }
    }
    return URL(dataRepresentation: data, relativeTo: nil)
}

/// Drop-classification plumbing shared by the AI panel's drop destinations.
///
/// This is the iOS rebuild of the macOS `NSDraggingInfo`/`NSPasteboard`
/// classifier: the same two payload shapes and the same "name it here, read it
/// off the main actor" contract, but driven by `NSItemProvider` because that is
/// what SwiftUI's `.onDrop` and UIKit's `UIDropInteraction` both hand over.
///
/// It lives outside the panel because the iPad registers *three* destinations
/// for the same gesture — the panel root, the composer `TextField`, and each
/// transcript bubble's `UITextView`, which would otherwise swallow a drop that
/// lands over it — and all three must classify identically.
///
/// Main-actor for the same reason main's AppKit version is: every caller is a
/// drop callback, `NSItemProvider` is not `Sendable`, and the only work done
/// here is naming the payload — the reading and decoding happen off the main
/// actor inside `AiStore`.
@MainActor
enum AttachmentDrop {
    /// What the panel registers with SwiftUI's `.onDrop(of:)`. Both types are
    /// needed: Files hands over a file URL and NOT an image, so `.image` alone
    /// never matches it; Photos and browsers hand over the bytes, which `.image`
    /// matches.
    ///
    /// Deliberately NOT gated on the active model's vision support. A non-image
    /// file — or an image on a text-only model — now produces a notice instead
    /// of a drag that silently springs back to its source: the images-only
    /// policy lives in `AiStore.attachFiles`, and a stranded image is explained
    /// by the composer's `strandedImagesNotice`.
    static let draggedTypes: [UTType] = [.image, .fileURL]

    /// True when this provider carries something we can classify. Cheap — never
    /// touches the file, so it is safe to call from the synchronous body of
    /// `.onDrop(perform:)`, which has to answer "did you take it?" immediately.
    static func carriesAttachment(_ provider: NSItemProvider) -> Bool {
        provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier)
            || provider.hasItemConformingToTypeIdentifier(UTType.image.identifier)
    }

    /// Resolve one provider into a payload. File URLs are only *named* here —
    /// the bytes are read, classified and decoded off the main actor by
    /// `AiStore.attachFiles(at:)`, so a 60 MB TIFF or an iCloud Drive file never
    /// stalls the drop. The file branch is checked first because a drag out of
    /// Files advertises both identifiers for an image file, and the URL form is
    /// the one carrying the filename the decline notices name.
    static func payload(for provider: NSItemProvider) async -> AttachmentDropPayload? {
        if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
            guard let url = await loadFileURL(provider) else { return nil }
            return .files([url])
        }
        if provider.hasItemConformingToTypeIdentifier(UTType.image.identifier) {
            let name = provider.suggestedName ?? "Dropped image"
            guard let data = await loadImageData(provider) else { return nil }
            return .imageData(data, name: name)
        }
        return nil
    }

    /// Classify a whole gesture at once and coalesce every file payload into a
    /// single `.files` case.
    ///
    /// This batching is the point of the function, not an optimisation: a drop
    /// of three PDFs and one PNG must attach the PNG and produce exactly ONE
    /// notice naming the three, not three notices stacked on each other. macOS
    /// gets that for free because `NSPasteboard.readObjects` returns all the
    /// URLs in one payload; on iOS the providers arrive one per item, so the
    /// coalescing has to be explicit.
    ///
    /// Raw-bytes payloads stay separate — each carries its own suggested name
    /// and none of them can be declined, so there is no notice to merge.
    static func payloads(for providers: [NSItemProvider]) async -> [AttachmentDropPayload] {
        var urls: [URL] = []
        var imageData: [AttachmentDropPayload] = []
        for provider in providers {
            switch await payload(for: provider) {
            case let .files(dropped): urls.append(contentsOf: dropped)
            case let .imageData(data, name): imageData.append(.imageData(data, name: name))
            case nil: continue
            }
        }
        return (urls.isEmpty ? [] : [.files(urls)]) + imageData
    }

    // MARK: - Continuation wrappers

    /// `NSItemProvider`'s async overloads hand back non-`Sendable` values, so
    /// both loads go through the completion-handler form and convert to a
    /// `Sendable` result inside the callback — matching the shape the panel used
    /// before this file existed. Errors collapse to nil: a drag whose promise
    /// fails is indistinguishable, to us, from one that carried nothing.
    /// `loadObject(ofClass: URL.self)` is preferred over `loadItem` because it
    /// lets the system decode its own `public.file-url` representation (see
    /// `fileURL(fromDropData:)`) instead of us guessing at the bytes. `loadItem`
    /// remains the fallback for providers that registered a shape `URL` cannot
    /// be read from.
    private static func loadFileURL(_ provider: NSItemProvider) async -> URL? {
        if provider.canLoadObject(ofClass: URL.self) {
            let url: URL? = await withCheckedContinuation { continuation in
                _ = provider.loadObject(ofClass: URL.self) { url, _ in
                    continuation.resume(returning: url)
                }
            }
            if let url { return url }
        }
        return await withCheckedContinuation { continuation in
            provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier) { item, _ in
                continuation.resume(returning: fileURL(fromDropItem: item))
            }
        }
    }

    private static func loadImageData(_ provider: NSItemProvider) async -> Data? {
        await withCheckedContinuation { continuation in
            provider.loadDataRepresentation(
                forTypeIdentifier: UTType.image.identifier
            ) { data, _ in
                continuation.resume(returning: data)
            }
        }
    }
}
