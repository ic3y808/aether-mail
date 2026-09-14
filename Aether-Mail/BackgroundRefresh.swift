import Foundation
import BackgroundTasks
import EmailKit

/// Wakes the app periodically to check for mail.
///
/// iOS decides when - it learns from how the owner uses the app, so this is
/// minutes-to-an-hour, not instant. A task must reschedule itself before it
/// finishes or it never runs again, and it must call setTaskCompleted or the
/// system stops trusting the app with background time at all.
@MainActor
enum BackgroundRefresh {
    static let identifier = "com.aether.mail.refresh"

    /// Registered before the app finishes launching, which the system requires.
    static func register(store: MailStore) {
        BGTaskScheduler.shared.register(forTaskWithIdentifier: identifier, using: nil) { task in
            guard let task = task as? BGAppRefreshTask else { return }
            Task { @MainActor in await run(task, store: store) }
        }
    }

    static func schedule() {
        let request = BGAppRefreshTaskRequest(identifier: identifier)
        // A floor, not a promise: iOS will not run it sooner, and may run it
        // much later or not at all if the app is rarely opened.
        request.earliestBeginDate = Date(timeIntervalSinceNow: 15 * 60)
        try? BGTaskScheduler.shared.submit(request)
    }

    private static func run(_ task: BGAppRefreshTask, store: MailStore) async {
        // Always queue the next one first. Doing it at the end means a crash or
        // an expiry silently ends background refresh for good.
        schedule()

        let work = Task { @MainActor in
            for account in store.enabledAccounts {
                guard !Task.isCancelled else { break }
                await store.sync(account)
            }
            guard !Task.isCancelled else { return }
            let inbox = store.inbox
            await MailNotifier.shared.announce(inbox, unreadTotal: store.unreadCount, blockedAddresses: store.blockedSenders)
        }

        // The system gives roughly 30s and kills the app if it overruns.
        task.expirationHandler = { work.cancel() }
        _ = await work.result
        task.setTaskCompleted(success: true)
    }
}
