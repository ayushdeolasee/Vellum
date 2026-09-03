import Foundation
import Testing

@testable import Vellum

@Suite("External webpage links")
struct VellumExternalWebLinkTests {
    @Test("A webpage round-trips through the browser extension route", .bug(id: 207))
    func webpageRoundTrip() throws {
        let webpage = try #require(URL(string: "https://example.com/article?q=swift&sort=new#notes"))
        let route = try #require(VellumExternalWebLink.url(for: webpage))

        #expect(VellumExternalWebLink.parse(route) == webpage)
    }

    @Test(
        "Malformed or unsafe webpage routes fail closed",
        .bug(id: 207),
        arguments: [
            "vellum://open-url?url=file%3A%2F%2F%2Ftmp%2Fprivate.pdf",
            "vellum://open-url?url=javascript%3Aalert(1)",
            "vellum://open-url?url=https%3A%2F%2Fexample.com&extra=value",
            "vellum://open-url/path?url=https%3A%2F%2Fexample.com",
            "vellum://open-url?url=https%3A%2F%2Fexample.com#fragment",
            "vellum://user@open-url?url=https%3A%2F%2Fexample.com",
        ])
    func rejectsMalformed(_ value: String) throws {
        let route = try #require(URL(string: value))
        #expect(VellumExternalWebLink.parse(route) == nil)
    }
}
