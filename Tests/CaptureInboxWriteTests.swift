import Foundation
import Testing

@testable import Vellum

@Suite("Capture inbox — write discipline")
struct CaptureInboxWriteTests {
    @Test("A written record lands in pending/ and leaves no temp file behind")
    func writeLandsInPending() throws {
        let layout = CaptureFixtures.scratchLayout("capture-write")
        defer { CaptureFixtures.remove(layout) }

        let writer = CaptureInboxWriter(layout: layout)
        let record = CaptureFixtures.record()
        let url = try writer.write(record)

        #expect(url.deletingLastPathComponent().standardizedFileURL == layout.pending.standardizedFileURL)
        #expect(CaptureFixtures.names(in: layout.pending).count == 1)
        #expect(CaptureFixtures.names(in: layout.tmp).isEmpty)

        let decoded = CaptureCoding.decode(try Data(contentsOf: url))
        #expect(decoded == .ok(record))
    }

    /// Temps in the same directory as pending records would mean a drain could
    /// enumerate a file mid-write and decide it was corrupt. A separate
    /// directory makes that unreachable rather than unlikely.
    @Test("A drain never sees a half-written record, because temps live outside pending/")
    func tempsAreOutsidePending() async throws {
        let layout = CaptureFixtures.scratchLayout("capture-write")
        defer { CaptureFixtures.remove(layout) }
        try layout.createDirectories()

        #expect(!layout.tmp.path.hasPrefix(layout.pending.path))

        // A half-written file, exactly as an interrupted extension would leave it.
        try Data("{\"schema_ver".utf8).write(
            to: layout.tmp.appendingPathComponent("half.json"))

        let inbox = CaptureInbox(layout: layout, clock: CaptureFixtures.clock)
        #expect(await inbox.pendingCount() == 0)
        let report = await inbox.drain { _, _ in
            Issue.record("a temp file must never reach ingest")
            return .ingested(DocumentKey.web(normalizedURL: "https://example.com/"))
        }
        #expect(report == CaptureDrainReport())
    }

    @Test("Two captures in the same millisecond produce two distinct files")
    func sameMillisecondCapturesCoexist() throws {
        let layout = CaptureFixtures.scratchLayout("capture-write")
        defer { CaptureFixtures.remove(layout) }

        let writer = CaptureInboxWriter(layout: layout)
        let stamp = "2026-08-02T18:22:04.512000+00:00"
        let first = try writer.write(
            CaptureFixtures.record(
                captureID: "11111111-1111-4111-8111-111111111111", capturedAt: stamp,
                sourceURL: "https://example.com/a"))
        let second = try writer.write(
            CaptureFixtures.record(
                captureID: "22222222-2222-4222-8222-222222222222", capturedAt: stamp,
                sourceURL: "https://example.com/b"))

        #expect(first != second)
        #expect(CaptureFixtures.names(in: layout.pending).count == 2)
    }

    @Test("Pending file names sort chronologically")
    func namesSortChronologically() throws {
        let layout = CaptureFixtures.scratchLayout("capture-write")
        defer { CaptureFixtures.remove(layout) }

        let writer = CaptureInboxWriter(layout: layout)
        // Deliberately written newest-first, and with capture ids whose
        // alphabetical order is the reverse of their capture order, so only the
        // millisecond prefix can produce the right answer.
        try writer.write(
            CaptureFixtures.record(
                captureID: "aaaaaaaa-0000-4000-8000-000000000003",
                capturedAt: "2026-08-02T18:30:00.000000+00:00"))
        try writer.write(
            CaptureFixtures.record(
                captureID: "cccccccc-0000-4000-8000-000000000001",
                capturedAt: "2026-08-02T18:10:00.000000+00:00"))
        try writer.write(
            CaptureFixtures.record(
                captureID: "bbbbbbbb-0000-4000-8000-000000000002",
                capturedAt: "2026-08-02T18:20:00.000000+00:00"))

        let names = CaptureFixtures.names(in: layout.pending)
        #expect(names.map { String($0.suffix(41).prefix(36)) }
            == [
                "cccccccc-0000-4000-8000-000000000001",
                "bbbbbbbb-0000-4000-8000-000000000002",
                "aaaaaaaa-0000-4000-8000-000000000003",
            ])
    }

    @Test("The writer creates its directories on first use")
    func writerCreatesDirectories() throws {
        let layout = CaptureFixtures.scratchLayout("capture-write")
        defer { CaptureFixtures.remove(layout) }

        #expect(!FileManager.default.fileExists(atPath: layout.root.path))
        try CaptureInboxWriter(layout: layout).write(CaptureFixtures.record())

        for directory in [layout.tmp, layout.pending, layout.failed] {
            var isDirectory: ObjCBool = false
            #expect(
                FileManager.default.fileExists(atPath: directory.path, isDirectory: &isDirectory))
            #expect(isDirectory.boolValue)
        }
    }
    @Test("Concurrent writers count pending and failed intent against one budget")
    func concurrentAdmissionPreservesExistingIntent() async throws {
        let layout = CaptureFixtures.scratchLayout("capture-capacity")
        defer { CaptureFixtures.remove(layout) }
        try layout.createDirectories()
        let old = layout.failed.appendingPathComponent("old.json")
        let original = try CaptureCoding.encode(CaptureFixtures.record())
        try original.write(to: old)
        let capacity = CaptureInboxCapacity(maximumBytes: 65_536, maximumEntries: 2)
        let accepted = await withTaskGroup(of: Bool.self) { group in
            for _ in 0..<20 {
                group.addTask {
                    do {
                        _ = try CaptureInboxWriter(layout: layout, capacity: capacity).write(
                            CaptureFixtures.record(captureID: UUID().uuidString.lowercased()))
                        return true
                    } catch CaptureInboxError.capacityExceeded { return false }
                    catch { Issue.record("Unexpected writer failure: \(error)"); return false }
                }
            }
            var total = 0
            for await success in group where success { total += 1 }
            return total
        }
        #expect(accepted == 1)
        #expect(CaptureFixtures.names(in: layout.pending).count == 1)
        #expect(try Data(contentsOf: old) == original)
        // Lowering a limit below existing usage refuses only the new capture.
        do {
            try CaptureInboxWriter(layout: layout,
                capacity: CaptureInboxCapacity(maximumBytes: 1, maximumEntries: 1_000))
                .write(CaptureFixtures.record(captureID: UUID().uuidString.lowercased()))
            Issue.record("new capture must be refused above the byte budget")
        } catch let error as CaptureInboxError { #expect(error == .capacityExceeded) }
        #expect(try Data(contentsOf: old) == original)
        #expect(CaptureFixtures.names(in: layout.pending).count == 1)
        #expect(CaptureInboxCapacity().maximumBytes == 256 * 1024 * 1024)
        #expect(CaptureInboxCapacity().maximumEntries == 1_000)
    }

    @Test("Publishing a colliding capture never overwrites existing bytes")
    func writerCollisionPreservesOriginal() throws {
        let layout = CaptureFixtures.scratchLayout("capture-collision")
        defer { CaptureFixtures.remove(layout) }
        let writer = CaptureInboxWriter(layout: layout)
        let record = CaptureFixtures.record()
        let original = try writer.write(record)
        let bytes = try Data(contentsOf: original)
        var changed = record
        changed.title = "Different capture with the same filename"
        do { try writer.write(changed); Issue.record("collision must refuse replacement") }
        catch { }
        #expect(try Data(contentsOf: original) == bytes)
        #expect(CaptureFixtures.names(in: layout.tmp).isEmpty)
    }

}
