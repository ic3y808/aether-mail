import Foundation
import BackgroundTasks
import EmailKit

/// Wakes the app periodically to check for mail.
///
/// Supports both BGAppRefreshTask (for quick opportunistic checks) and
/// BGProcessingTask (for deeper sync and body prefetching when charging/idle).
@MainActor
enum BackgroundRefresh {
    static let refreshIdentifier = "com.aether.mail.refresh"
    static let processingIdentifier = "com.aether.mail.processing"

    /// Registered before the app finishes launching, which the system requires.
    static func register(store: MailStore) {
        BGTaskScheduler.shared.register(forTaskWithIdentifier: refreshIdentifier, using: nil) { task in
            guard let task = task as? BGAppRefreshTask else { return }
            Task { @MainActor in await run(task, store: store) }
        }
        BGTaskScheduler.shared.register(forTaskWithIdentifier: processingIdentifier, using: nil) { task in
            guard let task = task as? BGProcessingTask else { return }
            Task { @MainActor in await run(task, store: store) }
        }
    }

    static func schedule() {
        // Schedule opportunistic app refresh (every 10-15 minutes)
        let refreshRequest = BGAppRefreshTaskRequest(identifier: refreshIdentifier)
        refreshRequest.earliestBeginDate = Date(timeIntervalSinceNow: 10 * 60)
        try? BGTaskScheduler.shared.submit(refreshRequest)

        // Schedule background processing for deeper sync and prefetching
        let processingRequest = BGProcessingTaskRequest(identifier: processingIdentifier)
        processingRequest.earliestBeginDate = Date(timeIntervalSinceNow: 30 * 60)
        processingRequest.requiresNetworkConnectivity = true
        processingRequest.requiresExternalPower = false
        try? BGTaskScheduler.shared.submit(processingRequest)
    }

    private static func run(_ task: BGTask, store: MailStore) async {
        // Always queue the next run first so iOS has a pending request
        schedule()

        let work = Task { @MainActor in
            if task is BGAppRefreshTask {
                // Lean 1-2s check: INBOX only, no heavy folders or AI, announces immediately
                _ = await store.backgroundQuickSync()
            } else {
                // Deeper processing task (allowed more runtime)
                await store.refresh()
            }
        }

        // The system kills the app if it overruns (~30s for refresh)
        task.expirationHandler = { work.cancel() }
        _ = await work.result
        task.setTaskCompleted(success: !work.isCancelled)
    }
}
