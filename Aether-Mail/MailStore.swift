import Foundation
import Observation
import EmailKit

/// App state for Aether Mail. Holds accounts + messages using the shared EmailKit
/// models, so the iOS UI and the macOS Courier client speak the exact same types.
///
/// Milestone 1 (this scaffold): the UI shell renders EmailKit `MailMessage`s.
/// Next milestone: live IMAP over `EmailKit.IMAPClient` — connect → login →
/// select("INBOX") → fetchSummaries, and reading via fetchRawMessage → MIME parse,
/// mirroring Aether-Courier's `MailService`. AI comes after that (on-device →
/// Mac → cloud), with private endpoints kept out of any public export.
@MainActor @Observable
final class MailStore {
    var messages: [MailMessage] = []
    var selectedID: String?
    var isAddingAccount = false

    /// Inbox newest-first for the list.
    var inbox: [MailMessage] {
        messages.sorted { ($0.date ?? .distantPast) > ($1.date ?? .distantPast) }
    }
    var unreadCount: Int { messages.filter(\.isUnread).count }

    init() { seedPreview() }

    func markRead(_ m: MailMessage) {
        guard let i = messages.firstIndex(where: { $0.id == m.id }) else { return }
        messages[i].flags.insert(.seen)
    }

    // MARK: - Placeholder data (until the live IMAP path lands)

    private func seedPreview() {
        let account = UUID()
        func msg(_ uid: UInt32, _ name: String, _ addr: String, _ subject: String,
                 _ snippet: String, minsAgo: Double, unread: Bool) -> MailMessage {
            MailMessage(uid: uid, folderPath: "INBOX", accountID: account,
                        subject: subject,
                        from: [MailAddress(name: name, address: addr)],
                        date: Date().addingTimeInterval(-minsAgo * 60),
                        flags: unread ? [] : [.seen],
                        snippet: snippet)
        }
        messages = [
            msg(5, "Orbit CI", "builds@orbit-ci.dev", "Your release build passed ✓",
                "v0.1.8 signed & notarized — the .dmg is ready to download.", minsAgo: 8, unread: true),
            msg(4, "Ledger", "receipts@ledger.app", "Your July statement is ready",
                "Receipt · $12.00 · view or download your invoice.", minsAgo: 55, unread: true),
            msg(3, "Vela Design", "aisha@vela.design", "Q3 Brand Kit shared with you",
                "You now have access to the shared library.", minsAgo: 140, unread: false),
            msg(2, "Northwind Travel", "trips@northwind.travel", "Itinerary: SFO → LHR",
                "Check-in opens 24 hours before departure.", minsAgo: 1500, unread: false),
            msg(1, "Cadence", "digest@cadence.app", "Weekly digest — 3 threads need you",
                "A summary of what moved this week across your projects.", minsAgo: 1600, unread: false),
        ]
    }
}
