import Foundation
import VellumCore

public struct ScratchpadStorage: Sendable {
    public typealias Replace = @Sendable (URL, Data, Data?) async throws -> Bool

    public struct Note: Sendable {
        public let text: String
        public let baseline: Data?
        public let images: [Image]
        public let unavailableImages: Int

    }

    public struct Image: Sendable {
        public let name: String
        public let data: Data

        public var format: String {
            switch (name as NSString).pathExtension.lowercased() {
            case "jpg": "jpeg"
            case "tif": "tiff"
            case let ext: ext
            }
        }

        public var id: String { ScratchpadStorage.id(name) }

        public var markdown: String { "![Image](attachments/\(name))" }
    }

    public enum Failure: LocalizedError {
        case invalidNote, oversizedNote, unsupportedImage, changedOnDisk, unavailableImage

        public var errorDescription: String? {
            switch self {
            case .invalidNote: "The scratchpad is not valid UTF-8 text."
            case .oversizedNote: "The scratchpad exceeds the 200,000-character limit."
            case .unsupportedImage: "Choose a supported image inside the library folder."
            case .changedOnDisk: "The saved note changed on disk. Your draft is still here."
            case .unavailableImage: "The image could not be saved intact. Your draft is still here."
            }
        }
    }

    public var canEdit: Bool { replace != nil }
    public let importDirectory: URL?
    private let files: ReadOnlyLibraryFileStore
    private let replace: Replace?
    private static let noteBytes = 4 * 1024 * 1024
    private static let imageBytes = 12 * 1024 * 1024
    private static let formats: Set<String> = ["png", "jpg", "jpeg", "gif", "webp", "tif", "tiff", "heic"]

    public init(files: ReadOnlyLibraryFileStore, importDirectory: URL? = nil, replace: Replace? = nil) {
        self.files = files
        self.importDirectory = importDirectory
        self.replace = replace
    }

    private func directory(_ key: String) throws -> URL {
        guard DocumentIdentity.isCanonicalKey(key) else { throw Failure.invalidNote }
        return files.root.url.appendingPathComponent(".vellum/documents", isDirectory: true)
            .appendingPathComponent(key, isDirectory: true)
    }

    @concurrent
    public func load(_ key: String) async throws -> Note {
        let directory = try directory(key)
        let baseline = try await files.root.readRegularFile(
            directory.appendingPathComponent("scratchpad.md"), byteLimit: Self.noteBytes)
        guard let text = String(data: baseline ?? Data(), encoding: .utf8), !text.utf8.contains(0) else {
            throw Failure.invalidNote
        }

        let references = Self.references(in: text)
        guard !references.isEmpty else {
            return Note(text: text, baseline: baseline, images: [], unavailableImages: 0)
        }
        let attachments = directory.appendingPathComponent("attachments", isDirectory: true)
        let entries = ((try? await files.list(attachments, suffix: nil)) ?? [])
            .filter { !$0.url.hasDirectoryPath && Self.attachmentName($0.name) != nil }
        let byID = Dictionary(grouping: entries, by: { Self.id($0.name) })
        var images: [Image] = []
        var unavailable = 0
        var remaining = 2 * Self.imageBytes
        var seen = Set<String>()
        for reference in references {
            try Task.checkCancellation()
            guard seen.insert(reference.id).inserted else { continue }
            let candidates = byID[reference.id] ?? []
            guard candidates.count == 1, let entry = candidates.first,
                  reference.name == nil || reference.name?.lowercased() == entry.name.lowercased(),
                  images.count < 16, remaining > 0,
                  let data = try? await files.root.readRegularFile(
                    entry.url, byteLimit: min(remaining, Self.imageBytes))
            else {
                unavailable += 1
                continue
            }
            remaining -= data.count
            images.append(Image(name: entry.name, data: data))
        }
        try Task.checkCancellation()
        return Note(text: text, baseline: baseline, images: images, unavailableImages: unavailable)
    }

    @concurrent
    public func prepareImage(_ url: URL) async throws -> Image {
        let ext = url.pathExtension.lowercased()
        guard canEdit, let importDirectory, Self.formats.contains(ext),
              url.pathComponents.starts(with: importDirectory.pathComponents),
              let data = try await files.root.readRegularFile(url, byteLimit: Self.imageBytes)
        else { throw Failure.unsupportedImage }
        let id = UUID().uuidString.lowercased()
        return Image(name: "\(id).\(ext)", data: data)
    }

    @concurrent
    public func save(_ key: String, text: String, baseline: Data?, staged: [Image]) async throws -> Data {
        guard let replace else { throw ReaderFileError.readOnly }
        guard !text.utf8.contains(0) else { throw Failure.invalidNote }
        guard text.count <= 200_000, text.utf8.count <= Self.noteBytes else { throw Failure.oversizedNote }

        let directory = try directory(key)
        let note = directory.appendingPathComponent("scratchpad.md")
        guard try await files.root.readRegularFile(note, byteLimit: Self.noteBytes) == baseline else {
            throw Failure.changedOnDisk
        }

        // Each new image gets a fresh Apple-compatible ID. A retry reuses the
        // same bytes and ID after a partial publication. No existing image is
        // overwritten or removed, including images an offline peer may need.
        for image in staged {
            try Task.checkCancellation()
            let path = directory.appendingPathComponent("attachments", isDirectory: true)
                .appendingPathComponent(image.name)
            let current = try await files.root.readRegularFile(path, byteLimit: Self.imageBytes)
            if current == nil {
                _ = try await replace(path, image.data, nil)
            }
            guard try await files.root.readRegularFile(path, byteLimit: Self.imageBytes) == image.data else {
                throw Failure.unavailableImage
            }
        }

        try Task.checkCancellation()
        let data = Data(text.utf8)
        // An empty edit publishes empty Markdown. It never deletes the note or
        // its images, and is subject to the same conditional replace.
        guard try await replace(note, data, baseline) else { throw Failure.changedOnDisk }
        return data
    }

    @concurrent
    public static func referencedImageIDs(in text: String) async -> Set<String> {
        Set(references(in: text).map(\.id))
    }

    private struct Reference {
        let id: String
        let name: String?
    }

    // The editor keeps Apple’s persisted relative URLs as written. Only
    // Markdown image destinations may request bytes. There is no URL loader,
    // HTML renderer, shell, or fallback to another document's attachments.
    private static let imageLink = try! NSRegularExpression(
        pattern: #"(?<!`)(`++)[^`\r\n]*+\1(?!`)|(?<!\\)!\[[^\]\r\n]*\]\([ \t]*<?attachments/([A-Fa-f0-9-]{8,64}(?:\.[A-Za-z0-9]+)?)(?=[> \t)])"#)

    private static func references(in text: String) -> [Reference] {
        var references: [Reference] = []
        var fence: (Character, Int)?
        for line in text.split(whereSeparator: \.isNewline) {
            let content = line.trimmingCharacters(in: .whitespaces)
            if let (marker, length) = fence {
                let run = content.prefix { $0 == marker }
                if run.count >= length && run.count == content.count { fence = nil }
                continue
            }
            if let marker = content.first, marker == "`" || marker == "~" {
                let run = content.prefix { $0 == marker }.count
                if run >= 3 { fence = (marker, run); continue }
            }
            let source = String(line)
            let range = NSRange(source.startIndex..<source.endIndex, in: source)
            for match in imageLink.matches(in: source, range: range) {
                guard let destination = Range(match.range(at: 2), in: source) else { continue }
                let name = String(source[destination])
                if DocumentIdentity.isCanonicalKey(name.lowercased()) {
                    references.append(Reference(id: name.lowercased(), name: nil))
                } else if let id = attachmentName(name) {
                    references.append(Reference(id: id, name: name))
                }
            }
        }
        return references
    }

    private static func id(_ name: String) -> String {
        (name as NSString).deletingPathExtension.lowercased()
    }

    private static func attachmentName(_ name: String) -> String? {
        let id = id(name)
        guard DocumentIdentity.isCanonicalKey(id),
              formats.contains((name as NSString).pathExtension.lowercased()) else { return nil }
        return id
    }
}
