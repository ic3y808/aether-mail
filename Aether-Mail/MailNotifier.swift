import Foundation
import UserNotifications
import EmailKit

/// New-mail notifications.
///
/// iOS cannot hold an IMAP IDLE connection open in the background, so this is
/// not true push: the OS wakes the app when it feels like it (typically every
/// 15-60 minutes, learned from usage), the app syncs, and anything genuinely new
/// becomes a local notification. True push would need an APNs key plus a
/// server-side watcher holding IDLE per account - a separate build, and this
/// works with no infrastructure at all.
@MainActor
final class MailNotifier: NSObject, UNUserNotificationCenterDelegate {
    static let shared = MailNotifier()

    /// Message ids already announced, so a re-sync of the same mail is silent.
    /// Persisted, because the whole point is surviving app launches.
    private let seenKey = "MailNotifier.announced"
    private var announced: Set<String> {
        get { Set(UserDefaults.standard.stringArray(forKey: seenKey) ?? []) }
        set {
            // Bounded: this grows forever otherwise, and only the recent tail
            // matters for "have I already mentioned this?".
            let trimmed = Array(newValue.suffix(2000))
            UserDefaults.standard.set(trimmed, forKey: seenKey)
        }
    }

    private override init() {
        super.init()
        UNUserNotificationCenter.current().delegate = self
    }

    /// Presents banners, sounds and badges even while the app is active in the foreground.
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound, .badge, .list])
    }

    /// Asks once. A refusal is remembered by the system, so this is safe to call
    /// on every launch.
    func requestAuthorization() async {
        _ = try? await UNUserNotificationCenter.current()
            .requestAuthorization(options: [.alert, .sound, .badge])
    }

    var isAuthorized: Bool {
        get async {
            let settings = await UNUserNotificationCenter.current().notificationSettings()
            return settings.authorizationStatus == .authorized
                || settings.authorizationStatus == .provisional
        }
    }

    /// Announces unread mail that has not been announced before.
    ///
    /// Takes the whole inbox rather than a delta so the caller does not have to
    /// track state: what is new is decided here, against what was announced.
    /// Returns how many notifications were posted.
    @discardableResult
    func announce(
        _ messages: [MailMessage],
        unreadTotal: Int,
        blockedAddresses: Set<String> = [],
        blockedChecker: ((MailMessage) -> Bool)? = nil
    ) async -> Int {
        guard await isAuthorized else { return 0 }

        var seen = announced
        // Newest first, and never more than a handful at once - waking up to
        // twenty separate banners for one sync is worse than a summary.
        let fresh = messages
            .filter { m in
                guard m.isUnread && !seen.contains(m.id) else { return false }
                if let checker = blockedChecker, checker(m) { return false }
                if !blockedAddresses.isEmpty {
                    for addr in m.from {
                        var clean = addr.address.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
                        if let s = clean.firstIndex(of: "<"), let e = clean.lastIndex(of: ">"), s < e {
                            clean = String(clean[clean.index(after: s)..<e])
                        }
                        clean = clean.trimmingCharacters(in: CharacterSet(charactersIn: "\"' <>\t\r\n"))
                        if blockedAddresses.contains(clean) { return false }
                        if let at = clean.firstIndex(of: "@") {
                            let domain = String(clean[at...])
                            if blockedAddresses.contains(domain) { return false }
                            let bareDomain = String(clean[clean.index(after: at)...])
                            if blockedAddresses.contains(bareDomain) { return false }
                            for b in blockedAddresses {
                                let bare = b.hasPrefix("@") ? String(b.dropFirst()) : b
                                if !bare.isEmpty && (bareDomain == bare || bareDomain.hasSuffix("." + bare)) {
                                    return false
                                }
                            }
                        }
                    }
                }
                return true
            }
            .sorted { ($0.date ?? .distantPast) > ($1.date ?? .distantPast) }

        guard !fresh.isEmpty else {
            await setBadge(unreadTotal)
            return 0
        }

        let center = UNUserNotificationCenter.current()
        let shown = Array(fresh.prefix(5))

        for message in shown {
            let content = UNMutableNotificationContent()
            content.title = message.from.first?.shortLabel ?? "New mail"
            content.body = message.subject.isEmpty ? "(no subject)" : message.subject
            content.sound = .default
            content.threadIdentifier = message.accountID.uuidString
            content.userInfo = ["messageID": message.id]
            try? await center.add(UNNotificationRequest(
                identifier: message.id, content: content, trigger: nil))
        }

        if fresh.count > shown.count {
            let rest = fresh.count - shown.count
            let content = UNMutableNotificationContent()
            content.title = "Aether Mail"
            content.body = "and \(rest) more new message\(rest == 1 ? "" : "s")"
            content.sound = nil
            try? await center.add(UNNotificationRequest(
                identifier: "summary-\(Date().timeIntervalSince1970)", content: content, trigger: nil))
        }

        for message in fresh { seen.insert(message.id) }
        announced = seen
        await setBadge(unreadTotal)
        return fresh.count
    }

    /// Marks mail as already-announced without notifying - used on first run so
    /// a fresh install does not fire a banner for every message in the inbox.
    func suppress(_ messages: [MailMessage]) {
        var seen = announced
        for message in messages { seen.insert(message.id) }
        announced = seen
    }

    var hasAnnouncedAnything: Bool { !announced.isEmpty }

    /// Sets the application icon badge count.
    func updateBadge(_ count: Int) async {
        await setBadge(count)
    }

    private func setBadge(_ count: Int) async {
        try? await UNUserNotificationCenter.current().setBadgeCount(max(0, count))
    }
}
