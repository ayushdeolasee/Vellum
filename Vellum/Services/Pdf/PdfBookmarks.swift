import Foundation
import CoreGraphics
import VellumCore

// Outline bookmarks — port of create_bookmark / read_bookmarks /
// delete_bookmark / ensure_outlines_root / is_vellum_outline /
// adjust_outline_count from src-tauri/src/pdf_annotations.rs.
//
// Bookmarks are standard /Outlines items carrying /VellumType /Bookmark,
// /VellumNM (the id) and Vellum timestamps. PDFKit can neither write custom
// keys on outline items nor persist PDFOutline tree mutations (its serializer
// re-emits the raw outline dictionaries), so creation and deletion are done as
// in-memory incremental updates on PDFKit-normalized data (see PdfIncrement);
// the caller then reloads the patched data through PDFKit and performs a clean
// full rewrite. Reads walk the raw outline tree through CGPDF, so items
// written by the Rust app are recognized as-is.

enum PdfBookmarks {
    // MARK: - Reading

    /// read_bookmarks: every outline item that passes is_vellum_outline, mapped
    /// to its destination page, optionally filtered by page number.
    static func readBookmarks(document: CGPDFDocument, pageNumber: Int?) -> [Annotation] {
        guard let catalog = document.catalog,
              let outlines = CgPdf.dictionary(catalog, "Outlines")
        else { return [] }

        var pageNumbers: [CGPDFDictionaryRef: Int] = [:]
        let pageCount = document.numberOfPages
        if pageCount > 0 {
            for index in 1...pageCount {
                if let dictionary = document.page(at: index)?.dictionary {
                    pageNumbers[dictionary] = index
                }
            }
        }

        var bookmarks: [Annotation] = []
        var visited: Set<CGPDFDictionaryRef> = []

        func walk(_ first: CGPDFDictionaryRef?) {
            var item = first
            while let current = item {
                guard visited.insert(current).inserted else { return }
                if isVellumOutline(current),
                   let id = CgPdf.string(current, "VellumNM"),
                   let destinationPage = outlinePage(of: current),
                   let page = pageNumbers[destinationPage],
                   pageNumber == nil || pageNumber == page
                {
                    let now = PdfDates.rfc3339Now()
                    // The user title lives in /VellumContent; /Title mirrors it
                    // for external viewers and holds the default when untitled.
                    let content = CgPdf.string(current, "VellumContent")
                    let isPinned = CgPdf.integer(current, "VellumPinned") == 1 ? true : nil
                    bookmarks.append(Annotation(
                        id: id,
                        type: .bookmark,
                        pageNumber: page,
                        color: nil,
                        content: content?.isEmpty == false ? content : nil,
                        positionData: nil,
                        createdAt: CgPdf.string(current, "VellumCreatedAt") ?? now,
                        updatedAt: CgPdf.string(current, "VellumUpdatedAt") ?? now,
                        isPinned: isPinned))
                }
                walk(CgPdf.dictionary(current, "First"))
                item = CgPdf.dictionary(current, "Next")
            }
        }
        walk(CgPdf.dictionary(outlines, "First"))
        return bookmarks
    }

    /// is_vellum_outline: no /Subtype, /VellumType name == Bookmark, has
    /// /VellumNM and /Title.
    static func isVellumOutline(_ dictionary: CGPDFDictionaryRef) -> Bool {
        !CgPdf.has(dictionary, "Subtype")
            && CgPdf.name(dictionary, "VellumType") == "Bookmark"
            && CgPdf.has(dictionary, "VellumNM")
            && CgPdf.has(dictionary, "Title")
    }

    /// outline_page_id: first element of the (possibly referenced) /Dest array.
    static func outlinePage(of dictionary: CGPDFDictionaryRef) -> CGPDFDictionaryRef? {
        guard let destination = CgPdf.array(dictionary, "Dest") else { return nil }
        return CgPdf.dictionaryAt(destination, 0)
    }

    /// True when the raw outline tree contains a Vellum bookmark with this id
    /// (used to route delete_annotation to the outline path first).
    static func containsBookmark(document: CGPDFDocument, id: String) -> Bool {
        guard let catalog = document.catalog,
              let outlines = CgPdf.dictionary(catalog, "Outlines")
        else { return false }
        var found = false
        var visited: Set<CGPDFDictionaryRef> = []
        func walk(_ first: CGPDFDictionaryRef?) {
            var item = first
            while let current = item, !found {
                guard visited.insert(current).inserted else { return }
                if isVellumOutline(current), CgPdf.string(current, "VellumNM") == id {
                    found = true
                    return
                }
                walk(CgPdf.dictionary(current, "First"))
                item = CgPdf.dictionary(current, "Next")
            }
        }
        walk(CgPdf.dictionary(outlines, "First"))
        return found
    }

    static func createBookmarkIncrement(
        normalizedData: Data, pageNumber: Int, id: String, content: String? = nil, now: String
    ) throws -> Data {
        try SessionServiceError.translatingPdfErrors {
            try PdfOutlineIncrement.createBookmarkIncrement(
                normalizedData: normalizedData, pageNumber: pageNumber, id: id, content: content, now: now)
        }
    }

    static func updateBookmarkIncrement(
        normalizedData: Data, id: String, content: String, defaultTitle: String, now: String
    ) throws -> Data? {
        try SessionServiceError.translatingPdfErrors {
            try PdfOutlineIncrement.updateBookmarkIncrement(
                normalizedData: normalizedData, id: id, content: content, defaultTitle: defaultTitle, now: now)
        }
    }

    static func updateBookmarkIncrement(normalizedData: Data, id: String, isPinned: Bool, now: String) throws -> Data? {
        try SessionServiceError.translatingPdfErrors {
            try PdfOutlineIncrement.updateBookmarkIncrement(normalizedData: normalizedData, id: id, isPinned: isPinned, now: now)
        }
    }

    static func deleteBookmarkIncrement(normalizedData: Data, id: String) throws -> Data? {
        try SessionServiceError.translatingPdfErrors {
            try PdfOutlineIncrement.deleteBookmarkIncrement(normalizedData: normalizedData, id: id)
        }
    }
}
