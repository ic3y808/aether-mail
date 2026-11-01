import Foundation
import UIKit
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

    private static let lastCheckKey = "BackgroundRefresh.lastCheck"
    private static let lastStatusKey = "BackgroundRefresh.lastStatus"
    private static let lastScheduleKey = "BackgroundRefresh.lastSchedule"

    /// Registered synchronously before the app finishes launching in application:didFinishLaunchingWithOptions:
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
        UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: lastScheduleKey)

        // Schedule opportunistic app refresh (as early as 1 minute)
        let refreshRequest = BGAppRefreshTaskRequest(identifier: refreshIdentifier)
        refreshRequest.earliestBeginDate = Date(timeIntervalSinceNow: 60)
        do {
            try BGTaskScheduler.shared.submit(refreshRequest)
        } catch {
            // Error code 1 is BGTaskSchedulerError.Code.tooManyPendingTaskRequests - safe to ignore
        }

        // Schedule background processing for deeper sync and prefetching
        let processingRequest = BGProcessingTaskRequest(identifier: processingIdentifier)
        processingRequest.earliestBeginDate = Date(timeIntervalSinceNow: 5 * 60)
        processingRequest.requiresNetworkConnectivity = true
        processingRequest.requiresExternalPower = false
        do {
            try BGTaskScheduler.shared.submit(processingRequest)
        } catch {
            // Non-fatal if already pending
        }
    }

    private static func run(_ task: BGTask, store: MailStore) async {
        // Always queue the next run first so iOS has a pending request
        schedule()

        let work = Task { @MainActor in
            if !store.cacheRestored {
                await store.restoreCache()
            }
            if task is BGAppRefreshTask {
                let announced = await store.backgroundQuickSync()
                recordCheck(summary: "Quick check: \(announced) announced")
            } else {
                let announced = await store.backgroundDeepSync()
                recordCheck(summary: "Deep sync: \(announced) announced")
            }
        }

        // The system kills the app if it overruns (~30s for refresh)
        task.expirationHandler = {
            work.cancel()
            recordCheck(summary: "Expired by iOS")
        }
        _ = await work.result
        task.setTaskCompleted(success: !work.isCancelled)
    }

    static func recordCheck(summary: String) {
        UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: lastCheckKey)
        UserDefaults.standard.set(summary, forKey: lastStatusKey)
    }

    static var lastCheckDate: Date? {
        let ts = UserDefaults.standard.double(forKey: lastCheckKey)
        return ts > 0 ? Date(timeIntervalSince1970: ts) : nil
    }

    static var lastCheckStatus: String {
        UserDefaults.standard.string(forKey: lastStatusKey) ?? "No background checks recorded yet"
    }

    static var backgroundRefreshStatusDescription: String {
        switch UIApplication.shared.backgroundRefreshStatus {
        case .available:
            return "Available"
        case .denied:
            return "Disabled in iOS Settings"
        case .restricted:
            return "Restricted (MDM / Screen Time)"
        @unknown default:
            return "Unknown"
        }
    }
}
