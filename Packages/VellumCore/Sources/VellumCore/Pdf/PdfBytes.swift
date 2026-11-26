import Foundation

// MARK: - PDF byte classification

enum PdfBytes {
    static func isWhitespace(_ byte: UInt8) -> Bool {
        byte == 0x00 || byte == 0x09 || byte == 0x0a || byte == 0x0c || byte == 0x0d || byte == 0x20
    }

    static func isDelimiter(_ byte: UInt8) -> Bool {
        switch byte {
        case UInt8(ascii: "("), UInt8(ascii: ")"), UInt8(ascii: "<"), UInt8(ascii: ">"),
             UInt8(ascii: "["), UInt8(ascii: "]"), UInt8(ascii: "{"), UInt8(ascii: "}"),
             UInt8(ascii: "/"), UInt8(ascii: "%"):
            return true
        default:
            return false
        }
    }

    static func isDigit(_ byte: UInt8) -> Bool {
        (0x30...0x39).contains(byte)
    }

    /// PDF integers are untrusted; Int conversion also rejects overflow.
    static func unsigned(in bytes: [UInt8], at index: inout Int) -> Int? {
        let start = index
        while index < bytes.count, isDigit(bytes[index]) { index += 1 }
        guard start < index else { return nil }
        return Int(String(decoding: bytes[start..<index], as: UTF8.self))
    }

    static func firstRange(of needle: [UInt8], in haystack: [UInt8], from start: Int = 0, to end: Int? = nil) -> Range<Int>? {
        let end = end ?? haystack.count
        guard !needle.isEmpty, end - start >= needle.count else { return nil }
        for i in start...(end - needle.count) where haystack[i..<i + needle.count].elementsEqual(needle) {
            return i..<i + needle.count
        }
        return nil
    }

    static func lastRange(of needle: [UInt8], in haystack: [UInt8], to end: Int? = nil) -> Range<Int>? {
        let end = end ?? haystack.count
        guard !needle.isEmpty, end >= needle.count else { return nil }
        for i in stride(from: end - needle.count, through: 0, by: -1)
        where haystack[i..<i + needle.count].elementsEqual(needle) {
            return i..<i + needle.count
        }
        return nil
    }
}

// MARK: - Same-length byte patches

/// A fixed-length byte replacement. `nil` pattern entries match any single PDF
/// whitespace byte (the Quartz serializer may line-wrap between a key and its
/// value). Pattern and replacement lengths are equal so cross-reference offsets
/// in the serialized file stay valid.
public struct PdfBytePatch: Sendable {
    let pattern: [UInt8?]
    let replacement: [UInt8]

    init(pattern: [UInt8?], replacement: [UInt8]) {
        precondition(pattern.count == replacement.count, "byte patch must preserve length")
        self.pattern = pattern
        self.replacement = replacement
    }

    /// "/VellumOpacityPlaceholder 4" → "/CA .4" (padded): PDFKit rejects
    /// setValue for the standard /CA key, so creates carry a uniquely named
    /// placeholder that is rewritten into the real /CA 0.4 entry.
    public static let highlightOpacity: PdfBytePatch = {
        let key = Array("/VellumOpacityPlaceholder".utf8)
        var pattern: [UInt8?] = key.map { Optional($0) }
        pattern.append(nil)
        pattern.append(UInt8(ascii: "4"))
        var replacement = Array("/CA .4".utf8)
        replacement.append(contentsOf: Array(repeating: UInt8(ascii: " "), count: pattern.count - replacement.count))
        return PdfBytePatch(pattern: pattern, replacement: replacement)
    }()

    /// "/Name (Note)" → "/Name /Note ": PDFKit writes custom string values as
    /// PDF strings; the sticky-note icon must be the name /Note like the Rust
    /// writer produces.
    public static let noteIconName: PdfBytePatch = {
        var pattern: [UInt8?] = Array("/Name".utf8).map { Optional($0) }
        pattern.append(nil)
        pattern.append(contentsOf: Array("(Note)".utf8).map { Optional($0) })
        let replacement = Array("/Name /Note ".utf8)
        return PdfBytePatch(pattern: pattern, replacement: replacement)
    }()

    public static func apply(_ patches: [PdfBytePatch], to data: inout Data) {
        guard !patches.isEmpty else { return }
        var bytes = [UInt8](data)
        var changed = false
        for patch in patches {
            let length = patch.pattern.count
            guard bytes.count >= length else { continue }
            var i = 0
            while i <= bytes.count - length {
                var matches = true
                for (offset, expected) in patch.pattern.enumerated() {
                    let byte = bytes[i + offset]
                    if let expected {
                        if byte != expected { matches = false; break }
                    } else if !PdfBytes.isWhitespace(byte) {
                        matches = false
                        break
                    }
                }
                if matches {
                    bytes.replaceSubrange(i..<i + length, with: patch.replacement)
                    changed = true
                    i += length
                } else {
                    i += 1
                }
            }
        }
        if changed { data = Data(bytes) }
    }
}

// MARK: - Stale-xref recovery (strip_stale_xref_links port)

public enum PdfXrefRepair {
    static let marker = Array("VellumCreatedAt".utf8)

    public static func containsVellumMarker(_ bytes: [UInt8]) -> Bool {
        PdfBytes.firstRange(of: marker, in: bytes) != nil
    }

    /// Blank out `/Prev <digits>` and `/XRefStm <digits>` in the final trailer
    /// (or final xref-stream dictionary). Returns true if anything changed.
    public static func stripStaleXrefLinks(_ bytes: inout [UInt8]) -> Bool {
        let trailerSpan: (start: Int, end: Int)
        if let trailerStart = PdfBytes.lastRange(of: Array("trailer".utf8), in: bytes)?.lowerBound {
            guard let relativeEnd = PdfBytes.firstRange(of: Array("startxref".utf8), in: bytes, from: trailerStart)
            else { return false }
            trailerSpan = (trailerStart, relativeEnd.lowerBound)
        } else {
            guard let xrefMarker = PdfBytes.lastRange(of: Array("/Type/XRef".utf8), in: bytes)?.lowerBound,
                  let dictionaryStart = PdfBytes.lastRange(of: Array("<<".utf8), in: bytes, to: xrefMarker)?.lowerBound,
                  let streamRange = PdfBytes.firstRange(of: Array("stream".utf8), in: bytes, from: xrefMarker)
            else { return false }
            trailerSpan = (dictionaryStart, streamRange.lowerBound)
        }

        var changed = false
        for key in [Array("/Prev".utf8), Array("/XRefStm".utf8)] {
            var searchStart = trailerSpan.start
            while searchStart < trailerSpan.end {
                guard let keyRange = PdfBytes.firstRange(of: key, in: bytes, from: searchStart, to: trailerSpan.end)
                else { break }
                var valueEnd = keyRange.upperBound
                while valueEnd < trailerSpan.end, PdfBytes.isWhitespace(bytes[valueEnd]) { valueEnd += 1 }
                let numberStart = valueEnd
                while valueEnd < trailerSpan.end, PdfBytes.isDigit(bytes[valueEnd]) { valueEnd += 1 }
                if valueEnd == numberStart {
                    searchStart = keyRange.upperBound
                    continue
                }
                for i in keyRange.lowerBound..<valueEnd { bytes[i] = UInt8(ascii: " ") }
                changed = true
                searchStart = valueEnd
            }
        }
        return changed
    }
}

// MARK: - Dictionary source manipulation

/// Locate complete PDF values without decoding or reserializing their contents.
/// Every consumer uses the same whitespace, comment and delimiter rules.
private enum PdfSyntax {
    static func skipTrivia(_ bytes: [UInt8], from start: Int, to end: Int) -> Int {
        var i = start
        while i < end {
            if PdfBytes.isWhitespace(bytes[i]) {
                i += 1
            } else if bytes[i] == UInt8(ascii: "%") {
                while i < end, bytes[i] != 10, bytes[i] != 13 { i += 1 }
            } else {
                break
            }
        }
        return i
    }

    static func wordEnd(_ bytes: [UInt8], from start: Int, to end: Int) -> Int {
        var i = start
        while i < end, !PdfBytes.isWhitespace(bytes[i]), !PdfBytes.isDelimiter(bytes[i]) { i += 1 }
        return i
    }

    /// PDF names can spell the same byte literally or as # followed by two hex digits.
    static func nameBytes(_ raw: ArraySlice<UInt8>) -> [UInt8] {
        var result: [UInt8] = []
        var i = raw.startIndex
        while i < raw.endIndex {
            if raw[i] == UInt8(ascii: "#"), i + 2 < raw.endIndex,
               let high = hexDigit(raw[i + 1]), let low = hexDigit(raw[i + 2]) {
                result.append(high * 16 + low)
                i += 3
            } else {
                result.append(raw[i])
                i += 1
            }
        }
        return result
    }

    private static func hexDigit(_ byte: UInt8) -> UInt8? {
        switch byte {
        case 48...57: return byte - 48
        case 65...70: return byte - 65 + 10
        case 97...102: return byte - 97 + 10
        default: return nil
        }
    }

    static func keyword(_ word: StaticString, in bytes: [UInt8], at i: Int) -> Bool {
        let count = word.utf8CodeUnitCount
        guard bytes.count - i >= count else { return false }
        let after = i + count
        return (after == bytes.count || PdfBytes.isWhitespace(bytes[after]) || PdfBytes.isDelimiter(bytes[after]))
            && word.withUTF8Buffer { bytes[i..<after].elementsEqual($0) }
    }

    /// Called directly after an unsigned first token. Comments count as
    /// separators in indirect references, just as they do between values.
    static func referenceEnd(_ bytes: [UInt8], after first: Int, to end: Int) -> Int? {
        let generation = skipTrivia(bytes, from: first, to: end)
        var i = generation
        while i < end, PdfBytes.isDigit(bytes[i]) { i += 1 }
        guard i > generation else { return nil }
        let marker = skipTrivia(bytes, from: i, to: end)
        guard marker > i, marker < end, bytes[marker] == UInt8(ascii: "R") else { return nil }
        let after = marker + 1
        guard after == end || PdfBytes.isWhitespace(bytes[after]) || PdfBytes.isDelimiter(bytes[after]) else { return nil }
        return after
    }

    /// Scan composites iteratively. A string or comment may contain any of
    /// their delimiters; only tokens outside those values close a composite.
    static func valueSpan(in bytes: [UInt8], from start: Int, to end: Int) -> Range<Int>? {
        let first = skipTrivia(bytes, from: start, to: end)
        var i = first
        var closers: [UInt8] = []
        repeat {
            i = skipTrivia(bytes, from: i, to: end)
            guard i < end else { return nil }
            let token = i
            let byte = bytes[i]
            i += 1
            switch byte {
            case UInt8(ascii: "["):
                closers.append(UInt8(ascii: "]"))
            case UInt8(ascii: "<") where i < end && bytes[i] == UInt8(ascii: "<"):
                i += 1
                closers.append(UInt8(ascii: ">"))
            case UInt8(ascii: "]"), UInt8(ascii: ">"):
                guard closers.popLast() == byte else { return nil }
                if byte == UInt8(ascii: ">") {
                    guard i < end, bytes[i] == byte else { return nil }
                    i += 1
                }
            case UInt8(ascii: "("):
                var nesting = 1
                while nesting > 0 {
                    guard i < end else { return nil }
                    let character = bytes[i]
                    i += 1
                    switch character {
                    case UInt8(ascii: "\\"): if i < end { i += 1 }
                    case UInt8(ascii: "("): nesting += 1
                    case UInt8(ascii: ")"): nesting -= 1
                    default: break
                    }
                }
            case UInt8(ascii: "<"):
                while i < end, bytes[i] != UInt8(ascii: ">") { i += 1 }
                guard i < end else { return nil }
                i += 1
            case UInt8(ascii: "/"):
                i = wordEnd(bytes, from: i, to: end)
            default:
                guard !PdfBytes.isDelimiter(byte) else { return nil }
                i = wordEnd(bytes, from: i, to: end)
                if closers.isEmpty, bytes[token..<i].allSatisfy(PdfBytes.isDigit),
                   let refEnd = referenceEnd(bytes, after: i, to: end) {
                    i = refEnd
                }
            }
        } while !closers.isEmpty
        return first..<i
    }
}

/// A dictionary retains its original bytes except for explicitly edited entries.
public struct PdfDictSource {
    private var bytes: [UInt8]

    init(_ bytes: [UInt8]) {
        self.bytes = bytes
    }

    public var sourceBytes: [UInt8] { bytes }

    private func keyTokenRange(_ key: String) -> Range<Int>? {
        let token = Array("/\(key)".utf8)
        var i = 2
        while i < bytes.count {
            i = PdfSyntax.skipTrivia(bytes, from: i, to: bytes.count)
            guard i < bytes.count, bytes[i] == UInt8(ascii: "/") else { return nil }
            let end = PdfSyntax.wordEnd(bytes, from: i + 1, to: bytes.count)
            let range = i..<end
            if bytes[range].elementsEqual(token) { return range }
            if bytes[range].contains(UInt8(ascii: "#")), PdfSyntax.nameBytes(bytes[range]) == token { return range }
            guard let value = valueSpan(afterKeyToken: range) else { return nil }
            i = value.upperBound
        }
        return nil
    }

    private func valueSpan(afterKeyToken key: Range<Int>) -> Range<Int>? {
        PdfSyntax.valueSpan(in: bytes, from: key.upperBound, to: bytes.count)
    }

    public func hasKey(_ key: String) -> Bool {
        keyTokenRange(key) != nil
    }

    /// Raw source of an INLINE dictionary value ("<< ... >>"), used to promote
    /// direct /Outlines and /Info dictionaries to indirect objects the way
    /// ensure_outlines_root/ensure_info_dictionary do.
    public func inlineDictionary(forKey key: String) -> [UInt8]? {
        guard let raw = rawValue(forKey: key), raw.count >= 4,
              raw[0] == UInt8(ascii: "<"), raw[1] == UInt8(ascii: "<")
        else { return nil }
        return raw
    }

    /// Raw source of an INLINE array value ("[ ... ]"), e.g. a page's /Annots.
    public func inlineArray(forKey key: String) -> [UInt8]? {
        guard let raw = rawValue(forKey: key), raw.count >= 2,
              raw.first == UInt8(ascii: "["), raw.last == UInt8(ascii: "]")
        else { return nil }
        return raw
    }

    func rawValue(forKey key: String) -> [UInt8]? {
        guard let keyRange = keyTokenRange(key), let span = valueSpan(afterKeyToken: keyRange) else { return nil }
        return Array(bytes[span])
    }

    /// Object number of an indirect reference value ("12 0 R" → 12).
    public func reference(forKey key: String) -> Int? {
        guard let raw = rawValue(forKey: key) else { return nil }
        return PdfDictSource.parseReference(raw)
    }

    static func parseReference(_ raw: [UInt8]) -> Int? {
        var i = 0
        guard let number = PdfBytes.unsigned(in: raw, at: &i) else { return nil }
        guard PdfSyntax.referenceEnd(raw, after: i, to: raw.count) == raw.count else { return nil }
        return number
    }

    /// Plain integer value (not a reference).
    public func integer(forKey key: String) -> Int? {
        guard let raw = rawValue(forKey: key) else { return nil }
        guard PdfDictSource.parseReference(raw) == nil else { return nil }
        let text = String(decoding: raw, as: UTF8.self)
        return Int(text)
    }

    public func name(forKey key: String) -> String? {
        rawValue(forKey: key).flatMap(Self.decodeName)
    }

    static func decodeName(_ raw: [UInt8]) -> String? {
        guard raw.first == UInt8(ascii: "/") else { return nil }
        return String(decoding: PdfSyntax.nameBytes(raw.dropFirst()), as: UTF8.self)
    }

    /// Decoded PDF text string (PDFDocEncoding, UTF-16BE BOM, or PDF 2.0 UTF-8 BOM).
    public func textString(forKey key: String) -> String? {
        guard let raw = rawValue(forKey: key) else { return nil }
        return PdfDictSource.decodeTextString(raw)
    }

    static func decodeTextString(_ raw: [UInt8]) -> String? {
        decodeTextString(raw, identity: false)
    }

    /// CGPDF can interpret a PDF 2.0 UTF-8 BOM as three PDFDocEncoding
    /// characters. Such a string can be displayed, but cannot witness an
    /// identity shared between the Linux and Apple readers.
    static func decodeIdentityString(_ raw: [UInt8]) -> String? {
        decodeTextString(raw, identity: true)
    }

    static func annotationIdentity(_ raw: [UInt8]) -> String? {
        guard raw.count <= 1024, let id = decodeIdentityString(raw), !id.isEmpty,
              id.utf8.allSatisfy({ (32...126).contains($0) }) else { return nil }
        return id
    }

    private static func decodeTextString(_ raw: [UInt8], identity: Bool) -> String? {
        var content: [UInt8] = []
        if raw.first == UInt8(ascii: "("), raw.last == UInt8(ascii: ")") {
            var i = 1
            let end = raw.count - 1
            while i < end {
                let byte = raw[i]
                if byte == UInt8(ascii: "\\"), i + 1 < end {
                    let next = raw[i + 1]
                    switch next {
                    case 10, 13: // Escaped EOL is a continuation, including CRLF.
                        i += next == 13 && i + 2 < end && raw[i + 2] == 10 ? 3 : 2
                        continue
                    case UInt8(ascii: "n"): content.append(0x0a)
                    case UInt8(ascii: "r"): content.append(0x0d)
                    case UInt8(ascii: "t"): content.append(0x09)
                    case UInt8(ascii: "b"): content.append(0x08)
                    case UInt8(ascii: "f"): content.append(0x0c)
                    case UInt8(ascii: "0")...UInt8(ascii: "7"):
                        var value = 0
                        var digits = 0
                        var j = i + 1
                        while j < end, digits < 3, (UInt8(ascii: "0")...UInt8(ascii: "7")).contains(raw[j]) {
                            value = value * 8 + Int(raw[j] - UInt8(ascii: "0"))
                            digits += 1
                            j += 1
                        }
                        content.append(UInt8(truncatingIfNeeded: value))
                        i = j
                        continue
                    default: content.append(next)
                    }
                    i += 2
                    continue
                }
                if byte == 13 {
                    content.append(10) // PDF literal EOLs normalize to LF.
                    if i + 1 < end && raw[i + 1] == 10 { i += 1 }
                } else {
                    content.append(byte)
                }
                i += 1
            }
        } else if raw.first == UInt8(ascii: "<"), raw.last == UInt8(ascii: ">"), !raw.starts(with: [60, 60]) {
            var nibbles: [UInt8] = []
            for byte in raw.dropFirst().dropLast() {
                switch byte {
                case UInt8(ascii: "0")...UInt8(ascii: "9"): nibbles.append(byte - UInt8(ascii: "0"))
                case UInt8(ascii: "a")...UInt8(ascii: "f"): nibbles.append(byte - UInt8(ascii: "a") + 10)
                case UInt8(ascii: "A")...UInt8(ascii: "F"): nibbles.append(byte - UInt8(ascii: "A") + 10)
                default: guard PdfBytes.isWhitespace(byte) else { return nil }
                }
            }
            if nibbles.count % 2 == 1 { nibbles.append(0) }
            for pair in stride(from: 0, to: nibbles.count, by: 2) {
                content.append(nibbles[pair] << 4 | nibbles[pair + 1])
            }
        } else {
            return nil
        }

        if content.starts(with: [0xef, 0xbb, 0xbf]) {
            guard !identity else { return nil }
            return String(bytes: content.dropFirst(3), encoding: .utf8)
        }
        if content.starts(with: [0xfe, 0xff]) {
            guard content.count.isMultiple(of: 2) else { return nil }
            let utf16 = stride(from: 2, to: content.count - 1, by: 2).map {
                UInt16(content[$0]) << 8 | UInt16(content[$0 + 1])
            }
            return String(decoding: utf16, as: UTF16.self)
        }
        // ISO 32000-2, Annex D, Table D.2. Most codes map directly to
        // Unicode; these are the two blocks of accents and punctuation.
        var text = String.UnicodeScalarView()
        for byte in content {
            switch byte {
            case 0x18...0x1f: text.append(pdfDocAccents[Int(byte) - 0x18])
            case 0x80...0x9e: text.append(pdfDocPunctuation[Int(byte) - 0x80])
            case 0xa0: text.append("€")
            case 0x7f, 0x9f, 0xad: text.append("�") // Undefined in PDFDocEncoding.
            default: text.append(Unicode.Scalar(byte))
            }
        }
        return String(text)
    }

    private static let pdfDocAccents = Array("˘ˇˆ˙˝˛˚˜".unicodeScalars)
    private static let pdfDocPunctuation = Array("•†‡…—–ƒ⁄‹›−‰„“”‘’‚™ﬁﬂŁŒŠŸŽıłœšž".unicodeScalars)

    // MARK: Mutation

    /// Replace the value of `key`, or insert the entry right after "<<".
    public mutating func setValue(forKey key: String, raw: [UInt8]) {
        if let keyRange = keyTokenRange(key), let span = valueSpan(afterKeyToken: keyRange) {
            bytes.replaceSubrange(span, with: raw)
        } else {
            var insertion = Array(" /\(key) ".utf8)
            insertion.append(contentsOf: raw)
            bytes.insert(contentsOf: insertion, at: 2)
        }
    }

    public mutating func setReference(forKey key: String, to objectNumber: Int) {
        setValue(forKey: key, raw: Array("\(objectNumber) 0 R".utf8))
    }

    public mutating func setInteger(forKey key: String, to value: Int) {
        setValue(forKey: key, raw: Array("\(value)".utf8))
    }

    public mutating func setTextString(forKey key: String, to value: String) {
        setValue(forKey: key, raw: PdfTextString.encode(value))
    }

    public mutating func removeEntry(forKey key: String) {
        guard let keyRange = keyTokenRange(key), let span = valueSpan(afterKeyToken: keyRange) else { return }
        bytes.removeSubrange(keyRange.lowerBound..<span.upperBound)
    }
}

// MARK: - Raw array source manipulation

/// Editing helpers for raw PDF array sources ("[ ... ]"), e.g. a page's
/// /Annots. Element grammar mirrors PdfDictSource.valueSpan: names, strings,
/// hex strings, nested arrays/dictionaries, and "N G R" indirect references.
public enum PdfArraySource {
    /// Byte ranges of the array's top-level elements (brackets excluded);
    /// nil when the source is not a well-formed array.
    static func elementSpans(inArray bytes: [UInt8]) -> [Range<Int>]? {
        guard bytes.count >= 2, bytes.first == UInt8(ascii: "["),
              bytes.last == UInt8(ascii: "]") else { return nil }
        var spans: [Range<Int>] = []
        var i = 1
        let end = bytes.count - 1
        i = PdfSyntax.skipTrivia(bytes, from: i, to: end)
        while i < end {
            guard let span = PdfSyntax.valueSpan(in: bytes, from: i, to: end) else { return nil }
            spans.append(span)
            i = PdfSyntax.skipTrivia(bytes, from: span.upperBound, to: end)
        }
        return spans
    }

    /// The array with its `index`-th element removed; nil when out of range or
    /// unparsable.
    public static func removingElement(at index: Int, fromArray bytes: [UInt8]) -> [UInt8]? {
        guard let spans = elementSpans(inArray: bytes), index >= 0, index < spans.count else {
            return nil
        }
        var out = bytes
        out.removeSubrange(spans[index])
        return out
    }

    /// Indirect object numbers in an array, in source order. Direct values are
    /// ignored; PDFKit writes page annotation arrays as indirect references.
    public static func references(inArray bytes: [UInt8]) -> [Int]? {
        guard let spans = elementSpans(inArray: bytes) else { return nil }
        return spans.compactMap { PdfDictSource.parseReference(Array(bytes[$0])) }
    }
}

// MARK: - Classic cross-reference file model

/// Parser for classic-xref PDFs produced by PDFKit or Vellum's incremental
/// writer. Follows `/Prev` chains so later metadata/bookmark edits can build on
/// earlier increments without a lossy normalization pass.
public struct ClassicPdfFile {
    let data: Data
    private let bytes: [UInt8]
    private(set) var objectOffsets: [Int: Int] = [:]
    private var compressedSources: [Int: ArraySlice<UInt8>] = [:]
    private(set) var usesXrefStreams = false
    fileprivate var usesPrimaryTable: Bool { PdfSyntax.keyword("xref", in: bytes, at: startXref) }
    private(set) var trailer: PdfDictSource
    let startXref: Int

    let size: Int
    public var rootNumber: Int? { trailer.reference(forKey: "Root") }
    public var infoNumber: Int? { trailer.reference(forKey: "Info") }

    public init(data: Data) throws {
        try self.init(data: data, forEditing: true)
    }

    /// Recover original metadata for a PDFKit rewrite. This returns only a
    /// dictionary, so a read-only proof cannot be passed to an increment.
    public static func infoForRecovery(in original: Data) throws -> PdfDictSource? {
        let file = try ClassicPdfFile(data: original, forEditing: false)
        if let number = file.infoNumber {
            guard let raw = file.rawObjectValue(number), raw.starts(with: "<<".utf8) else { throw PdfReadOnlyReason.malformed }
            return PdfDictSource(raw)
        }
        return file.trailer.inlineDictionary(forKey: "Info").map(PdfDictSource.init)
    }

    private init(data: Data, forEditing: Bool) throws {
        self.data = data
        self.bytes = [UInt8](data)

        guard let startXrefRange = PdfBytes.lastRange(of: Array("startxref".utf8), in: bytes) else {
            throw PdfCoreError.invalidDocument("Failed to rewrite PDF: no cross-reference offset")
        }
        var i = startXrefRange.upperBound
        while i < bytes.count, PdfBytes.isWhitespace(bytes[i]) { i += 1 }
        guard let offset = PdfBytes.unsigned(in: bytes, at: &i), offset < bytes.count else {
            throw PdfCoreError.invalidDocument("Failed to rewrite PDF: invalid cross-reference offset")
        }
        startXref = offset

        var entries: [Int: XrefEntry] = [:]
        var seenOffsets = Set<Int>()
        var latest: PdfDictSource?
        var newerSize: Int?
        var position = offset
        while true {
            guard bytes.indices.contains(position), seenOffsets.insert(position).inserted else {
                throw PdfCoreError.invalidDocument("Invalid cross-reference revision")
            }
            let section = PdfSyntax.keyword("xref", in: bytes, at: position)
                ? try Self.xrefSection(in: bytes, at: position) : nil
            if let section, !section.trailer.hasKey("XRefStm") {
                guard let size = section.trailer.integer(forKey: "Size"), size > 0,
                      size <= (newerSize ?? Int.max) else {
                    throw PdfCoreError.invalidDocument("Failed to rewrite PDF: invalid trailer size")
                }
                if latest == nil { latest = section.trailer }
                newerSize = size
                entries.merge(section.entries) { current, _ in current }
                guard section.trailer.hasKey("Prev") else { break }
                guard let previous = section.trailer.integer(forKey: "Prev") else {
                    throw PdfCoreError.invalidDocument("Failed to rewrite PDF: invalid cross-reference offset")
                }
                position = previous
            } else {
                // Before a stream-backed file reaches any writer, prove every
                // revision and use that exact object map for all subsequent reads.
                guard data.count <= 128 * 1024 * 1024 else { throw PdfReadOnlyReason.inspectionLimit }
                let structure = PdfClassicStructure(bytes: bytes)
                try structure.inspect(forEditing: forEditing)
                guard structure.usesXrefStreams, let size = structure.latestTrailer.integer(forKey: "Size")
                else { throw PdfReadOnlyReason.malformed }
                self.size = size
                trailer = structure.latestTrailer
                objectOffsets = structure.offsets
                compressedSources = structure.compressedSources
                usesXrefStreams = true
                return
            }
        }
        guard let latest, let size = latest.integer(forKey: "Size"),
              size > (entries.keys.max() ?? 0), size <= Int(UInt32.max) else {
            throw PdfCoreError.invalidDocument("Failed to rewrite PDF: invalid trailer size")
        }
        self.size = size
        objectOffsets = entries.compactMapValues { entry in
            if case .inUse(let offset, _) = entry { return offset }
            return nil
        }
        trailer = latest
    }

    private enum XrefEntry {
        case inUse(offset: Int, generation: Int)
        case free
    }

    /// Parse one classic xref section. Incremental Vellum writes chain these
    /// through `/Prev`; callers merge newest-to-oldest so replaced objects win.
    private static func xrefSection(
        in bytes: [UInt8], at offset: Int, verifyingIdentity: Bool = false
    ) throws -> (entries: [Int: XrefEntry], trailer: PdfDictSource, end: Int) {
        var position = offset
        guard bytes.indices.contains(position), PdfSyntax.keyword("xref", in: bytes, at: position) else {
            throw PdfCoreError.invalidDocument("Failed to rewrite PDF: unsupported cross-reference format")
        }
        position = PdfSyntax.skipTrivia(bytes, from: position + 4, to: bytes.count)

        var entries: [Int: XrefEntry] = [:]
        let invalidEntry = PdfCoreError.invalidDocument("Failed to rewrite PDF: invalid cross-reference offset")
        while position < bytes.count, PdfBytes.isDigit(bytes[position]) {
            guard let first = PdfBytes.unsigned(in: bytes, at: &position) else { throw invalidEntry }
            position = PdfSyntax.skipTrivia(bytes, from: position, to: bytes.count)
            guard let count = PdfBytes.unsigned(in: bytes, at: &position), first <= Int.max - count else {
                throw invalidEntry
            }
            let headerEnd = position
            position = PdfSyntax.skipTrivia(bytes, from: position, to: bytes.count)
            if verifyingIdentity, count > 0 {
                let eol = bytes[headerEnd..<position].drop { $0 == 32 || $0 == 9 }
                guard eol.elementsEqual("\r\n".utf8) || eol.elementsEqual("\n".utf8) ||
                      eol.elementsEqual("\r".utf8) else { throw invalidEntry }
            }
            for number in first..<(first + count) {
                let start = position
                guard let offset = PdfBytes.unsigned(in: bytes, at: &position), position - start == 10,
                      position < bytes.count, bytes[position] == 32 else { throw invalidEntry }
                position += 1
                let generation = position
                guard let generationNumber = PdfBytes.unsigned(in: bytes, at: &position), position - generation == 5,
                      position + 1 < bytes.count, bytes[position] == 32 else { throw invalidEntry }
                position += 1
                if verifyingIdentity {
                    // PDFium addresses classic rows at fixed 20-byte strides. Refuse
                    // ambiguous duplicates or spacing before trusting the same row.
                    let ending = position + 1
                    guard entries[number] == nil, ending + 2 <= bytes.count else { throw invalidEntry }
                    let suffix = bytes[ending..<(ending + 2)]
                    guard suffix.elementsEqual(" \n".utf8) || suffix.elementsEqual("\r\n".utf8) ||
                          suffix.elementsEqual(" \r".utf8) else { throw invalidEntry }
                }
                switch bytes[position] {
                case UInt8(ascii: "n"): entries[number] = .inUse(offset: offset, generation: generationNumber)
                case UInt8(ascii: "f"): entries[number] = .free
                default: throw invalidEntry
                }
                position += 1
                guard position < bytes.count, PdfBytes.isWhitespace(bytes[position]) else { throw invalidEntry }
                if verifyingIdentity && number + 1 < first + count {
                    position += 2
                } else {
                    position = PdfSyntax.skipTrivia(bytes, from: position, to: bytes.count)
                }
            }
        }
        guard PdfSyntax.keyword("trailer", in: bytes, at: position) else {
            throw PdfCoreError.invalidDocument("Failed to rewrite PDF: missing trailer")
        }
        guard let span = PdfSyntax.valueSpan(in: bytes, from: position + 7, to: bytes.count),
              bytes[span].starts(with: [60, 60]) else {
            throw PdfCoreError.invalidDocument("Failed to rewrite PDF: invalid trailer")
        }
        return (entries, PdfDictSource(Array(bytes[span])), span.upperBound)
    }

    private func objectValueSpan(_ number: Int) -> Range<Int>? {
        guard var i = objectOffsets[number], bytes.indices.contains(i),
              PdfBytes.unsigned(in: bytes, at: &i) == number else { return nil }
        i = PdfSyntax.skipTrivia(bytes, from: i, to: bytes.count)
        guard PdfBytes.unsigned(in: bytes, at: &i) != nil else { return nil }
        i = PdfSyntax.skipTrivia(bytes, from: i, to: bytes.count)
        guard PdfSyntax.keyword("obj", in: bytes, at: i) else { return nil }
        return PdfSyntax.valueSpan(in: bytes, from: i + 3, to: bytes.count)
    }

    public func objectSource(_ number: Int) -> PdfDictSource? {
        if let source = compressedSources[number] {
            return source.starts(with: "<<".utf8) ? PdfDictSource(Array(source)) : nil
        }
        guard let span = objectValueSpan(number), bytes[span].starts(with: [60, 60]) else { return nil }
        return PdfDictSource(Array(bytes[span]))
    }

    func resolvedValue(forKey key: String, in dictionary: PdfDictSource) -> [UInt8]? {
        dictionary.rawValue(forKey: key).flatMap(resolvedValue)
    }

    func resolvedValue(_ value: [UInt8]) -> [UInt8]? {
        var result = value
        var visited = Set<Int>()
        while let number = PdfDictSource.parseReference(result) {
            guard visited.count < 64, visited.insert(number).inserted, let bytes = rawObjectValue(number) else { return nil }
            result = bytes
        }
        return result
    }

    /// Raw top-level value of a non-stream indirect object. This is used for
    /// PDFKit's `/Annots` array object (`[ 12 0 R ... ]`), which is not a
    /// dictionary and therefore cannot be returned by `objectSource`.
    public func rawObjectValue(_ number: Int) -> [UInt8]? {
        if let source = compressedSources[number] { return Array(source) }
        guard let span = objectValueSpan(number) else { return nil }
        let end = PdfSyntax.skipTrivia(bytes, from: span.upperBound, to: bytes.count)
        guard PdfSyntax.keyword("endobj", in: bytes, at: end) else { return nil }
        return Array(bytes[span])
    }
}

extension PdfDictSource {
    /// Reading an identity requires one unambiguous key, including #NN spellings.
    fileprivate func uniqueValue(forKey key: String) -> [UInt8]? {
        guard let first = keyTokenRange(key), let value = valueSpan(afterKeyToken: first) else { return nil }
        var i = value.upperBound
        let token = Array("/\(key)".utf8)
        while i < bytes.count {
            i = PdfSyntax.skipTrivia(bytes, from: i, to: bytes.count)
            if bytes[i...].elementsEqual(">>".utf8) { return Array(bytes[value]) }
            guard i < bytes.count, bytes[i] == UInt8(ascii: "/") else { return nil }
            let end = PdfSyntax.wordEnd(bytes, from: i + 1, to: bytes.count)
            guard PdfSyntax.nameBytes(bytes[i..<end]) != token,
                  let next = valueSpan(afterKeyToken: i..<end) else { return nil }
            i = next.upperBound
        }
        return nil
    }
}

extension ClassicPdfFile {
    /// Verify the actual type behind PDFium's text-only metadata API. Traverse up
    /// to 64 classic revisions newest-first, with a 1 MiB window per table and
    /// 8 MiB of total classic xref reads. Stream proofs use the bounded physical parser.
    public static func currentInfoText(forKey key: String, in data: Data) -> String? {
        guard data.starts(with: "%PDF-".utf8),
              let marker = data.suffix(1024).range(of: Data("startxref".utf8), options: .backwards)
        else { return nil }
        let footer = data[marker.upperBound...].split(whereSeparator: PdfBytes.isWhitespace)
        guard footer.count == 2, footer[0].allSatisfy(PdfBytes.isDigit), footer[1].elementsEqual("%%EOF".utf8),
              var offset = Int(String(decoding: footer[0], as: UTF8.self)) else { return nil }
        var upperBound = marker.lowerBound - data.startIndex
        var remaining = 8 * 1024 * 1024
        var infoNumber: Int?
        for revision in 0..<64 {
            guard offset >= 0, offset < upperBound else { return nil }
            let count = min(upperBound - offset, 1024 * 1024, remaining)
            guard count > 0 else { return nil }
            remaining -= count
            let start = data.startIndex + offset
            let window = Array(data[start..<(start + count)])
            if !PdfSyntax.keyword("xref", in: window, at: 0) {
                return streamInfoText(forKey: key, in: data)
            }
            guard let section = try? xrefSection(in: window, at: 0, verifyingIdentity: true) else { return nil }
            if section.trailer.hasKey("XRefStm") { return streamInfoText(forKey: key, in: data) }
            if revision == 0 {
                guard count == upperBound - offset,
                      PdfSyntax.skipTrivia(window, from: section.end, to: count) == count,
                      let ref = section.trailer.uniqueValue(forKey: "Info") else { return nil }
                let parts = ref.split(whereSeparator: PdfBytes.isWhitespace)
                guard parts.count == 3, parts[0].allSatisfy(PdfBytes.isDigit),
                      parts[1].elementsEqual("0".utf8), parts[2].elementsEqual("R".utf8) else { return nil }
                infoNumber = Int(String(decoding: parts[0], as: UTF8.self))
            }
            guard let number = infoNumber else { return nil }
            if let entry = section.entries[number] {
                // A free/reused object shadows all previous rows for this number.
                guard case .inUse(let object, 0) = entry, object < offset else { return nil }
                return infoText(forKey: key, in: data, number: number, at: object, before: offset)
            }
            guard let prev = section.trailer.uniqueValue(forKey: "Prev"),
                  prev.allSatisfy(PdfBytes.isDigit),
                  let previous = Int(String(decoding: prev, as: UTF8.self)), previous < offset else { return nil }
            upperBound = offset
            offset = previous
        }
        return nil
    }

    private static func streamInfoText(forKey key: String, in data: Data) -> String? {
        // The physical proof visits the complete revision chain. Bound both the
        // source and total inflated bytes independently of the rendering limit.
        guard data.count <= 128 * 1024 * 1024 else { return nil }
        let structure = PdfClassicStructure(data)
        guard (try? structure.inspect(forEditing: false)) != nil, structure.usesXrefStreams,
              let info = structure.latestTrailer.reference(forKey: "Info"),
              case .dictionary(let dictionary) = structure.objects[info],
              case .string(let raw) = dictionary[key], raw.count <= 64 * 1024
        else { return nil }
        return key == "VellumDocId" ? PdfDictSource.decodeIdentityString(Array(raw)) : PdfDictSource.decodeTextString(Array(raw))
    }

    private static func infoText(forKey key: String, in data: Data, number: Int, at object: Int,
                                 before offset: Int) -> String? {
        let prefix = Array("\(number) 0 obj".utf8)
        let objectStart = data.startIndex + object
        let bytes = Array(data[objectStart..<(objectStart + min(offset - object, 64 * 1024))])
        guard bytes.starts(with: prefix),
              let info = PdfSyntax.valueSpan(in: bytes, from: prefix.count, to: bytes.count),
              bytes[info].starts(with: "<<".utf8),
              PdfSyntax.keyword("endobj", in: bytes, at: PdfSyntax.skipTrivia(bytes, from: info.upperBound, to: bytes.count)),
              let value = PdfDictSource(Array(bytes[info])).uniqueValue(forKey: key),
              value.first == UInt8(ascii: "(") ||
                (value.first == UInt8(ascii: "<") && !value.starts(with: "<<".utf8))
        else { return nil }
        return key == "VellumDocId" ? PdfDictSource.decodeIdentityString(value) : PdfDictSource.decodeTextString(value)
    }
}

// MARK: - Incremental update builder

/// Builds an incremental update (new/replaced objects + classic xref section +
/// trailer) appended to a classic PDF. On iPadOS 26 these increments are kept
/// intact because PDFKit would discard their custom keys; newer runtimes may
/// still normalize them when that is safe.
public struct PdfIncrement {
    private var objects: [Int: [UInt8]] = [:]
    private(set) var nextObjectNumber: Int
    private let file: ClassicPdfFile

    public init(file: ClassicPdfFile) {
        self.file = file
        self.nextObjectNumber = file.size
    }

    public mutating func allocateObjectNumber() -> Int {
        let number = nextObjectNumber
        nextObjectNumber += 1
        return number
    }

    public mutating func setObject(_ number: Int, source: [UInt8]) {
        objects[number] = source
    }

    /// Mark an object as replaced by `null` (used to drop deleted bookmarks).
    mutating func setNull(_ number: Int) {
        objects[number] = Array("null".utf8)
    }

    func object(_ number: Int) -> [UInt8]? {
        objects[number]
    }

    /// Check the resulting stream revision as well as its input before a
    /// metadata or outline caller can publish the appended bytes.
    func checkedAppend(infoNumber: Int? = nil) throws -> Data {
        let bytes = appended(infoNumber: infoNumber)
        if file.usesXrefStreams { try PdfEditEligibility.validateOutput(bytes) }
        return bytes
    }

    /// The base data with the update appended. `infoNumber` overrides the
    /// trailer /Info reference when the Info dictionary moved. Built at the
    /// byte level: copied object sources may contain non-UTF8 string literals
    /// and must pass through unmodified.
    public func appended(infoNumber: Int? = nil) -> Data {
        var out = file.data
        var body: [UInt8] = [UInt8(ascii: "\n")]
        var offsets: [Int: Int] = [:]
        for (number, source) in objects.sorted(by: { $0.key < $1.key }) {
            offsets[number] = out.count + body.count
            body.append(contentsOf: Array("\(number) 0 obj\n".utf8))
            body.append(contentsOf: source)
            body.append(contentsOf: Array("\nendobj\n".utf8))
        }
        var xrefOffset = out.count + body.count
        let streamNumber = max(nextObjectNumber, (offsets.keys.max() ?? 0) + 1)
        var trailer = file.trailer
        trailer.removeEntry(forKey: "XRefStm")
        trailer.setInteger(forKey: "Prev", to: file.startXref)
        trailer.setInteger(forKey: "Size", to: file.usesXrefStreams ? streamNumber + 1 : streamNumber)
        if let infoNumber { trailer.setReference(forKey: "Info", to: infoNumber) }
        if file.usesXrefStreams { offsets[streamNumber] = xrefOffset }

        let numbers = offsets.keys.sorted()
        var groups: [ArraySlice<Int>] = []
        var start = 0
        while start < numbers.count {
            var end = start + 1
            while end < numbers.count, numbers[end] == numbers[end - 1] + 1 { end += 1 }
            groups.append(numbers[start..<end])
            start = end
        }
        if file.usesXrefStreams {
            var stream = trailer
            for key in ["Filter", "DecodeParms", "DL"] { stream.removeEntry(forKey: key) }
            if file.usesPrimaryTable { stream.removeEntry(forKey: "Prev") }
            stream.setValue(forKey: "Type", raw: Array("/XRef".utf8))
            stream.setValue(forKey: "W", raw: Array("[1 8 2]".utf8))
            let index = groups.map { "\($0.first!) \($0.count)" }.joined(separator: " ")
            stream.setValue(forKey: "Index", raw: Array("[\(index)]".utf8))
            stream.setInteger(forKey: "Length", to: numbers.count * 11)
            body.append(contentsOf: "\(streamNumber) 0 obj\n".utf8)
            body.append(contentsOf: stream.sourceBytes)
            body.append(contentsOf: "\nstream\n".utf8)
            for number in numbers {
                body.append(1)
                withUnsafeBytes(of: UInt64(offsets[number]!).bigEndian) { body.append(contentsOf: $0) }
                body.append(contentsOf: [0, 0])
            }
            body.append(contentsOf: "\nendstream\nendobj\n".utf8)
            // In a hybrid, PDFKit follows the primary table chain. Each
            // supplemental stream belongs only to its own table revision.
            if file.usesPrimaryTable {
                trailer.setInteger(forKey: "XRefStm", to: xrefOffset)
                xrefOffset = out.count + body.count
            }
        }
        if file.usesPrimaryTable {
            body.append(contentsOf: "xref\n".utf8)
            for group in groups {
                body.append(contentsOf: "\(group.first!) \(group.count)\n".utf8)
                for number in group {
                    body.append(contentsOf: String(format: "%010lld 00000 n \n", Int64(offsets[number]!)).utf8)
                }
            }
            body.append(contentsOf: "trailer\n".utf8)
            body.append(contentsOf: trailer.sourceBytes)
        }
        body.append(contentsOf: "\nstartxref\n\(xrefOffset)\n%%EOF\n".utf8)
        out.append(Data(body))
        return out
    }
}

// MARK: - PDF text-string encoding (for raw dictionary writes)

public enum PdfTextString {
    /// Serialize a text string the way lopdf's text_string does semantically:
    /// ASCII-safe content as an escaped literal, everything else as UTF-16BE
    /// with BOM (hex form, so the increment stays printable).
    public static func encode(_ value: String) -> [UInt8] {
        let asciiSafe = value.unicodeScalars.allSatisfy { $0.value >= 0x20 && $0.value < 0x7f }
        if asciiSafe {
            var out: [UInt8] = [UInt8(ascii: "(")]
            for byte in Array(value.utf8) {
                if byte == UInt8(ascii: "(") || byte == UInt8(ascii: ")") || byte == UInt8(ascii: "\\") {
                    out.append(UInt8(ascii: "\\"))
                }
                out.append(byte)
            }
            out.append(UInt8(ascii: ")"))
            return out
        }
        var hex = "<FEFF"
        for unit in Array(value.utf16) {
            hex += String(format: "%04X", unit)
        }
        hex += ">"
        return Array(hex.utf8)
    }
}
