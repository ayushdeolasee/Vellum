import XCTest
@testable import Vellum

/// Round-trip guarantees for the truthful proxy-URL mapping
/// (plans/web-proxy-truthful-urls.html): a normalized page URL must survive
/// normalized → proxyUrl → WKWebView → realUrl → normalize unchanged, or the
/// reader rebinds documents to the wrong identity.
final class WebProxyUrlTests: XCTestCase {
    private func assertRoundTrip(_ raw: String, file: StaticString = #filePath, line: UInt = #line) throws {
        let normalized = try WebUrl.normalize(raw)
        let proxy = VellumWebSchemeHandler.proxyUrl(for: normalized)
        guard let real = VellumWebSchemeHandler.realUrl(from: proxy) else {
            XCTFail("realUrl returned nil for \(proxy)", file: file, line: line)
            return
        }
        XCTAssertEqual(try WebUrl.normalize(real), normalized, file: file, line: line)
    }

    func testRoundTripBasics() throws {
        try assertRoundTrip("https://www.anthropic.com/research/global-workspace")
        try assertRoundTrip("https://example.com")
        try assertRoundTrip("https://example.com/")
        try assertRoundTrip("http://localhost:3000/dev-page")
    }

    func testRoundTripEncodingEdges() throws {
        try assertRoundTrip("https://example.com/a b/c")          // space → %20
        try assertRoundTrip("https://münchen.de/straße")          // punycode host, encoded path
        try assertRoundTrip("https://example.com/a//b/")          // preserved empty segments
        try assertRoundTrip("https://example.com/?q=a%26b&x=1")   // encoded & inside a value
        try assertRoundTrip("https://user:pw@example.com/private") // userinfo
    }

    func testSchemeMapping() {
        XCTAssertEqual(
            VellumWebSchemeHandler.proxyUrl(for: "https://example.com/a").absoluteString,
            "vellum-web://example.com/a")
        XCTAssertEqual(
            VellumWebSchemeHandler.proxyUrl(for: "http://example.com/a").absoluteString,
            "vellum-webi://example.com/a")
    }

    func testReservedHostsAreNotPages() {
        XCTAssertNil(VellumWebSchemeHandler.realUrl(
            from: URL(string: "vellum-web://assets.vellum.invalid/abc123/img.png")!))
        XCTAssertNil(VellumWebSchemeHandler.realUrl(
            from: URL(string: "vellum-web://snapshot.vellum.invalid/abc123")!))
        XCTAssertNil(VellumWebSchemeHandler.realUrl(
            from: URL(string: "https://example.com/not-a-proxy-url")!))
    }

    func testRealSiteAssetPathIsAPage() {
        // A real site's own /asset/... path must reach the page pipeline,
        // not the archive-asset route (which lives on the reserved host).
        XCTAssertEqual(
            VellumWebSchemeHandler.realUrl(
                from: URL(string: "vellum-web://example.com/asset/whatever")!),
            "https://example.com/asset/whatever")
    }
}
