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

    @Test("Routes from the other app profile are rejected", .bug(id: 207))
    func rejectsOtherProfile() throws {
        let otherScheme = RuntimeProfile.current.isDevelopment ? "vellum" : "vellum-dev"
        let route = try #require(URL(string: "\(otherScheme)://open-url?url=https%3A%2F%2Fexample.com"))
        #expect(VellumExternalWebLink.parse(route) == nil)
    }

    @Test(
        "Malformed or unsafe webpage routes fail closed",
        .bug(id: 207),
        arguments: [
            "\(VellumExternalWebLink.scheme)://open-url?url=file%3A%2F%2F%2Ftmp%2Fprivate.pdf",
            "\(VellumExternalWebLink.scheme)://open-url?url=javascript%3Aalert(1)",
            "\(VellumExternalWebLink.scheme)://open-url?url=https%3A%2F%2F",
            "\(VellumExternalWebLink.scheme)://open-url?url=https%3A%2F%2Fexample.com&url=https%3A%2F%2Fother.com",
            "\(VellumExternalWebLink.scheme)://open-url?url=https%3A%2F%2Fexample.com&extra=value",
            "\(VellumExternalWebLink.scheme)://open-url/path?url=https%3A%2F%2Fexample.com",
            "\(VellumExternalWebLink.scheme)://open-url?url=https%3A%2F%2Fexample.com#fragment",
            "\(VellumExternalWebLink.scheme)://user@open-url?url=https%3A%2F%2Fexample.com",
        ])
    func rejectsMalformed(_ value: String) throws {
        let route = try #require(URL(string: value))
        #expect(VellumExternalWebLink.parse(route) == nil)
    }
}
