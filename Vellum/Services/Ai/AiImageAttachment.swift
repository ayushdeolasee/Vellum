import AppKit
import Foundation

/// Normalize arbitrary image bytes — a file dropped on the AI panel, or one
/// picked through the attach menu — into the same `AiPageImageSnapshot` the PDF
/// and web captures produce, so every provider client's existing image payload
/// path (base64 data URL, or Gemini's `inline_data`) takes it unchanged.
///
/// Deliberately stricter than the scratchpad's `scratchpadCapture(from:)`, and
/// for a different reason: that one stores bytes on disk, so it passes small
/// PNG/JPEG/GIF through verbatim and only caps at 2000px. These bytes are
/// base64'd into every request instead, so the budget is the provider's, not the
/// disk's: HEIC/TIFF/BMP/GIF are always re-encoded (only PNG/JPEG/WebP are
/// reliably accepted), the long side is capped so a 12MP photo can't dominate
/// the request, and an oversized encode is retried at lower quality rather than
/// shipped. Animated GIFs and multi-page TIFFs collapse to their first frame.
///
/// `maxSide` defaults to Anthropic's recommended long edge (those models are
/// reachable via OpenRouter and OpenCode Zen) and sits comfortably under the
/// OpenAI and Gemini limits.
func aiImageSnapshot(from data: Data, maxSide: Int = 1568) -> AiPageImageSnapshot? {
    guard let rep = NSBitmapImageRep(data: data) else { return nil }
    let sourceWidth = rep.pixelsWide, sourceHeight = rep.pixelsHigh
    guard sourceWidth > 0, sourceHeight > 0 else { return nil }

    let longest = max(sourceWidth, sourceHeight)
    let scale = longest > maxSide ? Double(maxSide) / Double(longest) : 1
    let width = max(1, Int((Double(sourceWidth) * scale).rounded()))
    let height = max(1, Int((Double(sourceHeight) * scale).rounded()))
    let hasAlpha = rep.hasAlpha

    // Always draw into an RGBA buffer, even for an opaque source: CoreGraphics
    // has no 24-bit backing store, so `NSGraphicsContext(bitmapImageRep:)`
    // returns nil for a 3-sample rep. The alpha channel is simply dropped again
    // by the JPEG encoder below.
    guard let out = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
        isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
    ), let context = NSGraphicsContext(bitmapImageRep: out) else { return nil }

    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = context
    context.imageInterpolation = .high
    let target = NSRect(x: 0, y: 0, width: CGFloat(width), height: CGFloat(height))
    if !hasAlpha {
        // Flatten onto white so a JPEG-bound image can't pick up the untouched
        // buffer's transparency as black.
        NSColor.white.setFill()
        target.fill()
    }
    rep.draw(in: target, from: .zero, operation: hasAlpha ? .copy : .sourceOver,
             fraction: 1, respectFlipped: true, hints: nil)
    NSGraphicsContext.restoreGraphicsState()

    // Alpha survives only in PNG; opaque images go to JPEG, which is far smaller
    // for photographs (the common case for a dropped file).
    var encoded: Data?
    var mediaType = "image/png"
    if hasAlpha {
        encoded = out.representation(using: .png, properties: [:])
    } else {
        mediaType = "image/jpeg"
        encoded = out.representation(using: .jpeg, properties: [.compressionFactor: 0.8])
    }

    // Per-image byte ceilings are real (Anthropic rejects above 5 MB); re-encode
    // rather than let the request fail at the provider. JPEG even for an alpha
    // image at this point — a >4 MB PNG is a photo-sized image whose transparency
    // is worth less than the request going through.
    if let current = encoded, current.count > 4 * 1_024 * 1_024 {
        if let smaller = out.representation(using: .jpeg, properties: [.compressionFactor: 0.6]) {
            encoded = smaller
            mediaType = "image/jpeg"
        }
    }

    guard let bytes = encoded else { return nil }
    return AiPageImageSnapshot(
        pageNumber: nil,
        base64Data: bytes.base64EncodedString(),
        mediaType: mediaType,
        width: width,
        height: height
    )
}
