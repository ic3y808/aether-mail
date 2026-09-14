import Foundation
import EmailKit

/// A fixed mailbox for evaluating the Lab's reading models.
///
/// The Simulator has no mail account, and configuring a real one there is both
/// awkward and a bad idea. Worse, judging a ranking UI against whatever happens
/// to be in a live inbox is unreliable - you cannot tell a good ranker from a
/// quiet week. This set is deliberately built to exercise every signal: a
/// genuine deadline, a bill, a shipping notice, a security code, a newsletter,
/// a question waiting on a reply, and a promise the owner made.
enum LabSampleMail {

    /// Stable ids, so the same fake account survives a view redraw.
    private static let demoAccountID = UUID(uuidString: "A11A0000-0000-4000-8000-000000000001")!
    private static let demoWorkID = UUID(uuidString: "A11A0000-0000-4000-8000-000000000002")!

    /// Accounts for demo mode. Plausible but obviously not real addresses -
    /// marketing footage should never show someone's actual mailbox, and it
    /// should not imply an endorsement by a real company either.
    static func accounts() -> [MailAccount] {
        [
            MailAccount(id: demoAccountID, provider: .icloud,
                        emailAddress: "jesse@example.com", displayName: "Personal",
                        imap: ProviderCatalog.imap(for: .icloud),
                        smtp: ProviderCatalog.smtp(for: .icloud),
                        credentialRef: "demo", sortIndex: 0),
            MailAccount(id: demoWorkID, provider: .gmail,
                        emailAddress: "jesse@yampalabs.example", displayName: "Work",
                        imap: ProviderCatalog.imap(for: .gmail),
                        smtp: ProviderCatalog.smtp(for: .gmail),
                        credentialRef: "demo", sortIndex: 1)
        ]
    }

    static func inbox() -> [MailMessage] {
        let account = demoAccountID
        var uid: UInt32 = 1

        func make(_ from: (String, String), _ subject: String, _ body: String,
                  hoursAgo: Double, unread: Bool = true,
                  to: [(String, String)] = [("You", "you@example.com")],
                  cc: [(String, String)] = [],
                  attachments: Bool = false) -> MailMessage {
            defer { uid += 1 }
            var m = MailMessage(
                uid: uid,
                folderPath: "INBOX",
                accountID: account,
                messageID: "<lab-\(uid)@aether>",
                subject: subject,
                from: [MailAddress(name: from.0, address: from.1)],
                to: to.map { MailAddress(name: $0.0, address: $0.1) },
                cc: cc.map { MailAddress(name: $0.0, address: $0.1) },
                date: Date().addingTimeInterval(-hoursAgo * 3600),
                flags: unread ? [] : [.seen],
                snippet: body,
                hasAttachments: attachments,
                sizeBytes: body.count
            )
            m.folderPath = "INBOX"
            return m
        }

        return [
            make(("Dana Whitlock", "dana@northgate-legal.com"),
                 "Re: signature needed before Friday",
                 "Hi - the lease amendment still needs your signature. The deadline is Friday and the landlord will not extend again. Can you confirm today?",
                 hoursAgo: 1.5, attachments: true),

            make(("Marcus Reid", "marcus@reid-fabrication.co"),
                 "Quick question on the bracket tolerances?",
                 "What tolerance did you want on the mounting brackets? Let me know and I'll get the run started.",
                 hoursAgo: 4),

            make(("Chase for Business", "no-reply@alerts.chase.com"),
                 "Your statement is ready - payment due in 6 days",
                 "Your December statement is available. Balance due $2,184.30. Autopay is not enabled on this account.",
                 hoursAgo: 9),

            make(("Apple", "no_reply@email.apple.com"),
                 "Your Apple ID verification code",
                 "Your verification code is 448192. If you did not request a sign-in, secure your account immediately.",
                 hoursAgo: 0.4),

            make(("UPS", "auto-notify@ups.com"),
                 "Your package is out for delivery",
                 "Tracking 1Z999AA10123456784 is out for delivery and arriving today by 8:00 PM.",
                 hoursAgo: 2),

            make(("You", "you@example.com"),
                 "Re: revised quote",
                 "Thanks for the numbers. I'll send over the revised quote tomorrow morning once I've checked the material costs.",
                 hoursAgo: 26, unread: false,
                 to: [("Priya Nair", "priya@lumenworks.io")]),

            make(("Priya Nair", "priya@lumenworks.io"),
                 "Following up - still waiting on that quote",
                 "Just following up on the revised quote. Could you confirm when I should expect it? We need to lock the budget this week.",
                 hoursAgo: 6),

            make(("Stripe", "receipts@stripe.com"),
                 "Receipt for your payment - $49.00",
                 "You paid $49.00 to Figma. This receipt is for your records. No action needed.",
                 hoursAgo: 30, unread: false),

            make(("The Browser Company", "hello@thebrowser.company"),
                 "This week in browsers: tabs, and why we keep redesigning them",
                 "A weekly roundup of what shipped. Unsubscribe or manage preferences at any time. View in browser.",
                 hoursAgo: 20),

            make(("Hacker Newsletter", "newsletter@hackernewsletter.com"),
                 "Issue #742 - the best of Hacker News this week",
                 "The top stories of the week, curated. You are receiving this because you subscribed. Unsubscribe.",
                 hoursAgo: 44, unread: false),

            make(("Colorado Registered Agent", "notices@coloradoregisteredagent.com"),
                 "ACTION REQUIRED: annual report past due",
                 "Your annual report is past due. File immediately to avoid administrative dissolution of the entity.",
                 hoursAgo: 52),

            make(("Sam Okafor", "sam@okafor.studio"),
                 "dinner thursday?",
                 "Are you free Thursday evening? Thinking about that ramen place on 12th. Let me know.",
                 hoursAgo: 11),

            make(("LinkedIn", "notifications-noreply@linkedin.com"),
                 "Marcus and 3 others commented on your post",
                 "See what people are saying about your recent post.",
                 hoursAgo: 15, unread: false),

            make(("GitHub", "notifications@github.com"),
                 "[ic3y808/aether-mail] CI passed on main",
                 "All checks have passed for commit 6069792.",
                 hoursAgo: 3, unread: false),
        ]
    }
}
