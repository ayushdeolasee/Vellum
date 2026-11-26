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
}
