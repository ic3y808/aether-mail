import SwiftUI

/// Aether Mail on Apple Watch — a glanceable mirror of the iPhone inbox: unread
/// count, newest senders/subjects, and the on-device AI summary the phone
/// already computed. Read-only by design; the phone does the heavy lifting.
@main
struct AetherMailWatchApp: App {
    @State private var store = WatchStore()

    var body: some Scene {
        WindowGroup {
            WatchRootView()
                .environment(store)
                .tint(.watchViolet)
        }
    }
}
