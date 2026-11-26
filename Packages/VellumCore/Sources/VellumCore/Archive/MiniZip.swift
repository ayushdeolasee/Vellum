import CZlib
import Foundation

/// Just enough ZIP to write and read `.vellumweb` archives: Stored and
/// Deflate entries, central directory, no zip64 (archives are size-capped far
/// below 4 GiB). Read paths enforce decompressed-size caps *during* inflation
/// so a crafted archive can't inflate a bomb.
public struct MiniZip {
    public struct Entry {
        var name: String
        var data: Data
        var stored: Bool

        public init(name: String, data: Data, stored: Bool) {
            self.name = name
            self.data = data
            self.stored = stored
        }
    }

    private struct SizeLimitExceeded: Error {}

    // MARK: Writing

    public static func write(entries: [Entry]) throws -> Data {
        guard entries.count <= Int(UInt16.max) else { throw SizeLimitExceeded() }
        var out = Data()
        var central = Data()
        let (dosTime, dosDate) = dosDateTime(Date())

        for entry in entries {
            let nameBytes = Data(entry.name.utf8)
            guard nameBytes.count <= Int(UInt16.max), entry.data.count <= Int(UInt32.max),
                  out.count <= Int(UInt32.max) else { throw SizeLimitExceeded() }
            let crc = crc32(entry.data)
            let method: UInt16
            let payload: Data
            if entry.stored {
                method = 0
                payload = entry.data
            } else {
                method = 8
                payload = try deflate(entry.data)
            }
            let offset = UInt32(out.count)

            // Local file header
            out.appendUInt32(0x0403_4b50)
            out.appendUInt16(20)        // version needed
            out.appendUInt16(0)         // flags
            out.appendUInt16(method)
            out.appendUInt16(dosTime)
            out.appendUInt16(dosDate)
            out.appendUInt32(crc)
            out.appendUInt32(UInt32(payload.count))
            out.appendUInt32(UInt32(entry.data.count))
            out.appendUInt16(UInt16(nameBytes.count))
            out.appendUInt16(0)         // extra length
            out.append(nameBytes)
            out.append(payload)

            // Central directory record
            central.appendUInt32(0x0201_4b50)
            central.appendUInt16(20)    // version made by
            central.appendUInt16(20)    // version needed
            central.appendUInt16(0)     // flags
            central.appendUInt16(method)
            central.appendUInt16(dosTime)
            central.appendUInt16(dosDate)
            central.appendUInt32(crc)
            central.appendUInt32(UInt32(payload.count))
            central.appendUInt32(UInt32(entry.data.count))
            central.appendUInt16(UInt16(nameBytes.count))
            central.appendUInt16(0)     // extra length
            central.appendUInt16(0)     // comment length
            central.appendUInt16(0)     // disk number start
            central.appendUInt16(0)     // internal attributes
            central.appendUInt32(0)     // external attributes
            central.appendUInt32(offset)
            central.append(nameBytes)
        }

        guard out.count <= Int(UInt32.max), central.count <= Int(UInt32.max) else {
            throw SizeLimitExceeded()
        }
        let centralOffset = UInt32(out.count)
        out.append(central)
        // End of central directory
        out.appendUInt32(0x0605_4b50)
        out.appendUInt16(0)
        out.appendUInt16(0)
        out.appendUInt16(UInt16(entries.count))
        out.appendUInt16(UInt16(entries.count))
        out.appendUInt32(UInt32(central.count))
        out.appendUInt32(centralOffset)
        out.appendUInt16(0)
        return out
    }

    // MARK: Reading

    private struct CentralEntry {
        var method: UInt16
        var crc: UInt32
        var compressedSize: Int
        var uncompressedSize: Int
        var localHeaderOffset: Int
    }

    private let data: Data
    private let entries: [String: CentralEntry]
    private let orderedNames: [String]

    public var entryNames: [String] { orderedNames }

    /// Number of entries the central directory declares.
    public var entryCount: Int { orderedNames.count }

    /// Sum of every entry's DECLARED uncompressed size. Attacker-controlled in a
    /// shared archive, so a caller uses it only as a pre-parse budget gate — never
    /// as ground truth (`readCapped` re-checks each entry while inflating).
    public var totalDeclaredUncompressedSize: Int {
        entries.values.reduce(0) { $0 + $1.uncompressedSize }
    }

    func contains(_ name: String) -> Bool { entries[name] != nil }

    public init(contentsOf path: URL, maxBytes: Int, maxEntries: Int,
                maxUncompressedBytes: Int) throws {
        let bytes: Data
        do {
            bytes = try Self.readFile(path, maxBytes: maxBytes)
        } catch let error as ArchiveCodecError {
            throw error
        } catch {
            throw ArchiveCodecError.io(error.localizedDescription)
        }
        try self.init(data: bytes, maxBytes: maxBytes, maxEntries: maxEntries,
                      maxUncompressedBytes: maxUncompressedBytes)
    }

    private static func readFile(_ path: URL, maxBytes: Int) throws -> Data {
        guard maxBytes >= 0 else { throw Self.invalid("negative size limit") }
        let handle = try FileHandle(forReadingFrom: path)
        defer { try? handle.close() }
        // Inspect the opened file before allocation, then enforce the bound again
        // while reading in case another writer grows it after the size check.
        guard try handle.seekToEnd() <= UInt64(maxBytes) else {
            throw Self.invalid("archive exceeds its size limit")
        }
        try handle.seek(toOffset: 0)
        var bytes = Data()
        while let chunk = try handle.read(upToCount: 1024 * 1024), !chunk.isEmpty {
            guard chunk.count <= maxBytes - bytes.count else {
                throw Self.invalid("archive exceeds its size limit")
            }
            bytes.append(chunk)
        }
        return bytes
    }

    public init(data: Data, maxBytes: Int, maxEntries: Int, maxUncompressedBytes: Int) throws {
        guard data.count <= maxBytes else {
            throw Self.invalid("archive exceeds its size limit")
        }
        self.data = data
        (entries, orderedNames) = try Self.parseCentralDirectory(
            data, maxEntries: maxEntries, maxUncompressedBytes: maxUncompressedBytes)
    }

    private static func invalid(_ detail: String) -> ArchiveCodecError {
        .invalidDocument("Not a valid .vellumweb archive: \(detail)")
    }

    private static func parseCentralDirectory(
        _ data: Data, maxEntries: Int, maxUncompressedBytes: Int
    ) throws -> ([String: CentralEntry], [String]) {
        try data.withUnsafeBytes { (bytes: UnsafeRawBufferPointer) in
            guard bytes.count >= 22 else { throw invalid("file too small") }
            // Find the End of Central Directory record (scan back past a comment).
            var eocd = -1
            let scanStart = max(0, bytes.count - 22 - 65535)
            var i = bytes.count - 22
            while i >= scanStart {
                if bytes[i] == 0x50, bytes[i + 1] == 0x4b, bytes[i + 2] == 0x05, bytes[i + 3] == 0x06 {
                    eocd = i
                    break
                }
                i -= 1
            }
            guard eocd >= 0 else { throw invalid("end of central directory not found") }

            func u16(_ offset: Int) -> Int {
                Int(bytes[offset]) | Int(bytes[offset + 1]) << 8
            }
            func u32(_ offset: Int) -> Int {
                Int(bytes[offset]) | Int(bytes[offset + 1]) << 8
                    | Int(bytes[offset + 2]) << 16 | Int(bytes[offset + 3]) << 24
            }

            let entryCount = u16(eocd + 10)
            guard entryCount <= maxEntries else { throw invalid("too many entries in archive") }
            var declaredBytes = 0
            var cursor = u32(eocd + 16)
            var entries: [String: CentralEntry] = [:]
            var names: [String] = []
            for _ in 0..<entryCount {
                guard cursor + 46 <= bytes.count, u32(cursor) == 0x0201_4b50 else {
                    throw invalid("bad central directory record")
                }
                let method = UInt16(u16(cursor + 10))
                let compressedSize = u32(cursor + 20)
                let uncompressedSize = u32(cursor + 24)
                guard uncompressedSize <= maxUncompressedBytes - declaredBytes else {
                    throw invalid("declared archive data exceeds its size limit")
                }
                declaredBytes += uncompressedSize
                let nameLen = u16(cursor + 28)
                let extraLen = u16(cursor + 30)
                let commentLen = u16(cursor + 32)
                let localOffset = u32(cursor + 42)
                guard cursor + 46 + nameLen <= bytes.count else {
                    throw invalid("bad central directory record")
                }
                let name = String(decoding: bytes[(cursor + 46)..<(cursor + 46 + nameLen)], as: UTF8.self)
                guard entries[name] == nil else { throw invalid("duplicate archive entry") }
                names.append(name)
                entries[name] = CentralEntry(
                    method: method,
                    crc: UInt32(u32(cursor + 16)),
                    compressedSize: compressedSize,
                    uncompressedSize: uncompressedSize,
                    localHeaderOffset: localOffset)
                cursor += 46 + nameLen + extraLen + commentLen
            }
            return (entries, names)
        }
    }

    /// Read one entry with a hard decompressed-size cap. Size fields are
    /// attacker-controlled in a shared archive, so they gate early but the
    /// cap is enforced again while inflating.
    public func readCapped(_ name: String, cap: Int) throws -> Data {
        guard let entry = entries[name] else {
            throw ArchiveCodecError.invalidDocument("Archive is missing \(name)")
        }
        if entry.uncompressedSize > cap {
            throw ArchiveCodecError.invalidDocument(
                "Archive entry \(name) exceeds its size limit")
        }
        let bytes = data
        let offset = entry.localHeaderOffset
        guard offset + 30 <= bytes.count else {
            throw ArchiveCodecError.invalidDocument("Failed to read \(name): bad local header")
        }
        func u16(_ at: Int) -> Int {
            Int(bytes[bytes.startIndex + at]) | Int(bytes[bytes.startIndex + at + 1]) << 8
        }
        func u32(_ at: Int) -> Int {
            u16(at) | u16(at + 2) << 16
        }
        guard u32(offset) == 0x0403_4b50 else {
            throw ArchiveCodecError.invalidDocument("Failed to read \(name): bad local header")
        }
        let nameLen = u16(offset + 26)
        let extraLen = u16(offset + 28)
        let dataStart = offset + 30 + nameLen + extraLen
        guard dataStart + entry.compressedSize <= bytes.count else {
            throw ArchiveCodecError.invalidDocument("Failed to read \(name): truncated entry")
        }
        let payload = bytes[(bytes.startIndex + dataStart)..<(bytes.startIndex + dataStart + entry.compressedSize)]

        let decoded: Data
        switch entry.method {
        case 0:
            if payload.count > entry.uncompressedSize {
                throw ArchiveCodecError.invalidDocument(
                    "Archive entry \(name) exceeds its size limit")
            }
            decoded = Data(payload)
        case 8:
            do {
                decoded = try MiniZip.inflate(payload, cap: entry.uncompressedSize)
            } catch is SizeLimitExceeded {
                throw ArchiveCodecError.invalidDocument(
                    "Archive entry \(name) exceeds its size limit")
            } catch {
                throw ArchiveCodecError.invalidDocument(
                    "Failed to read \(name): \(error.localizedDescription)")
            }
        default:
            throw ArchiveCodecError.invalidDocument(
                "Failed to read \(name): unsupported compression method")
        }
        guard decoded.count == entry.uncompressedSize, Self.crc32(decoded) == entry.crc else {
            throw ArchiveCodecError.invalidDocument("Failed to read \(name): size or CRC mismatch")
        }
        return decoded
    }

    // MARK: Raw DEFLATE (RFC 1951)

    private struct CodecError: Error {}

    private static func deflate(_ input: Data) throws -> Data {
        var stream = z_stream()
        guard deflateInit2_(&stream, Z_DEFAULT_COMPRESSION, Z_DEFLATED, -15, 8,
                            Z_DEFAULT_STRATEGY, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size)) == Z_OK
        else { throw CodecError() }
        defer { deflateEnd(&stream) }
        return try process(input, stream: &stream, cap: Int(UInt32.max)) {
            CZlib.deflate(&$0, Z_FINISH)
        }
    }

    static func inflate(_ input: Data, cap: Int, windowBits: Int32 = -15) throws -> Data {
        var stream = z_stream()
        guard inflateInit2_(&stream, windowBits, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size)) == Z_OK
        else { throw CodecError() }
        defer { inflateEnd(&stream) }
        return try process(input, stream: &stream, cap: cap) {
            CZlib.inflate(&$0, Z_NO_FLUSH)
        }
    }

    private static func process(
        _ input: Data, stream: inout z_stream, cap: Int, step: (inout z_stream) -> Int32
    ) throws -> Data {
        guard let size = UInt32(exactly: input.count) else { throw SizeLimitExceeded() }
        let capacity = 64 * 1024
        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: capacity)
        defer { buffer.deallocate() }
        var output = Data()
        return try input.withUnsafeBytes { raw in
            stream.next_in = UnsafeMutablePointer(mutating: raw.bindMemory(to: UInt8.self).baseAddress)
            stream.avail_in = size
            while true {
                // One extra byte distinguishes an exact fit from an overrun,
                // even when the cap is zero and the stream still needs its end marker.
                let remaining = cap - output.count
                let window = min(remaining, capacity - 1) + 1
                stream.next_out = buffer
                stream.avail_out = UInt32(window)
                let status = step(&stream)
                let produced = window - Int(stream.avail_out)
                guard produced <= remaining else { throw SizeLimitExceeded() }
                output.append(buffer, count: produced)
                if status == Z_STREAM_END {
                    guard stream.avail_in == 0 else { throw CodecError() }
                    return output
                }
                guard status == Z_OK else { throw CodecError() }
            }
        }
    }

    // MARK: CRC32 / DOS timestamps

    private static func crc32(_ data: Data) -> UInt32 {
        data.withUnsafeBytes { raw in
            UInt32(CZlib.crc32_z(0, raw.bindMemory(to: UInt8.self).baseAddress, raw.count))
        }
    }

    private static func dosDateTime(_ date: Date) -> (time: UInt16, date: UInt16) {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone.current
        let parts = calendar.dateComponents(
            [.year, .month, .day, .hour, .minute, .second], from: date)
        let year = max(1980, parts.year ?? 1980)
        let time = UInt16(((parts.hour ?? 0) << 11) | ((parts.minute ?? 0) << 5)
            | ((parts.second ?? 0) / 2))
        let dosDate = UInt16(((year - 1980) << 9) | ((parts.month ?? 1) << 5) | (parts.day ?? 1))
        return (time, dosDate)
    }
}

private extension Data {
    mutating func appendUInt16(_ value: UInt16) {
        append(UInt8(value & 0xff))
        append(UInt8(value >> 8))
    }

    mutating func appendUInt32(_ value: UInt32) {
        append(UInt8(value & 0xff))
        append(UInt8((value >> 8) & 0xff))
        append(UInt8((value >> 16) & 0xff))
        append(UInt8((value >> 24) & 0xff))
    }
}
