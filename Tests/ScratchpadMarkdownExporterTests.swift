import XCTest
@testable import Vellum

final class ScratchpadMarkdownExporterTests: XCTestCase {
    private var temporaryDirectory: URL!

    override func setUpWithError() throws {
        temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: temporaryDirectory,
            withIntermediateDirectories: true
        )
        ScratchpadAttachmentStore.directoryOverride = nil
    }

    override func tearDownWithError() throws {
        ScratchpadAttachmentStore.directoryOverride = nil
        try? FileManager.default.removeItem(at: temporaryDirectory)
    }

    func testSuggestedFilenameIsSanitizedAndConflictSafe() throws {
        try Data().write(to: temporaryDirectory.appendingPathComponent("Paper Notes.md"))

        let filename = ScratchpadMarkdownExporter.suggestedFilename(
            title: "Paper:/",
            in: temporaryDirectory
        )

        XCTAssertEqual(filename, "Paper Notes 2.md")
    }

    func testSuggestedFilenameAvoidsCorrespondingAssetsDirectory() throws {
        let existingAssets = temporaryDirectory.appendingPathComponent(
            "Paper Notes Assets",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: existingAssets, withIntermediateDirectories: true)

        let filename = ScratchpadMarkdownExporter.suggestedFilename(
            title: "Paper",
            in: temporaryDirectory
        )

        XCTAssertEqual(filename, "Paper Notes 2.md")
    }

    func testExportAddsFrontMatterCopiesImagesAndRewritesLinks() throws {
        let sourceDirectory = try makeSourceDirectory()
        try writeImage(named: "capture.png", in: sourceDirectory)
        let destination = temporaryDirectory.appendingPathComponent("Research Notes.md")

        let summary = try ScratchpadMarkdownExporter.export(
            markdown: "# Thought\n\n![Diagram](vellum-scratchpad://capture)",
            to: destination,
            options: exportOptions(includeFrontMatter: true, title: "Research \"Notes\""),
            attachmentsDirectory: sourceDirectory
        )

        let exported = try String(contentsOf: destination, encoding: .utf8)
        XCTAssertTrue(exported.hasPrefix("---\ntitle: \"Research \\\"Notes\\\"\"\n---\n\n"))
        XCTAssertTrue(exported.contains(
            "![Diagram](Research Notes Assets/capture.png)"
        ))
        XCTAssertEqual(summary.copiedImageCount, 1)
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: temporaryDirectory
                .appendingPathComponent("Research Notes Assets/capture.png").path
        ))
    }

    func testExportRewritesOnlyMarkdownImageDestinations() throws {
        let sourceDirectory = try makeSourceDirectory()
        try writeImage(named: "capture.png", in: sourceDirectory)
        let destination = temporaryDirectory.appendingPathComponent("Notes.md")
        let markdown = """
        prose vellum-scratchpad://capture
        [Ordinary link](vellum-scratchpad://capture)
        `![Inline code](vellum-scratchpad://capture)`
        ```markdown
        ![Fenced](vellum-scratchpad://capture)
        ```
        ![First](vellum-scratchpad://capture)
        ![Repeated](vellum-scratchpad://capture)
        """

        let summary = try ScratchpadMarkdownExporter.export(
            markdown: markdown,
            to: destination,
            options: exportOptions(),
            attachmentsDirectory: sourceDirectory
        )

        let exported = try String(contentsOf: destination, encoding: .utf8)
        XCTAssertTrue(exported.contains("prose vellum-scratchpad://capture"))
        XCTAssertTrue(exported.contains("[Ordinary link](vellum-scratchpad://capture)"))
        XCTAssertTrue(exported.contains("`![Inline code](vellum-scratchpad://capture)`"))
        XCTAssertTrue(exported.contains("![Fenced](vellum-scratchpad://capture)"))
        XCTAssertEqual(
            exported.components(separatedBy: "Notes Assets/capture.png").count - 1,
            2
        )
        XCTAssertEqual(summary.copiedImageCount, 1)
    }

    func testExportParsesNestedAltTextAndContinuesAfterUnmatchedBackticks() throws {
        let sourceDirectory = try makeSourceDirectory()
        try writeImage(named: "capture.png", in: sourceDirectory)
        let destination = temporaryDirectory.appendingPathComponent("Notes.md")
        let markdown = "`unfinished inline code ![Outer [inner]](vellum-scratchpad://capture)"

        _ = try ScratchpadMarkdownExporter.export(
            markdown: markdown,
            to: destination,
            options: exportOptions(),
            attachmentsDirectory: sourceDirectory
        )

        let exported = try String(contentsOf: destination, encoding: .utf8)
        XCTAssertEqual(
            exported,
            "`unfinished inline code ![Outer [inner]](Notes Assets/capture.png)"
        )
    }

    func testExportTracksFenceCharacterLengthAndQuotedClosingFence() throws {
        let sourceDirectory = try makeSourceDirectory()
        try writeImage(named: "capture.png", in: sourceDirectory)
        let destination = temporaryDirectory.appendingPathComponent("Notes.md")
        let markdown = [
            "````markdown",
            "![Still fenced](vellum-scratchpad://capture)",
            "```",
            "![Also fenced](vellum-scratchpad://capture)",
            "````   ",
            "> ~~~markdown",
            "> ![Quoted fenced](vellum-scratchpad://capture)",
            "> ~~~   ",
            "![Exported](vellum-scratchpad://capture)"
        ].joined(separator: "\n")

        let summary = try ScratchpadMarkdownExporter.export(
            markdown: markdown,
            to: destination,
            options: exportOptions(),
            attachmentsDirectory: sourceDirectory
        )

        let exported = try String(contentsOf: destination, encoding: .utf8)
        XCTAssertTrue(exported.contains("![Still fenced](vellum-scratchpad://capture)"))
        XCTAssertTrue(exported.contains("![Also fenced](vellum-scratchpad://capture)"))
        XCTAssertTrue(exported.contains("![Quoted fenced](vellum-scratchpad://capture)"))
        XCTAssertTrue(exported.contains("![Exported](Notes Assets/capture.png)"))
        XCTAssertEqual(summary.copiedImageCount, 1)
    }

    func testExportTreatsFourSpaceIndentedFencesAsRegularMarkdown() throws {
        let sourceDirectory = try makeSourceDirectory()
        try writeImage(named: "capture.png", in: sourceDirectory)
        let destination = temporaryDirectory.appendingPathComponent("Notes.md")
        let markdown = [
            "   ```markdown",
            "![Three-space fence](vellum-scratchpad://capture)",
            "   ```",
            "    ```markdown",
            "![Four-space indentation](vellum-scratchpad://capture)",
            "    ```",
            ">    ```markdown",
            "> ![Quoted three-space fence](vellum-scratchpad://capture)",
            ">    ```",
            ">     ```markdown",
            "> ![Quoted four-space indentation](vellum-scratchpad://capture)",
            ">     ```"
        ].joined(separator: "\n")

        let summary = try ScratchpadMarkdownExporter.export(
            markdown: markdown,
            to: destination,
            options: exportOptions(),
            attachmentsDirectory: sourceDirectory
        )

        let exported = try String(contentsOf: destination, encoding: .utf8)
        XCTAssertTrue(exported.contains(
            "![Three-space fence](vellum-scratchpad://capture)"
        ))
        XCTAssertTrue(exported.contains(
            "![Quoted three-space fence](vellum-scratchpad://capture)"
        ))
        XCTAssertTrue(exported.contains(
            "![Four-space indentation](Notes Assets/capture.png)"
        ))
        XCTAssertTrue(exported.contains(
            "![Quoted four-space indentation](Notes Assets/capture.png)"
        ))
        XCTAssertEqual(summary.copiedImageCount, 1)
    }

    func testExportMergesLeadingYAMLFrontMatter() throws {
        let destination = temporaryDirectory.appendingPathComponent("Notes.md")
        let markdown = """
        ---
        tags:
          - research
        title: "Old title"
        ---
        Existing body.
        """

        _ = try ScratchpadMarkdownExporter.export(
            markdown: markdown,
            to: destination,
            options: exportOptions(includeFrontMatter: true, title: "New title"),
            attachmentsDirectory: nil
        )

        XCTAssertEqual(
            try String(contentsOf: destination, encoding: .utf8),
            """
            ---
            tags:
              - research
            title: "New title"
            ---
            Existing body.
            """
        )
    }

    func testExportRejectsDirectoryAttachmentBeforeStagingIt() throws {
        let sourceDirectory = try makeSourceDirectory()
        try FileManager.default.createDirectory(
            at: sourceDirectory.appendingPathComponent("capture.png", isDirectory: true),
            withIntermediateDirectories: false
        )
        let destination = temporaryDirectory.appendingPathComponent("Notes.md")

        XCTAssertThrowsError(
            try ScratchpadMarkdownExporter.export(
                markdown: "![Image](vellum-scratchpad://capture)",
                to: destination,
                options: exportOptions(),
                attachmentsDirectory: sourceDirectory
            )
        ) { error in
            guard let exportError = error as? ScratchpadMarkdownExportError,
                  case .unsafeSourceAttachment(_) = exportError else {
                return XCTFail("Expected unsafe source error, got \(error)")
            }
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
    }

    func testExportRollsBackWhenAnyReferencedImageIsUnavailable() throws {
        let sourceDirectory = try makeSourceDirectory()
        try writeImage(named: "present.png", in: sourceDirectory)
        let destination = temporaryDirectory.appendingPathComponent("Notes.md")

        XCTAssertThrowsError(
            try ScratchpadMarkdownExporter.export(
                markdown: "![Present](vellum-scratchpad://present) ![Missing](vellum-scratchpad://missing)",
                to: destination,
                options: exportOptions(),
                attachmentsDirectory: sourceDirectory
            )
        ) { error in
            guard let exportError = error as? ScratchpadMarkdownExportError,
                  case .attachmentUnavailable("missing") = exportError else {
                return XCTFail("Expected unavailable attachment error, got \(error)")
            }
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: temporaryDirectory.appendingPathComponent("Notes Assets").path
        ))
    }

    func testExportRejectsExistingOutputConflictsWithoutTouchingThem() throws {
        let sourceDirectory = try makeSourceDirectory()
        try writeImage(named: "capture.png", in: sourceDirectory)
        let destination = temporaryDirectory.appendingPathComponent("Notes.md")
        try "existing markdown".write(to: destination, atomically: true, encoding: .utf8)

        XCTAssertThrowsError(
            try ScratchpadMarkdownExporter.export(
                markdown: "![Image](vellum-scratchpad://capture)",
                to: destination,
                options: exportOptions(),
                attachmentsDirectory: sourceDirectory
            )
        ) { error in
            guard let exportError = error as? ScratchpadMarkdownExportError,
                  case .destinationAlreadyExists(_) = exportError else {
                return XCTFail("Expected destination conflict, got \(error)")
            }
        }
        XCTAssertEqual(try String(contentsOf: destination, encoding: .utf8), "existing markdown")

        try FileManager.default.removeItem(at: destination)
        let assets = temporaryDirectory.appendingPathComponent("Notes Assets", isDirectory: true)
        try FileManager.default.createDirectory(at: assets, withIntermediateDirectories: true)
        let sentinel = assets.appendingPathComponent("keep.txt")
        try "keep".write(to: sentinel, atomically: true, encoding: .utf8)

        XCTAssertThrowsError(
            try ScratchpadMarkdownExporter.export(
                markdown: "![Image](vellum-scratchpad://capture)",
                to: destination,
                options: exportOptions(),
                attachmentsDirectory: sourceDirectory
            )
        ) { error in
            guard let exportError = error as? ScratchpadMarkdownExportError,
                  case .assetsDirectoryAlreadyExists(_) = exportError else {
                return XCTFail("Expected assets conflict, got \(error)")
            }
        }
        XCTAssertEqual(try String(contentsOf: sentinel, encoding: .utf8), "keep")
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
    }

    func testExportRejectsSymlinkedSourceAndAssetsDirectory() throws {
        let sourceDirectory = try makeSourceDirectory()
        let externalImage = temporaryDirectory.appendingPathComponent("external.png")
        try Data([0x89, 0x50, 0x4E, 0x47]).write(to: externalImage)
        let sourceLink = sourceDirectory.appendingPathComponent("capture.png")
        try FileManager.default.createSymbolicLink(
            at: sourceLink,
            withDestinationURL: externalImage
        )
        let destination = temporaryDirectory.appendingPathComponent("Notes.md")

        XCTAssertThrowsError(
            try ScratchpadMarkdownExporter.export(
                markdown: "![Image](vellum-scratchpad://capture)",
                to: destination,
                options: exportOptions(),
                attachmentsDirectory: sourceDirectory
            )
        ) { error in
            guard let exportError = error as? ScratchpadMarkdownExportError,
                  case .unsafeSourceAttachment(_) = exportError else {
                return XCTFail("Expected unsafe source error, got \(error)")
            }
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))

        try FileManager.default.removeItem(at: sourceLink)
        try writeImage(named: "capture.png", in: sourceDirectory)
        let externalAssets = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: externalAssets) }
        try FileManager.default.createDirectory(at: externalAssets, withIntermediateDirectories: true)
        let assetsLink = temporaryDirectory.appendingPathComponent("Notes Assets", isDirectory: true)
        try FileManager.default.createSymbolicLink(
            at: assetsLink,
            withDestinationURL: externalAssets
        )

        XCTAssertThrowsError(
            try ScratchpadMarkdownExporter.export(
                markdown: "![Image](vellum-scratchpad://capture)",
                to: destination,
                options: exportOptions(),
                attachmentsDirectory: sourceDirectory
            )
        ) { error in
            guard let exportError = error as? ScratchpadMarkdownExportError,
                  case .unsafeAssetsDirectory(_) = exportError else {
                return XCTFail("Expected unsafe assets directory error, got \(error)")
            }
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: externalAssets.appendingPathComponent("capture.png").path
        ))
    }

    func testStorageExplanationMatchesSyncBehavior() {
        XCTAssertTrue(
            ScratchpadMarkdownExporter.storageExplanation(
                mode: .icloud,
                degraded: false
            ).contains("syncs through iCloud")
        )
        XCTAssertTrue(
            ScratchpadMarkdownExporter.storageExplanation(
                mode: .custom,
                degraded: false
            ).contains("stays in Application Support")
        )
        XCTAssertTrue(
            ScratchpadMarkdownExporter.storageExplanation(
                mode: .local,
                degraded: true
            ).contains("temporarily stored on this iPad")
        )
    }

    /// A destination that only looks like an attachment reference must not be
    /// treated as one. An id is a UUID: anything carrying path separators,
    /// percent escapes, or a traversal prefix is left byte-for-byte alone rather
    /// than resolved into a file to copy — the export must not become a way to
    /// read a file outside the attachments directory.
    func testExportIgnoresDestinationsThatAreNotAttachmentIDs() throws {
        let sourceDirectory = try makeSourceDirectory()
        try writeImage(named: "capture.png", in: sourceDirectory)
        let outsideDirectory = temporaryDirectory.appendingPathComponent(
            "outside", isDirectory: true)
        try FileManager.default.createDirectory(
            at: outsideDirectory, withIntermediateDirectories: true)
        try writeImage(named: "secret.png", in: outsideDirectory)
        let destination = temporaryDirectory.appendingPathComponent("Notes.md")
        let markdown = """
        ![Traversal](vellum-scratchpad://../outside/secret)
        ![Escaped](vellum-scratchpad://..%2Foutside%2Fsecret)
        ![Absolute](vellum-scratchpad:///etc/hosts)
        ![Real](vellum-scratchpad://capture)
        """

        let summary = try ScratchpadMarkdownExporter.export(
            markdown: markdown,
            to: destination,
            options: exportOptions(),
            attachmentsDirectory: sourceDirectory
        )

        let exported = try String(contentsOf: destination, encoding: .utf8)
        XCTAssertTrue(exported.contains("![Traversal](vellum-scratchpad://../outside/secret)"))
        XCTAssertTrue(exported.contains("![Escaped](vellum-scratchpad://..%2Foutside%2Fsecret)"))
        XCTAssertTrue(exported.contains("![Absolute](vellum-scratchpad:///etc/hosts)"))
        XCTAssertTrue(exported.contains("![Real](Notes Assets/capture.png)"))
        XCTAssertEqual(summary.copiedImageCount, 1)
        let assets = try FileManager.default.contentsOfDirectory(
            atPath: temporaryDirectory.appendingPathComponent("Notes Assets").path)
        XCTAssertEqual(assets, ["capture.png"])
    }

    private func makeSourceDirectory() throws -> URL {
        let sourceDirectory = temporaryDirectory.appendingPathComponent(
            "source",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: sourceDirectory,
            withIntermediateDirectories: true
        )
        return sourceDirectory
    }

    private func writeImage(named name: String, in directory: URL) throws {
        try Data([0x89, 0x50, 0x4E, 0x47]).write(
            to: directory.appendingPathComponent(name)
        )
    }

    private func exportOptions(
        includeFrontMatter: Bool = false,
        title: String = ""
    ) -> ScratchpadMarkdownExportOptions {
        ScratchpadMarkdownExportOptions(
            copyLinkedImages: true,
            includeFrontMatter: includeFrontMatter,
            title: title
        )
    }
}
