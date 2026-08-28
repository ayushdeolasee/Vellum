#if os(iOS)
    import BackgroundTasks
    import Foundation

    // The one trigger the app cannot produce for itself: a wake-up while the
    // user is not in the app. Everything else about read-later autopull rides
    // `IntegrationsSyncEngine`'s existing startup / staleness / manual triggers
    // (see `IntegrationsStore.start` and `foregroundRefresh`); this adds the
    // "phone in a pocket on the way to the subway" case.
    //
    // `BGAppRefreshTask`, not `BGProcessingTask`: the work is a short network
    // top-up measured in tens of seconds, not a long maintenance job, and app
    // refresh is the class the system schedules against actual app usage.

    enum ReadLaterBackgroundRefresh {
        /// Must match `BGTaskSchedulerPermittedIdentifiers` in Info-iOS.plist.
        /// A mismatch is a launch-time crash on register, by design.
        static let identifier = "com.ayushdeolasee.vellum.readlater.refresh"

        /// A floor, not a schedule. iOS decides when (or whether) to run this
        /// based on usage and power; asking for less than an hour just wastes
        /// the request.
        static let earliestInterval: TimeInterval = 2 * 60 * 60

        /// Registration MUST happen before the app finishes launching, so this
        /// is called from `VellumApp_iOS.init` — not from a `.task`, which runs
        /// after the first frame and would make the launch-time registration
        /// check fail.
        @MainActor
        static func register(work: @escaping @MainActor @Sendable () async -> Void) {
            // The handler hands off to main-actor stores, so ask BackgroundTasks
            // to invoke it on the main queue instead of its default background queue.
            BGTaskScheduler.shared.register(forTaskWithIdentifier: identifier, using: .main) { task in
                guard let refresh = task as? BGAppRefreshTask else {
                    task.setTaskCompleted(success: false)
                    return
                }
                MainActor.assumeIsolated { handle(refresh, work: work) }
            }
        }

        /// Submits the next request. Called when the app leaves the foreground
        /// and again from inside the handler, because a task that ran is a task
        /// that is no longer scheduled.
        static func schedule(after interval: TimeInterval = earliestInterval) {
            let request = BGAppRefreshTaskRequest(identifier: identifier)
            request.earliestBeginDate = Date(timeIntervalSinceNow: interval)
            // Throws on the simulator (no background scheduling) and when the
            // user has disabled Background App Refresh. Neither is an error the
            // app can act on, and neither may take the launch down with it.
            try? BGTaskScheduler.shared.submit(request)
        }

        @MainActor
        private static func handle(
            _ task: BGAppRefreshTask, work: @escaping @MainActor @Sendable () async -> Void
        ) {
            // Reschedule FIRST. If the work throws the process into a crash, or
            // the system expires it, there is still a next wake-up pending.
            schedule()
            let job = Task { @MainActor in
                await work()
                task.setTaskCompleted(success: !Task.isCancelled)
            }
            // Expiration is a hard deadline: cancel and let the transfers
            // unwind. The prefetcher records nothing for an item whose download
            // did not finish, so a killed run costs a retry, never a phantom
            // retention entry.
            task.expirationHandler = { job.cancel() }
        }
    }
#endif
