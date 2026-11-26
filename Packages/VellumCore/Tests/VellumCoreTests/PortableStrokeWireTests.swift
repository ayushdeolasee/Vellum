import Foundation
import VellumCore
import XCTest

final class PortableStrokeWireTests: XCTestCase {
    /// Derived from the first embedded PKStroke of #446's pdf-ink-erased-partial.pdf.
    func testPartialErasureGoldenAndOpaqueFutureFields() throws {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "partial-stroke", withExtension: "json",
                                                  subdirectory: "Fixtures/Ink"))
        let data = try Data(contentsOf: url)
        var stroke = try JSONDecoder().decode(PortableStroke.self, from: data)
        XCTAssertEqual(stroke.id, "a284060ec6d9ca567256f7c186bc2477a35577d2561a2e6f9fd5005f1946c114")
        XCTAssertEqual(stroke.visibleRanges, [[0, 2.5833332538604736], [5.7083330154418945, 8]])
        XCTAssertEqual(stroke.points.count, 9)
        let json = try JSONDecoder().decode(JSONValue.self, from: data)
        let encoded = try JSONEncoder().encode(stroke)
        XCTAssertEqual(try JSONDecoder().decode(JSONValue.self, from: encoded), json)

        stroke.id = "future:opaque/007"
        let extra = JSONValue.object(["payload": .array([.int(3), .null])])
        stroke.unknownFields["future_stroke"] = extra
        stroke.points[0].unknownFields["future_point"] = extra
        stroke.mask?.unknownFields["future_mask"] = extra
        let carried = try JSONEncoder().encode(stroke)
        XCTAssertEqual(try JSONDecoder().decode(PortableStroke.self, from: carried), stroke)
    }

    func testEraseRequiresObservedRestoreAndIgnoresUnrelatedPageClock() throws {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "partial-stroke", withExtension: "json",
                                                  subdirectory: "Fixtures/Ink"))
        let stroke = try JSONDecoder().decode(PortableStroke.self, from: Data(contentsOf: url))
        let id = stroke.id
        let erase = "2026-11-26T09:00:00Z"
        let tie = "2026-11-26T10:00:00+01:00"
        var deleted = InkMergeHistory()
        deleted.deleted[id] = erase
        let wire = try JSONDecoder().decode(InkMergeHistory.self, from: JSONEncoder().encode(deleted))
        XCTAssertEqual(wire, deleted)
        for undo in [nil, tie, InkMergeHistory.next(tie, after: erase)] {
            var candidate = deleted
            candidate.restored[id] = undo
            let left = InkMergeHistory.merge(current: deleted, ids: [], timestamp: erase, incoming: candidate,
                                             incomingIDs: [id], incomingTimestamp: "2099-01-01T00:00:00Z")
            let right = InkMergeHistory.merge(current: candidate, ids: [id], timestamp: "2099-01-01T00:00:00Z",
                                              incoming: deleted, incomingIDs: [], incomingTimestamp: erase)
            let count = undo.map { InkMergeHistory.newer($0, than: erase) } == true ? 1 : 0
            XCTAssertEqual(left.strokes.count, count)
            XCTAssertEqual(right.strokes.count, count)
            XCTAssertEqual(left.history, right.history)
        }
        var lateUndo = deleted
        lateUndo.restored[id] = "2099-02-01T00:00:00Z"
        var laterErase = deleted
        laterErase.deleted[id] = "2026-11-27T00:00:00Z"
        let stale = InkMergeHistory.merge(current: laterErase, ids: [], timestamp: erase,
                                          incoming: lateUndo, incomingIDs: [id], incomingTimestamp: erase)
        XCTAssertTrue(stale.strokes.isEmpty)
        XCTAssertNil(stale.history.restored[id])
        XCTAssertFalse(InkMergeHistory.newer("2026-01-01T00:00:00.123999Z", than: "2026-01-01T00:00:00.123001Z"))
        var old = InkMergeHistory()
        old.updated[id] = erase
        let new = InkMergeHistory.merge(current: old, ids: [id], timestamp: "2099-01-01T00:00:00Z",
                                        incoming: InkMergeHistory(), incomingIDs: [id],
                                        incomingTimestamp: "2026-11-26T09:00:01Z")
        XCTAssertEqual(new.strokes.first?.incoming, true)
    }

    func testPortablePDFPayloadValidatesZlibFraming() throws {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "portable-partial", withExtension: "pdf",
                                                  subdirectory: "Fixtures/Ink"))
        let pdf = try ClassicPdfFile(data: Data(contentsOf: url))
        let payload = try XCTUnwrap(pdf.objectSource(7)?.textString(forKey: "VellumInkStrokes"))
        let strokes = try PortableStroke.decodePDFPayload(payload)
        XCTAssertEqual(strokes.count, 1)
        XCTAssertEqual(strokes.first?.id, "a284060ec6d9ca567256f7c186bc2477a35577d2561a2e6f9fd5005f1946c114")
        var compressed = try XCTUnwrap(Data(base64Encoded: payload))
        compressed.removeLast()
        XCTAssertThrowsError(try PortableStroke.decodePDFPayload(compressed.base64EncodedString()))
        compressed = try XCTUnwrap(Data(base64Encoded: payload))
        compressed.append(0)
        XCTAssertThrowsError(try PortableStroke.decodePDFPayload(compressed.base64EncodedString()))
    }

}
