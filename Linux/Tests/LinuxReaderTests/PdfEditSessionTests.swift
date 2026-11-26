import Foundation
import Testing
import VellumCore
@testable import LinuxReader

extension PdfiumTests {
    @Test func disposableEditsSerializeAndCloseJoinsEveryAdmission() async throws {
        let original = try fixture("classic-two-column")
        let session = try await PdfEditSession(disposableCopyOf: original)
        let now = "2026-11-26T12:34:56Z"
        let created = try await session.enqueue(.create(.init(type: .note, pageNumber: 1, id: "note")), now: now)
        let pinned = try await session.enqueue(.update(.init(id: "note", content: "second", isPinned: true)), now: now)
        try await session.close()
        let first = try await created.value
        let second = try await pinned.value
        #expect(first.starts(with: original))
        #expect(second.starts(with: first))
        let records = try PdfAnnotationPureReader.annotations(on: 1, in: second, now: now)
        #expect(records.first?.content == "second" && records.first?.pinned == true)
        #expect(!FileManager.default.fileExists(atPath: session.file.path))
        await #expect(throws: PdfEditSession.Failure.closed) { try await session.enqueue(.delete(id: "note"), now: now) }
        try await session.close()
    }

    @Test func pdfiumPaintsHighlightsAtTheRequestedUICornersOnEveryRotation() async throws {
        let original = try fixture("rotated-all-angles")
        for index in 0..<4 {
            let info = try await PdfiumDocument.pageInfo(in: original, at: index)
            let position = PositionData(rects: [.init(x: 100, y: 150, width: 70, height: 12)],
                                        pageWidth: info.widthPt, pageHeight: info.heightPt)
            let edit = PdfAnnotationEdit.create(.init(type: .highlight, pageNumber: index + 1, color: "#1256ab",
                                                      positionData: position, id: "render"))
            let next = try PdfAnnotationIncrement.applying(edit, to: original, now: "2026-11-26T12:34:56Z")
            let before = try await PdfiumDocument.render(in: original, at: index, scale: 1)
            let after = try await PdfiumDocument.render(in: next, at: index, scale: 1)
            func changed(_ x: Int, _ y: Int) -> Bool {
                let i = after.bytesPerRow * y + 4 * x
                return before.pixels[i..<i+3] != after.pixels[i..<i+3]
            }
            #expect(changed(105, 152) && changed(165, 160))
            #expect(!changed(135, 144) && !changed(135, 170))
        }
    }

    @Test func failedAndStaleWritesRetainDiskAndSessionSnapshot() async throws {
        let original = try fixture("ipad-vellum-ink")
        let session = try await PdfEditSession(disposableCopyOf: original)
        let file = session.file
        let directory = file.deletingLastPathComponent()
        let now = "2026-11-26T12:34:56Z"
        let edit = PdfAnnotationEdit.create(.init(type: .note, pageNumber: 1, id: "retry"))
        let newer = try fixture("foreign-annotations")
        try newer.write(to: file, options: .atomic)
        let stale = try await session.enqueue(edit, now: now)
        await #expect(throws: PdfEditSession.Failure.stale) { try await stale.value }
        #expect(try Data(contentsOf: file) == newer)
        #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path) == ["fixture.pdf"])

        // Block staging while leaving the original file readable. The pinned
        // Linux image runs tests as an unprivileged user.
        try original.write(to: file)
        let fm = FileManager.default
        try fm.setAttributes([.posixPermissions: 0o500], ofItemAtPath: directory.path)
        if !fm.isWritableFile(atPath: directory.path) {
            let failed = try await session.enqueue(edit, now: now)
            await #expect(throws: PdfCoreError.self) { try await failed.value }
            #expect(try Data(contentsOf: file) == original)
            #expect(try fm.contentsOfDirectory(atPath: directory.path) == ["fixture.pdf"])
        }
        try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)

        // A non-regular target also fails under root, where chmod cannot
        // induce a permissions error. The following retry uses the same session.
        try fm.removeItem(at: file)
        try fm.createDirectory(at: file, withIntermediateDirectories: false)
        let failed = try await session.enqueue(edit, now: now)
        await #expect(throws: PdfCoreError.self) { try await failed.value }
        #expect(try fm.contentsOfDirectory(atPath: file.path).isEmpty)
        try fm.removeItem(at: file)
        try original.write(to: file)
        let retry = try await session.enqueue(edit, now: now).value
        #expect(retry.starts(with: original))
        #expect(try Data(contentsOf: file) == retry)
        try await session.close()
    }
}
