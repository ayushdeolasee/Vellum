import Foundation

/// Vellum's providers send one JSON payload per data line. Decode only after a
/// delimiter so neither a network chunk nor a split CRLF changes the payload.
public struct SSEDecoder: Sendable {
    private var line = Data()

    public init() {}

    public mutating func append(_ bytes: Data) -> [String] {
        var payloads: [String] = []
        var start = bytes.startIndex
        for index in bytes.indices where bytes[index] == 10 || bytes[index] == 13 {
            line.append(bytes[start..<index])
            if let payload = finish() { payloads.append(payload) }
            start = bytes.index(after: index)
        }
        line.append(bytes[start...])
        return payloads
    }

    public mutating func finish() -> String? {
        defer { line.removeAll(keepingCapacity: true) }
        guard line.starts(with: "data:".utf8) else { return nil }
        let payload = String(decoding: line.dropFirst(5), as: UTF8.self)
            .trimmingCharacters(in: .whitespaces)
        return payload.isEmpty || payload == "[DONE]" ? nil : payload
    }
}
