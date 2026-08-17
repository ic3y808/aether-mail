import SwiftUI

/// Aether Mail — the iOS/iPadOS email client. Shell over the shared EmailKit
/// engine (same one the macOS Aether-Courier uses). AI routing (on-device → Mac
/// → cloud) layers in later.
@main
struct AetherMailApp: App {
    @State private var store = MailStore()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(store)
                .tint(Color(red: 0.60, green: 0.38, blue: 0.96))   // Aether violet
        }
    }
}
