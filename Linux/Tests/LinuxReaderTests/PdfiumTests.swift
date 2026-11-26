import Dispatch
import Foundation
import Synchronization
import Testing
@testable import LinuxReader

@Suite(.serialized)
struct PdfiumTests {
    // P7 owns the shared corpus. dev-shell stages Packages alongside Linux.
    private func fixture(_ name: String) throws -> Data {
        let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let directory = repo.appendingPathComponent("Packages/VellumCore/Tests/VellumCoreTests/Fixtures/Pdf")
        return try Data(contentsOf: directory.appendingPathComponent(name + ".pdf"))
    }

    private func bgra(_ image: PdfiumBitmap, _ x: Int, _ y: Int) -> [UInt8] {
        let offset = y * image.bytesPerRow + x * 4
        return Array(image.pixels[offset..<(offset + 4)])
    }

    @Test func readsCorpusAndOwnsResultsAcrossJobs() async throws {
        for (name, expected) in [("classic-two-column", "Left column: Café"),
                                 ("xref-stream-objstm", "Compressed page dictionary"),
                                 ("digitally-signed", "Right column: naïve")] {
            let bytes = try fixture(name)
            let info = try await PdfiumDocument.pageInfo(in: bytes, at: 0)
            #expect(info.pageCount == 1)
            let text = try await PdfiumDocument.extractText(in: bytes, at: 0)
            let bitmap = try await PdfiumDocument.render(in: bytes, at: 0, scale: 0.5)
            #expect(bitmap.width == 306 && bitmap.height == 396)
            #expect(bitmap.bytesPerRow == 4 * bitmap.width)
            #expect(bitmap.pixels.count == bitmap.bytesPerRow * bitmap.height)
            #expect(bitmap.pixels.contains { $0 < 160 })
            #expect(text.text.contains(expected))
            #expect(text.chars.map(\.codeUnit) == Array(text.text.utf16))
            #expect(text.chars.map(\.utf16Index) == Array(0..<text.text.utf16.count))
            if name == "classic-two-column" {
                let first = try #require(text.chars.first)
                #expect(first.left >= 64 && first.left < 68 && first.right > first.left)
                #expect(first.bottom >= 700 && first.top <= 720 && first.top > first.bottom)
                #expect(!first.isGenerated)
                #expect(text.chars.contains { $0.isGenerated })
            }
        }
    }

    @Test func intrinsicRotationsKeepAllFourColoredCornersAndOpaquePixels() async throws {
        let bytes = try fixture("rotated-all-angles")
        var width = 552, height = 708
        var marks: [(x: Int, y: Int, color: [UInt8])] = [
            (15, 691, [0, 0, 255, 255]), (530, 685, [0, 255, 0, 255]),
            (22, 21, [255, 0, 0, 255]), (523, 28, [255, 0, 255, 255])
        ]
        for index in 0..<4 {
            let info = try await PdfiumDocument.pageInfo(in: bytes, at: index)
            #expect(info.pageCount == 4 && info.rotation == 90 * index)
            #expect(info.widthPt == Double(width) && info.heightPt == Double(height))
            #expect(info.visibleLeft == 24 && info.visibleBottom == 36)
            // PDFKit's characterBounds(at: 0) for "R" on each page is
            // [73.2305,700,82.0408,710.042] before display rotation.
            let text = try await PdfiumDocument.extractText(in: bytes, at: index)
            let r = try #require(text.chars.first)
            #expect(r.codeUnit == 82)
            #expect(abs((r.left - info.visibleLeft) - 49.2305) < 1)
            #expect(abs((r.bottom - info.visibleBottom) - 664) < 1)
            #expect(abs((r.right - info.visibleLeft) - 58.0408) < 1)
            #expect(abs((r.top - info.visibleBottom) - 674.042) < 1)
            let bitmap = try await PdfiumDocument.render(in: bytes, at: index, scale: 1)
            try #require(bitmap.width == width && bitmap.height == height)
            for mark in marks {
                #expect(bgra(bitmap, mark.x, mark.y) == mark.color)
            }
            #expect(stride(from: 3, to: bitmap.pixels.count, by: 4).allSatisfy { bitmap.pixels[$0] == 255 })
            marks = marks.map { (height - 1 - $0.y, $0.x, $0.color) }
            swap(&width, &height)
        }
    }

    @Test func rendersForeignHighlightAndFreeTextInTheirPageRects() async throws {
        let bytes = try fixture("foreign-annotations")
        let bitmap = try await PdfiumDocument.render(in: bytes, at: 0, scale: 1)
        // Yellow highlight extends beyond the text, within PDF rect [72 695 172 711].
        let inside = bgra(bitmap, 165, 94)
        #expect(inside[0] < 180 && inside[1] > 240 && inside[2] > 240)
        #expect(bgra(bitmap, 165, 102) == [255, 255, 255, 255])
        // The blank page content in this rect has only the "Margin note" annotation.
        let notePixels = (160..<192).reduce(0) { count, y in
            count + (72..<230).filter { x in bitmap.pixels[y * bitmap.bytesPerRow + x * 4] < 200 }.count
        }
        #expect(notePixels > 100)
    }

    // Interior landmarks from the unstripped macOS PDFKit renders, at one pixel per point.
    @Test func rendersIPadInkIncludingMaskAndRotationBehavior() async throws {
        let indigo: [UInt8] = [143, 65, 69, 255]
        let red: [UInt8] = [48, 58, 178, 255]
        let yellow: [UInt8] = [138, 240, 254, 255]
        let gray: [UInt8] = [153, 153, 153, 255]

        func render(_ name: String, rotated: Bool = false) async throws -> PdfiumBitmap {
            let image = try await PdfiumDocument.render(in: fixture(name), at: 0, scale: 1)
            try #require(image.width == (rotated ? 240 : 320) && image.height == (rotated ? 320 : 240))
            return image
        }

        let pens = try await render("ipad-vellum-ink")
        let foreign = bgra(pens, 50, 36)
        #expect(foreign[0] == foreign[1] && foreign[1] == foreign[2] && foreign[2] < 65)
        #expect(bgra(pens, 100, 84) == indigo)
        #expect(bgra(pens, 100, 150) == red)

        let full = try await render("pdf-ink-erased-full")
        let partial = try await render("pdf-ink-erased-partial")
        #expect(bgra(full, 100, 150) == red && bgra(partial, 100, 150) == red)
        // Full erasure omits the indigo annotation. The partially erased PDF
        // exports the whole line, including PencilKit's masked x=110...185 gap.
        for x in 48..<240 {
            let bare = bgra(full, x, 90)
            #expect(bare[0] == bare[1] && bare[1] == bare[2])
            #expect(bgra(partial, x, 90) == indigo)
        }

        let marker = try await render("pdf-ink-marker")
        #expect(bgra(marker, 95, 90) == yellow)   // white paper underneath
        #expect(bgra(marker, 84, 90) == yellow)   // gray bar underneath
        #expect(bgra(marker, 144, 90) == yellow)  // two strokes cross on gray
        #expect(bgra(marker, 84, 120) == gray)

        let rotated = try await render("pdf-ink-rotated", rotated: true)
        #expect(bgra(rotated, 156, 95) == indigo && bgra(rotated, 144, 237) == indigo)
        #expect(bgra(rotated, 120, 84) == gray)
    }

    @Test func opensEncryptedBytesOnlyWithTheFullPassword() async throws {
        let bytes = try fixture("encrypted-user-pass")
        for password: String? in [nil, "", "wrong", "vellum\0suffix"] {
            await #expect(throws: PdfiumError.passwordRequired) {
                try await PdfiumDocument.pageInfo(in: bytes, at: 0, password: password)
            }
        }
        let text = try await PdfiumDocument.extractText(in: bytes, at: 0, password: "vellum")
        #expect(text.text.contains("Café"))
    }

    @Test func rejectsBadInputsBeforeAllocatingABitmap() async throws {
        for bytes in [Data(), Data("not a pdf".utf8)] {
            await #expect(throws: PdfiumError.invalidDocument) {
                try await PdfiumDocument.pageInfo(in: bytes, at: 0)
            }
        }
        let bytes = try fixture("classic-two-column")
        for index in [-1, 1, Int.max] {
            await #expect(throws: PdfiumError.invalidPage) {
                try await PdfiumDocument.extractText(in: bytes, at: index)
            }
        }
        for scale: Double in [0, -1, .nan, .infinity, 0.00001, 8, 100, .greatestFiniteMagnitude] {
            await #expect(throws: PdfiumError.invalidDimensions) {
                try await PdfiumDocument.render(in: bytes, at: 0, scale: scale)
            }
        }
    }

    @Test func concurrentInputDocumentsKeepIndependentResults() async throws {
        let rotated = try fixture("rotated-all-angles")
        let encrypted = try fixture("encrypted-user-pass")
        try await withThrowingTaskGroup(of: Void.self) { group in
            for index in 0..<16 {
                group.addTask {
                    if index.isMultiple(of: 2) {
                        let info = try await PdfiumDocument.pageInfo(in: rotated, at: index % 4)
                        #expect(info.rotation == 90 * (index % 4))
                    } else {
                        let text = try await PdfiumDocument.extractText(in: encrypted, at: 0, password: "vellum")
                        #expect(text.text.contains("Café"))
                    }
                }
            }
            try await group.waitForAll()
        }
    }

    @Test func interactiveJobsPassQueuedBackgroundJobsAndCancelledJobsReleaseTheirSlot() async throws {
        let worker = PdfiumActor.shared
        let release = DispatchSemaphore(value: 0)
        let order = Mutex<[Int]>([])
        let started = Mutex(false)
        let active = Task {
            try await worker.run(priority: .background, byteCount: PdfiumDocument.maxInputBytes) {
                started.withLock { $0 = true }
                #expect(release.wait(timeout: .now() + 10) == .success)
                order.withLock { $0.append(0) }
            }
        }
        defer { release.signal() }
        try await waitUntil { started.withLock { $0 } }
        func enqueue(_ n: Int, _ priority: PdfiumActor.Priority, bytes: Int = 0) -> Task<Void, Error> {
            Task {
                try await worker.run(priority: priority, byteCount: bytes) {
                    order.withLock { $0.append(n) }
                }
            }
        }
        let background = enqueue(1, .background)
        try await waitUntil { await worker.pendingCount == 1 }
        let cancelled = enqueue(2, .onDemand, bytes: PdfiumDocument.maxInputBytes)
        try await waitUntil { await worker.pendingCount == 2 }
        let interactive = enqueue(3, .onDemand)
        try await waitUntil { await worker.pendingCount == 3 }
        await #expect(throws: PdfiumError.queueFull) { try await enqueue(4, .onDemand, bytes: 1).value }
        cancelled.cancel()
        await #expect(throws: CancellationError.self) { try await cancelled.value }
        #expect(await worker.pendingCount == 2)
        // A running synchronous call finishes; its cancelled caller discards the result.
        active.cancel()
        release.signal()
        await #expect(throws: CancellationError.self) { try await active.value }
        try await interactive.value
        try await background.value
        #expect(order.withLock { $0 } == [0, 3, 1])
    }

    @Test func backgroundFloodLeavesAnInteractiveSlotAndReleasesBytesBeforeReturning() async throws {
        let worker = PdfiumActor.shared
        let maxBytes = PdfiumDocument.maxInputBytes
        let activeStarted = Mutex(false)
        let releaseActive = DispatchSemaphore(value: 0)
        let releaseInteractive = DispatchSemaphore(value: 0)
        let interactiveStarted = Mutex(false)
        defer {
            releaseActive.signal()
            releaseInteractive.signal()
        }
        // The byte counts model maximum-size inputs without allocating the documents.
        let consecutive = Task {
            try await worker.run(priority: .background, byteCount: maxBytes) {
                activeStarted.withLock { $0 = true }
                #expect(releaseActive.wait(timeout: .now() + 10) == .success)
            }
            // At return, the first job's bytes must be available even though
            // the other maximum-size job remains admitted and cannot finish.
            try await worker.run(priority: .onDemand, byteCount: maxBytes) {}
        }
        try await waitUntil { activeStarted.withLock { $0 } }
        await #expect(throws: PdfiumError.queueFull) {
            try await worker.run(priority: .background, byteCount: 1) {}
        }
        let backlog = (0..<63).map { _ in
            Task { try await worker.run(priority: .background, byteCount: 0) {} }
        }
        try await waitUntil { await worker.pendingCount == backlog.count }
        await #expect(throws: PdfiumError.queueFull) {
            try await worker.run(priority: .background, byteCount: 0) {}
        }

        let interactive = Task {
            try await worker.run(priority: .onDemand, byteCount: maxBytes) {
                interactiveStarted.withLock { $0 = true }
                #expect(releaseInteractive.wait(timeout: .now() + 10) == .success)
            }
        }
        try await waitUntil { await worker.pendingCount == 64 }
        releaseActive.signal()
        // Wait for the blocked interactive to take its slot AND the consecutive
        // caller to refill the queue. The count alone also equals 64 before dequeue.
        try await waitUntil { await worker.pendingCount == 64 && interactiveStarted.withLock { $0 } }
        releaseInteractive.signal()
        try await consecutive.value
        try await interactive.value
        for job in backlog { try await job.value }
    }

    private func waitUntil(_ ready: () async -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(5)
        while !(await ready()) {
            try #require(ContinuousClock.now < deadline)
            try await Task.sleep(for: .milliseconds(1))
        }
    }
}
