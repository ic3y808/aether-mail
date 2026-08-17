import Foundation
#if canImport(WatchConnectivity)
import WatchConnectivity
#endif

/// Phone → Watch link. Keeps the paired Apple Watch's inbox glance in sync by
/// pushing a tiny `MailMirror` (unread count + newest messages + their AI
/// summaries) through WatchConnectivity's `updateApplicationContext` — which
/// always delivers the *latest* state, exactly what a glanceable watch app wants.
@MainActor
final class WatchBridge: NSObject {
    static let shared = WatchBridge()
    private var lastPayload: Data?

    #if canImport(WatchConnectivity)
    private var session: WCSession? { WCSession.isSupported() ? WCSession.default : nil }
    #endif

    func activate() {
        #if canImport(WatchConnectivity)
        guard let session, session.delegate == nil else { return }
        session.delegate = self
        session.activate()
        #endif
    }

    /// Build the mirror from the store's current inbox and hand it to the watch.
    func sync(from store: MailStore) {
        #if canImport(WatchConnectivity)
        guard let session, session.activationState == .activated, session.isPaired,
              session.isWatchAppInstalled else { return }
        let items = store.inbox.prefix(20).map { m in
            MailGlance(id: m.id,
                       sender: m.from.first?.shortLabel ?? "Unknown",
                       subject: m.subject.isEmpty ? "(no subject)" : m.subject,
                       snippet: m.snippet,
                       summary: store.summary(for: m.id),
                       unread: store.isUnread(m),
                       date: m.date)
        }
        let mirror = MailMirror(unreadCount: store.unreadCount, messages: Array(items))
        guard let data = try? JSONEncoder().encode(mirror), data != lastPayload else { return }
        lastPayload = data
        try? session.updateApplicationContext([MailMirror.contextKey: data])
        #endif
    }
}

#if canImport(WatchConnectivity)
extension WatchBridge: WCSessionDelegate {
    nonisolated func session(_ session: WCSession, activationDidCompleteWith state: WCSessionActivationState, error: Error?) {}
    nonisolated func sessionDidBecomeInactive(_ session: WCSession) {}
    nonisolated func sessionDidDeactivate(_ session: WCSession) { session.activate() }
}
#endif
