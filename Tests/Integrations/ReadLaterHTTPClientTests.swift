import Foundation
import Synchronization
import Testing
@testable import Vellum

@Suite(.serialized)
struct ReadLaterHTTPClientTests {
    @Test func retries408AndStopsAfterSuccess() async throws {
        let attempts = Mutex(0)
        StubURLProtocol.install { request in
            let attempt = attempts.withLock { value in value += 1; return value }
            let status = attempt < 3 ? 408 : 200
            return (HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!, Data("ok".utf8))
        }
        defer { StubURLProtocol.reset() }
        let client = ReadLaterHTTPClient(session: StubURLProtocol.session(), sleeper: NoWaitIntegrationSleeper())
        let response = try await client.perform(URLRequest(url: URL(string: "https://example.com")!), provider: .readwise, idempotent: true)
        #expect(response.response.statusCode == 200)
        #expect(attempts.withLock { $0 } == 3)
    }

    @Test func rateLimitUsesNumericRetryAfterBeforeRetrying() async throws {
        let attempts = Mutex(0)
        StubURLProtocol.install { request in
            let attempt = attempts.withLock { value in value += 1; return value }
            let headers = attempt == 1 ? ["Retry-After": "7"] : nil
            let status = attempt == 1 ? 429 : 200
            return (HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: headers)!, Data())
        }
        defer { StubURLProtocol.reset() }
        let sleeper = RecordingIntegrationSleeper()
        let client = ReadLaterHTTPClient(session: StubURLProtocol.session(), sleeper: sleeper)

        _ = try await client.perform(URLRequest(url: URL(string: "https://example.com")!), provider: .raindrop, idempotent: true)

        let durations = await sleeper.durations()
        #expect(durations == [.seconds(7)])
        #expect(attempts.withLock { $0 } == 2)
    }

    @Test func rateLimitUsesHTTPDateRetryAfterAndCapsTheDelay() async throws {
        let attempts = Mutex(0)
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "EEE',' dd MMM yyyy HH':'mm':'ss z"
        let retryAfter = formatter.string(from: now.addingTimeInterval(120))
        StubURLProtocol.install { request in
            let attempt = attempts.withLock { value in value += 1; return value }
            let headers = attempt == 1 ? ["Retry-After": retryAfter] : nil
            let status = attempt == 1 ? 429 : 200
            return (HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: headers)!, Data())
        }
        defer { StubURLProtocol.reset() }
        let sleeper = RecordingIntegrationSleeper()
        let client = ReadLaterHTTPClient(
            session: StubURLProtocol.session(),
            sleeper: sleeper,
            now: { now },
            maximumRetryDelay: 30
        )

        _ = try await client.perform(URLRequest(url: URL(string: "https://example.com")!), provider: .readwise, idempotent: true)

        let durations = await sleeper.durations()
        #expect(durations == [.seconds(30)])
    }

    @Test func repeated429EndsAsRateLimitedAfterThreeAttempts() async {
        let attempts = Mutex(0)
        StubURLProtocol.install { request in
            attempts.withLock { $0 += 1 }
            return (HTTPURLResponse(url: request.url!, statusCode: 429, httpVersion: nil, headerFields: ["Retry-After": "0"])!, Data())
        }
        defer { StubURLProtocol.reset() }
        let sleeper = RecordingIntegrationSleeper()
        let client = ReadLaterHTTPClient(session: StubURLProtocol.session(), sleeper: sleeper)

        await #expect(throws: IntegrationError.rateLimited) {
            try await client.perform(URLRequest(url: URL(string: "https://example.com")!), provider: .readwise, idempotent: true)
        }

        let durations = await sleeper.durations()
        #expect(attempts.withLock { $0 } == 3)
        #expect(durations.count == 2)
    }

    @Test func readwisePageSendsCursorWatermarkLimitAndToken() async throws {
        let boundary = Date(timeIntervalSince1970: 1_700_000_000)
        StubURLProtocol.install { request in
            guard let url = request.url, let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { throw URLError(.badURL) }
            let query = Dictionary(uniqueKeysWithValues: (components.queryItems ?? []).map { ($0.name, $0.value ?? "") })
            #expect(components.path == "/api/v3/list/")
            #expect(query["pageCursor"] == "cursor-2")
            #expect(query["updatedAfter"] == ISO8601DateFormatter.integrationString(from: boundary))
            #expect(query["limit"] == "37")
            #expect(request.value(forHTTPHeaderField: "Authorization") == "Token readwise-token")
            return (HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!, try FixtureLoader.data("Readwise", "items-page-final"))
        }
        defer { StubURLProtocol.reset() }
        let http = ReadLaterHTTPClient(session: StubURLProtocol.session(), sleeper: NoWaitIntegrationSleeper())
        let client = ReadwiseClient(http: http, baseURL: URL(string: "https://example.test")!)

        let page = try await client.page(token: "readwise-token", cursor: "cursor-2", updatedAfter: boundary, limit: 37)

        #expect(page.items.map(\.id) == ["readwise:rw-pdf"])
    }

    @Test func raindropPageSendsFullWalkPageSizeSortAndBearerToken() async throws {
        StubURLProtocol.install { request in
            guard let url = request.url, let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { throw URLError(.badURL) }
            let query = Dictionary(uniqueKeysWithValues: (components.queryItems ?? []).map { ($0.name, $0.value ?? "") })
            #expect(components.path == "/rest/v1/raindrops/0")
            #expect(query["page"] == "4")
            #expect(query["perpage"] == "50")
            #expect(query["sort"] == "-created")
            #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer raindrop-token")
            return (HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!, try FixtureLoader.data("Raindrop", "items-page-final"))
        }
        defer { StubURLProtocol.reset() }
        let http = ReadLaterHTTPClient(session: StubURLProtocol.session(), sleeper: NoWaitIntegrationSleeper())
        let client = RaindropClient(http: http, baseURL: URL(string: "https://example.test")!)

        let page = try await client.page(token: "raindrop-token", page: 4, perPage: 50)

        #expect(page.hasMore == false)
        #expect(page.responseWasEmpty)
    }

    @Test func raindropCollectionsFetchesRootsAndChildrenBeforeFlattening() async throws {
        let paths = Mutex<[String]>([])
        StubURLProtocol.install { request in
            guard let url = request.url else { throw URLError(.badURL) }
            paths.withLock { $0.append(url.path) }
            let fixture: String
            switch url.path {
            case "/rest/v1/collections": fixture = "collections-root"
            case "/rest/v1/collections/childrens": fixture = "collections-child"
            default: throw URLError(.unsupportedURL)
            }
            return (HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!, try FixtureLoader.data("Raindrop", fixture))
        }
        defer { StubURLProtocol.reset() }
        let http = ReadLaterHTTPClient(session: StubURLProtocol.session(), sleeper: NoWaitIntegrationSleeper())
        let client = RaindropClient(http: http, baseURL: URL(string: "https://example.test")!)

        let collections = try await client.collections(token: "raindrop-token")

        #expect(Set(paths.withLock { $0 }) == Set(["/rest/v1/collections", "/rest/v1/collections/childrens"]))
        #expect(collections.map(\.title) == ["Research", "Swift", "Concurrency"])
        #expect(collections.map(\.depth) == [0, 1, 2])
    }

    @Test func readwiseRawSourceLookupUsesDurableItemIDAndDoesNotCacheTheURL() async throws {
        StubURLProtocol.install { request in
            guard let url = request.url, let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { throw URLError(.badURL) }
            let query = Dictionary(uniqueKeysWithValues: (components.queryItems ?? []).map { ($0.name, $0.value ?? "") })
            #expect(query["id"] == "rw-pdf")
            #expect(query["withRawSourceUrl"] == "true")
            #expect(query["limit"] == "1")
            return (HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!, try FixtureLoader.data("Readwise", "raw-source"))
        }
        defer { StubURLProtocol.reset() }
        let http = ReadLaterHTTPClient(session: StubURLProtocol.session(), sleeper: NoWaitIntegrationSleeper())
        let client = ReadwiseClient(http: http, baseURL: URL(string: "https://example.test")!)

        let rawSourceURL = try await client.rawSourceURL(token: "readwise-token", itemID: "rw-pdf")

        #expect(rawSourceURL?.host() == "signed.example.com")
    }

    @Test func cancelledURLErrorDoesNotRetry() async {
        let attempts = Mutex(0)
        StubURLProtocol.install { _ in attempts.withLock { $0 += 1 }; throw URLError(.cancelled) }
        defer { StubURLProtocol.reset() }
        let client = ReadLaterHTTPClient(session: StubURLProtocol.session(), sleeper: NoWaitIntegrationSleeper())
        await #expect(throws: CancellationError.self) {
            try await client.perform(URLRequest(url: URL(string: "https://example.com")!), provider: .readwise, idempotent: true)
        }
        #expect(attempts.withLock { $0 } == 1)
    }

    // Retryability is now explicit rather than method-sniffed: a non-idempotent request must
    // not be silently retried on a transient status code, even though the status-code path
    // used to retry regardless of HTTP method.
    @Test func nonIdempotentRequestDoesNotRetryOnServerError() async {
        let attempts = Mutex(0)
        StubURLProtocol.install { request in
            attempts.withLock { $0 += 1 }
            return (HTTPURLResponse(url: request.url!, statusCode: 503, httpVersion: nil, headerFields: nil)!, Data())
        }
        defer { StubURLProtocol.reset() }
        let client = ReadLaterHTTPClient(session: StubURLProtocol.session(), sleeper: NoWaitIntegrationSleeper())
        await #expect(throws: IntegrationError.server(status: 503)) {
            try await client.perform(URLRequest(url: URL(string: "https://example.com")!), provider: .readwise, idempotent: false)
        }
        #expect(attempts.withLock { $0 } == 1)
    }

    // Same guarantee on the transient-URLError retry path.
    @Test func nonIdempotentRequestDoesNotRetryOnTransientURLError() async {
        let attempts = Mutex(0)
        StubURLProtocol.install { _ in attempts.withLock { $0 += 1 }; throw URLError(.networkConnectionLost) }
        defer { StubURLProtocol.reset() }
        let client = ReadLaterHTTPClient(session: StubURLProtocol.session(), sleeper: NoWaitIntegrationSleeper())
        await #expect(throws: URLError.self) {
            try await client.perform(URLRequest(url: URL(string: "https://example.com")!), provider: .readwise, idempotent: false)
        }
        #expect(attempts.withLock { $0 } == 1)
    }
}
