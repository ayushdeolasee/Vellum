import Darwin
import Foundation

struct ScratchpadMarkdownExportOptions: Equatable, Sendable {
    var copyLinkedImages: Bool
    var includeFrontMatter: Bool
    var title: String
}

struct ScratchpadMarkdownExportSummary: Equatable, Sendable {
    var markdownURL: URL
    var copiedImageCount: Int
    var assetsDirectoryURL: URL?
}

enum ScratchpadMarkdownExportError: LocalizedError {
    case destinationAlreadyExists(URL)
    case assetsDirectoryAlreadyExists(URL)
    case attachmentUnavailable(String)
    case unsafeSourceAttachment(URL)
    case unsafeAssetsDirectory(URL)
    case assetNameCollision(String)
    case rollbackFailed

    var errorDescription: String? {
        switch self {
        case let .destinationAlreadyExists(url):
            "The destination already exists: \(url.lastPathComponent)."
        case let .assetsDirectoryAlreadyExists(url):
            "The adjacent assets folder already exists: \(url.lastPathComponent)."
        case let .attachmentUnavailable(id):
            "The linked image \(id) is unavailable."
        case let .unsafeSourceAttachment(url):
            "The linked image is outside the attachments folder or is a symbolic link: \(url.lastPathComponent)."
        case let .unsafeAssetsDirectory(url):
            "The adjacent assets folder is a symbolic link: \(url.lastPathComponent)."
        case let .assetNameCollision(name):
            "Multiple linked images would overwrite \(name)."
        case .rollbackFailed:
            "The export could not be completed and its copied assets could not be removed."
        }
    }
}

enum ScratchpadMarkdownExporter {
    private struct ImageReference {
        var destinationRange: Range<String.Index>
        var id: String
    }

    private struct PlannedAsset {
        var sourceURL: URL
        var filename: String
    }

    private struct CodeFence {
        var character: Character
        var length: Int
        var quoteDepth: Int
    }

    private struct LeadingFrontMatter {
        var headerRange: Range<String.Index>
        var closingRange: Range<String.Index>
    }

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
        while itemExists(at: candidate, fileManager: fileManager)
            || itemExists(
                at: assetsURL(for: candidate),
                fileManager: fileManager
            ) {
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
        let destinationParent = try canonicalDirectory(
            markdownURL.deletingLastPathComponent(), fileManager: fileManager)
        let destinationURL = destinationParent.appendingPathComponent(
            markdownURL.lastPathComponent)
        guard itemDoesNotExist(at: destinationURL, fileManager: fileManager) else {
            throw ScratchpadMarkdownExportError.destinationAlreadyExists(destinationURL)
        }

        let references = options.copyLinkedImages ? imageReferences(in: markdown) : []
        let assetDirectoryName =
            "\(destinationURL.deletingPathExtension().lastPathComponent) Assets"
        let assetsURL = destinationParent.appendingPathComponent(
            assetDirectoryName, isDirectory: true)
        guard contains(assetsURL, within: destinationParent) else {
            throw ScratchpadMarkdownExportError.unsafeAssetsDirectory(assetsURL)
        }
        if !references.isEmpty, itemDoesNotExist(at: assetsURL, fileManager: fileManager) == false {
            if isSymbolicLink(at: assetsURL, fileManager: fileManager) {
                throw ScratchpadMarkdownExportError.unsafeAssetsDirectory(assetsURL)
            }
            throw ScratchpadMarkdownExportError.assetsDirectoryAlreadyExists(assetsURL)
        }

        let plannedAssets = try plannedAssets(
            for: references,
            attachmentsDirectory: attachmentsDirectory,
            fileManager: fileManager
        )
        let assetCopies = uniqueAssets(from: plannedAssets)
        var exportedMarkdown = replacingImageDestinations(
            in: markdown,
            references: references,
            assetDirectoryName: assetDirectoryName,
            plannedAssets: plannedAssets
        )
        if options.includeFrontMatter {
            exportedMarkdown = addingFrontMatter(to: exportedMarkdown, title: options.title)
        }

        let stagingURL = destinationParent.appendingPathComponent(
            ".vellum-scratchpad-export-\(UUID().uuidString)", isDirectory: true)
        defer { try? fileManager.removeItem(at: stagingURL) }
        try fileManager.createDirectory(
            at: stagingURL,
            withIntermediateDirectories: false
        )

        let stagedMarkdownURL = stagingURL.appendingPathComponent(destinationURL.lastPathComponent)
        try Data(exportedMarkdown.utf8).write(to: stagedMarkdownURL, options: .atomic)
        let stagedAssetsURL = stagingURL.appendingPathComponent(
            assetDirectoryName, isDirectory: true)
        let exportOwner = UUID().uuidString
        if !assetCopies.isEmpty {
            try fileManager.createDirectory(
                at: stagedAssetsURL,
                withIntermediateDirectories: false
            )
            guard let ownerData = exportOwner.data(using: .utf8) else {
                throw CocoaError(.fileWriteUnknown)
            }
            try ownerData.write(
                to: ownerMarkerURL(in: stagedAssetsURL),
                options: .atomic
            )
            for asset in assetCopies.values {
                // Revalidate at the point of use. This cannot prevent an
                // attachment from changing contents during a normal file copy,
                // but it rejects a path replaced by a link before copying it.
                guard sourceIsSafe(
                    asset.sourceURL,
                    attachmentsDirectory: attachmentsDirectory,
                    fileManager: fileManager
                ) else {
                    throw ScratchpadMarkdownExportError.unsafeSourceAttachment(asset.sourceURL)
                }
                try fileManager.copyItem(
                    at: asset.sourceURL,
                    to: stagedAssetsURL.appendingPathComponent(asset.filename)
                )
            }
        }

        // Re-check immediately before publishing. The save panel's conflict
        // prompt cannot protect against another process creating either output
        // while the assets are being staged.
        guard itemDoesNotExist(at: destinationURL, fileManager: fileManager) else {
            throw ScratchpadMarkdownExportError.destinationAlreadyExists(destinationURL)
        }
        if !assetCopies.isEmpty,
           itemDoesNotExist(at: assetsURL, fileManager: fileManager) == false {
            if isSymbolicLink(at: assetsURL, fileManager: fileManager) {
                throw ScratchpadMarkdownExportError.unsafeAssetsDirectory(assetsURL)
            }
            throw ScratchpadMarkdownExportError.assetsDirectoryAlreadyExists(assetsURL)
        }

        var publishedAssets = false
        do {
            if !assetCopies.isEmpty {
                try publishExclusively(
                    stagedAssetsURL,
                    to: assetsURL,
                    conflict: .assetsDirectoryAlreadyExists(assetsURL)
                )
                publishedAssets = true
            }
            try publishExclusively(
                stagedMarkdownURL,
                to: destinationURL,
                conflict: .destinationAlreadyExists(destinationURL)
            )
            if publishedAssets {
                // The marker exists only while this transaction might need a
                // rollback. A failure to remove it must not turn a completed
                // export into a failed one.
                try? fileManager.removeItem(at: ownerMarkerURL(in: assetsURL))
            }
        } catch {
            if publishedAssets {
                if removeOwnedAssets(
                    at: assetsURL,
                    exportOwner: exportOwner,
                    fileManager: fileManager
                ) == false {
                    throw ScratchpadMarkdownExportError.rollbackFailed
                }
            }
            throw error
        }

        return ScratchpadMarkdownExportSummary(
            markdownURL: destinationURL,
            copiedImageCount: assetCopies.count,
            assetsDirectoryURL: assetCopies.isEmpty ? nil : assetsURL
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

    private static func plannedAssets(
        for references: [ImageReference],
        attachmentsDirectory: URL?,
        fileManager: FileManager
    ) throws -> [String: PlannedAsset] {
        var planned = [String: PlannedAsset]()
        var filenames = [String: URL]()
        for reference in references {
            guard let sourceURL = ScratchpadAttachmentStore.fileURL(
                for: reference.id,
                preferredDir: attachmentsDirectory
            ) else {
                throw ScratchpadMarkdownExportError.attachmentUnavailable(reference.id)
            }
            guard sourceIsSafe(
                sourceURL,
                attachmentsDirectory: attachmentsDirectory,
                fileManager: fileManager
            ) else {
                throw ScratchpadMarkdownExportError.unsafeSourceAttachment(sourceURL)
            }

            let filename = sourceURL.lastPathComponent
            if let existing = filenames[filename], existing != sourceURL {
                throw ScratchpadMarkdownExportError.assetNameCollision(filename)
            }
            filenames[filename] = sourceURL
            planned[reference.id] = PlannedAsset(sourceURL: sourceURL, filename: filename)
        }
        return planned
    }

    private static func replacingImageDestinations(
        in markdown: String,
        references: [ImageReference],
        assetDirectoryName: String,
        plannedAssets: [String: PlannedAsset]
    ) -> String {
        var result = markdown
        for reference in references.reversed() {
            guard let asset = plannedAssets[reference.id] else { continue }
            result.replaceSubrange(
                reference.destinationRange,
                with: "\(assetDirectoryName)/\(asset.filename)"
            )
        }
        return result
    }

    private static func uniqueAssets(
        from plannedAssets: [String: PlannedAsset]
    ) -> [String: PlannedAsset] {
        plannedAssets.values.reduce(into: [String: PlannedAsset]()) { result, asset in
            result[asset.filename] = asset
        }
    }

    private static func addingFrontMatter(to markdown: String, title: String) -> String {
        let title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { return markdown }
        let escapedTitle = title
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: " ")
        let titleLine = "title: \"\(escapedTitle)\""

        guard let frontMatter = leadingFrontMatter(in: markdown) else {
            return "---\n\(titleLine)\n---\n\n\(markdown)"
        }

        var headerLines = String(markdown[frontMatter.headerRange])
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map(String.init)
        if let existingTitle = headerLines.firstIndex(where: { $0.hasPrefix("title:") }) {
            headerLines[existingTitle] = titleLine
        } else {
            headerLines.append(titleLine)
        }
        var updatedHeader = headerLines.joined(separator: "\n")
        if updatedHeader.isEmpty == false, updatedHeader.hasSuffix("\n") == false {
            updatedHeader.append("\n")
        }
        return "---\n\(updatedHeader)\(markdown[frontMatter.closingRange.lowerBound...])"
    }

    private static func leadingFrontMatter(in markdown: String) -> LeadingFrontMatter? {
        guard let openerEnd = markdown.firstIndex(of: "\n"),
              markdown[..<openerEnd] == "---"
        else {
            return nil
        }
        let headerStart = markdown.index(after: openerEnd)
        var lineStart = headerStart
        while lineStart <= markdown.endIndex {
            let lineEnd = markdown[lineStart...].firstIndex(of: "\n") ?? markdown.endIndex
            let line = markdown[lineStart..<lineEnd]
            if line == "---" || line == "..." {
                return LeadingFrontMatter(
                    headerRange: headerStart..<lineStart,
                    closingRange: lineStart..<lineEnd
                )
            }
            guard lineEnd < markdown.endIndex else { break }
            lineStart = markdown.index(after: lineEnd)
        }
        return nil
    }

    private static func canonicalDirectory(
        _ directory: URL,
        fileManager: FileManager
    ) throws -> URL {
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: directory.path, isDirectory: &isDirectory),
              isDirectory.boolValue
        else {
            throw CocoaError(.fileNoSuchFile)
        }
        return directory.standardizedFileURL.resolvingSymlinksInPath()
    }

    private static func assetsURL(for markdownURL: URL) -> URL {
        markdownURL.deletingLastPathComponent().appendingPathComponent(
            "\(markdownURL.deletingPathExtension().lastPathComponent) Assets",
            isDirectory: true
        )
    }

    private static func ownerMarkerURL(in assetsURL: URL) -> URL {
        assetsURL.appendingPathComponent(".vellum-scratchpad-export-owner")
    }

    private static func publishExclusively(
        _ stagedURL: URL,
        to destinationURL: URL,
        conflict: ScratchpadMarkdownExportError
    ) throws {
        let result = stagedURL.path.withCString { sourcePath in
            destinationURL.path.withCString { destinationPath in
                renameatx_np(
                    AT_FDCWD,
                    sourcePath,
                    AT_FDCWD,
                    destinationPath,
                    UInt32(RENAME_EXCL)
                )
            }
        }
        guard result == 0 else {
            if errno == EEXIST { throw conflict }
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
    }

    /// The marker is created in the unique staging directory, then moved into
    /// place atomically with the assets. Never delete an adjacent folder unless
    /// it still carries this transaction's marker.
    private static func removeOwnedAssets(
        at assetsURL: URL,
        exportOwner: String,
        fileManager: FileManager
    ) -> Bool {
        guard itemExists(at: assetsURL, fileManager: fileManager) else { return true }
        let markerURL = ownerMarkerURL(in: assetsURL)
        guard let marker = try? String(contentsOf: markerURL, encoding: .utf8),
              marker == exportOwner
        else {
            return false
        }
        do {
            try fileManager.removeItem(at: assetsURL)
            return true
        } catch {
            return false
        }
    }

    private static func sourceIsSafe(
        _ sourceURL: URL,
        attachmentsDirectory: URL?,
        fileManager: FileManager
    ) -> Bool {
        guard isSymbolicLink(at: sourceURL, fileManager: fileManager) == false else {
            return false
        }
        let roots = [attachmentsDirectory, ScratchpadAttachmentStore.activeDirectory,
                     ScratchpadAttachmentStore.directory].compactMap { $0 }
        return roots.contains { root in
            contains(sourceURL, within: root)
        }
    }

    private static func contains(_ url: URL, within root: URL) -> Bool {
        let resolvedURL = url.standardizedFileURL.resolvingSymlinksInPath().path
        let resolvedRoot = root.standardizedFileURL.resolvingSymlinksInPath().path
        return resolvedURL == resolvedRoot || resolvedURL.hasPrefix(resolvedRoot + "/")
    }

    private static func itemDoesNotExist(at url: URL, fileManager: FileManager) -> Bool {
        itemExists(at: url, fileManager: fileManager) == false
    }

    private static func itemExists(at url: URL, fileManager: FileManager) -> Bool {
        fileManager.fileExists(atPath: url.path)
            || (try? fileManager.destinationOfSymbolicLink(atPath: url.path)) != nil
    }

    private static func isSymbolicLink(at url: URL, fileManager: FileManager) -> Bool {
        (try? fileManager.destinationOfSymbolicLink(atPath: url.path)) != nil
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

    /// Only Markdown image destinations are eligible for rewriting. This keeps
    /// prose, code spans/fences, and ordinary links byte-for-byte intact.
    private static func imageReferences(in markdown: String) -> [ImageReference] {
        var references = [ImageReference]()
        var index = markdown.startIndex
        var openFence: CodeFence?

        while index < markdown.endIndex {
            let lineEnd = markdown[index...].firstIndex(of: "\n") ?? markdown.endIndex
            let line = markdown[index..<lineEnd]
            if let openFence {
                if isClosingFence(line, for: openFence) {
                    openFence = nil
                }
            } else if let fence = openingFence(in: line) {
                openFence = fence
            } else {
                references.append(contentsOf: imageReferences(inLine: markdown, range: index..<lineEnd))
            }
            index = lineEnd < markdown.endIndex
                ? markdown.index(after: lineEnd)
                : markdown.endIndex
        }
        return references
    }

    private static func openingFence(in line: Substring) -> CodeFence? {
        let (content, quoteDepth) = fenceContent(in: line)
        guard let character = content.first, character == "`" || character == "~" else {
            return nil
        }
        let length = content.prefix(while: { $0 == character }).count
        guard length >= 3 else { return nil }
        return CodeFence(character: character, length: length, quoteDepth: quoteDepth)
    }

    private static func isClosingFence(_ line: Substring, for fence: CodeFence) -> Bool {
        let (content, quoteDepth) = fenceContent(in: line)
        guard quoteDepth == fence.quoteDepth,
              content.first == fence.character
        else {
            return false
        }
        let fenceLength = content.prefix(while: { $0 == fence.character }).count
        guard fenceLength >= fence.length else { return false }
        return content.dropFirst(fenceLength).allSatisfy { $0 == " " || $0 == "\t" }
    }

    /// Fenced code blocks can sit inside block quotes. Ignore up to three
    /// spaces around each quote marker, while requiring the same quote depth
    /// for a closing fence.
    private static func fenceContent(in line: Substring) -> (Substring, Int) {
        var content = line
        content = content.drop(while: { $0 == " " || $0 == "\t" })
        var quoteDepth = 0
        while content.first == ">" {
            quoteDepth += 1
            content = content.dropFirst()
            if content.first == " " || content.first == "\t" {
                content = content.dropFirst()
            }
            content = content.drop(while: { $0 == " " || $0 == "\t" })
        }
        return (content, quoteDepth)
    }

    private static func imageReferences(
        inLine markdown: String,
        range: Range<String.Index>
    ) -> [ImageReference] {
        var references = [ImageReference]()
        var index = range.lowerBound
        while index < range.upperBound {
            if markdown[index] == "`" {
                let tickCount = markdown[index...].prefix(while: { $0 == "`" }).count
                let afterTicks = markdown.index(index, offsetBy: tickCount)
                if let closing = closingBackticks(
                    in: markdown,
                    from: afterTicks,
                    to: range.upperBound,
                    count: tickCount
                ) {
                    index = markdown.index(closing, offsetBy: tickCount)
                    continue
                }
                // An unmatched delimiter is literal Markdown, not the start
                // of a code span that hides the remainder of the line.
                index = afterTicks
                continue
            }
            if markdown[index] == "!", isEscaped(markdown, at: index) == false,
               let reference = imageReference(in: markdown, startingAt: index, limit: range.upperBound) {
                references.append(reference.reference)
                index = reference.nextIndex
                continue
            }
            index = markdown.index(after: index)
        }
        return references
    }

    private static func imageReference(
        in markdown: String,
        startingAt start: String.Index,
        limit: String.Index
    ) -> (reference: ImageReference, nextIndex: String.Index)? {
        let openBracket = markdown.index(after: start)
        guard openBracket < limit, markdown[openBracket] == "[",
              let closeBracket = closingBracket(in: markdown, from: openBracket, limit: limit)
        else { return nil }
        let openParen = markdown.index(after: closeBracket)
        guard openParen < limit, markdown[openParen] == "(" else { return nil }
        let destinationStart = markdown.index(after: openParen)
        guard let destination = markdownDestination(
            in: markdown, from: destinationStart, limit: limit
        ) else { return nil }
        let url = String(markdown[destination.range])
        guard let id = attachmentID(from: url) else { return nil }
        return (ImageReference(destinationRange: destination.range, id: id), destination.nextIndex)
    }

    private static func closingBracket(
        in markdown: String,
        from openBracket: String.Index,
        limit: String.Index
    ) -> String.Index? {
        var index = markdown.index(after: openBracket)
        var depth = 1
        while index < limit {
            if isEscaped(markdown, at: index) == false {
                if markdown[index] == "[" {
                    depth += 1
                } else if markdown[index] == "]" {
                    depth -= 1
                    if depth == 0 { return index }
                }
            }
            index = markdown.index(after: index)
        }
        return nil
    }

    private static func markdownDestination(
        in markdown: String,
        from start: String.Index,
        limit: String.Index
    ) -> (range: Range<String.Index>, nextIndex: String.Index)? {
        guard start < limit else { return nil }
        if markdown[start] == "<" {
            guard let close = markdown[markdown.index(after: start)..<limit].firstIndex(of: ">") else {
                return nil
            }
            let afterClose = markdown.index(after: close)
            guard afterClose < limit, markdown[afterClose] == ")" else { return nil }
            return (markdown.index(after: start)..<close, markdown.index(after: afterClose))
        }

        var index = start
        var depth = 0
        while index < limit {
            let character = markdown[index]
            if character == "\\", isEscaped(markdown, at: index) == false {
                index = markdown.index(after: index)
                if index < limit { index = markdown.index(after: index) }
                continue
            }
            if character == "(" { depth += 1 }
            if character == ")" {
                if depth == 0 {
                    return (start..<index, markdown.index(after: index))
                }
                depth -= 1
            }
            if character == " " || character == "\t" {
                return destinationWithTitle(
                    in: markdown,
                    destinationRange: start..<index,
                    from: index,
                    limit: limit
                )
            }
            index = markdown.index(after: index)
        }
        return nil
    }

    private static func destinationWithTitle(
        in markdown: String,
        destinationRange: Range<String.Index>,
        from start: String.Index,
        limit: String.Index
    ) -> (range: Range<String.Index>, nextIndex: String.Index)? {
        var index = start
        while index < limit, markdown[index] == " " || markdown[index] == "\t" {
            index = markdown.index(after: index)
        }
        guard index < limit else { return nil }
        if markdown[index] == ")" {
            return (destinationRange, markdown.index(after: index))
        }
        guard markdown[index] == "\"" || markdown[index] == "'" else { return nil }
        let quote = markdown[index]
        index = markdown.index(after: index)
        while index < limit {
            if markdown[index] == quote, isEscaped(markdown, at: index) == false {
                index = markdown.index(after: index)
                while index < limit, markdown[index] == " " || markdown[index] == "\t" {
                    index = markdown.index(after: index)
                }
                guard index < limit, markdown[index] == ")" else { return nil }
                return (destinationRange, markdown.index(after: index))
            }
            index = markdown.index(after: index)
        }
        return nil
    }

    private static func attachmentID(from url: String) -> String? {
        let prefix = "\(ScratchpadAttachmentStore.scheme)://"
        guard url.hasPrefix(prefix) else { return nil }
        let id = String(url.dropFirst(prefix.count))
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "._-"))
        guard let first = id.unicodeScalars.first,
              CharacterSet.alphanumerics.contains(first),
              id.unicodeScalars.allSatisfy(allowed.contains)
        else { return nil }
        return id
    }

    private static func closingBackticks(
        in markdown: String,
        from start: String.Index,
        to limit: String.Index,
        count: Int
    ) -> String.Index? {
        var index = start
        while index < limit {
            if markdown[index] == "`",
               markdown[index...].prefix(while: { $0 == "`" }).count == count {
                return index
            }
            index = markdown.index(after: index)
        }
        return nil
    }

    private static func isEscaped(_ markdown: String, at index: String.Index) -> Bool {
        var cursor = index
        var slashCount = 0
        while cursor > markdown.startIndex {
            let previous = markdown.index(before: cursor)
            guard markdown[previous] == "\\" else { break }
            slashCount += 1
            cursor = previous
        }
        return slashCount.isMultiple(of: 2) == false
    }
}
