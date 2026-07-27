import Foundation

struct ScratchpadMarkdownExportOptions: Equatable, Sendable {
    var copyLinkedImages: Bool
    var includeFrontMatter: Bool
    var title: String
}

struct ScratchpadMarkdownExportSummary: Equatable, Sendable {
    var markdownURL: URL
    var copiedImageCount: Int
    var skippedImageCount: Int
    var assetsDirectoryURL: URL?
}

enum ScratchpadMarkdownExporter {
    private static let imageReferencePattern =
        #"vellum-scratchpad://([A-Za-z0-9][A-Za-z0-9._-]*)"#

    static func suggestedFilename(title: String, in directory: URL) -> String {
        let base = sanitizedFilenameComponent(title).isEmpty
            ? "Scratchpad"
            : "\(sanitizedFilenameComponent(title)) Notes"
        return conflictSafeURL(
            in: directory,
            baseName: base,
            pathExtension: "md"
        ).lastPathComponent
    }

    static func conflictSafeURL(
        in directory: URL,
        baseName: String,
        pathExtension: String,
        fileManager: FileManager = .default
    ) -> URL {
        let safeBase = sanitizedFilenameComponent(baseName).isEmpty
            ? "Scratchpad"
            : sanitizedFilenameComponent(baseName)
        var candidate = directory
            .appendingPathComponent(safeBase)
            .appendingPathExtension(pathExtension)
        var suffix = 2
        while fileManager.fileExists(atPath: candidate.path) {
            candidate = directory
                .appendingPathComponent("\(safeBase) \(suffix)")
                .appendingPathExtension(pathExtension)
            suffix += 1
        }
        return candidate
    }

    static func export(
        markdown: String,
        to markdownURL: URL,
        options: ScratchpadMarkdownExportOptions,
        attachmentsDirectory: URL?,
        fileManager: FileManager = .default
    ) throws -> ScratchpadMarkdownExportSummary {
        var exportedMarkdown = markdown
        var copiedCount = 0
        var skippedCount = 0
        var assetsDirectoryURL: URL?

        if options.copyLinkedImages {
            let assetDirectoryName =
                "\(markdownURL.deletingPathExtension().lastPathComponent) Assets"
            let destinationDirectory = markdownURL
                .deletingLastPathComponent()
                .appendingPathComponent(assetDirectoryName, isDirectory: true)
            let references = imageReferences(in: markdown)

            if !references.isEmpty {
                try fileManager.createDirectory(
                    at: destinationDirectory,
                    withIntermediateDirectories: true
                )
                assetsDirectoryURL = destinationDirectory
            }

            for reference in references {
                guard
                    let sourceURL = ScratchpadAttachmentStore.fileURL(
                        for: reference.id,
                        preferredDir: attachmentsDirectory
                    )
                else {
                    skippedCount += 1
                    continue
                }

                let destinationURL = destinationDirectory
                    .appendingPathComponent(sourceURL.lastPathComponent)
                do {
                    if fileManager.fileExists(atPath: destinationURL.path) {
                        let existing = try Data(contentsOf: destinationURL)
                        let source = try Data(contentsOf: sourceURL)
                        guard existing == source else {
                            skippedCount += 1
                            continue
                        }
                    } else {
                        try fileManager.copyItem(at: sourceURL, to: destinationURL)
                    }
                    let relativePath =
                        "\(assetDirectoryName)/\(sourceURL.lastPathComponent)"
                    exportedMarkdown = exportedMarkdown.replacingOccurrences(
                        of: reference.url,
                        with: relativePath
                    )
                    copiedCount += 1
                } catch {
                    skippedCount += 1
                }
            }
        }

        if options.includeFrontMatter {
            let title = options.title.trimmingCharacters(in: .whitespacesAndNewlines)
            if !title.isEmpty {
                let escapedTitle = title
                    .replacingOccurrences(of: "\\", with: "\\\\")
                    .replacingOccurrences(of: "\"", with: "\\\"")
                    .replacingOccurrences(of: "\n", with: " ")
                exportedMarkdown =
                    "---\ntitle: \"\(escapedTitle)\"\n---\n\n\(exportedMarkdown)"
            }
        }

        try Data(exportedMarkdown.utf8).write(to: markdownURL, options: .atomic)
        return ScratchpadMarkdownExportSummary(
            markdownURL: markdownURL,
            copiedImageCount: copiedCount,
            skippedImageCount: skippedCount,
            assetsDirectoryURL: assetsDirectoryURL
        )
    }

    static func storageExplanation(mode: WebStorageMode, degraded: Bool) -> String {
        if degraded {
            return "Scratchpad data is temporarily stored on this Mac because the selected storage location is unavailable. It will not sync until that location is restored."
        }
        switch mode {
        case .icloud:
            return "Scratchpad data lives in Vellum’s iCloud Drive storage and syncs through iCloud."
        case .custom:
            return "Scratchpad data stays in Application Support on this Mac. The custom folder contains offline webpages, not scratchpad notes."
        case .local:
            return "Scratchpad data stays in Application Support on this Mac and does not sync."
        }
    }

    private static func sanitizedFilenameComponent(_ value: String) -> String {
        let invalid = CharacterSet(charactersIn: "/:\\")
            .union(.controlCharacters)
        return value
            .components(separatedBy: invalid)
            .joined(separator: " ")
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
            .trimmingCharacters(in: CharacterSet(charactersIn: ". "))
    }

    private static func imageReferences(in markdown: String) -> [(url: String, id: String)] {
        guard let regex = try? NSRegularExpression(pattern: imageReferencePattern) else {
            return []
        }
        let range = NSRange(markdown.startIndex..., in: markdown)
        var seen = Set<String>()
        return regex.matches(in: markdown, range: range).compactMap { match in
            guard
                let urlRange = Range(match.range(at: 0), in: markdown),
                let idRange = Range(match.range(at: 1), in: markdown)
            else { return nil }
            let url = String(markdown[urlRange])
            guard seen.insert(url).inserted else { return nil }
            return (url, String(markdown[idRange]))
        }
    }
}
