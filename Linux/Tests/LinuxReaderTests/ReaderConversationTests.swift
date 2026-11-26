import Foundation
@testable import LinuxReader
import Testing
import VellumCore

@Test func appendAndReopenWithoutRewritingAppleOrFutureMessageBytes() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    let key = "abcd1234"
    let file = root.appendingPathComponent(".vellum/documents/\(key)/conversations.json")
    try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let writer = LocalFolderFileStore(root: root)
    let reader = ReadOnlyLibraryFileStore(root: try await RootDirectory.open(root))
    let original = #"""
    [
      {"role":"assistant", "createdAt":"2026-11-26T00:00:00.000Z","content":"caf\u00e9", "id":"1",
       "references":[{"kind":{"future":{"n":1234567890123456789012345678}}}],"usage":{"extra":1.000}},
      {"role":"future","payload":[null,{}]}
    """#
    let tail = "]\n  "
    try Data((original + tail).utf8).write(to: file)
    let loaded = try await ReaderConversation.load(key: key, from: reader)
    #expect(loaded.messages.map(\.content) == ["café"])
    #expect(try await loaded.save(appending: [], to: writer))
    #expect(try Data(contentsOf: file) == Data((original + tail).utf8))
    let turn = ConversationText(id: "2", role: .user, content: "Next?", createdAt: "2026-11-26T01:00:00.000Z")
    #expect(try await loaded.save(appending: [turn], to: writer))
    let changed = try String(contentsOf: file, encoding: .utf8)
    #expect(changed.hasPrefix(original + ",{"))
    #expect(changed.hasSuffix("}" + tail))
    let reopened = try await ReaderConversation.load(key: key, from: reader)
    #expect(reopened.messages == loaded.messages + [turn])
    #expect(try await !loaded.save(appending: [turn], to: writer))
    #expect(try String(contentsOf: file, encoding: .utf8) == changed)
}
