import Foundation

// PDF write engine.
//
// - Atomic on-disk replacement (temp file + rename, permissions preserved),
//   mirroring save_document/replace_file in src-tauri/src/pdf_annotations.rs.
// - Same-length byte patches for the two dictionary values PDFKit's public API
//   cannot produce (/CA real on highlights, /Name name-object on notes).
// - The stale-xref recovery pass (strip_stale_xref_links) for files written by
//   old Vellum builds with broken incremental cross references.
// - A classic cross-reference parser + incremental-update builder used for the
//   writes PDFKit cannot express at all (outline bookmark items with custom
//   keys, custom Info-dictionary entries). The increment is only ever applied
//   IN MEMORY to freshly PDFKit-serialized data ("Quartz PDFDocument"
//   serializer output: plain-text dictionaries, single classic xref table);
//   the result is re-loaded through PDFKit and fully rewritten, so files on
//   disk are always clean single-xref full rewrites, like the Rust side.

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

    static func firstRange(of needle: [UInt8], in haystack: [UInt8], from start: Int = 0, to end: Int? = nil) -> Range<Int>? {
        let end = end ?? haystack.count
        guard !needle.isEmpty, end - start >= needle.count else { return nil }
        for i in start...(end - needle.count) where Array(haystack[i..<i + needle.count]) == needle {
            return i..<i + needle.count
        }
        return nil
    }

    static func lastRange(of needle: [UInt8], in haystack: [UInt8], to end: Int? = nil) -> Range<Int>? {
        let end = end ?? haystack.count
        guard !needle.isEmpty, end >= needle.count else { return nil }
        for i in stride(from: end - needle.count, through: 0, by: -1)
        where Array(haystack[i..<i + needle.count]) == needle {
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
struct PdfBytePatch {
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
    static let highlightOpacity: PdfBytePatch = {
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
    static let noteIconName: PdfBytePatch = {
        var pattern: [UInt8?] = Array("/Name".utf8).map { Optional($0) }
        pattern.append(nil)
        pattern.append(contentsOf: Array("(Note)".utf8).map { Optional($0) })
        let replacement = Array("/Name /Note ".utf8)
        return PdfBytePatch(pattern: pattern, replacement: replacement)
    }()

    static func apply(_ patches: [PdfBytePatch], to data: inout Data) {
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

// MARK: - Atomic writer

enum PdfAtomicWriter {
    /// Write `data` over the PDF at `path` atomically: temp file
    /// `.{name}.vellum-{uuid}.tmp` in the same directory, original permissions
    /// preserved, POSIX rename. Error strings mirror save_document/replace_file.
    static func save(_ data: Data, toPath path: String) throws {
        let url = URL(fileURLWithPath: path)
        let parent = url.deletingLastPathComponent()
        let fileName = url.lastPathComponent.isEmpty ? "document.pdf" : url.lastPathComponent
        let nonce = UUID().uuidString.lowercased()
        let temporaryURL = parent.appendingPathComponent(".\(fileName).vellum-\(nonce).tmp")

        let permissions: Any?
        do {
            permissions = try FileManager.default.attributesOfItem(atPath: path)[.posixPermissions]
        } catch {
            throw SessionServiceError.io("Failed to read PDF permissions: \(error.localizedDescription)")
        }

        do {
            try data.write(to: temporaryURL)
        } catch {
            try? FileManager.default.removeItem(at: temporaryURL)
            throw SessionServiceError.io("Failed to write annotated PDF: \(error.localizedDescription)")
        }

        if let permissions {
            do {
                try FileManager.default.setAttributes(
                    [.posixPermissions: permissions], ofItemAtPath: temporaryURL.path)
            } catch {
                try? FileManager.default.removeItem(at: temporaryURL)
                throw SessionServiceError.io("Failed to preserve PDF permissions: \(error.localizedDescription)")
            }
        }

        // rename(2) is atomic on the same volume and replaces the destination.
        if rename(temporaryURL.path, path) != 0 {
            let message = String(cString: strerror(errno))
            try? FileManager.default.removeItem(at: temporaryURL)
            throw SessionServiceError.io("Failed to replace PDF with annotated copy: \(message)")
        }
    }
}

// MARK: - Stale-xref recovery (strip_stale_xref_links port)

enum PdfXrefRepair {
    static let marker = Array("VellumCreatedAt".utf8)

    static func containsVellumMarker(_ bytes: [UInt8]) -> Bool {
        PdfBytes.firstRange(of: marker, in: bytes) != nil
    }

    /// Blank out `/Prev <digits>` and `/XRefStm <digits>` in the final trailer
    /// (or final xref-stream dictionary). Returns true if anything changed.
    static func stripStaleXrefLinks(_ bytes: inout [UInt8]) -> Bool {
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

/// A raw PDF dictionary source ("<< ... >>") with a masked shadow copy in which
/// string contents are blanked, so key/value scanning never trips over
/// delimiter characters inside strings. All edits keep the source valid PDF.
struct PdfDictSource {
    private(set) var bytes: [UInt8]
    private var masked: [UInt8]

    init(_ bytes: [UInt8]) {
        self.bytes = bytes
        self.masked = PdfDictSource.mask(bytes)
    }

    var sourceBytes: [UInt8] { bytes }

    /// Replace literal-string and hex-string contents with 'X' (same length).
    private static func mask(_ bytes: [UInt8]) -> [UInt8] {
        var masked = bytes
        var i = 0
        while i < masked.count {
            let byte = masked[i]
            if byte == UInt8(ascii: "(") {
                // Literal string: honor escapes and nested parentheses.
                var depth = 1
                var j = i + 1
                while j < masked.count, depth > 0 {
                    let b = masked[j]
                    if b == UInt8(ascii: "\\") {
                        if j + 1 < masked.count { masked[j] = UInt8(ascii: "X"); masked[j + 1] = UInt8(ascii: "X") }
                        j += 2
                        continue
                    }
                    if b == UInt8(ascii: "(") { depth += 1 }
                    if b == UInt8(ascii: ")") {
                        depth -= 1
                        if depth == 0 { break }
                    }
                    masked[j] = UInt8(ascii: "X")
                    j += 1
                }
                i = j + 1
            } else if byte == UInt8(ascii: "<"), i + 1 < masked.count, masked[i + 1] != UInt8(ascii: "<") {
                // Hex string.
                var j = i + 1
                while j < masked.count, masked[j] != UInt8(ascii: ">") {
                    masked[j] = UInt8(ascii: "X")
                    j += 1
                }
                i = j + 1
            } else if byte == UInt8(ascii: "<"), i + 1 < masked.count {
                i += 2
            } else {
                i += 1
            }
        }
        return masked
    }

    // MARK: Scanning

    /// Range of the "/Key" token itself (key must be followed by a delimiter).
    private func keyTokenRange(_ key: String, from start: Int = 0) -> Range<Int>? {
        let token = Array("/\(key)".utf8)
        var searchStart = start
        while let range = PdfBytes.firstRange(of: token, in: masked, from: searchStart) {
            let next = range.upperBound
            if next >= masked.count || PdfBytes.isWhitespace(masked[next]) || PdfBytes.isDelimiter(masked[next]) {
                return range
            }
            searchStart = range.lowerBound + 1
        }
        return nil
    }

    /// Span of the value token following "/Key" (references span "N G R").
    private func valueSpan(afterKeyToken keyRange: Range<Int>) -> Range<Int>? {
        var i = keyRange.upperBound
        while i < masked.count, PdfBytes.isWhitespace(masked[i]) { i += 1 }
        guard i < masked.count else { return nil }
        let start = i
        let byte = masked[i]

        func scanBalanced(open: UInt8, close: UInt8) -> Range<Int>? {
            var depth = 0
            var j = start
            while j < masked.count {
                if masked[j] == open { depth += 1 }
                if masked[j] == close {
                    depth -= 1
                    if depth == 0 { return start..<j + 1 }
                }
                j += 1
            }
            return nil
        }

        switch byte {
        case UInt8(ascii: "/"):
            var j = i + 1
            while j < masked.count, !PdfBytes.isWhitespace(masked[j]), !PdfBytes.isDelimiter(masked[j]) { j += 1 }
            return start..<j
        case UInt8(ascii: "("):
            // Masked strings contain no parentheses, so a simple scan suffices.
            var j = i + 1
            while j < masked.count, masked[j] != UInt8(ascii: ")") { j += 1 }
            return j < masked.count ? start..<j + 1 : nil
        case UInt8(ascii: "["):
            return scanBalanced(open: UInt8(ascii: "["), close: UInt8(ascii: "]"))
        case UInt8(ascii: "<"):
            if i + 1 < masked.count, masked[i + 1] == UInt8(ascii: "<") {
                // Nested dictionary: track << >> pairs.
                var depth = 0
                var j = i
                while j + 1 < masked.count {
                    if masked[j] == UInt8(ascii: "<"), masked[j + 1] == UInt8(ascii: "<") { depth += 1; j += 2; continue }
                    if masked[j] == UInt8(ascii: ">"), masked[j + 1] == UInt8(ascii: ">") {
                        depth -= 1
                        j += 2
                        if depth == 0 { return start..<j }
                        continue
                    }
                    j += 1
                }
                return nil
            }
            var j = i + 1
            while j < masked.count, masked[j] != UInt8(ascii: ">") { j += 1 }
            return j < masked.count ? start..<j + 1 : nil
        default:
            // Number, boolean, null — and possibly an indirect reference.
            var j = i
            while j < masked.count, !PdfBytes.isWhitespace(masked[j]), !PdfBytes.isDelimiter(masked[j]) { j += 1 }
            let tokenEnd = j
            // Lookahead for "gen R" to capture references as one span.
            var k = tokenEnd
            while k < masked.count, PdfBytes.isWhitespace(masked[k]) { k += 1 }
            let genStart = k
            while k < masked.count, PdfBytes.isDigit(masked[k]) { k += 1 }
            if k > genStart {
                var m = k
                while m < masked.count, PdfBytes.isWhitespace(masked[m]) { m += 1 }
                if m < masked.count, masked[m] == UInt8(ascii: "R") {
                    let afterR = m + 1
                    if afterR >= masked.count || PdfBytes.isWhitespace(masked[afterR]) || PdfBytes.isDelimiter(masked[afterR]) {
                        return start..<afterR
                    }
                }
            }
            return start..<tokenEnd
        }
    }

    func hasKey(_ key: String) -> Bool {
        keyTokenRange(key) != nil
    }

    /// Raw source of an INLINE dictionary value ("<< ... >>"), used to promote
    /// direct /Outlines and /Info dictionaries to indirect objects the way
    /// ensure_outlines_root/ensure_info_dictionary do.
    func inlineDictionary(forKey key: String) -> [UInt8]? {
        guard let raw = rawValue(forKey: key), raw.count >= 4,
              raw[0] == UInt8(ascii: "<"), raw[1] == UInt8(ascii: "<")
        else { return nil }
        return raw
    }

    private func rawValue(forKey key: String) -> [UInt8]? {
        guard let keyRange = keyTokenRange(key), let span = valueSpan(afterKeyToken: keyRange) else { return nil }
        return Array(bytes[span])
    }

    /// Object number of an indirect reference value ("12 0 R" → 12).
    func reference(forKey key: String) -> Int? {
        guard let raw = rawValue(forKey: key) else { return nil }
        return PdfDictSource.parseReference(raw)
    }

    static func parseReference(_ raw: [UInt8]) -> Int? {
        var i = 0
        var number = 0
        var sawDigit = false
        while i < raw.count, PdfBytes.isDigit(raw[i]) { number = number * 10 + Int(raw[i] - 0x30); i += 1; sawDigit = true }
        guard sawDigit else { return nil }
        while i < raw.count, PdfBytes.isWhitespace(raw[i]) { i += 1 }
        let genStart = i
        while i < raw.count, PdfBytes.isDigit(raw[i]) { i += 1 }
        guard i > genStart else { return nil }
        while i < raw.count, PdfBytes.isWhitespace(raw[i]) { i += 1 }
        guard i < raw.count, raw[i] == UInt8(ascii: "R") else { return nil }
        return number
    }

    /// Plain integer value (not a reference).
    func integer(forKey key: String) -> Int? {
        guard let raw = rawValue(forKey: key) else { return nil }
        guard PdfDictSource.parseReference(raw) == nil else { return nil }
        let text = String(decoding: raw, as: UTF8.self)
        return Int(text)
    }

    func name(forKey key: String) -> String? {
        guard let raw = rawValue(forKey: key), raw.first == UInt8(ascii: "/") else { return nil }
        return String(decoding: raw.dropFirst(), as: UTF8.self)
    }

    /// Decoded text-string value (literal with escapes, or hex; UTF-16BE BOM aware).
    func textString(forKey key: String) -> String? {
        guard let raw = rawValue(forKey: key) else { return nil }
        return PdfDictSource.decodeTextString(raw)
    }

    static func decodeTextString(_ raw: [UInt8]) -> String? {
        var content: [UInt8] = []
        if raw.first == UInt8(ascii: "("), raw.last == UInt8(ascii: ")") {
            var i = 1
            let end = raw.count - 1
            while i < end {
                let byte = raw[i]
                if byte == UInt8(ascii: "\\"), i + 1 < end {
                    let next = raw[i + 1]
                    switch next {
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
                content.append(byte)
                i += 1
            }
        } else if raw.first == UInt8(ascii: "<"), raw.last == UInt8(ascii: ">") {
            var nibbles: [UInt8] = []
            for byte in raw.dropFirst().dropLast() {
                switch byte {
                case UInt8(ascii: "0")...UInt8(ascii: "9"): nibbles.append(byte - UInt8(ascii: "0"))
                case UInt8(ascii: "a")...UInt8(ascii: "f"): nibbles.append(byte - UInt8(ascii: "a") + 10)
                case UInt8(ascii: "A")...UInt8(ascii: "F"): nibbles.append(byte - UInt8(ascii: "A") + 10)
                default: continue
                }
            }
            if nibbles.count % 2 == 1 { nibbles.append(0) }
            for pair in stride(from: 0, to: nibbles.count, by: 2) {
                content.append(nibbles[pair] << 4 | nibbles[pair + 1])
            }
        } else {
            return nil
        }

        if content.count >= 2, content[0] == 0xfe, content[1] == 0xff {
            let utf16 = stride(from: 2, to: content.count - 1, by: 2).map {
                UInt16(content[$0]) << 8 | UInt16(content[$0 + 1])
            }
            return String(decoding: utf16, as: UTF16.self)
        }
        // PDFDocEncoding ≈ Latin-1 for the identifiers this module compares.
        return String(bytes: content, encoding: .isoLatin1)
    }

    // MARK: Mutation

    /// Replace the value of `key`, or insert the entry right after "<<".
    mutating func setValue(forKey key: String, raw: [UInt8]) {
        if let keyRange = keyTokenRange(key), let span = valueSpan(afterKeyToken: keyRange) {
            bytes.replaceSubrange(span, with: raw)
        } else {
            var insertion = Array(" /\(key) ".utf8)
            insertion.append(contentsOf: raw)
            bytes.insert(contentsOf: insertion, at: 2)
        }
        masked = PdfDictSource.mask(bytes)
    }

    mutating func setReference(forKey key: String, to objectNumber: Int) {
        setValue(forKey: key, raw: Array("\(objectNumber) 0 R".utf8))
    }

    mutating func setInteger(forKey key: String, to value: Int) {
        setValue(forKey: key, raw: Array("\(value)".utf8))
    }

    mutating func removeEntry(forKey key: String) {
        guard let keyRange = keyTokenRange(key), let span = valueSpan(afterKeyToken: keyRange) else { return }
        bytes.removeSubrange(keyRange.lowerBound..<span.upperBound)
        masked = PdfDictSource.mask(bytes)
    }
}

// MARK: - Classic cross-reference file model

/// Parser for the classic-xref PDFs produced by PDFKit's serializer. Used only
/// on freshly normalized in-memory data, never on arbitrary user files.
struct ClassicPdfFile {
    let data: Data
    private let bytes: [UInt8]
    private(set) var objectOffsets: [Int: Int] = [:]
    private(set) var trailer: PdfDictSource
    let startXref: Int

    var size: Int { trailer.integer(forKey: "Size") ?? 0 }
    var rootNumber: Int? { trailer.reference(forKey: "Root") }
    var infoNumber: Int? { trailer.reference(forKey: "Info") }

    init(data: Data) throws {
        self.data = data
        self.bytes = [UInt8](data)

        guard let startXrefRange = PdfBytes.lastRange(of: Array("startxref".utf8), in: bytes) else {
            throw SessionServiceError.invalidDocument("Failed to rewrite PDF: no cross-reference offset")
        }
        var i = startXrefRange.upperBound
        while i < bytes.count, PdfBytes.isWhitespace(bytes[i]) { i += 1 }
        var offset = 0
        var sawDigit = false
        while i < bytes.count, PdfBytes.isDigit(bytes[i]) {
            offset = offset * 10 + Int(bytes[i] - 0x30)
            i += 1
            sawDigit = true
        }
        guard sawDigit, offset < bytes.count else {
            throw SessionServiceError.invalidDocument("Failed to rewrite PDF: invalid cross-reference offset")
        }
        startXref = offset

        var position = offset
        guard PdfBytes.firstRange(of: Array("xref".utf8), in: bytes, from: position, to: min(position + 8, bytes.count))?.lowerBound == position else {
            throw SessionServiceError.invalidDocument("Failed to rewrite PDF: unsupported cross-reference format")
        }
        position += 4
        while position < bytes.count, PdfBytes.isWhitespace(bytes[position]) { position += 1 }

        var offsets: [Int: Int] = [:]
        while position < bytes.count, PdfBytes.isDigit(bytes[position]) {
            var first = 0
            while position < bytes.count, PdfBytes.isDigit(bytes[position]) {
                first = first * 10 + Int(bytes[position] - 0x30)
                position += 1
            }
            while position < bytes.count, bytes[position] == UInt8(ascii: " ") { position += 1 }
            var count = 0
            while position < bytes.count, PdfBytes.isDigit(bytes[position]) {
                count = count * 10 + Int(bytes[position] - 0x30)
                position += 1
            }
            // Skip to the start of the fixed-width entry lines.
            while position < bytes.count, PdfBytes.isWhitespace(bytes[position]) { position += 1 }
            for entry in 0..<count {
                let entryStart = position
                guard entryStart + 18 <= bytes.count else { break }
                let line = String(decoding: bytes[entryStart..<entryStart + 18], as: UTF8.self)
                let parts = line.split(separator: " ")
                if parts.count >= 3, parts[2].hasPrefix("n"), let entryOffset = Int(parts[0]) {
                    offsets[first + entry] = entryOffset
                }
                position = entryStart + 20
            }
            while position < bytes.count, PdfBytes.isWhitespace(bytes[position]) { position += 1 }
        }
        objectOffsets = offsets

        guard let trailerRange = PdfBytes.firstRange(of: Array("trailer".utf8), in: bytes, from: position)
            ?? PdfBytes.lastRange(of: Array("trailer".utf8), in: bytes)
        else {
            throw SessionServiceError.invalidDocument("Failed to rewrite PDF: missing trailer")
        }
        guard let trailerDict = ClassicPdfFile.balancedDictionary(in: bytes, from: trailerRange.upperBound) else {
            throw SessionServiceError.invalidDocument("Failed to rewrite PDF: invalid trailer")
        }
        trailer = PdfDictSource(trailerDict)
    }

    /// Dictionary source of an indirect object, or nil when the object is not
    /// a plain dictionary at a known offset.
    func objectSource(_ number: Int) -> PdfDictSource? {
        guard let offset = objectOffsets[number], offset < bytes.count else { return nil }
        guard let objRange = PdfBytes.firstRange(of: Array("obj".utf8), in: bytes, from: offset, to: min(offset + 64, bytes.count)) else { return nil }
        guard let source = ClassicPdfFile.balancedDictionary(in: bytes, from: objRange.upperBound) else { return nil }
        return PdfDictSource(source)
    }

    /// Extract a balanced "<< ... >>" starting at the first "<<" after `start`,
    /// skipping string contents while balancing.
    private static func balancedDictionary(in bytes: [UInt8], from start: Int) -> [UInt8]? {
        var i = start
        while i < bytes.count, PdfBytes.isWhitespace(bytes[i]) { i += 1 }
        guard i + 1 < bytes.count, bytes[i] == UInt8(ascii: "<"), bytes[i + 1] == UInt8(ascii: "<") else { return nil }
        let dictStart = i
        var depth = 0
        while i < bytes.count {
            let byte = bytes[i]
            if byte == UInt8(ascii: "(") {
                // Skip literal string with escapes.
                var stringDepth = 1
                i += 1
                while i < bytes.count, stringDepth > 0 {
                    if bytes[i] == UInt8(ascii: "\\") { i += 2; continue }
                    if bytes[i] == UInt8(ascii: "(") { stringDepth += 1 }
                    if bytes[i] == UInt8(ascii: ")") { stringDepth -= 1 }
                    i += 1
                }
                continue
            }
            if byte == UInt8(ascii: "<"), i + 1 < bytes.count, bytes[i + 1] == UInt8(ascii: "<") {
                depth += 1
                i += 2
                continue
            }
            if byte == UInt8(ascii: "<") {
                // Hex string.
                i += 1
                while i < bytes.count, bytes[i] != UInt8(ascii: ">") { i += 1 }
                i += 1
                continue
            }
            if byte == UInt8(ascii: ">"), i + 1 < bytes.count, bytes[i + 1] == UInt8(ascii: ">") {
                depth -= 1
                i += 2
                if depth == 0 { return Array(bytes[dictStart..<i]) }
                continue
            }
            i += 1
        }
        return nil
    }
}

// MARK: - Incremental update builder

/// Builds an incremental update (new/replaced objects + classic xref section +
/// trailer) appended to freshly serialized data. Applied in memory only; the
/// result is re-serialized through PDFKit before touching disk.
struct PdfIncrement {
    private var objects: [Int: [UInt8]] = [:]
    private(set) var nextObjectNumber: Int
    private let file: ClassicPdfFile

    init(file: ClassicPdfFile) {
        self.file = file
        self.nextObjectNumber = file.size
    }

    mutating func allocateObjectNumber() -> Int {
        let number = nextObjectNumber
        nextObjectNumber += 1
        return number
    }

    mutating func setObject(_ number: Int, source: [UInt8]) {
        objects[number] = source
    }

    /// Mark an object as replaced by `null` (used to drop deleted bookmarks).
    mutating func setNull(_ number: Int) {
        objects[number] = Array("null".utf8)
    }

    func object(_ number: Int) -> [UInt8]? {
        objects[number]
    }

    /// The base data with the update appended. `infoNumber` overrides the
    /// trailer /Info reference when the Info dictionary moved. Built at the
    /// byte level: copied object sources may contain non-UTF8 string literals
    /// and must pass through unmodified.
    func appended(infoNumber: Int? = nil) -> Data {
        var out = file.data
        var body: [UInt8] = [UInt8(ascii: "\n")]
        var offsets: [Int: Int] = [:]
        for (number, source) in objects.sorted(by: { $0.key < $1.key }) {
            offsets[number] = out.count + body.count
            body.append(contentsOf: Array("\(number) 0 obj\n".utf8))
            body.append(contentsOf: source)
            body.append(contentsOf: Array("\nendobj\n".utf8))
        }
        let xrefOffset = out.count + body.count
        body.append(contentsOf: Array("xref\n".utf8))
        let numbers = offsets.keys.sorted()
        var index = 0
        while index < numbers.count {
            var end = index
            while end + 1 < numbers.count, numbers[end + 1] == numbers[end] + 1 { end += 1 }
            body.append(contentsOf: Array("\(numbers[index]) \(end - index + 1)\n".utf8))
            for k in index...end {
                body.append(contentsOf: Array(String(format: "%010d 00000 n \n", offsets[numbers[k]]!).utf8))
            }
            index = end + 1
        }
        var trailer = "trailer\n<< /Size \(nextObjectNumber)"
        if let root = file.rootNumber { trailer += " /Root \(root) 0 R" }
        if let info = infoNumber ?? file.infoNumber { trailer += " /Info \(info) 0 R" }
        trailer += " /Prev \(file.startXref) >>\nstartxref\n\(xrefOffset)\n%%EOF\n"
        body.append(contentsOf: Array(trailer.utf8))
        out.append(Data(body))
        return out
    }
}

// MARK: - PDF text-string encoding (for raw dictionary writes)

enum PdfTextString {
    /// Serialize a text string the way lopdf's text_string does semantically:
    /// ASCII-safe content as an escaped literal, everything else as UTF-16BE
    /// with BOM (hex form, so the increment stays printable).
    static func encode(_ value: String) -> [UInt8] {
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
