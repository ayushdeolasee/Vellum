import Foundation

// FOUNDATION ONLY — compiled into both the app and share extension.

/// The extension's background download is a wake-up signal, not the capture
/// pipeline. Its bytes are discarded; once iOS wakes the containing app, the
/// app drains the App Group record through WebFetch/WebArchive itself.
enum CaptureBackgroundSession {
    static var identifier: String { RuntimeProfile.current.captureBackgroundSessionIdentifier }

    static func configuration() -> URLSessionConfiguration {
        configuration(identifier: identifier)
    }

    /// Parameterized for a side-effect-free configuration test.
    static func configuration(identifier: String) -> URLSessionConfiguration {
        let configuration = URLSessionConfiguration.background(withIdentifier: identifier)
        configuration.sharedContainerIdentifier = CaptureInboxLayout.appGroupIdentifier
        configuration.sessionSendsLaunchEvents = true
        return configuration
    }
}
