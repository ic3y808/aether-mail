import SwiftUI
import UIKit
import BackgroundTasks

/// Application delegate to support iOS background fetch intervals and legacy fetch wakes
/// alongside BGTaskScheduler.
final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey : Any]? = nil
    ) -> Bool {
        // MUST register BGTaskScheduler launch handlers synchronously BEFORE didFinishLaunching returns!
        BackgroundRefresh.register(store: MailStore.shared)

        // Set UNUserNotificationCenter delegate synchronously during launch so foreground notifications work!
        UNUserNotificationCenter.current().delegate = MailNotifier.shared

        // Enable iOS opportunistic background fetch with the system minimum interval
        application.setMinimumBackgroundFetchInterval(UIApplication.backgroundFetchIntervalMinimum)

        // Register for Apple Remote Push Notifications (APNs)
        application.registerForRemoteNotifications()

        return true
    }

    func application(
        _ application: UIApplication,
        didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data
    ) {
        let token = deviceToken.map { String(format: "%02.2hhx", $0) }.joined()
        UserDefaults.standard.set(token, forKey: "AetherMail.apnsDeviceToken")
        Task { @MainActor in
            await MailNotifier.shared.registerAPNSToken(token)
        }
    }

    func application(
        _ application: UIApplication,
        didFailToRegisterForRemoteNotificationsWithError error: Error
    ) {
        UserDefaults.standard.set("Failed: \(error.localizedDescription)", forKey: "AetherMail.apnsError")
    }

    func application(
        _ application: UIApplication,
        didReceiveRemoteNotification userInfo: [AnyHashable : Any],
        fetchCompletionHandler completionHandler: @escaping (UIBackgroundFetchResult) -> Void
    ) {
        Task { @MainActor in
            let count = await MailStore.shared.backgroundQuickSync()
            BackgroundRefresh.recordCheck(summary: "Push wake: \(count) announced")
            completionHandler(count > 0 ? .newData : .noData)
        }
    }

    func application(
        _ application: UIApplication,
        performFetchWithCompletionHandler completionHandler: @escaping (UIBackgroundFetchResult) -> Void
    ) {
        Task { @MainActor in
            let count = await MailStore.shared.backgroundQuickSync()
            BackgroundRefresh.recordCheck(summary: "Background fetch: \(count) announced")
            BackgroundRefresh.schedule()
            completionHandler(count > 0 ? .newData : .noData)
        }
    }
}

/// Aether Mail — the iOS/iPadOS email client. Shell over the shared EmailKit
/// engine (same one the macOS Aether-Courier uses). AI routing (on-device → Mac
/// → cloud) layers in later.
@main
struct AetherMailApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var store = MailStore.shared
    @Environment(\.scenePhase) private var scenePhase
    @State private var backgroundTaskID: UIBackgroundTaskIdentifier = .invalid

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(store)
                .tint(.aetherViolet)
                .preferredColorScheme(.dark)   // the aurora-glass look is dark-first
                .task {
                    // Debug + Simulator only: signs in from a file on the Mac so
                    // a rebuild does not mean retyping an app password.
                    await DevBootstrap.run(store: store)
                    await MailNotifier.shared.requestAuthorization()
                    // Schedule background checks with iOS right away
                    BackgroundRefresh.schedule()
                    // Synchronize the application icon badge with current unread count
                    store.updateIconBadge()
                    // A fresh install must not fire a banner for every message
                    // already sitting in the inbox - the first sync is the
                    // baseline, not news.
                    if !MailNotifier.shared.hasAnnouncedAnything {
                        MailNotifier.shared.suppress(store.inbox)
                    }
                }
                .onChange(of: scenePhase) { _, phase in
                    switch phase {
                    case .active:
                        // Cancel any pending background task since app is foregrounded
                        if backgroundTaskID != .invalid {
                            UIApplication.shared.endBackgroundTask(backgroundTaskID)
                            backgroundTaskID = .invalid
                        }
                        // Refresh and connect live IMAP push so new mail arrives instantly
                        Task {
                            await store.refresh()
                            store.startAllIdle()
                            store.updateIconBadge()
                        }
                    case .background:
                        // Schedule periodic background refresh with iOS
                        BackgroundRefresh.schedule()
                        store.updateIconBadge()

                        // Request an execution grace period from iOS (~30 seconds)
                        // so ongoing syncs finish and incoming mail can be notified immediately
                        var taskID: UIBackgroundTaskIdentifier = .invalid
                        taskID = UIApplication.shared.beginBackgroundTask(withName: "com.aether.mail.backgroundGrace") {
                            // Expiration handler: iOS is revoking time
                            store.stopAllIdle()
                            if taskID != .invalid {
                                UIApplication.shared.endBackgroundTask(taskID)
                                taskID = .invalid
                            }
                        }
                        backgroundTaskID = taskID

                        // Keep IDLE alive during background grace period until iOS revokes time
                        Task {
                            while UIApplication.shared.backgroundTimeRemaining > 4 {
                                try? await Task.sleep(for: .seconds(2))
                                if backgroundTaskID == .invalid { break }
                            }
                            if taskID != .invalid {
                                store.stopAllIdle()
                                UIApplication.shared.endBackgroundTask(taskID)
                                taskID = .invalid
                            }
                        }
                    default:
                        break
                    }
                }
        }
    }
}
