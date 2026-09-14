import Foundation
import EmailKit

/// What the app thinks about one message.
///
/// Deliberately heuristic first, AI second. The Simulator often has no
/// FoundationModels, and a lab you cannot run is not a lab - so every experiment
/// works from signals that are always available (sender shape, subject wording,
/// headers, recency), and the on-device model only sharpens what is already
/// there. It also means scoring is instant and deterministic while you are
/// flipping between views.
struct MailSignal: Sendable, Equatable {
    var urgency: Int          // 0-100
    var category: MailCategory
    var needsReply: Bool
    var isCommitment: Bool    // the owner promised something
    /// A machine sent it. Structural, not a guess about wording - and the only
    /// reliable way to know a reply would go nowhere.
    var isAutomated: Bool
    var reason: String        // why it scored this way, shown in the UI

    static let neutral = MailSignal(urgency: 20, category: .other,
                                    needsReply: false, isCommitment: false,
                                    isAutomated: false, reason: "")
}

enum MailCategory: String, CaseIterable, Sendable {
    case needsYou   = "Needs You"
    case money      = "Money"
    case shipping   = "Shipping"
    case security   = "Security"
    case calendar   = "Calendar"
    case newsletter = "Reading"
    case social     = "Social"
    case other      = "Everything Else"

    var icon: String {
        switch self {
        case .needsYou:   return "person.crop.circle.badge.exclamationmark"
        case .money:      return "creditcard"
        case .shipping:   return "shippingbox"
        case .security:   return "lock.shield"
        case .calendar:   return "calendar"
        case .newsletter: return "newspaper"
        case .social:     return "bubble.left.and.bubble.right"
        case .other:      return "tray"
        }
    }
}

enum MailInsight {

    private static func hits(_ haystack: String, _ needles: [String]) -> Bool {
        needles.contains { haystack.contains($0) }
    }

    /// Scores a message from what is always known about it.
    static func signal(for m: MailMessage, bodyText: String? = nil) -> MailSignal {
        let subject = m.subject.lowercased()
        let sender = (m.from.first?.address ?? "").lowercased()
        let senderName = (m.from.first?.name ?? "").lowercased()
        let body = (bodyText ?? "").lowercased().prefix(1200).description
        let hay = subject + " " + body

        // A machine wrote it. The single strongest signal there is, and it is
        // structural rather than a guess about wording.
        // Separators vary and that matters: a list of literal spellings missed
        // "no_reply@email.apple.com" - underscore rather than hyphen - and the
        // draft queue happily wrote a reply to Apple's 2FA robot. Normalise the
        // separators first, then match.
        let flatSender = sender.replacingOccurrences(of: "_", with: "-")
            .replacingOccurrences(of: ".", with: "-")
        let automated = hits(flatSender, ["no-reply", "noreply", "donotreply", "do-not-reply",
                                          "notifications@", "notification@", "mailer", "bounce",
                                          "newsletter", "updates@", "info@", "support@",
                                          "alerts@", "auto-", "automated"])

        var urgency = 25
        var reasons: [String] = []

        // Direct address beats broadcast: one recipient means it was meant for
        // this person specifically.
        if m.to.count == 1 && m.cc.isEmpty && !automated {
            urgency += 20; reasons.append("sent only to you")
        }
        if subject.hasPrefix("re:") || subject.hasPrefix("fwd:") {
            urgency += 15; reasons.append("part of a thread")
        }
        if hits(hay, ["urgent", "asap", "immediately", "action required", "past due",
                      "final notice", "expires today", "last chance to respond"]) {
            urgency += 30; reasons.append("says it is urgent")
        }
        if hits(hay, ["deadline", "due by", "by tomorrow", "by friday", "before end of day", "eod"]) {
            urgency += 20; reasons.append("has a deadline")
        }
        if subject.contains("?") {
            urgency += 12; reasons.append("asks a question")
        }
        if m.hasAttachments { urgency += 5 }
        if automated { urgency -= 25 }
        if hits(hay, ["unsubscribe", "view in browser", "manage preferences", "you are receiving this"]) {
            urgency -= 20
        }

        // Recency: today's mail matters more than last week's, and it decays
        // rather than falling off a cliff.
        if let date = m.date {
            let hours = Date().timeIntervalSince(date) / 3600
            if hours < 3 { urgency += 15 }
            else if hours < 24 { urgency += 8 }
            else if hours > 24 * 7 { urgency -= 10 }
        }
        if !m.isUnread { urgency -= 15 }

        let category: MailCategory
        if hits(hay, ["verification code", "security alert", "sign-in", "sign in attempt",
                      "password", "two-factor", "2fa", "suspicious"]) {
            category = .security
        } else if hits(hay, ["invoice", "receipt", "payment", "statement", "billing",
                             "subscription renew", "charged", "refund", "balance due"]) {
            category = .money
        } else if hits(hay, ["shipped", "tracking", "out for delivery", "delivered",
                             "your order", "dispatch"]) {
            category = .shipping
        } else if hits(hay, ["invitation", "invite", "meeting", "calendar", "rsvp", "scheduled for"]) {
            category = .calendar
        } else if hits(hay, ["mentioned you", "commented", "followed you", "friend request",
                             "tagged you", "liked your"]) {
            category = .social
        } else if automated || hits(hay, ["newsletter", "digest", "weekly roundup", "this week in"]) {
            category = .newsletter
        } else if urgency >= 55 {
            category = .needsYou
        } else {
            category = .other
        }

        // Someone asked something of a human, and a human has not answered.
        let needsReply = !automated && m.isUnread &&
            (subject.contains("?") || hits(hay, ["can you", "could you", "let me know",
                                                 "thoughts?", "what do you think",
                                                 "please confirm", "waiting on", "following up"]))
        if needsReply { urgency += 10; reasons.append("waiting on a reply") }

        // The owner's own promises, which are the easiest thing in a mailbox to
        // lose track of.
        let isCommitment = hits(hay, ["i'll send", "i will send", "i'll get back",
                                      "i'll take a look", "i'll follow up", "i'll have it"])

        if reasons.isEmpty { reasons.append(automated ? "automated sender" : "no strong signals") }

        return MailSignal(
            urgency: max(0, min(100, urgency)),
            category: category,
            needsReply: needsReply,
            isCommitment: isCommitment,
            isAutomated: automated,
            reason: reasons.prefix(2).joined(separator: " · ")
        )
    }

    /// Optional second pass on the few messages that actually matter. Costly
    /// enough that it is never run over a whole mailbox.
    static func refine(_ m: MailMessage, body: String) async -> String? {
        guard MailAI.isAvailable else { return nil }
        return await MailAI.summarize(subject: m.subject,
                                      from: m.from.first?.shortLabel ?? "unknown",
                                      body: body)
    }
}
