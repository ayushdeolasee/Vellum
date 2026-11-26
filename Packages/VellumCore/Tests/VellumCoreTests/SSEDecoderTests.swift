import Foundation
import Testing
import VellumCore

@Test func sseHandlesEverySplitIncludingUTF8CRLFAndUnterminatedEOF() {
    let bytes = Data(": ping\r\nevent: delta\rdata:\t \r\ndata: こんにちは 🌱 \r\ndata: [DONE]\ndata: tail".utf8)
    for split in 0...bytes.count {
        var decoder = SSEDecoder()
        let first = decoder.append(bytes.prefix(split))
        let second = decoder.append(bytes.dropFirst(split))
        #expect(first + second + [decoder.finish()].compactMap { $0 } == ["こんにちは 🌱", "tail"])
        #expect(decoder.finish() == nil)
    }
}
