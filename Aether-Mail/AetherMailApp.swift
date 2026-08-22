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
                    await MailNotifier.shared.requestAuthorization()
                    // A fresh install must not fire a banner for every message
                    // already sitting in the inbox - the first sync is the
                    // baseline, not news.
                    if !MailNotifier.shared.hasAnnouncedAnything {
                        MailNotifier.shared.suppress(store.inbox)
                    }
                }
                .onChange(of: scenePhase) { _, phase in
                    // Queue the next background check whenever the app leaves
                    // the foreground; that is the only moment iOS reliably
                    // honours the request.
                    if phase == .background { BackgroundRefresh.schedule() }
                }
        }
    }
}
