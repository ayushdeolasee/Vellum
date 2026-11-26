import Foundation

// The editing subset is deliberately narrower than the PDF reader. Read physical
// objects in order so an xref offset can only name an actual object boundary.
// Streams are opaque and skipped by length, never searched for object markers.
enum PdfStructuralValue {
    case dictionary([String: Self]), array([Self]), name(String), string(Range<Int>)
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

    let bytes: [UInt8]
    private var i = 0
    private var remaining = 500_000
    private var remainingComparisonBytes = 64 * 1024 * 1024
    private var portableSyntax = true
    private let objectLimit = 100_000
    private var offsets: [Int: Int] = [:]
    private var free: [Int: (next: Int, generation: Int)] = [:]
    private(set) var objects: [Int: Value] = [:]
    private var streams: [Int: Value] = [:] // Keep stream dictionaries for security checks.
    private var previousXref: Int?
    private var previousSize = 0
    private var hadInfo = false
    private var hadID = false

    init(_ data: Data) { bytes = Array(data) }

    func charge(_ count: Int = 1) throws {
        guard count <= remaining else { throw Reason.malformed }
        remaining -= count
    }

    func inspect() throws {
        guard consume("%PDF-"), i + 3 < bytes.count,
              [49, 50].contains(bytes[i]), bytes[i + 1] == 46,
              PdfBytes.isDigit(bytes[i + 2]), [10, 13].contains(bytes[i + 3])
        else { throw Reason.malformed }
        i += 3
        var revisions = 0
        repeat {
            revisions += 1
            guard revisions <= 64 else { throw Reason.malformed }
            var newObjects = Set<Int>()
            skipOuterTrivia()
            while !starts("xref") {
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
                if consumeWord("stream") {
                    guard let dict = body.dictionary else { throw Reason.malformed }
                    if dict["Type"]?.name == "XRef" || dict["Type"]?.name == "ObjStm" {
                        throw Reason.unsupportedXref
                    }
                    guard let length = dict["Length"]?.integer, length >= 0,
                          consume("\r\n") || consume("\n"), length <= bytes.count - i
                    else { throw Reason.malformed }
                    i += length
                    try keyword("endstream")
                    streams[number] = body
                    objects[number] = .stream
                } else {
                    // rawObjectValue uses the first endobj marker. Its range
                    // must agree even when that word occurs inside a string.
                    if bytes[bodyStart..<bodyEnd].contains(101),
                       bytes[bodyStart..<bodyEnd].firstRange(of: "endobj".utf8) != nil {
                        portableSyntax = false
                    }
                    streams.removeValue(forKey: number)
                    objects[number] = body
                }
                try keyword("endobj")
                offsets[number] = offset
                skipOuterTrivia()
            }
            try revision(newObjects: newObjects)
            skipSpace()
        } while i < bytes.count
        guard portableSyntax else { throw Reason.malformed }
    }

    private func revision(newObjects: Set<Int>) throws {
        let xref = i
        try keyword("xref")
        var listed = Set<Int>()
        var pending = newObjects
        skipSpace()
        while i < bytes.count, PdfBytes.isDigit(bytes[i]) {
            let first = try unsigned()
            // ClassicPdfFile consumes spaces between subsection start and count.
            guard i < bytes.count, bytes[i] == 32 else { throw Reason.malformed }
            while i < bytes.count, bytes[i] == 32 { i += 1 }
            guard i < bytes.count, PdfBytes.isDigit(bytes[i]) else { throw Reason.malformed }
            let count = try unsigned()
            guard count > 0, first < objectLimit, count <= objectLimit - first else { throw Reason.malformed }
            try charge(count)
            skipSpace()
            for number in first..<(first + count) {
                guard listed.insert(number).inserted, bytes.count - i >= 20,
                      bytes[i + 10] == 32, bytes[i + 16] == 32 else { throw Reason.malformed }
                let offset = try digits(i..<(i + 10))
                let generation = try digits((i + 11)..<(i + 16))
                let flag = bytes[i + 17]
                i += 18
                guard consume(" \n") || consume(" \r") || consume("\r\n") else { throw Reason.malformed }
                if flag == 110 { // n
                    guard generation == 0 else { throw Reason.nonzeroGeneration }
                    guard number > 0, offsets[number] == offset else { throw Reason.malformed }
                    if let entry = free.removeValue(forKey: number), entry.generation != 0 { throw Reason.malformed }
                    pending.remove(number)
                } else {
                    guard flag == 102, generation <= 65535, offset < objectLimit,
                          number != 0 || generation == 65535, !pending.contains(number)
                    else { throw Reason.malformed }
                    guard generation >= (free[number]?.generation ?? 0),
                          objects[number] == nil || generation > 0 else { throw Reason.malformed }
                    free[number] = (offset, generation)
                    objects.removeValue(forKey: number)
                    streams.removeValue(forKey: number)
                    offsets.removeValue(forKey: number)
                }
            }
            skipSpace()
        }
        try keyword("trailer")
        guard let trailer = try value().dictionary else { throw Reason.malformed }
        if trailer["Encrypt"] != nil { throw Reason.encrypted }
        if trailer["XRefStm"] != nil { throw Reason.unsupportedXref }
        guard pending.isEmpty, previousXref != nil || listed.contains(0),
              let size = trailer["Size"]?.integer, size >= previousSize, size <= objectLimit,
              size == max(previousSize, (listed.max() ?? -1) + 1),
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
        // A linked free list may terminate at object zero. Entries marked
        // permanently free can also stand alone. Reject dangling links/cycles.
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
        try validate(trailer: trailer, streamDictionaries: streams.values)
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
                if nesting == 0 { return .string(start..<i) }
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
            return .string(start..<i)
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
