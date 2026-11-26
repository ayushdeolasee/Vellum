import Foundation

public enum PdfInfoIncrement {
    /// set_metadata as an incremental update: `page_count` is a no-op handled
    /// by the caller; `title` sets /Title; `last_page` sets /VellumLastPage as
    /// an integer; anything else sets /Vellum{PascalCase} as a text string.
    public static func setMetadataIncrement(normalizedData: Data, key: String, value: String) throws -> Data {
        try setMetadataIncrement(normalizedData: normalizedData, entries: [(key: key, value: value)])
    }

    /// Fold several metadata entries into a SINGLE incremental Info update — one
    /// new/replaced Info object, one xref section, one write. Used to piggyback
    /// a lazy doc_id stamp onto a metadata write that was happening anyway, so
    /// the file is still rewritten only once per user action.
    public static func setMetadataIncrement(normalizedData: Data, entries: [(key: String, value: String)]) throws -> Data {
        try setMetadataIncrement(normalizedData: normalizedData, entries: entries, requiringAbsentKey: nil)
    }

    static func setMetadataIncrement(normalizedData: Data, entries: [(key: String, value: String)],
                                     requiringAbsentKey: String?) throws -> Data {
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

        if let key = requiringAbsentKey, info.hasKey(key) {
            throw PdfCoreError.invalidDocument("PDF already has /\(key)")
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

    /// u32::from_str error surface, mirrored: empty / non-digit / overflow.
    static func parseLastPage(_ value: String) throws -> UInt32 {
        if value.isEmpty {
            throw PdfCoreError.invalidDocument("Invalid last_page value: cannot parse integer from empty string")
        }
        var digits = Substring(value)
        if digits.first == "+" { digits = digits.dropFirst() }
        guard !digits.isEmpty, digits.allSatisfy({ $0.isASCII && $0.isNumber }) else {
            throw PdfCoreError.invalidDocument("Invalid last_page value: invalid digit found in string")
        }
        guard let page = UInt32(digits) else {
            throw PdfCoreError.invalidDocument("Invalid last_page value: number too large to fit in target type")
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
