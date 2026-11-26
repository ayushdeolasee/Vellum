import Foundation

public enum PdfOutlineIncrement {
    /// /Title for a bookmark with no user title.
    public static func defaultTitle(pageNumber: Int) -> String {
        "Bookmark - page \(pageNumber)"
    }

    // MARK: - Creation (incremental update)

    /// create_bookmark: new outline item appended at the end of the root's
    /// sibling list, root /First//Last//Count updated. Returns the supplied
    /// classic-xref data with the update appended.
    /// A non-empty `content` is the user title: stored in /VellumContent and
    /// mirrored into /Title.
    public static func createBookmarkIncrement(
        normalizedData: Data,
        pageNumber: Int,
        id: String,
        content: String? = nil,
        now: String
    ) throws -> Data {
        let file = try ClassicPdfFile(data: normalizedData)
        guard let catalogNumber = file.rootNumber, var catalog = file.objectSource(catalogNumber) else {
            throw PdfCoreError.invalidDocument("PDF has no catalog")
        }
        guard let pageObjectNumber = pageObjectNumber(in: file, catalog: catalog, pageNumber: pageNumber) else {
            throw PdfCoreError.invalidDocument("Page \(pageNumber) does not exist")
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

        let title = content?.isEmpty == false ? content! : defaultTitle(pageNumber: pageNumber)
        var bookmark: [UInt8] = Array("<< /Title ".utf8)
        bookmark.append(contentsOf: PdfTextString.encode(title))
        bookmark.append(contentsOf: Array(" /Parent \(outlinesNumber) 0 R /Dest [\(pageObjectNumber) 0 R /Fit] /VellumType /Bookmark /VellumNM ".utf8))
        bookmark.append(contentsOf: PdfTextString.encode(id))
        bookmark.append(contentsOf: Array(" /VellumCreatedAt ".utf8))
        bookmark.append(contentsOf: PdfTextString.encode(now))
        bookmark.append(contentsOf: Array(" /VellumUpdatedAt ".utf8))
        bookmark.append(contentsOf: PdfTextString.encode(now))
        if let content, !content.isEmpty {
            bookmark.append(contentsOf: Array(" /VellumContent ".utf8))
            bookmark.append(contentsOf: PdfTextString.encode(content))
        }
        if let lastNumber {
            bookmark.append(contentsOf: Array(" /Prev \(lastNumber) 0 R".utf8))
        }
        bookmark.append(contentsOf: Array(" >>".utf8))
        increment.setObject(bookmarkNumber, source: bookmark)

        if let lastNumber {
            guard var previous = file.objectSource(lastNumber) else {
                throw PdfCoreError.invalidDocument("Failed to update PDF outline: missing outline item")
            }
            previous.setReference(forKey: "Next", to: bookmarkNumber)
            increment.setObject(lastNumber, source: previous.sourceBytes)
        } else {
            root.setReference(forKey: "First", to: bookmarkNumber)
        }
        root.setReference(forKey: "Last", to: bookmarkNumber)
        adjustOutlineCount(&root, delta: 1)
        increment.setObject(outlinesNumber, source: root.sourceBytes)

        return try increment.checkedAppend()
    }

    // MARK: - Update (incremental update)

    /// Walk catalog → /Outlines → outline tree for the Vellum bookmark
    /// carrying this id, returning its object number. nil when the document
    /// has no outline or no item matches.
    private static func findBookmarkNumber(in file: ClassicPdfFile, id: String) -> Int? {
        guard let catalogNumber = file.rootNumber, let catalog = file.objectSource(catalogNumber),
              let outlinesNumber = catalog.reference(forKey: "Outlines"),
              let root = file.objectSource(outlinesNumber)
        else { return nil }
        return findBookmarkObject(in: file, rootNumber: outlinesNumber, root: root, id: id)
    }

    /// Retitle a bookmark: set /VellumContent and mirror it into /Title, or —
    /// when `content` is empty — clear the title back to `defaultTitle`.
    /// /VellumUpdatedAt always refreshes. Returns nil when no Vellum bookmark
    /// carries the id.
    public static func updateBookmarkIncrement(
        normalizedData: Data,
        id: String,
        content: String,
        defaultTitle: String,
        now: String
    ) throws -> Data? {
        let file = try ClassicPdfFile(data: normalizedData)
        guard let bookmarkNumber = findBookmarkNumber(in: file, id: id),
              var bookmark = file.objectSource(bookmarkNumber)
        else { return nil }

        if content.isEmpty {
            bookmark.removeEntry(forKey: "VellumContent")
            bookmark.setTextString(forKey: "Title", to: defaultTitle)
        } else {
            bookmark.setTextString(forKey: "VellumContent", to: content)
            bookmark.setTextString(forKey: "Title", to: content)
        }
        bookmark.setTextString(forKey: "VellumUpdatedAt", to: now)

        var increment = PdfIncrement(file: file)
        increment.setObject(bookmarkNumber, source: bookmark.sourceBytes)
        return try increment.checkedAppend()
    }

    /// Patch pin state on an outline bookmark. Returns nil when no Vellum
    /// bookmark carries the id. PDFKit cannot write custom keys on outline
    /// items, so this rewrites the outline object in place.
    public static func updateBookmarkIncrement(
        normalizedData: Data,
        id: String,
        isPinned: Bool,
        now: String
    ) throws -> Data? {
        let file = try ClassicPdfFile(data: normalizedData)
        guard let bookmarkNumber = findBookmarkNumber(in: file, id: id),
              var bookmark = file.objectSource(bookmarkNumber)
        else { return nil }

        bookmark.setInteger(forKey: "VellumPinned", to: isPinned ? 1 : 0)
        bookmark.setValue(forKey: "VellumUpdatedAt", raw: PdfTextString.encode(now))

        var increment = PdfIncrement(file: file)
        increment.setObject(bookmarkNumber, source: bookmark.sourceBytes)
        return try increment.checkedAppend()
    }

    // MARK: - Deletion (incremental update)

    /// delete_bookmark: unlink the item from its sibling chain, fix parent
    /// /First//Last, adjust /Count, drop the object. Returns nil when no
    /// Vellum bookmark carries the id.
    public static func deleteBookmarkIncrement(normalizedData: Data, id: String) throws -> Data? {
        let file = try ClassicPdfFile(data: normalizedData)
        guard let bookmarkNumber = findBookmarkNumber(in: file, id: id) else { return nil }

        guard let bookmark = file.objectSource(bookmarkNumber) else {
            throw PdfCoreError.invalidDocument("Failed to read PDF bookmark: missing object")
        }
        guard let parentNumber = bookmark.reference(forKey: "Parent") else {
            throw PdfCoreError.invalidDocument("PDF bookmark has no outline parent: missing /Parent")
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
                throw PdfCoreError.invalidDocument(error)
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
        return try increment.checkedAppend()
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
    private static func adjustOutlineCount(_ dictionary: inout PdfDictSource, delta: Int) {
        let count = dictionary.integer(forKey: "Count") ?? 0
        let next = count < 0 ? count - delta : max(count + delta, 0)
        dictionary.setInteger(forKey: "Count", to: next)
    }

    /// Object number of the 1-based page, walking the /Pages tree depth-first.
    public static func pageObjectNumber(in file: ClassicPdfFile, catalog: PdfDictSource, pageNumber: Int) -> Int? {
        guard let pagesNumber = catalog.reference(forKey: "Pages") else { return nil }
        var counter = 0
        var visited: Set<Int> = []
        var pending = [pagesNumber]
        while let number = pending.popLast() {
            guard visited.insert(number).inserted, let node = file.objectSource(number) else { continue }
            if node.name(forKey: "Type") == "Page" {
                counter += 1
                if counter == pageNumber { return number }
            } else if let kids = file.resolvedValue(forKey: "Kids", in: node),
                      let references = PdfArraySource.references(inArray: kids) {
                pending.append(contentsOf: references.reversed())
            }
        }
        return nil
    }
}
