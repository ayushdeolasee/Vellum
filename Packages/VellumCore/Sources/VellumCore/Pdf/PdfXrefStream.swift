import CZlib
import Foundation

enum PdfXrefRow {
    case free(next: Int, generation: Int)
    case direct(offset: Int, generation: Int)
    case compressed(stream: Int, index: Int)
}

/// Decoding is limited across the entire revision chain, including intermediate
/// predictor rows. Ordinary PDF content, font and image streams remain opaque.
struct PdfStreamDecoder {
    var remaining = 64 * 1024 * 1024
    typealias Value = PdfStructuralValue
    typealias Failure = PdfReadOnlyReason

    mutating func decode(_ input: ArraySlice<UInt8>, dictionary: [String: Value]) throws -> [UInt8] {
        guard input.count <= remaining else { throw Failure.inspectionLimit }
        guard dictionary["F"] == nil, dictionary["FFilter"] == nil, dictionary["FDecodeParms"] == nil
        else { throw Failure.unsupportedXref }
        guard let filter = dictionary["Filter"] else {
            guard dictionary["DecodeParms"] == nil else { throw Failure.unsupportedXref }
            remaining -= input.count
            return Array(input)
        }
        // One Flate stage, either directly or as a one-element filter chain.
        func single(_ value: Value?) throws -> Value? {
            if case .array(let array) = value {
                guard array.count == 1 else { throw Failure.unsupportedXref }
                return array[0]
            }
            return value
        }
        let name = try single(filter)?.name
        if name == "ASCIIHexDecode" {
            guard dictionary["DecodeParms"] == nil else { throw Failure.unsupportedXref }
            var result: [UInt8] = []
            var high: UInt8?
            var ended = false
            for byte in input where !PdfBytes.isWhitespace(byte) {
                guard !ended else { throw Failure.malformed }
                if byte == 62 { ended = true; continue }
                let digit: UInt8
                switch byte {
                case 48...57: digit = byte - 48
                case 65...70: digit = byte - 55
                case 97...102: digit = byte - 87
                default: throw Failure.malformed
                }
                if let first = high {
                    result.append(first << 4 | digit)
                    high = nil
                } else { high = digit }
            }
            guard ended else { throw Failure.malformed }
            if let high { result.append(high << 4) }
            remaining -= result.count
            return result
        }
        guard name == "FlateDecode" else { throw Failure.unsupportedXref }
        var stream = z_stream()
        guard inflateInit_(&stream, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size)) == Z_OK
        else { throw Failure.malformed }
        defer { inflateEnd(&stream) }
        var output: [UInt8] = []
        var chunk = [UInt8](repeating: 0, count: 32768)
        try input.withUnsafeBufferPointer { source in
            stream.next_in = UnsafeMutablePointer(mutating: source.baseAddress)
            stream.avail_in = uInt(source.count)
            while true {
                let status = chunk.withUnsafeMutableBufferPointer { buffer in
                    stream.next_out = buffer.baseAddress
                    stream.avail_out = uInt(buffer.count)
                    return inflate(&stream, Z_NO_FLUSH)
                }
                let count = chunk.count - Int(stream.avail_out)
                guard count <= remaining else { throw Failure.inspectionLimit }
                remaining -= count
                output.append(contentsOf: chunk.prefix(count))
                if status == Z_STREAM_END {
                    guard stream.avail_in == 0 else { throw Failure.malformed }
                    break
                }
                guard status == Z_OK, count > 0 else { throw Failure.malformed }
            }
        }
        guard let parameters = try single(dictionary["DecodeParms"]) else { return output }
        if case .null = parameters { return output }
        guard let dict = parameters.dictionary else { throw Failure.unsupportedXref }
        func positive(_ key: String, default fallback: Int) throws -> Int {
            guard let value = dict[key] else { return fallback }
            guard let number = value.integer, (1...1_000_000).contains(number) else { throw Failure.malformed }
            return number
        }
        let predictor = try positive("Predictor", default: 1)
        if predictor == 1 { return output }
        let columns = try positive("Columns", default: 1)
        let colors = try positive("Colors", default: 1)
        let bits = try positive("BitsPerComponent", default: 8)
        guard colors <= 32, [1, 2, 4, 8, 16].contains(bits) else { throw Failure.unsupportedXref }
        let samples = colors * columns
        let row = (samples * bits + 7) / 8
        if predictor == 2 {
            guard output.count % row == 0 else { throw Failure.malformed }
            // TIFF differences are per component (including packed samples).
            // Charge sample work as well as bytes for sub-byte components.
            let rows = output.count / row
            guard rows * samples <= remaining else { throw Failure.inspectionLimit }
            remaining -= rows * samples
            for base in stride(from: 0, to: output.count, by: row) {
                var previous = [Int](repeating: 0, count: colors)
                for sample in 0..<samples {
                    let bit = sample * bits
                    let at = base + bit / 8
                    let shift = bits < 8 ? 8 - bits - bit % 8 : 0
                    let mask = (1 << bits) - 1
                    let raw = bits == 16 ? Int(output[at]) * 256 + Int(output[at + 1]) : Int(output[at]) >> shift
                    let channel = sample % colors
                    let value = ((raw & mask) + previous[channel]) & mask
                    previous[channel] = value
                    if bits == 16 {
                        output[at] = UInt8(value >> 8)
                        output[at + 1] = UInt8(truncatingIfNeeded: value)
                    } else {
                        output[at] = UInt8((Int(output[at]) & ~(mask << shift)) | value << shift)
                    }
                }
            }
            return output
        }
        guard (10...15).contains(predictor), output.count % (row + 1) == 0 else { throw Failure.unsupportedXref }
        let pixel = (colors * bits + 7) / 8
        var dest = 0
        for base in stride(from: 0, to: output.count, by: row + 1) {
            let filter = output[base]
            guard filter <= 4 else { throw Failure.malformed }
            for x in 0..<row {
                let left = x >= pixel ? Int(output[dest - pixel]) : 0
                let up = dest >= row ? Int(output[dest - row]) : 0
                let corner = base > 0 && x >= pixel ? Int(output[dest - row - pixel]) : 0
                let delta: Int
                switch filter {
                case 0: delta = 0
                case 1: delta = left
                case 2: delta = up
                case 3: delta = (left + up) / 2
                default:
                    let p = left + up - corner
                    let a = abs(p - left), b = abs(p - up), c = abs(p - corner)
                    delta = a <= b && a <= c ? left : (b <= c ? up : corner)
                }
                output[dest] = output[base + 1 + x] &+ UInt8(delta)
                dest += 1
            }
        }
        output.removeLast(output.count - dest)
        return output
    }

    static func rows(_ bytes: [UInt8], dictionary: [String: Value], limit: Int) throws -> [Int: PdfXrefRow] {
        if let size = dictionary["Size"]?.integer, size > limit { throw Failure.inspectionLimit }
        guard let size = dictionary["Size"]?.integer, size > 0,
              case .array(let fields) = dictionary["W"], fields.count == 3 else { throw Failure.malformed }
        let widths = fields.compactMap(\.integer)
        guard widths.count == 3, widths.allSatisfy({ (0...8).contains($0) }) else { throw Failure.malformed }
        let stride = widths.reduce(0, +)
        var index = [0, size]
        if let value = dictionary["Index"] {
            guard case .array(let array) = value else { throw Failure.malformed }
            index = array.compactMap(\.integer)
            guard index.count == array.count, !index.isEmpty, index.count.isMultiple(of: 2) else { throw Failure.malformed }
        }
        var position = 0, end = 0
        func field(_ width: Int, default fallback: Int = 0) throws -> Int {
            guard width > 0 else { return fallback }
            var n = 0
            for _ in 0..<width {
                guard n <= Int.max >> 8 else { throw Failure.malformed }
                n = n << 8 | Int(bytes[position])
                position += 1
            }
            return n
        }
        var result: [Int: PdfXrefRow] = [:]
        for pair in Swift.stride(from: 0, to: index.count, by: 2) {
            let first = index[pair], count = index[pair + 1]
            guard first >= end, first < size, count > 0, count <= size - first,
                  stride > 0, count <= (bytes.count - position) / stride else { throw Failure.malformed }
            end = first + count
            for number in first..<end {
                let type = try field(widths[0], default: 1), a = try field(widths[1]), b = try field(widths[2])
                switch type {
                case 0: result[number] = .free(next: a, generation: b)
                case 1: result[number] = .direct(offset: a, generation: b)
                case 2: result[number] = .compressed(stream: a, index: b)
                default: throw Failure.unsupportedXref
                }
            }
        }
        guard position == bytes.count else { throw Failure.malformed }
        return result
    }
}
