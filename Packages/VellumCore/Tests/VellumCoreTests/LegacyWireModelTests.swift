import Foundation
import VellumCore
import XCTest

final class LegacyWireModelTests: XCTestCase {
    private func decode<T: Decodable>(_ type: T.Type, _ json: String) throws -> T {
        try JSONDecoder().decode(type, from: Data(json.utf8))
    }

    private func assertEncoding<T: Encodable>(
        _ value: T, _ expected: String, file: StaticString = #filePath, line: UInt = #line
    ) throws {
        let encoded = try JSONEncoder().encode(value)
        let actual = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? NSDictionary,
                                   file: file, line: line)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(expected.utf8)) as? NSDictionary,
                                   file: file, line: line)
        XCTAssertEqual(actual, object, file: file, line: line)
    }

    func testPublicInitializersAcceptLegacyCallSites() {
        let document = DocumentInfo(kind: .pdf, pdfPath: "/x")
        let position = PositionData(rects: [], pageWidth: 100, pageHeight: 200)
        let annotation = Annotation(id: "1", type: .note, pageNumber: 1, createdAt: "then", updatedAt: "now")
        let create = CreateAnnotationInput(type: .note, pageNumber: 1)
        let update = UpdateAnnotationInput(id: "1")

        XCTAssertNil(document.bookmarkData)
        XCTAssertNil(position.viewportOffset)
        XCTAssertNil(annotation.isPinned)
        XCTAssertNil(create.id)
        XCTAssertNil(update.pageNumber)
    }

    func testMissingDocumentKindAndOpaqueBookmarks() throws {
        let recent = try decode(RecentDocument.self, #"{"pdf_path":"/x","opened_at":"then"}"#)
        XCTAssertEqual(recent.kind, .pdf)
        try assertEncoding(recent, #"{"pdf_path":"/x","opened_at":"then","kind":"pdf"}"#)
        XCTAssertThrowsError(try decode(DocumentInfo.self, #"{"pdf_path":"/x"}"#)) { error in
            guard case DecodingError.keyNotFound(let key, _) = error else { return XCTFail("\(error)") }
            XCTAssertEqual(key.stringValue, "kind")
        }
        let json = #"{"pdf_path":"/x","kind":"pdf","bookmark_data":"AAH/gA=="}"#
        let document = try decode(DocumentInfo.self, json)
        XCTAssertEqual(document.bookmarkData, Data([0, 1, 255, 128]))
        try assertEncoding(document, json)
    }

    func testMissingPinRemainsAbsent() throws {
        let json = #"{"id":"1","type":"note","page_number":1,"created_at":"then","updated_at":"now"}"#
        let annotation = try decode(Annotation.self, json)
        XCTAssertFalse(annotation.pinned)
        XCTAssertNil(annotation.isPinned)
        try assertEncoding(annotation, json)
    }

    func testWebRecordTitleDefaults() throws {
        let inputs = [
            (#"{"url":"x","title":"Legacy"}"#,
             #"{"url":"x","title":"Legacy","title_is_user_defined":true,"saved":false,"annotations":[]}"#),
            (#"{"url":"x"}"#,
             #"{"url":"x","title_is_user_defined":false,"saved":false,"annotations":[]}"#),
            (#"{"url":"x","title":"DOM","title_is_user_defined":false}"#,
             #"{"url":"x","title":"DOM","title_is_user_defined":false,"saved":false,"annotations":[]}"#)
        ]
        for (input, expected) in inputs {
            try assertEncoding(decode(WebPageRecord.self, input), expected)
        }
    }
}
