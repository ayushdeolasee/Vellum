import Foundation
import XCTest
@testable import Vellum

final class AiPromptContextTests: XCTestCase {
    func testCurrentReferencesStayWithQuestionOutsideCacheableBackground() {
        let references = [
            AiReference(kind: .selection(text: "selected passage", page: 12)),
            AiReference(kind: .quote(text: "earlier explanation", messageId: "reply-1")),
        ]
        let context = AiContextSnapshot(
            title: "Document", numPages: 20, currentPage: 3, visiblePages: [3],
            annotations: [], currentPageImage: nil, references: references)
        let background = AiPrompts.buildContextBlock(pageTexts: [3: "unrelated current page"], context: context)
        let prompt = AiPrompts.buildNativeToolUserPrompt(AiPromptParameters(
            conversation: "(start of conversation)", context: background,
            latestUserRequest: "What does this mean?", references: references))

        XCTAssertTrue(prompt.stable.contains("unrelated current page"))
        XCTAssertFalse(prompt.stable.contains("selected passage"))
        XCTAssertFalse(prompt.stable.contains("earlier explanation"))
        XCTAssertTrue(prompt.volatile.contains("What does this mean?\n\nAttached material"))
        XCTAssertTrue(prompt.volatile.contains("[selected text, p.12] \"selected passage\""))
        XCTAssertTrue(prompt.volatile.contains("[quoted from an earlier assistant reply] \"earlier explanation\""))
        let withoutAttachments = AiPrompts.buildNativeToolUserPrompt(AiPromptParameters(
            conversation: "", context: background, latestUserRequest: "Summarize the whole page"))
        XCTAssertEqual(prompt.stable, withoutAttachments.stable)
        XCTAssertFalse(withoutAttachments.volatile.contains("Attached material"))
    }

    func testFollowUpKeepsReferencesOnTheirOriginalUserTurn() {
        let messages = [
            AiPersistence.makeMessage(role: .user, content: "What does this mean?", references: [
                AiReference(kind: .highlight(text: "document excerpt", page: 7)),
                AiReference(kind: .quote(text: "assistant excerpt", messageId: "reply-1")),
            ]),
            AiPersistence.makeMessage(role: .assistant, content: "It means..."),
        ]
        let history = AiPrompts.buildConversationBlock(messages)
        XCTAssertTrue(history.contains("USER: What does this mean?\nMaterial attached to that user message:"))
        XCTAssertTrue(history.contains("[existing highlight, p.7] \"document excerpt\""))
        XCTAssertTrue(history.contains("\"assistant excerpt\"\nASSISTANT: It means..."))
    }

    func testReferenceBudgetsAndHistoricalImagesDoNotResendPixels() {
        let image = AiPageImageSnapshot(
            pageNumber: 4, base64Data: "PIXELS-NOT-TEXT", mediaType: "image/png", width: 20, height: 10)
        let imageReference = AiReference(kind: .pageSnapshot(image: image, page: 4))
        let historicalImage = AiPrompts.buildConversationBlock([
            AiPersistence.makeMessage(role: .user, content: "Explain", references: [imageReference]),
        ])
        XCTAssertTrue(historicalImage.contains("[page snapshot, p.4] image not included in this request"))
        XCTAssertFalse(historicalImage.contains("PIXELS-NOT-TEXT"))
        let huge = AiReference(kind: .selection(
            text: String(repeating: "x", count: AiPrompts.maxReferenceCharacters * 2) + "OMITTED-END", page: 1))
        let historicalText = AiPrompts.buildConversationBlock([
            AiPersistence.makeMessage(role: .user, content: "Explain", references: [huge]),
        ])
        XCTAssertLessThan(historicalText.count, AiPrompts.maxHistoryReferenceCharacters + 200)
        XCTAssertTrue(historicalText.contains("[referenced context truncated]"))
        let current = AiPrompts.buildNativeToolUserPrompt(AiPromptParameters(
            conversation: "", context: "", latestUserRequest: "Explain", references: [huge, imageReference]))
        XCTAssertFalse(current.volatile.contains("OMITTED-END"))
        XCTAssertTrue(current.volatile.contains("…[truncated]"))
        XCTAssertTrue(current.volatile.contains("[page snapshot, p.4] image attached"))
        let many = AiPrompts.buildNativeToolUserPrompt(AiPromptParameters(
            conversation: "", context: "", latestUserRequest: "Explain", references: Array(repeating: huge, count: 10)))
        XCTAssertLessThan(many.volatile.count, AiPrompts.maxReferencedBlockCharacters + 400)
        XCTAssertTrue(many.volatile.contains("[referenced context truncated]"))
    }
}
