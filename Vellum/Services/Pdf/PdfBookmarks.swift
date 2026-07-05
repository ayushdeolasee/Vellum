import Foundation
import CoreGraphics

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
                    bookmarks.append(Annotation(
                        id: id,
                        type: .bookmark,
                        pageNumber: page,
                        color: nil,
                        content: nil,
                        positionData: nil,
                        createdAt: CgPdf.string(current, "VellumCreatedAt") ?? now,
                        updatedAt: CgPdf.string(current, "VellumUpdatedAt") ?? now))
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

    // MARK: - Creation (incremental update)

    /// create_bookmark: new outline item appended at the end of the root's
    /// sibling list, root /First//Last//Count updated. `normalizedData` must be
    /// PDFKit-serializer output; returns that data with the update appended.
    static func createBookmarkIncrement(
        normalizedData: Data,
        pageNumber: Int,
        id: String,
        now: String
    ) throws -> Data {
        let file = try ClassicPdfFile(data: normalizedData)
        guard let catalogNumber = file.rootNumber, var catalog = file.objectSource(catalogNumber) else {
            throw SessionServiceError.invalidDocument("PDF has no catalog")
        }
        guard let pageObjectNumber = pageObjectNumber(in: file, catalog: catalog, pageNumber: pageNumber) else {
            throw SessionServiceError.invalidDocument("Page \(pageNumber) does not exist")
        }

        var increment = PdfIncrement(file: file)

        // ensure_outlines_root: use the referenced root, promote a direct
        // dictionary to an indirect object, or create a fresh root.
        let outlinesNumber: Int
        var root: PdfDictSource
        if let existing = catalog.reference(forKey: "Outlines"), let source = file.objectSource(existing) {
            outlinesNumber = existing
            root = source
        } else {
            outlinesNumber = increment.allocateObjectNumber()
            if let inline = catalog.inlineDictionary(forKey: "Outlines") {
                root = PdfDictSource(inline)
            } else {
                root = PdfDictSource(Array("<< /Type /Outlines /Count 0 >>".utf8))
            }
            catalog.setReference(forKey: "Outlines", to: outlinesNumber)
            increment.setObject(catalogNumber, source: catalog.sourceBytes)
        }

        let lastNumber = root.reference(forKey: "Last")
        let bookmarkNumber = increment.allocateObjectNumber()

        var bookmark: [UInt8] = Array("<< /Title ".utf8)
        bookmark.append(contentsOf: PdfTextString.encode("Bookmark - page \(pageNumber)"))
        bookmark.append(contentsOf: Array(" /Parent \(outlinesNumber) 0 R /Dest [\(pageObjectNumber) 0 R /Fit] /VellumType /Bookmark /VellumNM ".utf8))
        bookmark.append(contentsOf: PdfTextString.encode(id))
        bookmark.append(contentsOf: Array(" /VellumCreatedAt ".utf8))
        bookmark.append(contentsOf: PdfTextString.encode(now))
        bookmark.append(contentsOf: Array(" /VellumUpdatedAt ".utf8))
        bookmark.append(contentsOf: PdfTextString.encode(now))
        if let lastNumber {
            bookmark.append(contentsOf: Array(" /Prev \(lastNumber) 0 R".utf8))
        }
        bookmark.append(contentsOf: Array(" >>".utf8))
        increment.setObject(bookmarkNumber, source: bookmark)

        if let lastNumber {
            guard var previous = file.objectSource(lastNumber) else {
                throw SessionServiceError.invalidDocument("Failed to update PDF outline: missing outline item")
            }
            previous.setReference(forKey: "Next", to: bookmarkNumber)
            increment.setObject(lastNumber, source: previous.sourceBytes)
        } else {
            root.setReference(forKey: "First", to: bookmarkNumber)
        }
        root.setReference(forKey: "Last", to: bookmarkNumber)
        adjustOutlineCount(&root, delta: 1)
        increment.setObject(outlinesNumber, source: root.sourceBytes)

        return increment.appended()
    }

    // MARK: - Deletion (incremental update)

    /// delete_bookmark: unlink the item from its sibling chain, fix parent
    /// /First//Last, adjust /Count, drop the object. Returns nil when no
    /// Vellum bookmark carries the id.
    static func deleteBookmarkIncrement(normalizedData: Data, id: String) throws -> Data? {
        let file = try ClassicPdfFile(data: normalizedData)
        guard let catalogNumber = file.rootNumber, let catalog = file.objectSource(catalogNumber),
              let outlinesNumber = catalog.reference(forKey: "Outlines"),
              let root = file.objectSource(outlinesNumber)
        else { return nil }

        guard let bookmarkNumber = findBookmarkObject(
            in: file, rootNumber: outlinesNumber, root: root, id: id)
        else { return nil }

        guard let bookmark = file.objectSource(bookmarkNumber) else {
            throw SessionServiceError.invalidDocument("Failed to read PDF bookmark: missing object")
        }
        guard let parentNumber = bookmark.reference(forKey: "Parent") else {
            throw SessionServiceError.invalidDocument("PDF bookmark has no outline parent: missing /Parent")
        }
        let previousNumber = bookmark.reference(forKey: "Prev")
        let nextNumber = bookmark.reference(forKey: "Next")

        var increment = PdfIncrement(file: file)

        // Objects may be touched more than once (parent gets First/Last/Count
        // updates) — accumulate edits per object number.
        var edited: [Int: PdfDictSource] = [:]
        func source(_ number: Int, error: String) throws -> PdfDictSource {
            if let existing = edited[number] { return existing }
            guard let loaded = file.objectSource(number) else {
                throw SessionServiceError.invalidDocument(error)
            }
            return loaded
        }

        if let previousNumber {
            var previous = try source(previousNumber, error: "Failed to update previous PDF bookmark: missing object")
            if let nextNumber {
                previous.setReference(forKey: "Next", to: nextNumber)
            } else {
                previous.removeEntry(forKey: "Next")
            }
            edited[previousNumber] = previous
        } else {
            var parent = try source(parentNumber, error: "Failed to update PDF outline root: missing object")
            if let nextNumber {
                parent.setReference(forKey: "First", to: nextNumber)
            } else {
                parent.removeEntry(forKey: "First")
            }
            edited[parentNumber] = parent
        }

        if let nextNumber {
            var next = try source(nextNumber, error: "Failed to update next PDF bookmark: missing object")
            if let previousNumber {
                next.setReference(forKey: "Prev", to: previousNumber)
            } else {
                next.removeEntry(forKey: "Prev")
            }
            edited[nextNumber] = next
        } else {
            var parent = try source(parentNumber, error: "Failed to update PDF outline root: missing object")
            if let previousNumber {
                parent.setReference(forKey: "Last", to: previousNumber)
            } else {
                parent.removeEntry(forKey: "Last")
            }
            edited[parentNumber] = parent
        }

        var parent = try source(parentNumber, error: "Failed to update PDF outline count: missing object")
        adjustOutlineCount(&parent, delta: -1)
        edited[parentNumber] = parent

        for (number, source) in edited {
            increment.setObject(number, source: source.sourceBytes)
        }
        increment.setNull(bookmarkNumber)
        return increment.appended()
    }

    /// Walk the outline tree at the raw-object level to find the object NUMBER
    /// of the Vellum bookmark with this id.
    private static func findBookmarkObject(
        in file: ClassicPdfFile,
        rootNumber: Int,
        root: PdfDictSource,
        id: String
    ) -> Int? {
        var visited: Set<Int> = [rootNumber]
        var queue: [Int] = []
        if let first = root.reference(forKey: "First") { queue.append(first) }

        while let number = queue.popLast() {
            guard visited.insert(number).inserted else { continue }
            guard let item = file.objectSource(number) else { continue }
            if !item.hasKey("Subtype"),
               item.name(forKey: "VellumType") == "Bookmark",
               item.hasKey("Title"),
               item.textString(forKey: "VellumNM") == id
            {
                return number
            }
            if let next = item.reference(forKey: "Next") { queue.append(next) }
            if let first = item.reference(forKey: "First") { queue.append(first) }
        }
        return nil
    }

    // MARK: - Shared helpers

    /// adjust_outline_count: negative counts grow more negative; non-negative
    /// counts clamp at zero.
    static func adjustOutlineCount(_ dictionary: inout PdfDictSource, delta: Int) {
        let count = dictionary.integer(forKey: "Count") ?? 0
        let next = count < 0 ? count - delta : max(count + delta, 0)
        dictionary.setInteger(forKey: "Count", to: next)
    }

    /// Object number of the 1-based page, walking the /Pages tree depth-first.
    static func pageObjectNumber(in file: ClassicPdfFile, catalog: PdfDictSource, pageNumber: Int) -> Int? {
        guard let pagesNumber = catalog.reference(forKey: "Pages") else { return nil }
        var counter = 0
        var visited: Set<Int> = []

        func visit(_ number: Int) -> Int? {
            guard visited.insert(number).inserted, let node = file.objectSource(number) else { return nil }
            if node.name(forKey: "Type") == "Page" {
                counter += 1
                return counter == pageNumber ? number : nil
            }
            for kid in kidReferences(of: node) {
                if let found = visit(kid) { return found }
            }
            return nil
        }
        return visit(pagesNumber)
    }

    /// Object numbers in a /Kids array (parsed from the raw source).
    private static func kidReferences(of node: PdfDictSource) -> [Int] {
        // The /Kids value is an array of references: [ 3 0 R 4 0 R ... ].
        guard node.hasKey("Kids") else { return [] }
        let source = node.sourceBytes
        // Locate "/Kids" then the bracketed span; parse "N G R" triples.
        guard let keyRange = PdfBytes.firstRange(of: Array("/Kids".utf8), in: source) else { return [] }
        var i = keyRange.upperBound
        while i < source.count, PdfBytes.isWhitespace(source[i]) { i += 1 }
        guard i < source.count, source[i] == UInt8(ascii: "[") else { return [] }
        var depth = 0
        var end = i
        while end < source.count {
            if source[end] == UInt8(ascii: "[") { depth += 1 }
            if source[end] == UInt8(ascii: "]") {
                depth -= 1
                if depth == 0 { break }
            }
            end += 1
        }
        guard end > i else { return [] }

        var references: [Int] = []
        var j = i + 1
        while j < end {
            while j < end, !PdfBytes.isDigit(source[j]) { j += 1 }
            guard j < end else { break }
            var number = 0
            while j < end, PdfBytes.isDigit(source[j]) { number = number * 10 + Int(source[j] - 0x30); j += 1 }
            while j < end, PdfBytes.isWhitespace(source[j]) { j += 1 }
            var sawGeneration = false
            while j < end, PdfBytes.isDigit(source[j]) { j += 1; sawGeneration = true }
            while j < end, PdfBytes.isWhitespace(source[j]) { j += 1 }
            if sawGeneration, j < end, source[j] == UInt8(ascii: "R") {
                references.append(number)
                j += 1
            }
        }
        return references
    }
}
