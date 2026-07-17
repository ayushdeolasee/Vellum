import Foundation
import CoreGraphics
import PDFKit

// Info-dictionary metadata — port of set_metadata / document_info /
// ensure_info_dictionary / metadata_key_suffix / object_u32 from
// src-tauri/src/pdf_annotations.rs.
//
// Reads go through CGPDF (trailer /Info handles direct or referenced
// dictionaries transparently). Writes are applied as an in-memory incremental
// update on PDFKit-normalized data because PDFKit neither exposes custom Info
// keys through documentAttributes on load nor reliably writes new ones; the
// caller reloads the patched data through PDFKit for the clean full rewrite
// (existing raw Info entries are preserved by PDFKit's serializer).

enum PdfMetadata {
    /// document_info: (title, page_count, last_page, doc_id). Title falls back
    /// to the file stem; last_page accepts an integer or a numeric text string;
    /// doc_id is the /VellumDocId text string (nil until the file is stamped).
    static func documentInfo(document: CGPDFDocument, path: String)
        -> (title: String?, pageCount: Int, lastPage: Int?, docId: String?) {
        let info = document.info
        let title = info.flatMap { CgPdf.string($0, "Title") }
            ?? URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent
        let lastPage = info.flatMap { dictionary -> Int? in
            guard let object = CgPdf.object(dictionary, "VellumLastPage") else { return nil }
            return objectU32(object)
        }
        return (title, document.numberOfPages, lastPage, documentId(document))
    }

    /// The /VellumDocId text string, or nil when the file has not been stamped.
    static func documentId(_ document: CGPDFDocument) -> String? {
        document.info.flatMap { CgPdf.string($0, "VellumDocId") }
    }

    /// Read a raw file's /VellumDocId without opening a session — used by the
    /// Storage pane's Relink flow to confirm a re-located PDF is the same
    /// document (its embedded id must still match the orphaned entry's key).
    /// nil when the file is unreadable or was never stamped.
    static func documentId(atPath path: String) -> String? {
        guard let raw = try? PdfDocumentLoader.loadRaw(path: path) else { return nil }
        return documentId(raw)
    }

    /// object_u32: Integer (non-negative) or numeric text string.
    static func objectU32(_ object: CGPDFObjectRef) -> Int? {
        if let integer = CgPdf.objectInteger(object) {
            return integer >= 0 && integer <= Int(UInt32.max) ? integer : nil
        }
        if let string = CgPdf.objectString(object) {
            return UInt32(string).map(Int.init)
        }
        return nil
    }

    /// set_metadata as an incremental update: `page_count` is a no-op handled
    /// by the caller; `title` sets /Title; `last_page` sets /VellumLastPage as
    /// an integer; anything else sets /Vellum{PascalCase} as a text string.
    static func setMetadataIncrement(normalizedData: Data, key: String, value: String) throws -> Data {
        try setMetadataIncrement(normalizedData: normalizedData, entries: [(key: key, value: value)])
    }

    /// Fold several metadata entries into a SINGLE incremental Info update — one
    /// new/replaced Info object, one xref section, one write. Used to piggyback
    /// a lazy doc_id stamp onto a metadata write that was happening anyway, so
    /// the file is still rewritten only once per user action.
    static func setMetadataIncrement(normalizedData: Data, entries: [(key: String, value: String)]) throws -> Data {
        let file = try ClassicPdfFile(data: normalizedData)

        var increment = PdfIncrement(file: file)
        var infoNumber: Int
        var info: PdfDictSource
        if let existing = file.infoNumber, let source = file.objectSource(existing) {
            infoNumber = existing
            info = source
        } else {
            // ensure_info_dictionary: promote a direct trailer /Info to an
            // indirect object (preserving its entries), else create an empty
            // one, and point the trailer at it.
            infoNumber = increment.allocateObjectNumber()
            if let inline = file.trailer.inlineDictionary(forKey: "Info") {
                info = PdfDictSource(inline)
            } else {
                info = PdfDictSource(Array("<< >>".utf8))
            }
        }

        for (key, value) in entries {
            switch key {
            case "title":
                info.setValue(forKey: "Title", raw: PdfTextString.encode(value))
            case "last_page":
                let page = try parseLastPage(value)
                info.setValue(forKey: "VellumLastPage", raw: Array("\(page)".utf8))
            default:
                info.setValue(forKey: "Vellum\(metadataKeySuffix(key))", raw: PdfTextString.encode(value))
            }
        }

        increment.setObject(infoNumber, source: info.sourceBytes)
        return increment.appended(infoNumber: infoNumber)
    }

    /// Stamp `/VellumDocId` into a brand-new file at `path`, in place. Used by
    /// `.vellum` import: the written PDF carried no stamp, so — left alone — its
    /// reopen would resolve `sha256(path)` and then get a FRESH UUID, orphaning
    /// the sidecar just installed under the manifest's id. Stamping the manifest
    /// id now makes the reopen key match.
    ///
    /// Mirrors `PdfDocumentIO`'s lazy stamp exactly (loadForMutation → PDFKit
    /// serialize → single doc_id Info increment → atomic-write of the
    /// increment-patched bytes). It deliberately does NOT reload through
    /// PDFDocument before writing: production never round-trips a custom Info key
    /// through `dataRepresentation()`, and CGPDF reads the increment-appended
    /// /VellumDocId back correctly, so this is the proven-readable form. No
    /// page-text cache refresh — a just-written file has no cache entry. Throws on
    /// any parse/serialize/write failure so the caller can fall back to its prior
    /// behavior.
    static func stampDocumentId(atPath path: String, id: String) throws {
        let (document, _) = try PdfDocumentLoader.loadForMutation(path: path)
        guard let normalized = document.dataRepresentation() else {
            throw SessionServiceError.io("Failed to stamp document id: PDFKit produced no data")
        }
        let stamped = try setMetadataIncrement(
            normalizedData: normalized, entries: [(key: "doc_id", value: id)])
        try PdfAtomicWriter.save(stamped, toPath: path)
    }

    /// u32::from_str error surface, mirrored: empty / non-digit / overflow.
    static func parseLastPage(_ value: String) throws -> UInt32 {
        if value.isEmpty {
            throw SessionServiceError.invalidDocument("Invalid last_page value: cannot parse integer from empty string")
        }
        var digits = Substring(value)
        if digits.first == "+" { digits = digits.dropFirst() }
        guard !digits.isEmpty, digits.allSatisfy({ $0.isASCII && $0.isNumber }) else {
            throw SessionServiceError.invalidDocument("Invalid last_page value: invalid digit found in string")
        }
        guard let page = UInt32(digits) else {
            throw SessionServiceError.invalidDocument("Invalid last_page value: number too large to fit in target type")
        }
        return page
    }

    /// metadata_key_suffix: split on '_', uppercase each segment's first
    /// character, concatenate ("reading_theme" → "ReadingTheme").
    static func metadataKeySuffix(_ key: String) -> String {
        key.split(separator: "_", omittingEmptySubsequences: true)
            .map { segment -> String in
                guard let first = segment.first else { return "" }
                return String(first).uppercased() + segment.dropFirst()
            }
            .joined()
    }
}
