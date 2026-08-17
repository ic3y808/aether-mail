import Foundation
import Observation
import WatchConnectivity

/// Watch-side state. Receives the phone's `MailMirror` over WatchConnectivity and
/// publishes it to the SwiftUI views. The watch never touches IMAP or the network
/// itself — it only ever shows what the iPhone pushed.
@MainActor @Observable
final class WatchStore: NSObject {
    var mirror: MailMirror = MailMirror(unreadCount: 0, messages: [])
    var hasData = false

    private static let cacheKey = "com.aether.mail.watch.mirror"

    override init() {
        super.init()
        loadCache()
        if WCSession.isSupported() {
            WCSession.default.delegate = self
            WCSession.default.activate()
        }
    }

    private func apply(_ m: MailMirror) {
        mirror = m
        hasData = true
        if let data = try? JSONEncoder().encode(m) {
            UserDefaults.standard.set(data, forKey: Self.cacheKey)
        }
    }

    private func loadCache() {
        guard let data = UserDefaults.standard.data(forKey: Self.cacheKey),
              let m = try? JSONDecoder().decode(MailMirror.self, from: data) else { return }
        mirror = m; hasData = true
    }
}

extension WatchStore: WCSessionDelegate {
    nonisolated func session(_ session: WCSession, activationDidCompleteWith state: WCSessionActivationState, error: Error?) {
        guard let m = MailMirror.from(context: session.receivedApplicationContext) else { return }
        Task { @MainActor in self.apply(m) }   // only the Sendable mirror crosses actors
    }
    nonisolated func session(_ session: WCSession, didReceiveApplicationContext applicationContext: [String: Any]) {
        guard let m = MailMirror.from(context: applicationContext) else { return }
        Task { @MainActor in self.apply(m) }
    }
}
