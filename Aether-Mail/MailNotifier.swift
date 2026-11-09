import Foundation
import UIKit
import UserNotifications
import EmailKit

/// Thread-safe deduplication state shared between `@MainActor` sync paths and
/// `nonisolated` `UNUserNotificationCenterDelegate` callbacks under Swift 6.
private final class NotificationDedupState: @unchecked Sendable {
    private let lock = NSLock()
    private var inFlightIDs: Set<String> = []
    private var locallyAnnouncedIDs: Set<String> = []
    private var remotelyAnnouncedIDs: Set<String> = []
    private var recentRemoteSubjects: [String: Date] = [:]

    func recordRemote(keys: [String], subject: String?) {
        lock.lock()
        defer { lock.unlock() }
        for k in keys where !k.isEmpty {
            inFlightIDs.insert(k)
            remotelyAnnouncedIDs.insert(k)
        }
        if let s = subject?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(), !s.isEmpty {
            recentRemoteSubjects[s] = Date()
        }
    }

    func shouldPresentRemote(reqID: String, collapseID: String?, emailUIDKey: String?, subject: String?) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if locallyAnnouncedIDs.contains(reqID) || remotelyAnnouncedIDs.contains(reqID) {
            return false
        }
        if let cid = collapseID, !cid.isEmpty,
           (locallyAnnouncedIDs.contains(cid) || remotelyAnnouncedIDs.contains(cid)) {
            return false
        }
        if let key = emailUIDKey, !key.isEmpty,
           (locallyAnnouncedIDs.contains(key) || remotelyAnnouncedIDs.contains(key)) {
            return false
        }
        remotelyAnnouncedIDs.insert(reqID)
        inFlightIDs.insert(reqID)
        if let cid = collapseID, !cid.isEmpty {
            remotelyAnnouncedIDs.insert(cid)
            inFlightIDs.insert(cid)
        }
        if let key = emailUIDKey, !key.isEmpty {
            remotelyAnnouncedIDs.insert(key)
            inFlightIDs.insert(key)
        }
        if let s = subject?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(), !s.isEmpty {
            recentRemoteSubjects[s] = Date()
        }
        return true
    }

    func shouldPresentLocal(reqID: String, collapseID: String?) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if remotelyAnnouncedIDs.contains(reqID) { return false }
        if let cid = collapseID, !cid.isEmpty, remotelyAnnouncedIDs.contains(cid) { return false }
        return true
    }

    func isAlreadyClaimed(msgID: String, collapseID: String, subject: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if inFlightIDs.contains(msgID) || inFlightIDs.contains(collapseID)
            || remotelyAnnouncedIDs.contains(msgID) || remotelyAnnouncedIDs.contains(collapseID)
            || locallyAnnouncedIDs.contains(msgID) || locallyAnnouncedIDs.contains(collapseID) {
            return true
        }
        let subjKey = subject.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if !subjKey.isEmpty, let remoteDate = recentRemoteSubjects[subjKey],
           Date().timeIntervalSince(remoteDate) < 180 {
            return true
        }
        return false
    }

    func claimLocal(keys: [String]) {
        lock.lock()
        defer { lock.unlock() }
        for k in keys where !k.isEmpty {
            inFlightIDs.insert(k)
            locallyAnnouncedIDs.insert(k)
        }
    }

    func markSuppressed(keys: [String]) {
        lock.lock()
        defer { lock.unlock() }
        for k in keys where !k.isEmpty {
            inFlightIDs.insert(k)
        }
    }
}

/// New-mail notifications.
///
/// Coordinates remote APNs notifications (from `aether_mail_push_bridge.py`) with
/// on-device local notifications (`BGAppRefreshTask` / IMAP IDLE fallback) so every
/// incoming email produces strictly ONE user-facing notification banner.
@MainActor
final class MailNotifier: NSObject, UNUserNotificationCenterDelegate {
    static let shared = MailNotifier()

    /// Message ids and collapse keys already announced, so a re-sync or push-wake
    /// of the same mail is silent. Persisted across app launches.
    private let seenKey = "MailNotifier.announced"
    private nonisolated let dedup = NotificationDedupState()

    private var announced: Set<String> {
        get { Set(UserDefaults.standard.stringArray(forKey: seenKey) ?? []) }
        set {
            let trimmed = Array(newValue.suffix(3000))
            UserDefaults.standard.set(trimmed, forKey: seenKey)
        }
    }

    private override init() {
        super.init()
        UNUserNotificationCenter.current().delegate = self
    }

    /// Deterministic cross-device notification identifier shared with `aether_mail_push_bridge.py`.
    func collapseID(for message: MailMessage, accounts: [MailAccount]) -> String {
        if let acct = accounts.first(where: { $0.id == message.accountID }) {
            let email = acct.emailAddress.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
            return "\(email):\(message.folderPath):\(message.uid)"
        }
        return message.id
    }

    private nonisolated static func extractMetadata(from userInfo: [AnyHashable: Any]) -> (collapseID: String?, emailUIDKey: String?, email: String?, folder: String, uid: UInt32?, subject: String?) {
        let folder = (userInfo["folderPath"] as? String) ?? "INBOX"
        let rawEmail = (userInfo["accountEmail"] as? String)?.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        let cid = userInfo["collapseId"] as? String

        var uidVal: UInt32?
        if let u = userInfo["uid"] as? UInt32 {
            uidVal = u
        } else if let u = userInfo["uid"] as? Int, u > 0 {
            uidVal = UInt32(u)
        } else if let s = userInfo["uid"] as? String, let u = UInt32(s) {
            uidVal = u
        }

        let emailUIDKey: String? = if let email = rawEmail, let uid = uidVal {
            "\(email):\(folder):\(uid)"
        } else {
            nil
        }

        var subj = (userInfo["subject"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        if (subj == nil || subj?.isEmpty == true),
           let aps = userInfo["aps"] as? [String: Any],
           let alert = aps["alert"] as? [String: Any],
           let body = (alert["body"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
           !body.isEmpty {
            subj = body.components(separatedBy: .newlines).first ?? body
        }

        return (cid, emailUIDKey, rawEmail, folder, uidVal, subj)
    }

    /// Records a remote APNs payload so subsequent or concurrent local syncs never
    /// fire a second local notification for the same email.
    func recordRemoteNotification(userInfo: [AnyHashable: Any], accounts: [MailAccount]) {
        let meta = Self.extractMetadata(from: userInfo)
        var keys: [String] = []
        if let cid = meta.collapseID, !cid.isEmpty { keys.append(cid) }
        if let eKey = meta.emailUIDKey, !eKey.isEmpty { keys.append(eKey) }
        if let email = meta.email, let uid = meta.uid,
           let acct = accounts.first(where: { $0.emailAddress.lowercased() == email }) {
            keys.append("\(acct.id.uuidString):\(meta.folder):\(uid)")
        }

        dedup.recordRemote(keys: keys, subject: meta.subject)
        if !keys.isEmpty {
            var seen = announced
            for k in keys { seen.insert(k) }
            announced = seen
        }
    }

    /// Presents banners, sounds and badges while deduplicating remote vs. local notifications.
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        let reqID = notification.request.identifier
        let isRemote = notification.request.trigger is UNPushNotificationTrigger
        let meta = Self.extractMetadata(from: notification.request.content.userInfo)
        let fallbackSubj = notification.request.content.body.components(separatedBy: .newlines).first

        if isRemote {
            let allow = dedup.shouldPresentRemote(
                reqID: reqID,
                collapseID: meta.collapseID,
                emailUIDKey: meta.emailUIDKey,
                subject: meta.subject ?? fallbackSubj
            )
            completionHandler(allow ? [.banner, .sound, .badge, .list] : [])
        } else {
            let allow = dedup.shouldPresentLocal(reqID: reqID, collapseID: meta.collapseID)
            completionHandler(allow ? [.banner, .sound, .badge, .list] : [])
        }
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let reqID = response.notification.request.identifier
        let meta = Self.extractMetadata(from: response.notification.request.content.userInfo)
        var keys = [reqID]
        if let cid = meta.collapseID { keys.append(cid) }
        if let eKey = meta.emailUIDKey { keys.append(eKey) }
        dedup.recordRemote(keys: keys, subject: meta.subject)
        completionHandler()
    }

    /// Asks once. A refusal is remembered by the system, so this is safe to call
    /// on every launch.
    func requestAuthorization() async {
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        _ = try? await center.requestAuthorization(options: [.alert, .sound, .badge])
    }

    var isAuthorized: Bool {
        get async {
            let settings = await UNUserNotificationCenter.current().notificationSettings()
            return settings.authorizationStatus == .authorized
                || settings.authorizationStatus == .provisional
        }
    }

    /// Announces unread mail that has not been announced before (neither locally nor via APNs).
    @discardableResult
    func announce(
        _ messages: [MailMessage],
        unreadTotal: Int,
        accounts: [MailAccount] = [],
        blockedAddresses: Set<String> = [],
        blockedChecker: ((MailMessage) -> Bool)? = nil
    ) async -> Int {
        // ALWAYS update the application icon badge first, regardless of banner authorization!
        await setBadge(unreadTotal)

        guard await isAuthorized else { return 0 }

        let activeAccounts = accounts.isEmpty ? MailStore.shared.accounts : accounts
        let center = UNUserNotificationCenter.current()

        // Inspect notifications already sitting in iOS Notification Center (including
        // remote APNs pushes delivered while the app was locked/suspended).
        let delivered = await center.deliveredNotifications()
        for item in delivered {
            let id = item.request.identifier
            if item.request.trigger is UNPushNotificationTrigger {
                dedup.recordRemote(keys: [id], subject: item.request.content.body.components(separatedBy: .newlines).first)
                recordRemoteNotification(userInfo: item.request.content.userInfo, accounts: activeAccounts)
            } else {
                dedup.markSuppressed(keys: [id])
            }
        }

        var seen = announced

        // Filter to genuinely unannounced messages, checking both message.id and APNs collapseID.
        let fresh = messages
            .filter { m in
                let cid = collapseID(for: m, accounts: activeAccounts)
                guard m.isUnread else { return false }
                if seen.contains(m.id) || seen.contains(cid)
                    || dedup.isAlreadyClaimed(msgID: m.id, collapseID: cid, subject: m.subject) {
                    seen.insert(m.id)
                    seen.insert(cid)
                    return false
                }
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
            announced = seen
            await setBadge(unreadTotal)
            return 0
        }

        // Claim all fresh IDs BEFORE awaiting `center.add` so concurrent callers cannot double-post.
        var claimedKeys: [String] = []
        for message in fresh {
            let cid = collapseID(for: message, accounts: activeAccounts)
            seen.insert(message.id)
            seen.insert(cid)
            claimedKeys.append(message.id)
            claimedKeys.append(cid)
        }
        dedup.claimLocal(keys: claimedKeys)
        announced = seen

        let shown = Array(fresh.prefix(5))

        for message in shown {
            let cid = collapseID(for: message, accounts: activeAccounts)
            let content = UNMutableNotificationContent()
            content.title = message.from.first?.shortLabel ?? "New mail"
            content.body = message.subject.isEmpty ? "(no subject)" : message.subject
            content.sound = .default
            content.threadIdentifier = message.accountID.uuidString
            content.userInfo = [
                "messageID": message.id,
                "collapseId": cid,
                "uid": message.uid
            ]
            try? await center.add(UNNotificationRequest(
                identifier: cid, content: content, trigger: nil))
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

        await setBadge(unreadTotal)
        return fresh.count
    }

    /// Marks mail as already-announced without notifying — used on first run, foreground
    /// refreshes, and APNs push wakes where the remote alert banner was already shown.
    func suppress(_ messages: [MailMessage], accounts: [MailAccount] = []) {
        let activeAccounts = accounts.isEmpty ? MailStore.shared.accounts : accounts
        var seen = announced
        var keys: [String] = []
        for message in messages {
            let cid = collapseID(for: message, accounts: activeAccounts)
            seen.insert(message.id)
            seen.insert(cid)
            keys.append(message.id)
            keys.append(cid)
        }
        dedup.markSuppressed(keys: keys)
        announced = seen
    }

    var hasAnnouncedAnything: Bool { !announced.isEmpty }

    /// Sets the application icon badge count across UNUserNotificationCenter and UIKit.
    func updateBadge(_ count: Int) async {
        await setBadge(count)
    }

    private func setBadge(_ count: Int) async {
        let clamped = max(0, count)
        try? await UNUserNotificationCenter.current().setBadgeCount(clamped)
        UIApplication.shared.applicationIconBadgeNumber = clamped
    }

    /// Sends an immediate test notification for user diagnostics.
    func sendTestNotification() async throws {
        let center = UNUserNotificationCenter.current()
        let settings = await center.notificationSettings()
        guard settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional else {
            throw NSError(domain: "MailNotifier", code: 1, userInfo: [NSLocalizedDescriptionKey: "Notifications are disabled in iOS Settings."])
        }
        let content = UNMutableNotificationContent()
        content.title = "Aether Mail"
        content.body = "Notifications are working! Background refresh is active."
        content.sound = .default
        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: 1, repeats: false)
        let request = UNNotificationRequest(identifier: "test-\(UUID().uuidString)", content: content, trigger: trigger)
        try await center.add(request)
    }

    /// Human-readable status for settings display.
    func authorizationStatusDescription() async -> String {
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        switch settings.authorizationStatus {
        case .authorized: return "Allowed"
        case .provisional: return "Provisional"
        case .denied: return "Disabled in iOS Settings"
        case .notDetermined: return "Not Determined"
        case .ephemeral: return "Ephemeral"
        @unknown default: return "Unknown"
        }
    }

    /// Stores the remote APNs device token and persists it to disk for the bridge.
    func registerAPNSToken(_ token: String) async {
        UserDefaults.standard.set(token, forKey: "AetherMail.apnsDeviceToken")
        if let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first {
            let url = docs.appendingPathComponent("apns_token.txt")
            try? token.write(to: url, atomically: true, encoding: .utf8)
        }
    }

    var apnsToken: String? {
        UserDefaults.standard.string(forKey: "AetherMail.apnsDeviceToken")
    }
}
