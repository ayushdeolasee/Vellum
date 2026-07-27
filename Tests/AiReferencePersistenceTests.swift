import XCTest
@testable import Vellum

// Coverage for persisting the references attached to a sent user message
// (issue #58): the `AiMessage.references` round-trip through
// documents/<storageKey>/conversations.json, backward compatibility with every
// transcript written before the field existed, forward compatibility with a
// reference kind this build doesn't know, the stable on-disk kind tags, and the
// two caps that keep a reference list from bloating the file (image pixels are
// dropped, excerpts are clipped).
//
// Uses XCTest to match the other twenty test files in this bundle.
@MainActor
final class AiReferencePersistenceTests: XCTestCase {
    private var root: URL!

    override func setUp() async throws {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("vellum-airef-\(UUID().uuidString)")
        root = base.appendingPathComponent("documents")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        DocumentDataStore.rootDirectoryOverride = root
    }

    override func tearDown() async throws {
        // Drain the coalesced flush before the scratch dir goes away so a late
        // detached write can't recreate it.
        await AiPersistence.awaitPendingFlush()
        DocumentDataStore.rootDirectoryOverride = nil
        if let root { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }
    }

    /// Unique per test so the static in-memory conversation cache never carries
    /// state between cases (keys derive from the path hash).
    private func pdfDocument() -> DocumentInfo {
        DocumentInfo(
            kind: .pdf, pdfPath: "/tmp/ai-ref-\(UUID().uuidString).pdf",
            title: "Doc", pageCount: 12, lastPage: 1, docId: nil)
    }

    private func fileMessages(forKey key: String) throws -> [AiMessage] {
        let data = try XCTUnwrap(DocumentDataStore.loadConversationsData(forKey: key))
        return try JSONDecoder().decode([AiMessage].self, from: data)
    }

    private func snapshot(page: Int?) -> AiPageImageSnapshot {
        AiPageImageSnapshot(
            pageNumber: page, base64Data: "QUJD", mediaType: "image/jpeg", width: 640, height: 480)
    }

    // MARK: - Round-trip

    func testReferencesSurviveConversationRoundTripThroughDisk() async throws {
        let doc = pdfDocument()
        let key = DocumentIdentity.storageKey(for: doc)
        let references = [
            AiReference(kind: .selection(text: "photosynthesis is\nendothermic", page: 4)),
            AiReference(kind: .highlight(text: "chlorophyll a", page: 5)),
            AiReference(kind: .quote(text: "As I said earlier…", messageId: "msg-1")),
            AiReference(kind: .region(image: snapshot(page: 7), page: 7)),
            AiReference(kind: .pageSnapshot(image: snapshot(page: 8), page: 8)),
            AiReference(kind: .image(image: snapshot(page: nil), name: "diagram.png")),
        ]
        let user = AiPersistence.makeMessage(
            role: .user, content: "explain this", references: references)

        AiPersistence.saveConversation(for: doc, messages: [user])
        await AiPersistence.awaitPendingFlush()

        let onDisk = try fileMessages(forKey: key)
        let restored = try XCTUnwrap(onDisk.first).references
        XCTAssertEqual(restored.map(\.id), references.map(\.id))
        // Everything except the image bytes comes back verbatim.
        XCTAssertEqual(restored.map(\.text), references.map(\.text))
        XCTAssertEqual(restored.map(\.page), references.map(\.page))
        XCTAssertEqual(restored.map(\.chipLabel), references.map(\.chipLabel))
        XCTAssertEqual(restored[2].kind, .quote(text: "As I said earlier…", messageId: "msg-1"))
    }

    func testLoadConversationReturnsReferencesAfterCacheIsCold() async throws {
        let doc = pdfDocument()
        let user = AiPersistence.makeMessage(
            role: .user, content: "what is this",
            references: [AiReference(kind: .selection(text: "the mitochondrion", page: 2))])
        AiPersistence.saveConversation(for: doc, messages: [user])
        await AiPersistence.awaitPendingFlush()
        // Force the next load to re-read the file instead of serving the
        // write-behind cache, which would pass without ever touching decoding.
        AiPersistence.invalidateCachedConversation(
            forKey: DocumentIdentity.storageKey(for: doc))

        let loaded = AiPersistence.loadConversation(for: doc)
        XCTAssertEqual(loaded.first?.references.first?.text, "the mitochondrion")
        XCTAssertEqual(loaded.first?.references.first?.page, 2)
    }

    // MARK: - Backward compatibility

    func testTranscriptWithoutReferencesFieldStillDecodes() throws {
        // Byte-for-byte the shape written before `references` existed.
        let legacy = """
        [
          {"id":"a1","role":"user","content":"hello","createdAt":"2025-01-01T00:00:00.000Z"},
          {"id":"a2","role":"assistant","content":"hi","createdAt":"2025-01-01T00:00:01.000Z",
           "usage":{"inputTokens":10,"cachedInputTokens":0,"cacheWriteTokens":0,
                    "reasoningTokens":0,"outputTokens":3}}
        ]
        """
        let messages = try JSONDecoder().decode(
            [AiMessage].self, from: XCTUnwrap(legacy.data(using: .utf8)))

        XCTAssertEqual(messages.count, 2)
        XCTAssertEqual(messages.map(\.references), [[], []])
        // The pre-existing fields must be untouched by the new initializer.
        XCTAssertEqual(messages.map(\.content), ["hello", "hi"])
        XCTAssertEqual(messages.last?.usage?.inputTokens, 10)
    }

    func testLegacyTranscriptLoadsThroughTheRealPersistencePath() async throws {
        let doc = pdfDocument()
        let key = DocumentIdentity.storageKey(for: doc)
        let legacy = """
        [{"id":"a1","role":"user","content":"older turn","createdAt":"2025-01-01T00:00:00.000Z"}]
        """
        try DocumentDataStore.saveConversationsData(
            forKey: key, data: XCTUnwrap(legacy.data(using: .utf8)))

        let loaded = AiPersistence.loadConversation(for: doc)
        XCTAssertEqual(loaded.map(\.content), ["older turn"])
        XCTAssertEqual(loaded.first?.references, [])
    }

    // MARK: - Forward compatibility

    func testUnknownReferenceKindIsDroppedWithoutLosingTheMessage() throws {
        // A kind tag written by some future build, sandwiched between two this
        // build understands. Losing the whole conversation over it would be a
        // far worse outcome than losing the one chip.
        let json = """
        [{"id":"a1","role":"user","content":"mixed","createdAt":"2025-01-01T00:00:00.000Z",
          "references":[
            {"id":"r1","kind":{"tag":"selection","text":"known","page":3}},
            {"id":"r2","kind":{"tag":"holographicProjection","text":"???","page":9}},
            {"id":"r3","kind":{"tag":"quote","text":"also known","messageId":"m9"}}]}]
        """
        let messages = try JSONDecoder().decode(
            [AiMessage].self, from: XCTUnwrap(json.data(using: .utf8)))

        XCTAssertEqual(messages.count, 1)
        XCTAssertEqual(messages.first?.references.map(\.text), ["known", "also known"])
    }

    func testMalformedReferencesValueDegradesToNoReferences() throws {
        // `references` present but not an array at all — the message body still
        // has to survive.
        let json = """
        [{"id":"a1","role":"user","content":"kept","createdAt":"2025-01-01T00:00:00.000Z",
          "references":"not-an-array"}]
        """
        let messages = try JSONDecoder().decode(
            [AiMessage].self, from: XCTUnwrap(json.data(using: .utf8)))

        XCTAssertEqual(messages.map(\.content), ["kept"])
        XCTAssertEqual(messages.first?.references, [])
    }

    // MARK: - On-disk shape

    func testKindTagsAreTheDocumentedStrings() throws {
        // These strings are frozen in users' files; a rename here is a data
        // migration, not a refactor.
        let expected: [(AiReference.Kind, String)] = [
            (.selection(text: "t", page: 1), "selection"),
            (.highlight(text: "t", page: 1), "highlight"),
            (.region(image: snapshot(page: 1), page: 1), "region"),
            (.pageSnapshot(image: snapshot(page: 1), page: 1), "pageSnapshot"),
            (.quote(text: "t", messageId: "m"), "quote"),
            (.image(image: snapshot(page: nil), name: "n"), "image"),
        ]
        for (kind, tag) in expected {
            let data = try JSONEncoder().encode(AiReference(kind: kind))
            let object = try XCTUnwrap(
                JSONSerialization.jsonObject(with: data) as? [String: Any])
            let encodedKind = try XCTUnwrap(object["kind"] as? [String: Any])
            XCTAssertEqual(encodedKind["tag"] as? String, tag)
        }
    }

    // MARK: - Caps

    func testPersistedReferenceDropsImagePixelsButKeepsDescriptor() throws {
        let reference = AiReference(kind: .pageSnapshot(image: snapshot(page: 6), page: 6))
        let stripped = reference.strippingImageData

        XCTAssertEqual(stripped.id, reference.id)
        XCTAssertEqual(stripped.image?.base64Data, "")
        XCTAssertEqual(stripped.image?.width, 640)
        XCTAssertEqual(stripped.image?.height, 480)
        XCTAssertEqual(stripped.image?.mediaType, "image/jpeg")
        XCTAssertEqual(stripped.page, 6)
        // A text reference has nothing to strip and must come back untouched.
        let text = AiReference(kind: .selection(text: "verbatim", page: 1))
        XCTAssertEqual(text.strippingImageData, text)
    }

    func testSaveClipsOversizedExcerptsAndImagePixels() async throws {
        let doc = pdfDocument()
        let key = DocumentIdentity.storageKey(for: doc)
        let huge = String(repeating: "x", count: AiPersistence.maxReferenceCharacters + 500)
        let user = AiPersistence.makeMessage(
            role: .user, content: "summarize",
            references: [
                AiReference(kind: .selection(text: huge, page: 1)),
                // Unstripped on purpose: `limit` is the last line of defence for
                // any caller that forgets to strip.
                AiReference(kind: .region(image: snapshot(page: 2), page: 2)),
            ])

        AiPersistence.saveConversation(for: doc, messages: [user])
        await AiPersistence.awaitPendingFlush()

        let restored = try XCTUnwrap(try fileMessages(forKey: key).first).references
        // maxReferenceCharacters plus the one-character ellipsis marker.
        XCTAssertEqual(restored.first?.text?.count, AiPersistence.maxReferenceCharacters + 1)
        XCTAssertEqual(restored.first?.text?.hasSuffix("…"), true)
        XCTAssertEqual(restored.last?.image?.base64Data, "")
        XCTAssertEqual(restored.last?.image?.width, 640)
    }

    // MARK: - Chip vocabulary shared by the composer and the transcript

    func testChipLabelCollapsesWhitespaceAndNamesThePage() {
        let selection = AiReference(kind: .selection(text: "line one\n   line two", page: 3))
        XCTAssertEqual(selection.chipLabel, "“line one line two” · p.3")
        XCTAssertEqual(selection.chipKindName, "Selected text")
        XCTAssertEqual(selection.chipIcon, "text.quote")

        // No document position, so no page locator and no jump affordance.
        let quote = AiReference(kind: .quote(text: "earlier reply", messageId: "m1"))
        XCTAssertEqual(quote.chipLabel, "“earlier reply”")
        XCTAssertNil(quote.page)

        let image = AiReference(kind: .image(image: snapshot(page: nil), name: "figure.png"))
        XCTAssertEqual(image.chipLabel, "figure.png")
        XCTAssertNil(image.page)
        XCTAssertNil(image.text)
    }
}
