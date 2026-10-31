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
        // Enable iOS opportunistic background fetch with the system minimum interval
        application.setMinimumBackgroundFetchInterval(UIApplication.backgroundFetchIntervalMinimum)
        return true
    }

    func application(
        _ application: UIApplication,
        performFetchWithCompletionHandler completionHandler: @escaping (UIBackgroundFetchResult) -> Void
    ) {
        guard let store = MailStore.current else {
            completionHandler(.noData)
            return
        }
        Task { @MainActor in
            let count = await store.backgroundQuickSync()
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
    @State private var store = MailStore()
    @Environment(\.scenePhase) private var scenePhase
    @State private var backgroundTaskID: UIBackgroundTaskIdentifier = .invalid

    init() {
        // Must happen before launch finishes, so it cannot wait for .task.
        // MailStore is created above, so it is safe to hand over here.
        let store = _store.wrappedValue
        BackgroundRefresh.register(store: store)
    }

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
                        }
                    case .background:
                        // Schedule periodic background refresh with iOS
                        BackgroundRefresh.schedule()

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

                        // Keep IDLE alive during the grace period (up to 25s), then cleanly disconnect
                        Task {
                            try? await Task.sleep(for: .seconds(25))
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
