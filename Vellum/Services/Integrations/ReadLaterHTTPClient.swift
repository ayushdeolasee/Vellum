import Foundation

protocol IntegrationSleeper: Sendable { func sleep(for duration: Duration) async throws }
struct ContinuousIntegrationSleeper: IntegrationSleeper { func sleep(for duration: Duration) async throws { try await Task.sleep(for: duration) } }

struct ReadLaterHTTPResponse: Sendable { let data: Data; let response: HTTPURLResponse }

actor ReadLaterHTTPClient {
    private let session: URLSession
    private let sleeper: any IntegrationSleeper
    private let now: @Sendable () -> Date
    private let maximumRetryDelay: TimeInterval

    init(session: URLSession = .shared, sleeper: any IntegrationSleeper = ContinuousIntegrationSleeper(), now: @escaping @Sendable () -> Date = { .now }, maximumRetryDelay: TimeInterval = 60) {
        self.session = session; self.sleeper = sleeper; self.now = now; self.maximumRetryDelay = maximumRetryDelay
    }

    func perform(_ request: URLRequest, provider: IntegrationProvider, acceptedStatus: ClosedRange<Int> = 200...299) async throws -> ReadLaterHTTPResponse {
        for attempt in 1...3 {
            try Task.checkCancellation()
            do {
                let (data, response) = try await session.data(for: request)
                try Task.checkCancellation()
                guard let response = response as? HTTPURLResponse else { throw IntegrationError.invalidResponse }
                if acceptedStatus.contains(response.statusCode) { return .init(data: data, response: response) }
                if response.statusCode == 401 || response.statusCode == 403 { throw IntegrationError.tokenRejected }
                let retryable = response.statusCode == 408 || response.statusCode == 429 || (500...599).contains(response.statusCode)
                guard retryable, attempt < 3 else {
                    if response.statusCode == 429 { throw IntegrationError.rateLimited }
                    throw IntegrationError.server(status: response.statusCode)
                }
                try await sleeper.sleep(for: .seconds(retryDelay(response, attempt: attempt)))
            } catch is CancellationError { throw CancellationError() }
            catch let error as URLError where error.code == .cancelled { throw CancellationError() }
            catch let error as IntegrationError { throw error }
            catch let error as URLError {
                let transient: Set<URLError.Code> = [.timedOut, .cannotFindHost, .cannotConnectToHost, .networkConnectionLost, .dnsLookupFailed, .notConnectedToInternet, .resourceUnavailable]
                guard request.httpMethod == nil || request.httpMethod == "GET", transient.contains(error.code), attempt < 3 else { throw error }
                try await sleeper.sleep(for: .seconds(min(pow(2, Double(attempt - 1)), maximumRetryDelay)))
            }
        }
        throw IntegrationError.invalidResponse
    }

    private func retryDelay(_ response: HTTPURLResponse, attempt: Int) -> TimeInterval {
        guard let value = response.value(forHTTPHeaderField: "Retry-After")?.trimmingCharacters(in: .whitespacesAndNewlines) else { return min(pow(2, Double(attempt - 1)), maximumRetryDelay) }
        if let seconds = TimeInterval(value) { return max(0, min(seconds, maximumRetryDelay)) }
        let formatter = DateFormatter(); formatter.locale = Locale(identifier: "en_US_POSIX"); formatter.timeZone = TimeZone(secondsFromGMT: 0); formatter.dateFormat = "EEE',' dd MMM yyyy HH':'mm':'ss z"
        if let date = formatter.date(from: value) { return max(0, min(date.timeIntervalSince(now()), maximumRetryDelay)) }
        return min(pow(2, Double(attempt - 1)), maximumRetryDelay)
    }
}

extension JSONEncoder {
    static var integrations: JSONEncoder { let value = JSONEncoder(); value.dateEncodingStrategy = .iso8601; value.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]; return value }
}
