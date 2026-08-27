#if os(macOS)
import Foundation

/// Reports one anonymous event after the Mac app reaches its main window.
/// No identifier is created or sent, and failed requests retry on a later launch.
actor AnonymousAnalytics {
    static let shared = AnonymousAnalytics()

    private let endpoint = URL(string: "https://vellum.work/api/analytics")!
    private let sentKey = "vellum.analytics.firstLaunchReported"

    private init() {}

    func reportFirstLaunchIfNeeded() async {
        guard !TestEnvironment.isHostedTestProcess,
              !UITestLaunchConfiguration.isEnabled
        else { return }

        let defaults = AppDefaults.current
        guard !defaults.bool(forKey: sentKey),
              let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String,
              let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String
        else { return }

        let payload = Event(event: "first_launch", version: version, build: build)
        guard let body = try? JSONEncoder().encode(payload) else { return }

        var request = URLRequest(url: endpoint, timeoutInterval: 8)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = body

        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse,
                  httpResponse.statusCode == 204
            else { return }
            defaults.set(true, forKey: sentKey)
        } catch {
            // Analytics failure must not affect launch or show an error.
        }
    }

    private struct Event: Encodable {
        let event: String
        let version: String
        let build: String
    }
}
#endif
