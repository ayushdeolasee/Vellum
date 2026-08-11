import Foundation
import Testing

@testable import Vellum

// The App Group container is device-local, so these bytes are not a
// cross-device contract — but they ARE an app-update contract: a record written
// by the extension of build N is drained by the app of build N+1, and the two
// binaries ship at the same instant only in theory. Pinning the bytes is what
// makes that skew survivable.

@Suite("Capture record — wire format")
struct CaptureRecordTests {
    private let fullBytes = Data(
        #"""
        {"capture_id":"c4b1e5a0-7e6d-4b2f-9a31-0d5c8e7f6a1b","captured_at":"2026-08-02T18:22:04.512000+00:00","extension_build":"0.1.0 (1)","html_byte_count":184320,"outer_html":"<html lang=\"en\"><head>…</head><body>…</body></html>","page_key_hint":"9c1f3a7e5b2d4c8f0a1b2c3d4e5f60718293a4b5c6d7e8f90a1b2c3d4e5f6071","payload":"full","schema_version":1,"source_url":"https://example.com/post?utm_source=newsletter","title":"A Post"}
        """#.utf8)

    private let urlOnlyBytes = Data(
        #"""
        {"capture_id":"7f0a2c9d-1b3e-4a5f-8c6d-2e9b0a1f3c4d","captured_at":"2026-08-02T18:23:41.008000+00:00","dropped_html_byte_count":6291456,"dropped_reason":"oversize","extension_build":"0.1.0 (1)","payload":"url_only","schema_version":1,"source_url":"https://example.com/enormous","title":"An Enormous Post"}
        """#.utf8)

    private func documentedFullRecord() -> CaptureRecord {
        CaptureRecord(
            captureID: "c4b1e5a0-7e6d-4b2f-9a31-0d5c8e7f6a1b",
            capturedAt: "2026-08-02T18:22:04.512000+00:00",
            sourceURL: "https://example.com/post?utm_source=newsletter",
            title: "A Post",
            payload: .full,
            outerHTML: "<html lang=\"en\"><head>…</head><body>…</body></html>",
            htmlByteCount: 184_320,
            pageKeyHint: "9c1f3a7e5b2d4c8f0a1b2c3d4e5f60718293a4b5c6d7e8f90a1b2c3d4e5f6071",
            extensionBuild: "0.1.0 (1)")
    }

    private func documentedURLOnlyRecord() -> CaptureRecord {
        CaptureRecord(
            captureID: "7f0a2c9d-1b3e-4a5f-8c6d-2e9b0a1f3c4d",
            capturedAt: "2026-08-02T18:23:41.008000+00:00",
            sourceURL: "https://example.com/enormous",
            title: "An Enormous Post",
            payload: .urlOnly,
            droppedReason: .oversize,
            droppedHTMLByteCount: 6_291_456,
            extensionBuild: "0.1.0 (1)")
    }

    @Test("A full record round-trips with its HTML and schema_version")
    func fullRoundTrip() throws {
        let record = documentedFullRecord()
        let decoded = try CaptureCoding.decoder.decode(
            CaptureRecord.self, from: try CaptureCoding.encode(record))
        #expect(decoded == record)
        #expect(decoded.outerHTML == record.outerHTML)
        #expect(decoded.schemaVersion == 1)
    }

    @Test("A URL-only record round-trips with its dropped reason")
    func urlOnlyRoundTrip() throws {
        let record = documentedURLOnlyRecord()
        let decoded = try CaptureCoding.decoder.decode(
            CaptureRecord.self, from: try CaptureCoding.encode(record))
        #expect(decoded == record)
        #expect(decoded.droppedReason == .oversize)
        #expect(decoded.droppedHTMLByteCount == 6_291_456)
        #expect(decoded.outerHTML == nil)
    }

    @Test("The encoded full record matches the documented bytes exactly")
    func fullBytesAreExact() throws {
        #expect(try CaptureCoding.encode(documentedFullRecord()) == fullBytes)
    }

    @Test("The encoded URL-only record matches the documented bytes exactly")
    func urlOnlyBytesAreExact() throws {
        #expect(try CaptureCoding.encode(documentedURLOnlyRecord()) == urlOnlyBytes)
    }

    /// A newer extension is a normal state of the world during a staged update.
    /// It must be reported so the drain can quarantine it, not thrown at a
    /// caller that would have to guess whether the bytes are salvageable.
    @Test("A record from an unknown newer schema version is reported unsupported, not thrown")
    func newerSchemaIsReported() throws {
        var record = documentedFullRecord()
        record.schemaVersion = CaptureRecord.currentSchemaVersion + 1
        let outcome = CaptureCoding.decode(try CaptureCoding.encode(record))
        #expect(outcome == .unsupportedSchema(CaptureRecord.currentSchemaVersion + 1))
    }

    @Test("Unknown keys from a future extension build survive decode")
    func unknownKeysSurvive() throws {
        var object =
            try JSONSerialization.jsonObject(with: try CaptureCoding.encode(documentedFullRecord()))
            as! [String: Any]
        object["reader_mode_html"] = "<article>later</article>"
        object["capture_attempt"] = 3
        let bytes = try JSONSerialization.data(withJSONObject: object)

        guard case .ok(let decoded) = CaptureCoding.decode(bytes) else {
            Issue.record("expected a decodable record")
            return
        }
        #expect(decoded.unknownFields["reader_mode_html"] == .string("<article>later</article>"))
        #expect(decoded.unknownFields["capture_attempt"] == .int(3))

        let reencoded =
            try JSONSerialization.jsonObject(with: try CaptureCoding.encode(decoded))
            as! [String: Any]
        #expect(reencoded["reader_mode_html"] as? String == "<article>later</article>")
        #expect(reencoded["capture_attempt"] as? Int == 3)
    }

    @Test("A full record never carries a dropped reason, and a URL-only record never carries HTML")
    func payloadDiscriminatorIsExclusive() {
        let full = CaptureFixtures.record(outerHTML: "<html><body>kept</body></html>")
        #expect(full.payload == .full)
        #expect(full.droppedReason == nil)
        #expect(full.droppedHTMLByteCount == nil)
        #expect(full.outerHTML != nil)

        let urlOnly = CaptureFixtures.record(outerHTML: nil)
        #expect(urlOnly.payload == .urlOnly)
        #expect(urlOnly.outerHTML == nil)
        #expect(urlOnly.htmlByteCount == nil)
        #expect(urlOnly.droppedReason == .unavailable)
    }
}
