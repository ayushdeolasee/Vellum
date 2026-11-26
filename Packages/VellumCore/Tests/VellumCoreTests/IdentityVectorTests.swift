import Foundation
import VellumCore
import XCTest

final class IdentityVectorTests: XCTestCase {
    func testHashUsesOriginalBytes() {
        XCTAssertEqual(DocumentIdentity.byteHash(Data()),
                       "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")
        let paths = [
            ("/Baseline Fixture/Reading Notes.pdf", "36c67571e9e165d17980d6e3c858d2e141fa4c88b22cdc3f71f821bbc25027dd"),
            ("/Baseline Fixture/café.pdf", "c963de55071e172a7449b32a4b394a4afa2f160c30072c282c912c03acf3e796"),
            ("/Baseline Fixture/cafe\u{301}.pdf", "aa218ec8c11daf66f300cc29684611de4c4410d3fcb8d2b7a66bfae0f43feb45")
        ]
        for (path, expected) in paths {
            let document = DocumentInfo(kind: .pdf, pdfPath: path, docId: "")
            XCTAssertEqual(DocumentIdentity.storageKey(for: document), expected)
        }
        XCTAssertEqual(DocumentIdentity.sha256Hex("https://example.test/a%2fb?q=%2B"),
                       "f38445bb3092462b4a31ab1a70f8db0b9a255d62cd5499976442f1806da39121")
        let stamped = DocumentInfo(kind: .pdf, pdfPath: paths[0].0, docId: "Legacy-ID")
        XCTAssertEqual(DocumentIdentity.storageKey(for: stamped), "Legacy-ID")
        XCTAssertFalse(DocumentIdentity.isCanonicalKey("Legacy-ID"))
    }

    func testInternationalHostAndRawPath() throws {
        let url = try WebURLNormalizer.normalize("https://Mu\u{308}nchen.test/cafe\u{301}", httpsOnly: false)
        XCTAssertEqual(url, "https://xn--mnchen-3ya.test/cafe%CC%81")
        XCTAssertEqual(DocumentIdentity.sha256Hex(url),
                       "9568a7810dafbc839d337c91e2461d0ef7318a2e93a79c38211693e2b7a45462")
    }

    func testFormEscapesAndTrackingParameters() throws {
        let raw = "https://example.test/?b=%2b%20a%26b%3dc%2f~*&ut%6d_source=x&a=one+two&b=%25&flag&&gclid=x#cut"
        XCTAssertEqual(try WebURLNormalizer.normalize(raw, httpsOnly: true),
                       "https://example.test/?b=%2B+a%26b%3Dc%2F%7E*&a=one+two&b=%25&flag=")
    }

    func testHTTPPolicyPrecedesHostValidation() throws {
        XCTAssertEqual(try WebURLNormalizer.normalize("HtTp://EXAMPLE.test:080/a", httpsOnly: false),
                       "http://example.test/a")
        for (httpsOnly, message) in [(true, "Plain HTTP webpages aren't supported. Use an HTTPS address."),
                                     (false, "Invalid URL: empty host")] {
            XCTAssertThrowsError(try WebURLNormalizer.normalize("http://?x", httpsOnly: httpsOnly)) { error in
                guard case WebURLNormalizationError.invalidDocument(let reason) = error else {
                    return XCTFail("Unexpected error: \(error)")
                }
                XCTAssertEqual(reason, message)
            }
        }
    }
}
