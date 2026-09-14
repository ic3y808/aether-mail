import SwiftUI

/// Aether Mail — the iOS/iPadOS email client. Shell over the shared EmailKit
/// engine (same one the macOS Aether-Courier uses). AI routing (on-device → Mac
/// → cloud) layers in later.
@main
struct AetherMailApp: App {
    @State private var store = MailStore()
    @Environment(\.scenePhase) private var scenePhase

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
                        // App resumed or brought to foreground: refresh immediately
                        // and connect live IMAP push so new mail arrives instantly.
                        store.refresh()
                        store.startAllIdle()
                    case .background:
                        // App left foreground: close live IMAP connections cleanly
                        // and schedule periodic background refresh with iOS.
                        store.stopAllIdle()
                        BackgroundRefresh.schedule()
                    default:
                        break
                    }
                }
        }
    }
}
