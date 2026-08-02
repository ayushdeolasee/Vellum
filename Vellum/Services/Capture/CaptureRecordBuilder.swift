import Foundation

// FOUNDATION ONLY — compiled into the share extension. See CaptureRecord.swift.

/// The whole oversize-fallback decision, as a pure function of its arguments.
enum CaptureRecordBuilder {
    /// `maxHTMLBytes` is a PARAMETER with no default. The real threshold is the
    /// point at which the extension's `NSItemProvider` hop starts failing, which
    /// is not knowable without an on-device probe, and a guessed constant baked
    /// in here would ship as fact. The extension supplies it from one named
    /// constant of its own; the tests supply 64 and 65.
    ///
    /// Oversize HTML is DROPPED, never truncated: a truncated DOM produces a
    /// plausible-looking but structurally broken document that the app pipeline
    /// would happily archive as if it were the page.
    static func make(
        sourceURL: String,
        title: String?,
        outerHTML: String?,
        maxHTMLBytes: Int,
        now: Date,
        captureID: String = UUID().uuidString.lowercased(),
        extensionBuild: String? = Bundle.main.shortVersionAndBuild
    ) -> CaptureRecord {
        let capturedAt = CaptureTimestamp.string(from: now)

        guard let outerHTML else {
            // No DOM was ever offered — shared from Messages, a bare URL.
            return CaptureRecord(
                captureID: captureID,
                capturedAt: capturedAt,
                sourceURL: sourceURL,
                title: title,
                payload: .urlOnly,
                droppedReason: .unavailable,
                extensionBuild: extensionBuild)
        }

        let byteCount = outerHTML.utf8.count
        guard byteCount <= maxHTMLBytes else {
            return CaptureRecord(
                captureID: captureID,
                capturedAt: capturedAt,
                sourceURL: sourceURL,
                title: title,
                payload: .urlOnly,
                droppedReason: .oversize,
                droppedHTMLByteCount: byteCount,
                extensionBuild: extensionBuild)
        }

        return CaptureRecord(
            captureID: captureID,
            capturedAt: capturedAt,
            sourceURL: sourceURL,
            title: title,
            payload: .full,
            outerHTML: outerHTML,
            htmlByteCount: byteCount,
            extensionBuild: extensionBuild)
    }
}

extension Bundle {
    /// `"0.1.0 (1)"` — the shape `extension_build` carries. Diagnostics only;
    /// the drain never branches on it.
    var shortVersionAndBuild: String? {
        let short = object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        let build = object(forInfoDictionaryKey: "CFBundleVersion") as? String
        switch (short, build) {
        case let (short?, build?): return "\(short) (\(build))"
        case let (short?, nil): return short
        case let (nil, build?): return "(\(build))"
        case (nil, nil): return nil
        }
    }
}
