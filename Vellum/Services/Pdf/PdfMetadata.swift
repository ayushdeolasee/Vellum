import Foundation
import CoreGraphics
import PDFKit
import VellumCore

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
    /// A crafted PDF could embed a traversal string (`../../…`) as /VellumDocId;
    /// only a CANONICAL id (lowercase UUID / bare-hex sha256 — the sole forms a
    /// genuine stamp takes) may become a storage key, so a non-conforming value
    /// is treated as "unstamped" and the file falls back to its path-hash
    /// identity instead of letting the attacker choose a folder name.
    static func documentId(_ document: CGPDFDocument) -> String? {
        guard let raw = document.info.flatMap({ CgPdf.string($0, "VellumDocId") }) else { return nil }
        return DocumentIdentity.isCanonicalKey(raw) ? raw : nil
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

    static func setMetadataIncrement(normalizedData: Data, key: String, value: String) throws -> Data {
        try setMetadataIncrement(normalizedData: normalizedData, entries: [(key: key, value: value)])
    }

    static func setMetadataIncrement(normalizedData: Data, entries: [(key: String, value: String)]) throws -> Data {
        try SessionServiceError.translatingPdfErrors {
            try PdfInfoIncrement.setMetadataIncrement(normalizedData: normalizedData, entries: entries)
        }
    }

    /// Stamp `/VellumDocId` into a brand-new file at `path`, in place. Used by
    /// `.vellum` import: the written PDF carried no stamp, so — left alone — its
    /// reopen would resolve `sha256(path)` and then get a FRESH UUID, orphaning
    /// the sidecar just installed under the manifest's id. Stamping the manifest
    /// id now makes the reopen key match.
    ///
    /// iPadOS 26's PDFKit serializer drops custom Info keys, so a
    /// normalize-then-stamp round trip would erase /VellumLastPage and
    /// friends. The increment is a pure byte append, so try it against the
    /// file's own bytes first; only fall back to PDFKit normalization when
    /// the file's xref shape defeats ClassicPdfFile.
    ///
    /// It deliberately does NOT reload through PDFDocument before writing:
    /// production never round-trips a custom Info key through
    /// `dataRepresentation()`, and CGPDF reads the increment-appended
    /// /VellumDocId back correctly, so this is the proven-readable form. No
    /// page-text cache refresh — a just-written file has no cache entry. Throws on
    /// any parse/serialize/write failure so the caller can fall back to its prior
    /// behavior.
    static func stampDocumentId(atPath path: String, id: String) throws {
        if let original = try? PdfDocumentLoader.readFile(path),
           let stamped = try? setMetadataIncrement(
               normalizedData: original, entries: [(key: "doc_id", value: id)]) {
            try PdfAtomicWriter.save(stamped, toPath: path)
            return
        }
        let (document, _) = try PdfDocumentLoader.loadForMutation(path: path)
        guard let normalized = document.dataRepresentation() else {
            throw SessionServiceError.io("Failed to stamp document id: PDFKit produced no data")
        }
        let stamped = try setMetadataIncrement(
            normalizedData: normalized, entries: [(key: "doc_id", value: id)])
        try PdfAtomicWriter.save(stamped, toPath: path)
    }
}
