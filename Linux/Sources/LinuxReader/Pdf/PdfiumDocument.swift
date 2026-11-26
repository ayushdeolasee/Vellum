import CPdfiumJob
import Foundation
import VellumCore

public enum PdfiumError: Error, Equatable {
    case invalidDocument, passwordRequired, unsupportedSecurity, invalidPage
    case invalidDimensions, limitExceeded, engineFailure, queueFull, closed
}

public struct PdfiumPageInfo: Sendable {
    public let pageCount: Int
    /// Cropped display size in points, including intrinsic rotation.
    public let widthPt, heightPt: Double
    /// Lower-left origin of the visible media/crop intersection in unrotated PDF user space.
    public let visibleLeft, visibleBottom: Double
    public let rotation: Int
}

public struct PdfiumBitmap: Sendable {
    public let width, height, bytesPerRow: Int
    /// Top-down, tightly packed BGRA with opaque alpha (GDK_MEMORY_B8G8R8A8).
    public let pixels: Data
}

public struct PdfiumCharBox: Sendable {
    public let utf16Index: Int
    /// Source UTF-16 unit. String decoding replaces an isolated surrogate with U+FFFD.
    public let codeUnit: UInt16
    /// Unrotated PDF user space. Generated separators can have zero-area boxes.
    public let left, bottom, right, top: Double
    public let isGenerated: Bool
    let selectionBounds: AnnotationRect
    let baseline: Double
    let isDiscretionaryHyphen: Bool
}

public struct PdfiumPageText: Sendable {
    public let text: String
    public let chars: [PdfiumCharBox]
    public let geometry: PageGeometry
}

/// Operations accept the bytes read by the root-confined store, and zero-based page indices.
public enum PdfiumDocument {
    public static let maxInputBytes = Int(PDF_MAX_INPUT_BYTES)

    /// Selection only. A PDF Name can have the same PDFium text as a String,
    /// so require the typed value from the original bytes to agree.
    public static func openingInfo(in bytes: Data, password: String? = nil) async throws
        -> (pageCount: Int, stableIdentifier: String?) {
        try await job(PDF_OPEN_INFO, bytes, 0, password, .onDemand) { out in
            let id = withUnsafeBytes(of: out.document_id) { raw in
                String(decoding: raw.bindMemory(to: UInt16.self).prefix(out.document_id_units), as: UTF16.self)
            }
            return (Int(out.pages), SharedPDFIdentity.stamp(in: bytes, readerID: id))
        }
    }

    public static func pageInfo(in bytes: Data, at index: Int, password: String? = nil,
                                priority: PdfiumActor.Priority = .onDemand) async throws -> PdfiumPageInfo {
        try await job(PDF_INFO, bytes, index, password, priority) { out in
            PdfiumPageInfo(pageCount: Int(out.pages), widthPt: out.width_pt,
                           heightPt: out.height_pt, visibleLeft: out.visible_left,
                           visibleBottom: out.visible_bottom, rotation: Int(out.rotation))
        }
    }

    public static func render(in bytes: Data, at index: Int, scale: Double, password: String? = nil,
                              priority: PdfiumActor.Priority = .onDemand) async throws -> PdfiumBitmap {
        guard scale.isFinite, scale > 0 else { throw PdfiumError.invalidDimensions }
        return try await job(PDF_BITMAP, bytes, index, password, priority, scale: scale) { out in
            let stride = Int(out.stride), height = Int(out.height)
            return PdfiumBitmap(width: Int(out.width), height: height, bytesPerRow: stride,
                                pixels: Data(bytesNoCopy: out.pixels!, count: stride * height, deallocator: .free))
        }
    }

    public static func extractText(in bytes: Data, at index: Int, password: String? = nil,
                                   priority: PdfiumActor.Priority = .onDemand) async throws -> PdfiumPageText {
        try await job(PDF_TEXT, bytes, index, password, priority) { out in
            defer { free(out.characters) }
            let characters = UnsafeBufferPointer(start: out.characters, count: Int(out.character_count))
            var units: [UInt16] = []
            var boxes: [PdfiumCharBox] = []
            units.reserveCapacity(characters.count)
            boxes.reserveCapacity(characters.count)
            for c in characters {
                func append(_ unit: UInt16) {
                    boxes.append(PdfiumCharBox(utf16Index: units.count, codeUnit: unit, left: c.left,
                                               bottom: c.bottom, right: c.right, top: c.top,
                                               isGenerated: c.generated,
                                               selectionBounds: AnnotationRect(
                                                   x: c.selection_left, y: c.selection_bottom,
                                                   width: c.selection_right - c.selection_left,
                                                   height: c.selection_top - c.selection_bottom),
                                               baseline: c.origin_y, isDiscretionaryHyphen: c.discretionary_hyphen))
                    units.append(unit)
                }
                // PDFium may supply UTF-16 surrogate units or a full scalar.
                // Unmapped characters (zero) still occupy a place in the text.
                switch c.unicode {
                case 1...0xffff: append(UInt16(c.unicode))
                case 0x10000...0x10ffff:
                    let value = c.unicode - 0x10000
                    append(UInt16(0xd800 + (value >> 10)))
                    append(UInt16(0xdc00 + (value & 0x3ff)))
                default: append(0xfffd)
                }
            }
            // Use the same effective page box and scale as PDFium rendering.
            let geometry = PageGeometry(left: out.visible_left, bottom: out.visible_bottom,
                                        width: out.visible_right - out.visible_left,
                                        height: out.visible_top - out.visible_bottom,
                                        rotation: Int(out.rotation), userUnit: 1)
            return PdfiumPageText(text: String(decoding: units, as: UTF16.self), chars: boxes, geometry: geometry)
        }
    }

    /// Extract and arrange text from the same validated bytes used for rendering.
    public static func readText(in bytes: Data, at index: Int, password: String? = nil,
                                priority: PdfiumActor.Priority = .onDemand) async throws -> ExtractedPageText {
        let raw = try await extractText(in: bytes, at: index, password: password, priority: priority)
        let layout = Task.detached(priority: priority == .onDemand ? .userInitiated : .utility) {
            try PdfTextReadingOrder.sort(raw)
        }
        return try await withTaskCancellationHandler {
            let page = try await layout.value
            try Task.checkCancellation()
            return page
        } onCancel: {
            layout.cancel()
        }
    }

    private static func job<T: Sendable>(_ operation: PdfOperation, _ bytes: Data, _ index: Int,
                                         _ password: String?, _ priority: PdfiumActor.Priority,
                                         scale: Double = 1,
                                         consume: @escaping @Sendable (PdfJobResult) -> T) async throws -> T {
        guard !bytes.isEmpty else { throw PdfiumError.invalidDocument }
        guard bytes.count <= maxInputBytes else { throw PdfiumError.limitExceeded }
        guard let page = Int32(exactly: index), page >= 0 else { throw PdfiumError.invalidPage }
        // A C string would silently accept a valid prefix before an embedded NUL.
        if let password {
            guard password.utf8.count <= 4096 else { throw PdfiumError.limitExceeded }
            guard !password.utf8.contains(0) else { throw PdfiumError.passwordRequired }
        }
        return try await PdfiumActor.shared.run(priority: priority, byteCount: bytes.count) {
            var out = PdfJobResult()
            let status = bytes.withUnsafeBytes { buffer in
                pdf_run_job(operation, buffer.baseAddress, buffer.count, password, page, scale, &out)
            }
            switch status {
            case PDF_OK: return consume(out)
            case PDF_BAD_DOCUMENT: throw PdfiumError.invalidDocument
            case PDF_PASSWORD_REQUIRED: throw PdfiumError.passwordRequired
            case PDF_SECURITY_ERROR: throw PdfiumError.unsupportedSecurity
            case PDF_BAD_PAGE: throw PdfiumError.invalidPage
            case PDF_BAD_DIMENSIONS: throw PdfiumError.invalidDimensions
            case PDF_LIMIT: throw PdfiumError.limitExceeded
            default: throw PdfiumError.engineFailure
            }
        }
    }
}
