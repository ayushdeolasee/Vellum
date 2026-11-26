import Foundation
import FoundationNetworking
import LinuxServices
import Testing
import VellumCore

private struct OverCap: Error {}
private actor Sink {
    var decoder = SSEDecoder()
    var payloads: [String] = []
    var receivedHead = false
    var bytesReceived = 0

    func receive(_ bytes: Data, cap: Int) throws {
        guard bytes.count <= cap - bytesReceived else { throw OverCap() }
        bytesReceived += bytes.count
    }

    func head(_ head: StreamingHead) {
        #expect(head.status == 200)
        #expect(head.header("Content-Type") == "text/event-stream")
        receivedHead = true
    }

    func receive(_ bytes: Data, acknowledge: FileHandle) throws {
        #expect(receivedHead)
        let events = decoder.append(bytes)
        payloads += events
        if events.contains("🌱") { try acknowledge.write(contentsOf: Data("next\n".utf8)) }
    }

    func finish() -> [String] { payloads + [decoder.finish()].compactMap { $0 } }
}

private func withLoopback(_ mode: String, run: (URLRequest, FileHandle) async throws -> Void) async throws {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
    let fixture = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Fixtures/stream.py")
    process.arguments = [fixture.path, mode]
    let input = Pipe(), output = Pipe()
    process.standardInput = input
    process.standardOutput = output
    try process.run()
    defer {
        if process.isRunning { process.terminate() }
        process.waitUntilExit()
    }
    let port = String(decoding: output.fileHandleForReading.availableData, as: UTF8.self)
        .trimmingCharacters(in: .whitespacesAndNewlines)
    var request = URLRequest(url: try #require(URL(string: "http://127.0.0.1:\(port)/stream")))
    request.httpMethod = "POST"
    request.httpBody = Data("body".utf8)
    request.setValue("test", forHTTPHeaderField: "X-Fixture")
    request.timeoutInterval = 8
    try await run(request, input.fileHandleForWriting)
    process.waitUntilExit()
    #expect(process.terminationStatus == 0)
}

@Test func deliversAnEventBeforeServerEOF() async throws {
    try await withLoopback("finish") { request, acknowledge in
        let sink = Sink()
        try await AHCTransport().execute(request, onHead: { await sink.head($0) }, onChunk: {
            try await sink.receive($0, acknowledge: acknowledge)
        })
        #expect(await sink.finish() == ["🌱", "last"])
    }
}

@Test func crossingTheCapClosesAStalledBody() async throws {
    try await withLoopback("cancel") { request, _ in
        let start = ContinuousClock.now
        let sink = Sink()
        await #expect(throws: OverCap.self) {
            try await AHCTransport().execute(request, onHead: { _ in }, onChunk: { data in
                try await sink.receive(data, cap: 5)
            })
        }
        #expect(start.duration(to: .now) < .seconds(4))
    }
}

@Test func cancellationWhileAwaitingTheNextChunkClosesTheSocket() async throws {
    try await withLoopback("cancel") { request, _ in
        let (received, signal) = AsyncStream<Void>.makeStream()
        let task = Task {
            defer { signal.finish() }
            try await AHCTransport().execute(request, onHead: { _ in }, onChunk: { _ in signal.yield(()) })
        }
        var iterator = received.makeAsyncIterator()
        try #require(await iterator.next() != nil)
        let start = ContinuousClock.now
        task.cancel()
        await #expect(throws: (any Error).self) { try await task.value }
        #expect(start.duration(to: .now) < .seconds(4))
    }
}
