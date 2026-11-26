import Foundation

// The editing subset is deliberately narrower than the PDF reader. Read physical
// objects in order so an xref offset can only name an actual object boundary.
// Streams are opaque and skipped by length, never searched for object markers.
enum PdfStructuralValue {
    case dictionary([String: Self]), array([Self]), name(String), string(ArraySlice<UInt8>)
    case integer(Int), real(Double), reference(Int), null, boolean, stream

    var dictionary: [String: Self]? {
        if case .dictionary(let entries) = self { return entries }
        return nil
    }
    var integer: Int? {
        if case .integer(let value) = self { return value }
        return nil
    }
    var reference: Int? {
        if case .reference(let number) = self { return number }
        return nil
    }
    var name: String? {
        if case .name(let value) = self { return value }
        return nil
    }
    var number: Double? {
        if case .real(let value) = self { return value }
        return integer.map(Double.init)
    }
}

final class PdfClassicStructure {
    typealias Value = PdfStructuralValue
    typealias Reason = PdfReadOnlyReason

    private var bytes: [UInt8]
    private var i = 0
    private var remaining = 500_000
    private var remainingComparisonBytes = 64 * 1024 * 1024
    private var portableSyntax = true
    private let objectLimit = 100_000
    private(set) var offsets: [Int: Int] = [:]
    private var free: [Int: (next: Int, generation: Int)] = [:]
    private(set) var objects: [Int: Value] = [:]
    private var streams: [Int: Value] = [:] // Keep stream dictionaries for security checks.
    private var previousXref: Int?
    private var previousSize = 0
    private var hadInfo = false
    private var hadID = false

    private var decoder = PdfStreamDecoder()
    private var objectStreams: [Int: [(number: Int, value: Value, source: ArraySlice<UInt8>)]] = [:]
    private var compressed: [Int: (stream: Int, index: Int)] = [:]
    private(set) var compressedSources: [Int: ArraySlice<UInt8>] = [:]
    private struct LengthSection {
        let previous: Int?
        let rows: [Int: PdfXrefRow]
    }
    private var lengthSections: [LengthSection]?
    private var indirectLengths: [Int: (number: Int, length: Int)] = [:]
    private(set) var latestTrailer = PdfDictSource([])
    private(set) var usesXrefStreams = false

    init(_ data: Data, decodedLimit: Int = 64 * 1024 * 1024) {
        bytes = Array(data)
        decoder.remaining = decodedLimit
    }

    func charge(_ count: Int = 1) throws {
        guard count <= remaining else { throw Reason.malformed }
        remaining -= count
    }

    private struct XrefStream {
        let number: Int
        let offset: Int
        let dict: [String: Value]
        let source: PdfDictSource
        let payload: Range<Int>
    }

    func inspect(forEditing: Bool = true) throws {
        guard consume("%PDF-"), i + 3 < bytes.count,
              bytes[i + 1] == 46, [10, 13].contains(bytes[i + 3]),
              (bytes[i] == 49 && (48...55).contains(bytes[i + 2])) || (bytes[i] == 50 && bytes[i + 2] == 48)
        else { throw Reason.malformed }
        i += 3
        var revisions = 0
        repeat {
            revisions += 1
            guard revisions <= 64 else { throw Reason.malformed }
            var newObjects = Set<Int>()
            var xrefStream: XrefStream?
            skipOuterTrivia()
            while !starts("xref") && !starts("startxref") {
                try charge()
                let offset = i
                let number = try unsigned()
                guard (1..<objectLimit).contains(number), newObjects.insert(number).inserted
                else { throw Reason.malformed }
                guard try unsigned() == 0 else { throw Reason.nonzeroGeneration }
                try keyword("obj")
                guard i - offset < 64 else { throw Reason.malformed }
                skipSpace()
                let bodyStart = i
                let body = try value()
                let bodyEnd = i
                skipSpace()
                streams.removeValue(forKey: number)
                indirectLengths.removeValue(forKey: number)
                objectStreams.removeValue(forKey: number)
                if consumeWord("stream") {
                    guard let dict = body.dictionary else { throw Reason.malformed }
                    var count = dict["Length"]?.integer
                    if !forEditing, count == nil, let ref = dict["Length"]?.reference,
                       dict["Type"]?.name != "XRef" {
                        let length = try readIndirectLength(ref)
                        indirectLengths[number] = (ref, length)
                        count = length
                    }
                    guard let length = count, length >= 0,
                          consume("\r\n") || consume("\n"), length <= bytes.count - i
                    else { throw Reason.malformed }
                    let payload = i..<(i + length)
                    i += length
                    try endStream()
                    objects[number] = .stream
                    switch dict["Type"]?.name {
                    case "XRef":
                        if dict["Encrypt"] != nil { throw Reason.encrypted }
                        guard xrefStream == nil else { throw Reason.malformed }
                        xrefStream = XrefStream(number: number, offset: offset, dict: dict,
                            source: PdfDictSource(Array(bytes[bodyStart..<bodyEnd])), payload: payload)
                    case "ObjStm":
                        objectStreams[number] = try unpack(bytes[payload], dict: dict)
                        streams[number] = body
                    default:
                        streams[number] = body
                    }
                } else {
                    if bytes[bodyStart..<bodyEnd].firstRange(of: "endobj".utf8) != nil { portableSyntax = false }
                    objects[number] = body
                }
                try keyword("endobj")
                offsets[number] = offset
                skipOuterTrivia()
            }
            try revision(newObjects: newObjects, stream: xrefStream, forEditing: forEditing)
            skipSpace()
        } while i < bytes.count
        guard !forEditing || portableSyntax else { throw Reason.malformed }
    }

    /// Parse every member against its header bounds with the same grammar and
    /// work counters as physical objects. A type-2 row must match both fields.
    private func unpack(_ input: ArraySlice<UInt8>, dict: [String: Value]) throws
        -> [(number: Int, value: Value, source: ArraySlice<UInt8>)] {
        guard let count = dict["N"]?.integer, (1..<objectLimit).contains(count),
              let first = dict["First"]?.integer, first >= 0, dict["Extends"] == nil else { throw Reason.malformed }
        try charge(count)
        let decoded = try decoder.decode(input, dictionary: dict)
        guard first < decoded.count else { throw Reason.malformed }
        let original = bytes, cursor = i
        bytes = decoded
        i = 0
        defer { bytes = original; i = cursor }
        var seen = Set<Int>()
        var headers: [(number: Int, offset: Int)] = []
        for _ in 0..<count {
            let number = try unsigned(), offset = try unsigned()
            guard (1..<objectLimit).contains(number), seen.insert(number).inserted,
                  offset < decoded.count - first, offset > (headers.last?.offset ?? -1),
                  i <= first else { throw Reason.malformed }
            headers.append((number, offset))
        }
        skipSpace()
        guard headers[0].offset == 0, i == first else { throw Reason.malformed }
        return try headers.enumerated().map { index, header in
            let start = first + header.offset
            let end = index + 1 < count ? first + headers[index + 1].offset : decoded.count
            guard i == start else { throw Reason.malformed }
            let body = try value()
            let source = bytes[start..<i]
            skipSpace()
            guard i == end else { throw Reason.malformed }
            return (header.number, body, source)
        }
    }

    private func classicRows() throws -> [Int: PdfXrefRow] {
        try keyword("xref")
        var rows: [Int: PdfXrefRow] = [:]
        skipSpace()
        while i < bytes.count, PdfBytes.isDigit(bytes[i]) {
            let first = try unsigned()
            guard i < bytes.count, bytes[i] == 32 else { throw Reason.malformed }
            while i < bytes.count, bytes[i] == 32 { i += 1 }
            guard i < bytes.count, PdfBytes.isDigit(bytes[i]) else { throw Reason.malformed }
            let count = try unsigned()
            guard count > 0, first < objectLimit, count <= objectLimit - first else { throw Reason.malformed }
            try charge(count)
            skipSpace()
            for number in first..<(first + count) {
                guard rows[number] == nil, bytes.count - i >= 20,
                      bytes[i + 10] == 32, bytes[i + 16] == 32 else { throw Reason.malformed }
                let offset = try digits(i..<(i + 10))
                let generation = try digits((i + 11)..<(i + 16))
                let flag = bytes[i + 17]
                i += 18
                guard consume(" \n") || consume(" \r") || consume("\r\n") else { throw Reason.malformed }
                switch flag {
                case 110: rows[number] = .direct(offset: offset, generation: generation)
                case 102: rows[number] = .free(next: offset, generation: generation)
                default: throw Reason.malformed
                }
            }
            skipSpace()
        }
        return rows
    }

    private func revision(newObjects: Set<Int>, stream: XrefStream?, forEditing: Bool) throws {
        var xref = i
        var rows: [Int: PdfXrefRow] = [:]
        let table = starts("xref")
        let trailer: [String: Value]
        if table {
            rows = try classicRows()
            try keyword("trailer")
            skipSpace()
            let start = i
            guard let dictionary = try value().dictionary else { throw Reason.malformed }
            trailer = dictionary
            latestTrailer = PdfDictSource(Array(bytes[start..<i]))
            if trailer["Encrypt"] != nil { throw Reason.encrypted }
            if trailer["XRefStm"] != nil || stream != nil {
                guard let stream, trailer["XRefStm"]?.integer == stream.offset else { throw Reason.unsupportedXref }
                for key in ["Root", "Info", "ID", "Size"] where stream.dict[key] != nil {
                    guard latestTrailer.rawValue(forKey: key) == stream.source.rawValue(forKey: key)
                    else { throw Reason.malformed }
                }
            }
        } else {
            guard let stream, newObjects.allSatisfy({ (offsets[$0] ?? Int.max) <= stream.offset }) else { throw Reason.malformed }
            xref = stream.offset
            trailer = stream.dict
            latestTrailer = stream.source
            guard trailer["XRefStm"] == nil else { throw Reason.malformed }
        }
        if let stream {
            usesXrefStreams = true
            let decoded = try decoder.decode(bytes[stream.payload], dictionary: stream.dict)
            let supplement = try PdfStreamDecoder.rows(decoded, dictionary: stream.dict, limit: objectLimit)
            try charge(supplement.count)
            // ISO 32000 hybrid precedence: the supplementary stream overrides
            // the table of this revision (including its free placeholders).
            rows.merge(supplement) { _, streamRow in streamRow }
            guard case .direct(stream.offset, 0) = rows[stream.number] else { throw Reason.malformed }
        }
        guard !rows.isEmpty, previousXref != nil || rows[0] != nil,
              let size = trailer["Size"]?.integer, size >= previousSize, size <= objectLimit,
              size == max(previousSize, (rows.keys.max() ?? -1) + 1),
              !hadInfo || trailer["Info"] != nil, !hadID || trailer["ID"] != nil,
              trailer["Prev"] == nil || trailer["Prev"]?.integer != nil,
              trailer["Prev"]?.integer == previousXref else { throw Reason.malformed }
        try keyword("startxref")
        guard try unsigned() == xref else { throw Reason.malformed }
        skipSpace()
        guard consume("%%EOF") else { throw Reason.malformed }
        while i < bytes.count, bytes[i] == 32 || bytes[i] == 9 { i += 1 }
        guard i == bytes.count || bytes[i] == 10 || bytes[i] == 13 else { throw Reason.malformed }
        previousXref = xref
        previousSize = size
        hadInfo = trailer["Info"] != nil
        hadID = trailer["ID"] != nil
        for number in newObjects {
            guard case .direct = rows[number] else { throw Reason.malformed }
        }
        for (number, row) in rows {
            switch row {
            case .direct(let offset, let generation):
                guard generation == 0 else { throw Reason.nonzeroGeneration }
                guard number > 0, offsets[number] == offset else { throw Reason.malformed }
                if let old = free.removeValue(forKey: number), old.generation != 0 { throw Reason.malformed }
                compressed.removeValue(forKey: number)
            case .free(let next, let generation):
                guard generation <= 65535, next < objectLimit,
                      number != 0 || generation == 65535 || (stream != nil && generation == 0),
                      generation >= (free[number]?.generation ?? 0),
                      objects[number] == nil || generation > 0 else { throw Reason.malformed }
                free[number] = (next, generation)
                offsets.removeValue(forKey: number)
                objects.removeValue(forKey: number)
                streams.removeValue(forKey: number)
                objectStreams.removeValue(forKey: number)
                compressed.removeValue(forKey: number)
            case .compressed(let container, let index):
                guard number > 0, container != number else { throw Reason.malformed }
                if let old = free.removeValue(forKey: number), old.generation != 0 { throw Reason.malformed }
                offsets.removeValue(forKey: number)
                streams.removeValue(forKey: number)
                objectStreams.removeValue(forKey: number)
                compressed[number] = (container, index)
            }
        }
        compressedSources.removeAll(keepingCapacity: true)
        try charge(compressed.count)
        for (number, entry) in compressed {
            guard let members = objectStreams[entry.stream], members.indices.contains(entry.index),
                  members[entry.index].number == number else { throw Reason.malformed }
            let member = members[entry.index]
            compressedSources[number] = member.source
            objects[number] = member.value
        }
        var visitedFree = Set<Int>()
        for start in free.keys where !visitedFree.contains(start) {
            var n = start
            var chain = Set<Int>()
            repeat {
                try charge()
                guard chain.insert(n).inserted, let entry = free[n] else { throw Reason.malformed }
                n = entry.next
            } while n != 0 && !visitedFree.contains(n)
            visitedFree.formUnion(chain)
        }
        // The xref lookahead only proposed a length. The physical walk must
        // independently reach the referenced integer as a live object at this
        // revision, including when its definition follows the stream payload.
        for (number, length) in indirectLengths {
            try charge()
            if streams[number] != nil, objects[length.number]?.integer != length.length { throw Reason.malformed }
        }
        guard forEditing else { return }
        if table, let stream {
            // Historical xref dictionaries are trailers, not ordinary inbound
            // references to today's page tree or Info dictionary.
            var inbound: [Int: Int] = [:]
            try inspect(.dictionary(stream.dict), inbound: &inbound, structuralStream: true)
        }
        guard usesXrefStreams || objectStreams.isEmpty else { throw Reason.unsupportedXref }
        try validate(trailer: trailer, streamDictionaries: streams.values, streamTrailer: !table)
    }

    /// Only needed for a read-only file with an indirect /Length. Read xref
    /// entries from their declared offsets, never by scanning a stream payload.
    /// The subsequent physical walk validates the hints and revision links.
    private func readIndirectLength(_ number: Int) throws -> Int {
        let cursor = i
        defer { i = cursor }
        if lengthSections == nil { lengthSections = try indexForLengths() }
        guard let sections = lengthSections,
              let current = sections.firstIndex(where: { $0.previous == previousXref }) else { throw Reason.malformed }
        for section in sections[current...] {
            try charge()
            guard let row = section.rows[number] else { continue }
            guard case .direct(let offset, 0) = row, bytes.indices.contains(offset) else { throw Reason.malformed }
            i = offset
            guard try unsigned() == number, try unsigned() == 0 else { throw Reason.malformed }
            try keyword("obj")
            let length = try unsigned()
            try keyword("endobj")
            try budgetComparison(length: i - offset, passes: 1)
            return length
        }
        throw Reason.malformed
    }

    private func indexForLengths() throws -> [LengthSection] {
        guard let marker = bytes.suffix(1024).lastRange(of: Array("startxref".utf8)) else { throw Reason.malformed }
        i = marker.upperBound
        var offset = try unsigned()
        var sections: [LengthSection] = []
        while true {
            guard sections.count < 64, bytes.indices.contains(offset) else { throw Reason.malformed }
            i = offset
            var rows: [Int: PdfXrefRow]
            let trailer: [String: Value]
            if starts("xref") {
                rows = try classicRows()
                try keyword("trailer")
                guard let dictionary = try value().dictionary else { throw Reason.malformed }
                trailer = dictionary
                if let entry = trailer["XRefStm"] {
                    guard let supplement = entry.integer, (0..<offset).contains(supplement) else { throw Reason.malformed }
                    let stream = try indexedStream(at: supplement)
                    rows.merge(stream.rows) { _, row in row }
                }
            } else {
                (rows, trailer) = try indexedStream(at: offset)
            }
            if trailer["Encrypt"] != nil { throw Reason.encrypted }
            let previous = trailer["Prev"]?.integer
            sections.append(LengthSection(previous: previous, rows: rows))
            guard trailer["Prev"] != nil else { return sections }
            guard let previous, (0..<offset).contains(previous) else { throw Reason.malformed }
            offset = previous
        }
    }

    private func indexedStream(at offset: Int) throws -> (rows: [Int: PdfXrefRow], trailer: [String: Value]) {
        i = offset
        _ = try unsigned()
        guard try unsigned() == 0 else { throw Reason.nonzeroGeneration }
        try keyword("obj")
        guard let dictionary = try value().dictionary, dictionary["Type"]?.name == "XRef",
              let length = dictionary["Length"]?.integer, length >= 0 else { throw Reason.malformed }
        if dictionary["Encrypt"] != nil { throw Reason.encrypted }
        try keyword("stream")
        guard consume("\r\n") || consume("\n"), length <= bytes.count - i else { throw Reason.malformed }
        let payload = bytes[i..<(i + length)]
        i += length
        try endStream()
        try keyword("endobj")
        let decoded = try decoder.decode(payload, dictionary: dictionary)
        let rows = try PdfStreamDecoder.rows(decoded, dictionary: dictionary, limit: objectLimit)
        try charge(rows.count)
        return (rows, dictionary)
    }

    private func budgetComparison(length: Int, passes: Int) throws {
        guard length <= remainingComparisonBytes / passes else { throw Reason.malformed }
        remainingComparisonBytes -= length * passes
    }

    private func starts(_ token: String) -> Bool {
        bytes[i...].starts(with: token.utf8)
    }

    private func consume(_ token: String) -> Bool {
        guard starts(token) else { return false }
        i += token.utf8.count
        return true
    }

    private func consumeWord(_ token: String) -> Bool {
        guard starts(token) else { return false }
        let end = i + token.utf8.count
        guard end == bytes.count || PdfBytes.isWhitespace(bytes[end]) || PdfBytes.isDelimiter(bytes[end])
        else { return false }
        i = end
        return true
    }

    private func skipSpace() {
        while i < bytes.count, PdfBytes.isWhitespace(bytes[i]) { i += 1 }
    }

    private func skipOuterTrivia() {
        skipSpace()
        while i < bytes.count, bytes[i] == 37 {
            while i < bytes.count, bytes[i] != 10, bytes[i] != 13 { i += 1 }
            skipSpace()
        }
    }

    private func endStream() throws {
        // /Length excludes at most the optional EOL before endstream. Skipping
        // general PDF whitespace here could hide an incorrect length in binary data.
        _ = consume("\r\n") || consume("\n") || consume("\r")
        guard consumeWord("endstream") else { throw Reason.malformed }
    }

    private func keyword(_ word: String) throws {
        skipSpace()
        guard consumeWord(word) else { throw Reason.malformed }
    }

    private func unsigned() throws -> Int {
        skipSpace()
        let start = i
        while i < bytes.count, PdfBytes.isDigit(bytes[i]) { i += 1 }
        guard i == bytes.count || PdfBytes.isWhitespace(bytes[i]) || PdfBytes.isDelimiter(bytes[i])
        else { throw Reason.malformed }
        return try digits(start..<i)
    }

    private func digits(_ range: Range<Int>) throws -> Int {
        guard !range.isEmpty, range.count <= 19, bytes[range].allSatisfy(PdfBytes.isDigit),
              let result = Int(String(decoding: bytes[range], as: UTF8.self)) else { throw Reason.malformed }
        return result
    }

    private func token() throws -> String {
        let start = i
        while i < bytes.count, !PdfBytes.isWhitespace(bytes[i]), !PdfBytes.isDelimiter(bytes[i]) { i += 1 }
        guard i > start, i - start <= 256, bytes[start..<i].allSatisfy({ (33...126).contains($0) })
        else { throw Reason.malformed }
        return String(decoding: bytes[start..<i], as: UTF8.self)
    }

    private func name() throws -> String {
        guard consume("/") else { throw Reason.malformed }
        let raw = try token()
        // The portable writer matches literal key spellings. Encoded names
        // could alias a critical or duplicate key that it would miss.
        guard raw.contains("#") else { return raw }
        portableSyntax = false
        var decoded: [UInt8] = []
        var chars = raw.utf8[...]
        while let b = chars.popFirst() {
            if b == 35 {
                guard chars.count >= 2, let byte = UInt8(String(decoding: chars.prefix(2), as: UTF8.self), radix: 16),
                      (32...126).contains(byte) else { throw Reason.malformed }
                decoded.append(byte)
                chars = chars.dropFirst(2)
            } else {
                decoded.append(b)
            }
        }
        return String(decoding: decoded, as: UTF8.self)
    }

    private func value(depth: Int = 0) throws -> Value {
        try charge()
        skipSpace()
        guard depth < 64, i < bytes.count else { throw Reason.malformed }
        let start = i
        if consume("<<") {
            var dict: [String: Value] = [:]
            var spans: [String: Range<Int>] = [:]
            skipSpace()
            while !consume(">>") {
                let key = try name()
                guard dict[key] == nil else { throw Reason.malformed }
                skipSpace()
                let valueStart = i
                dict[key] = try value(depth: depth + 1)
                spans[key] = valueStart..<i
                skipSpace()
            }
            // A structural proof alone cannot authorize an edit when the
            // portable writer sees a different key or value span.
            try budgetComparison(length: i - start, passes: spans.count + 1)
            let source = PdfDictSource(Array(bytes[start..<i]))
            for (key, span) in spans where source.rawValue(forKey: key)?.elementsEqual(bytes[span]) != true {
                portableSyntax = false
            }
            return .dictionary(dict)
        }
        if consume("[") {
            var items: [Value] = []
            var spans: [Range<Int>] = []
            skipSpace()
            while !consume("]") {
                let elementStart = i
                items.append(try value(depth: depth + 1))
                spans.append((elementStart - start)..<(i - start))
                skipSpace()
            }
            try budgetComparison(length: i - start, passes: 1)
            if PdfArraySource.elementSpans(inArray: Array(bytes[start..<i])) != spans { portableSyntax = false }
            return .array(items)
        }
        if starts("/") { return .name(try name()) }
        if consume("(") {
            var nesting = 1
            while i < bytes.count {
                let byte = bytes[i]
                i += 1
                switch byte {
                case 92:
                    guard i < bytes.count else { throw Reason.malformed }
                    i += 1
                case 40: nesting += 1
                case 41: nesting -= 1
                default: break
                }
                if nesting == 0 { return .string(bytes[start..<i]) }
            }
            throw Reason.malformed
        }
        if consume("<") {
            while i < bytes.count, bytes[i] != 62 {
                let b = bytes[i]
                guard PdfBytes.isWhitespace(b) || PdfBytes.isDigit(b) || (65...70).contains(b) || (97...102).contains(b)
                else { throw Reason.malformed }
                i += 1
            }
            guard consume(">") else { throw Reason.malformed }
            return .string(bytes[start..<i])
        }

        let raw = try token()
        switch raw {
        case "null": return .null
        case "true", "false": return .boolean
        default: break
        }
        if let integer = Int(raw) {
            let end = i
            skipSpace()
            if i < bytes.count, PdfBytes.isDigit(bytes[i]), let generation = try? unsigned() {
                skipSpace()
                if consumeWord("R") {
                    guard raw.utf8.allSatisfy(PdfBytes.isDigit), (1..<objectLimit).contains(integer)
                    else { throw Reason.malformed }
                    guard generation == 0 else { throw Reason.nonzeroGeneration }
                    return .reference(integer)
                }
            }
            i = end
            return .integer(integer)
        }
        guard raw.contains("."), raw.utf8.allSatisfy({ PdfBytes.isDigit($0) || [43, 45, 46].contains($0) }),
              let real = Double(raw), real.isFinite else { throw Reason.malformed }
        return .real(real)
    }
}
