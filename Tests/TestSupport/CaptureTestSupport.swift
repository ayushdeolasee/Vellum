import Foundation

@testable import Vellum

/// Shared fixtures for the capture-inbox suites. Capture ids are fixed so file
/// names — and therefore the tie-break rules that read them — are assertable.
enum CaptureFixtures {
    static func date(_ rfc3339: String) -> Date {
        guard let date = CaptureTimestamp.parse(rfc3339) else {
            fatalError("fixture timestamp is not RFC3339: \(rfc3339)")
        }
        return date
    }

    static func record(
        captureID: String = "c4b1e5a0-7e6d-4b2f-9a31-0d5c8e7f6a1b",
        capturedAt: String = "2026-08-02T18:22:04.512000+00:00",
        sourceURL: String = "https://example.com/post",
        title: String? = "A Post",
        outerHTML: String? = "<html><body>hi</body></html>"
    ) -> CaptureRecord {
        CaptureRecordBuilder.make(
            sourceURL: sourceURL,
            title: title,
            outerHTML: outerHTML,
            maxHTMLBytes: 1_000_000,
            now: date(capturedAt),
            captureID: captureID,
            extensionBuild: "0.1.0 (1)")
    }

    /// A scratch App Group container the suites own outright.
    static func scratchLayout(_ suite: String) -> CaptureInboxLayout {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("vellum-\(suite)-tests-\(UUID().uuidString)", isDirectory: true)
        return CaptureInboxLayout(container: root)
    }

    static func remove(_ layout: CaptureInboxLayout) {
        try? FileManager.default.removeItem(at: layout.container)
    }

    static func names(in directory: URL) -> [String] {
        let names =
            (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        return names.sorted()
    }
}
