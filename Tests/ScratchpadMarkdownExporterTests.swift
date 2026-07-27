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
        ScratchpadAttachmentStore.activeDirectory = nil
    }

    override func tearDownWithError() throws {
        ScratchpadAttachmentStore.directoryOverride = nil
        ScratchpadAttachmentStore.activeDirectory = nil
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

    func testExportAddsFrontMatterCopiesImagesAndRewritesLinks() throws {
        let sourceDirectory = temporaryDirectory.appendingPathComponent(
            "source",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: sourceDirectory,
            withIntermediateDirectories: true
        )
        let imageURL = sourceDirectory.appendingPathComponent("capture.png")
        try Data([0x89, 0x50, 0x4E, 0x47]).write(to: imageURL)
        let destination = temporaryDirectory.appendingPathComponent("Research Notes.md")

        let summary = try ScratchpadMarkdownExporter.export(
            markdown: "# Thought\n\n![Diagram](vellum-scratchpad://capture)",
            to: destination,
            options: ScratchpadMarkdownExportOptions(
                copyLinkedImages: true,
                includeFrontMatter: true,
                title: "Research \"Notes\""
            ),
            attachmentsDirectory: sourceDirectory
        )

        let exported = try String(contentsOf: destination, encoding: .utf8)
        XCTAssertTrue(exported.hasPrefix("---\ntitle: \"Research \\\"Notes\\\"\"\n---\n\n"))
        XCTAssertTrue(exported.contains(
            "![Diagram](Research Notes Assets/capture.png)"
        ))
        XCTAssertEqual(summary.copiedImageCount, 1)
        XCTAssertEqual(summary.skippedImageCount, 0)
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: temporaryDirectory
                .appendingPathComponent("Research Notes Assets/capture.png").path
        ))
    }

    func testExportReportsUnavailableImagesWithoutDestroyingReference() throws {
        let destination = temporaryDirectory.appendingPathComponent("Notes.md")

        let summary = try ScratchpadMarkdownExporter.export(
            markdown: "![Missing](vellum-scratchpad://not-here)",
            to: destination,
            options: ScratchpadMarkdownExportOptions(
                copyLinkedImages: true,
                includeFrontMatter: false,
                title: ""
            ),
            attachmentsDirectory: temporaryDirectory
        )

        XCTAssertEqual(summary.copiedImageCount, 0)
        XCTAssertEqual(summary.skippedImageCount, 1)
        XCTAssertEqual(
            try String(contentsOf: destination, encoding: .utf8),
            "![Missing](vellum-scratchpad://not-here)"
        )
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
            ).contains("temporarily stored on this Mac")
        )
    }
}
