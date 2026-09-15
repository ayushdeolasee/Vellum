#if os(iOS)
import Foundation
import UIKit

/// Reattaches to the extension-owned background session when iOS wakes Vellum,
/// drains the App Group inbox, then releases the system completion handler.
@MainActor
final class CaptureAppDelegate: NSObject, UIApplicationDelegate {
    static var drainInbox: (@Sendable () async -> Void)?

    private var backgroundSession: URLSession?
    private var backgroundSessionDelegate: CaptureBackgroundSessionDelegate?
    private var backgroundCompletionHandler: (() -> Void)?

    func application(
        _ application: UIApplication,
        handleEventsForBackgroundURLSession identifier: String,
        completionHandler: @escaping () -> Void
    ) {
        guard RuntimeProfile.current.syncEnabled,
              identifier == CaptureBackgroundSession.identifier else {
            completionHandler()
            return
        }
        backgroundCompletionHandler = completionHandler
        let delegate = CaptureBackgroundSessionDelegate { [weak self] in
            Task { @MainActor in
                await self?.finishBackgroundEvents()
            }
        }
        backgroundSessionDelegate = delegate
        backgroundSession = URLSession(
            configuration: CaptureBackgroundSession.configuration(),
            delegate: delegate,
            delegateQueue: nil)
    }

    private func finishBackgroundEvents() async {
        await Self.drainInbox?()
        let completion = backgroundCompletionHandler
        backgroundCompletionHandler = nil
        backgroundSession = nil
        backgroundSessionDelegate = nil
        completion?()
    }
}

/// Foundation owns the callback queue. This delegate has no mutable state: it
/// ignores the wake download and transfers the single completion signal onto
/// the app delegate's MainActor-isolated lifecycle state.
private final class CaptureBackgroundSessionDelegate: NSObject, URLSessionDownloadDelegate {
    private let didFinishEvents: @Sendable () -> Void

    init(didFinishEvents: @escaping @Sendable () -> Void) {
        self.didFinishEvents = didFinishEvents
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didFinishDownloadingTo location: URL
    ) {
        // The download only buys a launch event. The app deliberately refetches
        // through WebFetch so redirects, caps, and archive behavior stay shared
        // with normal reader capture; URLSession owns cleanup of this temp file.
    }

    func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        didFinishEvents()
    }
}
#endif
