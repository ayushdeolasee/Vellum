import Foundation
import Testing

@testable import Vellum

// The real byte ceiling is a property of the extension's XPC hop and is not
// knowable without an on-device probe. These tests use 64 and 65 on purpose:
// if the guard were ever replaced by a baked-in device constant, every one of
// them would fail rather than silently pass against the wrong number.

@Suite("Capture record — oversize fallback")
struct CaptureOversizeTests {
    private let now = CaptureFixtures.date("2026-08-02T18:23:41.008000+00:00")

    private func make(_ html: String?, max: Int) -> CaptureRecord {
        CaptureRecordBuilder.make(
            sourceURL: "https://example.com/enormous",
            title: "An Enormous Post",
            outerHTML: html,
            maxHTMLBytes: max,
            now: now,
            captureID: "7f0a2c9d-1b3e-4a5f-8c6d-2e9b0a1f3c4d",
            extensionBuild: "0.1.0 (1)")
    }

    private func html(bytes: Int) -> String { String(repeating: "a", count: bytes) }

    @Test("HTML over the injected byte guard is dropped, leaving a URL-only record")
    func oversizeDrops() {
        let record = make(html(bytes: 4096), max: 64)
        #expect(record.payload == .urlOnly)
        #expect(record.droppedReason == .oversize)
        #expect(record.sourceURL == "https://example.com/enormous")
        #expect(record.title == "An Enormous Post")
    }

    @Test("HTML exactly at the guard is kept")
    func exactlyAtGuardIsKept() {
        let record = make(html(bytes: 64), max: 64)
        #expect(record.payload == .full)
        #expect(record.htmlByteCount == 64)
    }

    @Test("HTML one byte over the guard is dropped")
    func oneByteOverIsDropped() {
        let record = make(html(bytes: 65), max: 64)
        #expect(record.payload == .urlOnly)
        #expect(record.droppedHTMLByteCount == 65)
    }

    /// The guard has to be genuinely a parameter, not a constant the parameter
    /// shadows: the same input either side of the threshold must flip.
    @Test("The same HTML is kept or dropped by the threshold alone")
    func thresholdAloneDecides() {
        let page = html(bytes: 64)
        #expect(make(page, max: 63).payload == .urlOnly)
        #expect(make(page, max: 64).payload == .full)
        #expect(make(page, max: 65).payload == .full)
    }

    /// Truncated HTML would produce a plausible-looking but structurally broken
    /// document that the app pipeline would archive as if it were the page.
    @Test("Dropped HTML is never truncated — the record carries no HTML at all")
    func droppedHTMLIsNotTruncated() throws {
        let record = make(html(bytes: 4096), max: 64)
        #expect(record.outerHTML == nil)
        #expect(record.htmlByteCount == nil)
        let bytes = try CaptureCoding.encode(record)
        #expect(!String(decoding: bytes, as: UTF8.self).contains("outer_html"))
    }

    @Test("Absent HTML is reported unavailable, not oversize")
    func absentHTMLIsUnavailable() {
        let record = make(nil, max: 64)
        #expect(record.payload == .urlOnly)
        #expect(record.droppedReason == .unavailable)
        #expect(record.droppedHTMLByteCount == nil)
    }

    @Test("The dropped byte count reports the original size, measured in UTF-8")
    func droppedByteCountIsUTF8() {
        // Four bytes in UTF-8, one Character, two UTF-16 units — measuring in
        // anything but UTF-8 would put this either side of the guard.
        let emoji = "🌍"
        #expect(emoji.utf8.count == 4)
        let page = String(repeating: emoji, count: 20)
        let record = make(page, max: 64)
        #expect(record.payload == .urlOnly)
        #expect(record.droppedHTMLByteCount == 80)
    }
}
